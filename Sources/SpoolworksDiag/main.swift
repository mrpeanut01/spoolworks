import Foundation
import SpoolworksCore

// Headless diagnostic CLI for hardware-in-the-loop verification.
// Deliberately separate from the GUI so reader problems can be diagnosed without launching the app.

func usage() {
    print("""
    spooldiag — CFS-RFID hardware diagnostics

      spooldiag readers            List connected PC/SC readers
      spooldiag watch              Wait for a tag and report its type and UID
      spooldiag dump [--keys HEX,HEX...]
                                Dump every readable sector (default key FFFFFFFFFFFF)
      spooldiag keys               Probe which keys and key types open each sector
      spooldiag read               Read and decode a spool tag
      spooldiag write [--material 01001] [--color 00A651] [--length 1kg]
                   [--serial 000001] [--printer-type ""] [--confirm]
                   [--allow-key-write]
                                Write a spool record. Dry run unless --confirm.
                                A blank tag also needs --allow-key-write, which
                                rewrites its sector keys irreversibly.

      spooldiag boxinfo --host ADDR [--family k2|k1|hi|i7] [--raw]
                                Read the CFS state from the printer over SSH and
                                print every slot. Password comes from the
                                SPOOLWORKS_SSH_PASSWORD environment variable, so
                                it never reaches the process list or the shell
                                history. Read-only.

    Only `write --confirm` modifies a tag; everything else is read-only.
    """)
}

func openContext() -> PCSCContext? {
    do { return try PCSCContext() }
    catch { print("PC/SC unavailable: \(error.localizedDescription)"); return nil }
}

/// Polls for a card, since macOS PC/SC gives us no usable direct-connect notification path.
func waitForCard(_ ctx: PCSCContext, timeout: TimeInterval = 60) -> CardSession? {
    let deadline = Date().addingTimeInterval(timeout)
    var announced = false
    while Date() < deadline {
        if let session = try? ctx.connectToAnyCard() { return session }
        if !announced {
            print("Waiting for a tag — place it on the reader…")
            announced = true
        }
        usleep(300_000)
    }
    return nil
}

func describe(_ session: CardSession) -> (CardType, [UInt8]) {
    let atr = (try? session.atr()) ?? []
    let type = CardType.from(atr: atr)
    let card = MifareClassicCard(transport: session)
    let uid = (try? card.readUID()) ?? []
    print("Reader:  \(session.readerName)")
    print("ATR:     \(atr.hexStringSpaced)")
    print("Type:    \(type)")
    print("UID:     \(uid.hexString)")
    return (type, uid)
}

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"

