import Foundation
@testable import SpoolworksCore
@testable import SpoolworksUI

// Adding one filament to a printer (D-013): the splice, the guarded write, the service that joins
// them, the websocket reply, and the offer shown after a verified write.

// MARK: - Bridging

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Drives async Core work from the synchronous harness, as `PrinterServiceTests` does.
private func runSync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<Result<T, Error>?>(nil)
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.value!.get()
}

private func errorFrom<T>(_ body: @escaping @Sendable () async throws -> T) -> Error? {
    do { _ = try runSync(body); return nil } catch { return error }
}

/// Pumps the main run loop until `body` finishes, because the model under test is `@MainActor`.
private func runOnMain(timeout: TimeInterval = 20, _ body: @escaping @MainActor () async -> Void) {
    let done = Box(false)
    Task { @MainActor in
        await body()
        done.value = true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !done.value && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

// MARK: - Fixtures

private enum FixtureError: Error {
    case missing(String)
}

private let k2Path = "/mnt/UDISK/creality/userdata/box/material_database.json"
private let backupPath = k2Path + ".spoolworks-bak"

/// A K2 Plus's own `material_database.json`: 98 records, three of them under id `00004`.
private func printerCapture() throws -> Data {
    guard let url = Bundle.module.url(forResource: "printer-k2plus-material_database", withExtension: "json") else {
        throw FixtureError.missing("printer-k2plus-material_database.json")
    }
    return try Data(contentsOf: url)
}

private func vendorCatalogue() throws -> [Filament] {
    guard let url = SpoolworksCoreResources.url(forResource: "vendor-k2", withExtension: "json") else {
        throw FixtureError.missing("vendor-k2.json")
    }
    return try MaterialDatabase.decode(try Data(contentsOf: url)).result.list
}

/// PolyTerra PLA from the shipped vendor catalogue — the record pushed to a real K2 Plus.
private func polyTerra() throws -> Filament {
    guard let record = try vendorCatalogue().first(where: { $0.id == "P1023" }) else {
        throw FixtureError.missing("P1023")
    }
    return record
}

private func hyperPLA(in capture: Data) throws -> Filament {
    guard let record = try MaterialDatabase.decode(capture).result.list.first(where: { $0.id == "01001" }) else {
        throw FixtureError.missing("01001")
    }
    return record
}

/// A one-record compact envelope, for the layouts a capture does not have.
private func compactEnvelope(withCount: Bool = true) -> Data {
    let count = withCount ? #""count":1,"# : ""
    return Data(#"{"code":0,"msg":"ok","reqId":"0","result":{"list":[{"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],"kvParam":{"filament_type":"PLA"},"base":{"id":"00001","brand":"Generic","name":"Generic PLA","alias":"","meterialType":"PLA"}}],\#(count)"version":"1784284303"}}"#.utf8)
}

private func lastRecord(in data: Data) -> [String: Any]? {
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let list = (root?["result"] as? [String: Any])?["list"] as? [[String: Any]]
    return list?.last
}

// MARK: - Splice

let printerMaterialSpliceTests = TestSuite(name: "Adding one filament to a printer's database (D-013)", cases: [

    test("appends the record and leaves every other byte as the printer wrote it") { t in
        let original = try printerCapture()
        let merged = try PrinterMaterialDocument.appending(try polyTerra(), to: original)

        var scanner = JSONLayoutScanner(bytes: [UInt8](original))
        let layout = try scanner.scan()
        guard let insertAt = t.unwrap(layout.lastElementEnd, "end of the last record") else { return }

        let before = [UInt8](original)
        let after = [UInt8](merged)
        t.expect(after.starts(with: before[..<insertAt]), "everything up to the end of the list is untouched")

        // The rest of the file is the printer's too, apart from the count.
        let tail = String(decoding: before[insertAt...], as: UTF8.self)
            .replacingOccurrences(of: "\"count\":98,", with: "\"count\":99,")
        let mergedText = String(decoding: after, as: UTF8.self)
        t.expect(tail.contains("\"count\":99,"), "the capture's count was found")
        t.expect(mergedText.hasSuffix(tail), "after the new record, only result.count differs")

        let inserted = String(decoding: after[insertAt..<(after.count - tail.utf8.count)], as: UTF8.self)
        t.expect(inserted.hasPrefix(",\n      {\n        \"engineVersion\":\"3.0.0\",\n        \"printerIntName\":\"F008\","),
                 "rendered in the capture's own layout")
        t.expect(inserted.hasSuffix("\n        }\n      }"), "closed at the capture's indentation")
    },

    test("keeps the printer's records, their order and its duplicate ids") { t in
        let original = try printerCapture()
        let merged = try PrinterMaterialDocument.appending(try polyTerra(), to: original)
        let before = try PrinterMaterialDocument.filamentIDs(in: original)
        let after = try PrinterMaterialDocument.filamentIDs(in: merged)
        t.equal(after, before + ["P1023"])
        t.expect(before.filter { $0 == "00004" }.count > 1, "the capture carries slicer-synced duplicates")
        t.equal(after.filter { $0 == "00004" }.count, before.filter { $0 == "00004" }.count)
    },

    test("the new record is shaped like the printer's: no provenance keys, an alias, its key order") { t in
        let merged = try PrinterMaterialDocument.appending(try polyTerra(), to: try printerCapture())
        guard let record = t.unwrap(lastRecord(in: merged), "appended record") else { return }
        t.equal(Set(record.keys), ["engineVersion", "printerIntName", "nozzleDiameter", "kvParam", "base"])
        let base = record["base"] as? [String: Any] ?? [:]
        t.equal(base["alias"] as? String, "")
        t.equal(base["name"] as? String, "PolyTerra PLA")
        // Key order only shows in the text.
        let text = String(decoding: merged, as: UTF8.self)
        t.expect(text.contains("\"base\":{\n          \"id\":\"P1023\",\n          \"brand\":\"Polymaker\",\n"
                               + "          \"name\":\"PolyTerra PLA\",\n          \"alias\":\"\",\n"
                               + "          \"meterialType\":\"PLA\","),
                 "base keys in the printer's order")
    },

    test("an id the printer already lists is refused") { t in
        let capture = try printerCapture()
        let existing = try hyperPLA(in: capture)
        t.throwsError(FilamentSpliceError.alreadyPresent(id: "01001")) {
            _ = try PrinterMaterialDocument.appending(existing, to: capture)
        }
    },

    test("a compact file stays compact, and its count follows the list") { t in
        let merged = try PrinterMaterialDocument.appending(try polyTerra(), to: compactEnvelope())
        let text = String(decoding: merged, as: UTF8.self)
        t.expect(!text.contains("\n"), "no line breaks introduced")
        t.expect(text.contains("\"count\":2,"), "count raised")
        t.equal(try PrinterMaterialDocument.filamentIDs(in: merged), ["00001", "P1023"])
    },

    test("a file with no result.count is not given one") { t in
        let merged = try PrinterMaterialDocument.appending(try polyTerra(), to: compactEnvelope(withCount: false))
        let root = try JSONSerialization.jsonObject(with: merged) as? [String: Any]
        let result = root?["result"] as? [String: Any]
        t.expect(result != nil && result?["count"] == nil, "no count key")
        t.equal(try PrinterMaterialDocument.filamentIDs(in: merged), ["00001", "P1023"])
    },

    test("anything but the printer's envelope is refused") { t in
        let filament = try polyTerra()
        t.throwsError("not JSON") { _ = try PrinterMaterialDocument.appending(filament, to: Data("nope".utf8)) }
        t.throwsError("no list") { _ = try PrinterMaterialDocument.appending(filament, to: Data(#"{"result":{}}"#.utf8)) }
        t.throwsError("list is not an array") {
            _ = try PrinterMaterialDocument.appending(filament, to: Data(#"{"result":{"list":{}}}"#.utf8))
        }
    },

    test("strings survive the renderer: quotes, backslashes, control characters, non-ASCII") { t in
        var filament = try polyTerra()
        filament.name = "Say \"hi\" \\ new\nline\ttab é ☃ \u{01}"
        let merged = try PrinterMaterialDocument.appending(filament, to: compactEnvelope())
        let base = lastRecord(in: merged)?["base"] as? [String: Any]
        t.equal(base?["name"] as? String, filament.name)
    },

    test("the checksum is the lower-case hex busybox md5sum prints") { t in
        t.equal(PrinterMaterialDocument.md5Hex(Data("abc".utf8)), "900150983cd24fb0d6963f7d28e17f72")
    },
])

// MARK: - Guarded replace

let sshReplaceTests = TestSuite(name: "SSHTransport guarded replace (D-013)", cases: [

    test("replace checks the file, keeps a backup, then stages like upload") { t in
        let operation = SSHOperation.replace(path: k2Path, byteCount: 502598,
                                             expectedMD5: "79650bd9b8f7211436d3c2cbda20022b",
                                             backupPath: backupPath)
        let destination = "'\(k2Path)'"
        let staging = "'\(k2Path).spoolworks-tmp'"
        let expected = "command -v md5sum >/dev/null 2>&1 || exit 4; "
            + "[ \"$(md5sum < \(destination) | cut -d ' ' -f 1)\" = '79650bd9b8f7211436d3c2cbda20022b' ] || exit 3; "
            + "{ cp -p \(destination) '\(backupPath)'"
            + " && cp -p \(destination) \(staging)"
            + " && cat > \(staging)"
            + " && [ \"$(wc -c < \(staging))\" -eq 502598 ]"
            + " && mv -f \(staging) \(destination)"
            + " && sync; }"
            + " || { rm -f \(staging); false; }"
        t.equal(operation.remoteCommand, expected)
    },

    test("exit 3 is a changed file, exit 4 no md5sum, a quiet exit 1 a short transfer") { t in
        let operation = SSHOperation.replace(path: k2Path, byteCount: 10,
                                             expectedMD5: String(repeating: "0", count: 32),
                                             backupPath: backupPath)
        func classify(_ status: Int32, _ stderr: String = "") -> PrinterTransportError? {
            SSHTransport.classify(operation: operation, exitStatus: status, stderr: stderr, host: "printer")
        }
        t.equal(classify(0), nil)
        t.equal(classify(3), .remoteFileChanged(path: k2Path))
        if case .remoteCommandFailed(exitStatus: 4, message: _)? = classify(4) {} else {
            t.expect(false, "exit 4 should say md5sum is missing, got \(String(describing: classify(4)))")
        }
        t.equal(classify(1, "\n"), .uploadIncomplete(path: k2Path))
        t.equal(classify(255, "root@printer: Permission denied (password)."), .authenticationFailed)
    },

    test("a checksum that is not MD5 is refused before ssh runs") { t in
        let transport = SSHTransport(configuration: SSHConfiguration(host: "printer",
                                                                     sshExecutablePath: "/nonexistent/ssh"),
                                     password: "unused")
        let error = errorFrom {
            try await transport.replace(data: Data(), at: k2Path, expectingMD5: "not-md5", backupPath: backupPath)
        }
        t.equal(error as? PrinterTransportError, .transportUnavailable("\"not-md5\" is not an MD5 checksum"))
    },
])

// MARK: - Service

let printerFilamentPushTests = TestSuite(name: "PrinterService.addFilament (D-013)", cases: [

    test("an id the printer already lists is left alone") { t in
        let mock = MockPrinterTransport()
        let capture = try printerCapture()
        mock.seed(k2Path, with: capture)
        let existing = try hyperPLA(in: capture)
        let service = PrinterService(transport: mock)
        let outcome = try runSync { try await service.addFilament(existing, to: PrinterModel(profileName: "K2 Plus")!) }
        t.equal(outcome, .alreadyOnPrinter)
        t.equal(mock.calls, [.download(path: k2Path)])
    },

    test("a missing filament is spliced in, guarded by the file it was made from, then read back") { t in
        let mock = MockPrinterTransport()
        let capture = try printerCapture()
        mock.seed(k2Path, with: capture)
        let filament = try polyTerra()
        let service = PrinterService(transport: mock)
        let outcome = try runSync { try await service.addFilament(filament, to: PrinterModel(profileName: "K2 Plus")!) }

        let expected = try PrinterMaterialDocument.appending(filament, to: capture)
        t.equal(outcome, .added(backupPath: backupPath))
        t.equal(mock.calls, [.download(path: k2Path),
                             .replace(path: k2Path, byteCount: expected.count,
                                      expectedMD5: PrinterMaterialDocument.md5Hex(capture),
                                      backupPath: backupPath),
                             .download(path: k2Path)])
        t.expect(mock.uploads[k2Path] == expected, "the spliced file is what reached the printer")
        t.expect((try? runSync { try await mock.download(from: backupPath) }) == capture, "the replaced file is kept")
    },

    test("a file that changed after it was read is not overwritten") { t in
        let mock = MockPrinterTransport()
        let capture = try printerCapture()
        mock.seed(k2Path, with: capture)
        let newer = capture + Data(" ".utf8)
        mock.beforeCall = { call in
            if case .replace = call { mock.seed(k2Path, with: newer) }
        }
        let filament = try polyTerra()
        let service = PrinterService(transport: mock)
        let error = errorFrom { try await service.addFilament(filament, to: PrinterModel(profileName: "K2 Plus")!) }
        t.equal(error as? PrinterTransportError, .remoteFileChanged(path: k2Path))
        t.expect(mock.uploads[k2Path] == nil, "nothing was written")
        mock.beforeCall = nil
        t.expect((try? runSync { try await mock.download(from: k2Path) }) == newer, "the printer's newer file stands")
    },

    test("a file that does not read back as written is reported") { t in
        let mock = MockPrinterTransport()
        mock.seed(k2Path, with: try printerCapture())
        mock.beforeCall = { call in
            // The read-back is the third call; something rewrites the file just before it.
            if case .download = call, mock.calls.count == 3 { mock.seed(k2Path, text: "{}") }
        }
        let filament = try polyTerra()
        let service = PrinterService(transport: mock)
        let error = errorFrom { try await service.addFilament(filament, to: PrinterModel(profileName: "K2 Plus")!) }
        if case .verificationFailed? = error as? FilamentSpliceError {} else {
            t.expect(false, "expected verificationFailed, got \(String(describing: error))")
        }
    },
])

// MARK: - Websocket reply

let crealitySocketReplyTests = TestSuite(name: "Creality websocket filament list (D-013)", cases: [

    test("the retMaterials reply yields the ids in the printer's order") { t in
        let reply = Data(#"{"retMaterials":[{"base":{"id":"01001"}},{"base":{"id":"00004"}},{"base":{"id":"00004"}},{"base":{"id":"P1023"}}]}"#.utf8)
        t.equal(CrealityPrinterSocket.filamentIDs(fromReply: reply), ["01001", "00004", "00004", "P1023"])
    },

    test("status pushes and non-JSON frames are not the reply") { t in
        t.equal(CrealityPrinterSocket.filamentIDs(fromReply: Data(#"{"nozzleTemp":"220.0","boxsInfo":{}}"#.utf8)), nil)
        t.equal(CrealityPrinterSocket.filamentIDs(fromReply: Data("ok".utf8)), nil)
    },

    test("the request is a read-only get") { t in
        t.equal(CrealityPrinterSocket.materialListRequest, #"{"method":"get","params":{"reqMaterials":1}}"#)
    },

    test("the address becomes ws://host:9999/, and anything else is refused") { t in
        t.equal(CrealityPrinterSocket.url(host: " 192.168.10.19 ")?.absoluteString, "ws://192.168.10.19:9999/")
        t.equal(CrealityPrinterSocket.url(host: "k2.local")?.absoluteString, "ws://k2.local:9999/")
        t.equal(CrealityPrinterSocket.url(host: ""), nil)
        t.equal(CrealityPrinterSocket.url(host: "http://printer/"), nil)
        t.equal(CrealityPrinterSocket.url(host: "printer:7125"), nil)
        t.equal(CrealityPrinterSocket.url(host: "two words"), nil)
    },
])

// MARK: - The offer

private final class FakeFilamentList: PrinterFilamentListReading, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>
    private var error: Error?
    private var _hosts: [String] = []

    init(ids: Set<String>) { self.ids = ids }

    var hosts: [String] { lock.withLock { _hosts } }

    func set(ids: Set<String>, error: Error? = nil) {
        lock.withLock {
            self.ids = ids
            self.error = error
        }
    }

    func filamentIDs(host: String) async throws -> Set<String> {
        try lock.withLock {
            _hosts.append(host)
            if let error { throw error }
            return ids
        }
    }
}

private final class FakePushTransport: PrinterTransporting, @unchecked Sendable {
    private let lock = NSLock()
    private var _pushes: [String] = []
    private var failures: [Error] = []

    /// `id@host/family` per push.
    var pushes: [String] { lock.withLock { _pushes } }

    func failNext(with error: Error) { lock.withLock { failures.append(error) } }

    func addFilament(_ filament: Filament, credentials: PrinterCredentials,
                     family: PrinterType) async throws -> FilamentPushOutcome {
        try lock.withLock {
            _pushes.append("\(filament.id)@\(credentials.host)/\(family.rawValue)")
            if !failures.isEmpty { throw failures.removeFirst() }
            return .added(backupPath: backupPath)
        }
    }

    func remoteDatabaseVersion(_: PrinterCredentials, family _: PrinterType) async throws -> String {
        throw PrinterUIError.notImplemented
    }

    func downloadDatabase(_: PrinterCredentials, family _: PrinterType) async throws -> Data {
        throw PrinterUIError.notImplemented
    }

    func uploadDatabase(_: Data, credentials _: PrinterCredentials, family _: PrinterType,
                        options _: UploadOptions,
                        progress _: @escaping @Sendable (PrinterProgress) -> Void) async throws -> String {
        throw PrinterUIError.notImplemented
    }

    func resetDatabase(_: Data, credentials _: PrinterCredentials, family _: PrinterType,
                       progress _: @escaping @Sendable (PrinterProgress) -> Void) async throws {
        throw PrinterUIError.notImplemented
    }

    func reboot(_: PrinterCredentials, family _: PrinterType) async throws {
        throw PrinterUIError.notImplemented
    }

    func downloadBoxInfo(_: PrinterCredentials, family _: PrinterType) async throws -> MaterialBoxInfo {
        throw PrinterUIError.notImplemented
    }
}

@MainActor
private struct PushHarness {
    let list: FakeFilamentList
    let transport: FakePushTransport
    let model: FilamentPushModel
}

@MainActor
private func makePushHarness(onPrinter: Set<String> = [],
                             printerConfigured: Bool = true,
                             hasPassword: Bool = true) throws -> PushHarness {
    let list = FakeFilamentList(ids: onPrinter)
    let transport = FakePushTransport()
    let catalogue = try vendorCatalogue()
    let model = FilamentPushModel(
        transport: transport,
        filamentList: list,
        printer: { family in
            printerConfigured && family == .k2 ? FilamentPushModel.Printer(host: "192.168.10.19", name: "K2 Plus") : nil
        },
        credentials: { _ in hasPassword ? PrinterCredentials(host: "192.168.10.19", password: "secret") : nil },
        catalogueRecord: { id, _ in catalogue.first { $0.id == id } },
        isFactoryFilament: { id, _ in id == "01001" })
    return PushHarness(list: list, transport: transport, model: model)
}

let filamentPushModelTests = TestSuite(name: "Add-to-printer offer after a verified write (D-013)", cases: [

    test("a vendor filament the printer does not list is offered") { t in
        runOnMain {
            do {
                let h = try makePushHarness()
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                guard case let .missing(subject) = h.model.phase else {
                    t.expect(false, "expected an offer, got \(h.model.phase)")
                    return
                }
                t.equal(subject.label, "Polymaker PolyTerra PLA")
                t.equal(subject.printerName, "K2 Plus")
                t.equal(h.list.hosts, ["192.168.10.19"])
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("a filament the printer already lists says nothing") { t in
        runOnMain {
            do {
                let h = try makePushHarness(onPrinter: ["P1023"])
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                t.equal(h.model.phase, .idle)
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("Creality's own filaments are not checked at all") { t in
        runOnMain {
            do {
                let h = try makePushHarness()
                h.model.noteVerifiedWrite(filamentID: "01001", printerTypeString: "K2")
                await h.model.settle()
                t.equal(h.model.phase, .idle)
                t.equal(h.list.hosts, [])
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("with no printer configured for the tag's family, nothing is checked") { t in
        runOnMain {
            do {
                let h = try makePushHarness(printerConfigured: false)
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                t.equal(h.model.phase, .idle)
                t.equal(h.list.hosts, [])
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("the second tag of the same spool does not check again") { t in
        runOnMain {
            do {
                let h = try makePushHarness()
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                t.equal(h.list.hosts.count, 1)
                if case .missing = h.model.phase {} else { t.expect(false, "still offering, got \(h.model.phase)") }
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("Add to printer sends the catalogue record to that printer") { t in
        runOnMain {
            do {
                let h = try makePushHarness()
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                h.model.add()
                await h.model.settle()
                if case .added = h.model.phase {} else { t.expect(false, "expected added, got \(h.model.phase)") }
                t.equal(h.transport.pushes, ["P1023@192.168.10.19/k2"])
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("without a saved password it says so and sends nothing") { t in
        runOnMain {
            do {
                let h = try makePushHarness(hasPassword: false)
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                h.model.add()
                guard case let .failed(_, .add, message) = h.model.phase else {
                    t.expect(false, "expected a failure, got \(h.model.phase)")
                    return
                }
                t.expect(message.contains("no saved password"), message)
                t.equal(h.transport.pushes, [])
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("a push that fails can be tried again") { t in
        runOnMain {
            do {
                let h = try makePushHarness()
                h.transport.failNext(with: PrinterTransportError.connectionFailed("192.168.10.19 did not answer"))
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                h.model.add()
                await h.model.settle()
                if case .failed(_, .add, _) = h.model.phase {} else { t.expect(false, "expected failed, got \(h.model.phase)") }
                h.model.retry()
                await h.model.settle()
                if case .added = h.model.phase {} else { t.expect(false, "expected added, got \(h.model.phase)") }
                t.equal(h.transport.pushes.count, 2)
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("Not now stays quiet for that filament, and not for the next one") { t in
        runOnMain {
            do {
                let h = try makePushHarness()
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                h.model.notNow()
                t.equal(h.model.phase, .idle)

                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                t.equal(h.model.phase, .idle)
                t.equal(h.list.hosts.count, 1)

                h.model.noteVerifiedWrite(filamentID: "P1024", printerTypeString: "K2")
                await h.model.settle()
                if case let .missing(subject) = h.model.phase {
                    t.equal(subject.filamentID, "P1024")
                } else {
                    t.expect(false, "expected an offer for P1024, got \(h.model.phase)")
                }
                t.equal(h.list.hosts.count, 2)
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },

    test("a printer that cannot be reached is reported, and can be checked again") { t in
        runOnMain {
            do {
                let h = try makePushHarness()
                h.list.set(ids: [], error: CrealitySocketError.connectionFailed("Could not connect to the server."))
                h.model.noteVerifiedWrite(filamentID: "P1023", printerTypeString: "K2")
                await h.model.settle()
                if case .failed(_, .check, _) = h.model.phase {} else { t.expect(false, "expected failed, got \(h.model.phase)") }
                h.list.set(ids: ["P1023"])
                h.model.retry()
                await h.model.settle()
                t.equal(h.model.phase, .idle)
            } catch {
                t.expect(false, "harness: \(error)")
            }
        }
    },
])