// Every command runs inside this handler: an uncaught throw at top level becomes a Swift
// fatalError with a stack trace, which is useless to someone holding a tag against a reader.
do {
switch command {
case "readers":
    guard let ctx = openContext() else { exit(1) }
    // Group slots into physical devices: an ACR1552 exposes two PC/SC slots but is one reader.
    let devices = (try? ctx.readerDevices()) ?? []
    if devices.isEmpty {
        print("No readers connected.")
        exit(2)
    }
    for (i, d) in devices.enumerated() {
        print("[\(i)] \(d.displayName)")
        if d.hasMultipleSlots {
            print("      \(d.slotNames.count) slots on this device: \(d.slotNames.joined(separator: ", "))")
        }
    }

case "watch":
    guard let ctx = openContext() else { exit(1) }
    guard let session = waitForCard(ctx) else { print("Timed out."); exit(2) }
    _ = describe(session)

case "dump":
    guard let ctx = openContext() else { exit(1) }
    guard let session = waitForCard(ctx) else { print("Timed out."); exit(2) }
    let (_, uid) = describe(session)

    // The sector key is derived from this tag's own UID, so it must be computed per tag
    // rather than supplied. Extra keys can still be passed for experimentation.
    var keys: [MifareKey] = []
    if !uid.isEmpty, let derived = try? CrealityCrypto.deriveSectorKey(uid: uid) {
        keys.append(derived)
        print("Derived: \(derived) (from UID via AES-128-ECB)")
    }
    keys.append(.default)
    if let idx = args.firstIndex(of: "--keys"), idx + 1 < args.count {
        keys += args[idx + 1].split(separator: ",").compactMap { MifareKey(hex: String($0)) }
    }
    print("Keys:    \(keys.map(\.description).joined(separator: ", "))\n")

    let card = MifareClassicCard(transport: session)
    let dumps = try card.dumpAll(keys: keys)
    for d in dumps {
        if d.authFailed {
            print("S\(String(format: "%02d", d.sector)): AUTH FAILED with all supplied keys")
            continue
        }
        print("S\(String(format: "%02d", d.sector)) [key\(d.keyType?.description ?? "?") \(d.key?.description ?? "")]:")
        for block in d.blocks.keys.sorted() {
            let data = d.blocks[block]!
            let marker = MifareClassicCard.isTrailer(block: block) ? "T" : " "
            print("   b\(String(format: "%02d", block))\(marker): \(data.hexStringSpaced)  |\(data.asciiDump)|")
        }
        // Sector 1 carries the AES-encrypted spool record; show the decrypted form too.
        if d.sector == 1 {
            let ordered = [4, 5, 6].compactMap { d.blocks[$0] }
            if ordered.count == 3, let plain = try? CrealityCrypto.decryptPayload(ordered) {
                print("   ── decrypted payload ──")
                print("   hex  : \(plain.hexString)")
                print("   ascii: |\(plain.asciiDump)|")
            }
        }
    }

case "keys":
    guard let ctx = openContext() else { exit(1) }
    guard let session = waitForCard(ctx) else { print("Timed out."); exit(2) }
    _ = describe(session)
    // Well-known MIFARE Classic keys, so an unknown tag can be characterised quickly.
    let candidates: [(String, String)] = [
        ("default",     "FFFFFFFFFFFF"),
        ("zeros",       "000000000000"),
        ("NFC Forum",   "D3F7D3F7D3F7"),
        ("MAD",         "A0A1A2A3A4A5"),
        ("Infineon",    "B0B1B2B3B4B5"),
        ("Transport A", "4D3A99C351DD"),
        ("Transport B", "1A982C7E459A"),
    ]
    let card = MifareClassicCard(transport: session)
    print("\nsector  keyA           keyB")
    for sector in 0..<MifareClassicCard.sectorCount {
        var hits: [MifareKeyType: String] = [:]
        for (name, hex) in candidates {
            guard let key = MifareKey(hex: hex) else { continue }
            try? card.loadKey(key)
            for type in MifareKeyType.allCases where hits[type] == nil {
                if (try? card.authenticate(block: MifareClassicCard.firstBlock(ofSector: sector),
                                           keyType: type)) == true {
                    hits[type] = name
                }
            }
        }
        let a = hits[.keyA] ?? "—"
        let b = hits[.keyB] ?? "—"
        print("  \(String(format: "%02d", sector))    \(a.padding(toLength: 14, withPad: " ", startingAt: 0)) \(b)")
    }

case "read":
    guard let ctx = openContext() else { exit(1) }
    guard let session = waitForCard(ctx) else { print("Timed out."); exit(2) }
    _ = describe(session)
    let service = try TagService(session: session)
    let result = try service.readTag()

    print("\nDerived key : \(result.derivedKey)")
    print("Opened with : key\(result.sector1KeyType) \(result.sector1Key)")
    print("Programmed  : \(result.isProgrammed ? "yes — carries the derived key" : "no — still on the factory key")")
    print("\nSector 1 decrypted:")
    print("  hex   : \(result.decryptedSector1.hexString)")
    print("  ascii : |\(result.decryptedSector1.asciiDump)|")

    if let record = result.record {
        print("\nParsed record:")
        print("  date          : \(record.date.month)\(record.date.day)\(record.date.year)")
        print("  vendorId      : \(record.vendorId)")
        print("  batch         : \(record.batch)")
        print("  filamentId    : \(record.filamentId)")
        print("  color         : \(record.color)")
        print("  filamentLength: \(record.filamentLength)")
        print("  serialNumber  : \(record.serialNumber)")
        print("  reserve       : \(record.reserve)")
        // Name the colour using the bundled table, ignoring the leading nibble.
        if let matcher = try? ColorMatcher.shared(),
           let name = try? matcher.nearestName(forHex: record.color) {
            print("  colour name   : \(name ?? "—")")
        }
    } else {
        print("\nNo valid record: \(result.recordError.map(String.init(describing:)) ?? "unknown")")
        print("(expected on a blank tag)")
    }
    if let pt = result.printerType {
        print("\nSector 2 printer type: \"\(pt)\"")
    } else {
        print("\nSector 2: unreadable")
    }

case "write":
    func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let materialId = arg("material") ?? "01001"
    let colorRGB = (arg("color") ?? "00A651").uppercased()
    let lengthArg = arg("length") ?? "1kg"
    let serial = arg("serial") ?? "000001"
    let printerType = arg("printer-type") ?? ""
    let confirmed = args.contains("--confirm")

    let lengths: [String: FilamentLength] = [
        "1kg": .kg1, "750g": .g750, "600g": .g600, "500g": .g500, "250g": .g250,
    ]
    guard let length = lengths[lengthArg.lowercased()] else {
        print("Unknown --length \(lengthArg). Use one of: \(lengths.keys.sorted().joined(separator: ", "))")
        exit(1)
    }

    let record = try SpoolRecord(materialId: materialId, colorRGB: colorRGB,
                                 filamentLength: length, serialNumber: serial)
    print("Record to write:")
    print("  encoded : \(record.encoded)")
    print("  material: \(materialId)   colour: #\(colorRGB)   length: \(lengthArg)   serial: \(serial)")
    let cipher = try CrealityCrypto.encryptPayload(record.paddedPayload)
    for (i, block) in cipher.enumerated() {
        print("  block \(4 + i): \(block.hexStringSpaced)")
    }

    guard confirmed else {
        print("\nDRY RUN — nothing was written. Re-run with --confirm to write to the tag.")
        exit(0)
    }

    guard let ctx = openContext() else { exit(1) }

    // A tag lifted off the antenna mid-write surfaces as noCard. That is a handling problem,
    // not a crash: keep the record, wait for the tag to come back, and try again.
    var result: TagWriteResult?
    var attempt = 0
    while result == nil && attempt < 5 {
        attempt += 1
        guard let session = waitForCard(ctx, timeout: 180) else { print("Timed out."); exit(2) }
        let (type, _) = describe(session)
        guard type.isSupported else {
            print("\nThis is a \(type). Only MIFARE Classic 1K carries the Creality layout.")
            exit(3)
        }
        do {
            let service = try TagService(session: session)
            result = try service.writeTag(record: record,
                                          printerType: printerType,
                                          allowTrailerWrite: args.contains("--allow-key-write"))
        } catch PCSCError.noCard {
            print("Tag left the reader mid-write — hold it flat and still (attempt \(attempt)/5).")
            usleep(700_000)
        }
    }
    guard let result else {
        print("\nGave up after \(attempt) attempts: the tag kept leaving the field.")
        exit(4)
    }

    print("\nWrite complete.")
    print("  already programmed: \(result.wasAlreadyProgrammed)")
    print("  wrote trailer     : \(result.wroteTrailer)")
    print("  wrote sector 2    : \(result.wroteSector2)")
    print("  blocks written    : \(result.writtenBlocks.keys.sorted())")
    let readable = result.backup.filter { !$0.authFailed }.count
    print("  backup captured   : \(readable)/16 sectors readable before writing")

case "boxinfo":
    // Verifies the whole CFS path end to end against real hardware: SSHTransport ->
    // PrinterService.boxInfo -> MaterialBoxInfo.decode. The GUI's Printer & CFS screen runs
    // exactly this, so a failure here is a failure there.
    func argument(_ name: String) -> String? {
        guard let i = args.firstIndex(of: "--" + name), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    guard let host = argument("host") else {
        print("boxinfo: --host is required")
        exit(2)
    }
    // Never from argv: anything on the command line is visible in `ps` to every user on the
    // machine, and lands in shell history.
    guard let password = ProcessInfo.processInfo.environment["SPOOLWORKS_SSH_PASSWORD"],
          !password.isEmpty else {
        print("boxinfo: set SPOOLWORKS_SSH_PASSWORD in the environment")
        exit(2)
    }
    let familyName = argument("family") ?? "k2"
    guard let printerType = PrinterType(rawValue: familyName) else {
        print("boxinfo: unknown family '\(familyName)'")
        exit(2)
    }
    let model = PrinterModel(profileName: printerType.displayName,
                             family: PrinterFamily(printerType))
    let configuration = SSHConfiguration(host: host, hostKeyPolicy: .acceptNew)
    let service = PrinterService(transport: SSHTransport(configuration: configuration,
                                                         password: password))

    // --raw prints the document untouched, for capturing a fixture or diagnosing a decode
    // failure against firmware we have not seen.
    let wantsRaw = args.contains("--raw")

    if wantsRaw {
        let transport = SSHTransport(configuration: configuration, password: password)
        let rawSemaphore = DispatchSemaphore(value: 0)
        var rawOutcome: Result<Data, Error>!
        Task {
            do { rawOutcome = .success(try await transport.download(from: model.materialBoxInfoPath)) }
            catch { rawOutcome = .failure(error) }
            rawSemaphore.signal()
        }
        rawSemaphore.wait()
        switch rawOutcome! {
        case let .failure(error):
            FileHandle.standardError.write(Data("Failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        case let .success(data):
            FileHandle.standardOutput.write(data)
            exit(0)
        }
    }

    print("Reading \(model.materialBoxInfoPath) from \(host)…")
    let semaphore = DispatchSemaphore(value: 0)
    var outcome: Result<MaterialBoxInfo, Error>!
    Task {
        do { outcome = .success(try await service.boxInfo(of: model)) }
        catch { outcome = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()

    switch outcome! {
    case let .failure(error):
        print("\nFailed: \(error.localizedDescription)")
        exit(1)
    case let .success(info):
        print("\nCFS state      : \(info.material.state.isEmpty ? "—" : info.material.state)")
        print("Auto refill    : \(info.material.isAutoRefillEnabled ? "on" : "off")")
        print("Boxes          : \(info.boxes.count)")
        print("Slots          : \(info.loadedSlotCount) loaded of \(info.slotCount)")

        for box in info.boxes {
            print("\n\(box.boxID)  \(box.state)  \(box.temperatureLabel)  \(box.humidityLabel)  fw \(box.version)")
            for slot in box.list {
                guard slot.isLoaded else {
                    print("  \(slot.label(in: box))  — empty —")
                    continue
                }
                let percent = slot.remainingPercent.map { "\(Int($0))%" } ?? "—"
                print("  \(slot.label(in: box))  \(percent.padding(toLength: 5, withPad: " ", startingAt: 0))"
                      + "  #\(slot.rgbHex)  \(slot.brand) \(slot.name) (\(slot.materialType))")
                print("        filament \(slot.filamentId) · vendor \(slot.venderId) · serial \(slot.serialNum)"
                      + " · len \(slot.filamentLen) → \(Spool.weightLabel(slot.netWeightGrams)) · \(slot.tagLabel)")
                if let identity = slot.identity, identity.hasGenericSerial {
                    print("        note: serial is the hard-coded 000001 — colour is carrying the identity")
                }
            }
        }

        if !info.material.sameMaterial.isEmpty {
            print("\nGrouped as identical:")
            for group in info.material.sameMaterial {
                print("  \(group.label)  \(group.materialType)  [\(group.slotsLabel)]"
                      + (group.isPartnered ? "  ← auto-refill partners" : ""))
            }
        }

        if let rack = info.rackMaterial {
            print("\nExternal holder: " + (rack.attach
                ? "\(rack.brand) \(rack.name) (\(rack.materialType)) #\(rack.rgbHex)"
                : "nothing mounted"))
        }

        // What the inventory would do with this reading.
        var inventory = SpoolInventory()
        let report = inventory.reconcile(with: info)
        print("\nReconciliation would: discover \(report.discovered.count),"
              + " update \(report.updated.count), unload \(report.unloaded.count)")
        for spool in inventory.active {
            print("  \(spool.remainingLabel.padding(toLength: 5, withPad: " ", startingAt: 0))"
                  + "  \(spool.location.description)  \(spool.label)")
        }
    }

default:
    usage()
}
} catch let error as PCSCError {
    print("\nReader error: \(error.localizedDescription)")
    exit(1)
} catch let error as TagError {
    print("\nTag error: \(error.description)")
    exit(1)
} catch {
    print("\nFailed: \(error.localizedDescription)")
    exit(1)
}
