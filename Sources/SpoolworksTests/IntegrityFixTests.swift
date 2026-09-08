import Foundation
@testable import SpoolworksCore

// Regression cover for the integrity defects fixed in the printer/SSH and material-database
// layers. Each case names the defect it pins, because the point of these is that they fail if
// the fix is ever reverted — not that they describe how the code works today.
//
// Nothing here touches the network or a printer. The two cases that spawn a process use
// /bin/sh and /usr/bin/ssh-keygen against a temp directory.

// MARK: - Async bridging

// The harness is synchronous, so async work is driven on a background task and waited for here.
// Deliberately named differently from PrinterServiceTests' equivalents: `private` in Swift is
// file-scoped, so both can exist, but two identically-named helpers in one module read as a
// mistake.

private final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func awaitResult<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.result = .success(try await body()) }
        catch { box.result = .failure(error) }
        done.signal()
    }
    done.wait()
    return try box.result!.get()
}

/// Runs `body`, returning the error it threw, or `nil` if it did not throw.
private func errorOf<T>(_ body: @escaping @Sendable () async throws -> T) -> Error? {
    do { _ = try awaitResult(body); return nil } catch { return error }
}

// MARK: - Fixtures

/// A throwaway directory, removed when the instance goes away.
private final class Scratch {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-integrity-\(UUID().uuidString)", isDirectory: true)
    }

    func makeRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    var storage: MaterialStorage {
        MaterialStorage(directory: root.appendingPathComponent("material_database", isDirectory: true))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

/// Parses JSON into a comparable object graph.
private func parsed(_ data: Data) -> NSDictionary? {
    (try? JSONSerialization.jsonObject(with: data)) as? NSDictionary
}

/// The `base` object of the first record of an encoded envelope.
private func firstBase(_ data: Data) -> [String: Any]? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let list = (root["result"] as? [String: Any])?["list"] as? [[String: Any]],
          let first = list.first
    else { return nil }
    return first["base"] as? [String: Any]
}

private func wrap(_ records: String, code: Int = 0, msg: String = "ok",
                  extraEnvelope: String = "", extraResult: String = "") -> Data {
    Data("""
    {"code":\(code),"msg":"\(msg)","reqId":"0"\(extraEnvelope),
     "result":{"list":[\(records)],"count":1,"version":"1758907369"\(extraResult)}}
    """.utf8)
}

private func filament(_ base: String) -> String {
    """
    {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],
     "kvParam":{"filament_density":"1.24"},"base":\(base)}
    """
}

private let fullBase = """
{"id":"01001","brand":"Creality","name":"Hyper PLA","meterialType":"PLA","colors":["#ffffff"],
 "density":1.24,"diameter":"1.75","costPerMeter":0,"weightPerMeter":0,"rank":10000,
 "minTemp":190,"maxTemp":240,"isSoluble":false,"isSupport":false,
 "shrinkageRate":0,"softeningTemp":0,"dryingTemp":0,"dryingTime":0}
"""

/// Only the four required identity keys. Everything else is *absent*, not zero.
private let sparseBase = """
{"id":"01001","brand":"Creality","name":"Hyper PLA","meterialType":"PLA"}
"""

private func realDatabase() -> Data? {
    Bundle.module.url(forResource: "printer-k2plus-material_database", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
}

// MARK: - Suite

let integrityFixTests = TestSuite(name: "Integrity fixes (printer transport + material DB)", cases: [

    // MARK: 2 — a sparse `base` must not gain invented settings

    test("a sparse base round-trips sparse instead of inventing printer settings") { t in
        // The defect: the decoder falls back to 0 for every missing numeric and `encode` wrote
        // all 18 modelled keys unconditionally, so a record that never mentioned minTemp came
        // back out as `minTemp: 0, maxTemp: 0, density: 0, colors: []` — and those bytes are
        // what gets uploaded to a printer as real settings.
        let file = try MaterialDatabase.decode(wrap(filament(sparseBase)))
        guard let base = t.unwrap(file.result.list.first?.base, "decoded base") else { return }

        // Reading is still lenient: the fallbacks are there so a sparse record loads at all.
        t.equal(base.minTemp, 0, "the in-memory fallback is unchanged")
        t.equal(base.colors, [], "…and so is this one")
        // Writing is not.
        t.equal(base.presentKeys, MaterialBase.requiredKeys, "only the four identity keys were present")

        guard let written = t.unwrap(firstBase(try MaterialDatabase.encode(file)), "encoded base") else { return }
        t.equal(Set(written.keys), ["id", "brand", "name", "meterialType"],
                "no key may be conjured out of a fallback")
        for invented in ["minTemp", "maxTemp", "density", "colors", "diameter", "dryingTime"] {
            t.expect(written[invented] == nil, "\(invented) was invented from a fallback")
        }
    },

    test("a fully-populated base still writes all 18 modelled keys") { t in
        let file = try MaterialDatabase.decode(wrap(filament(fullBase)))
        guard let written = t.unwrap(firstBase(try MaterialDatabase.encode(file))) else { return }
        t.equal(Set(written.keys), MaterialBase.allModelledKeys, "nothing may be dropped either")
        t.equal(written["minTemp"] as? Int, 190)
        t.equal(written["density"] as? Double, 1.24)
    },

    test("assigning a field that was absent makes it present, so an edit is not silently lost") { t in
        // The presence set must track the *caller* too, or the UI could set minTemp on a sparse
        // record and have the value quietly dropped on save — the mirror-image data loss.
        let file = try MaterialDatabase.decode(wrap(filament(sparseBase)))
        guard var record = t.unwrap(file.result.list.first) else { return }
        record.base.minTemp = 215
        record.base.colors = ["#ff0000"]

        var edited = file
        edited.result.list = [record]
        guard let written = t.unwrap(firstBase(try MaterialDatabase.encode(edited))) else { return }
        t.equal(Set(written.keys), ["id", "brand", "name", "meterialType", "minTemp", "colors"])
        t.equal(written["minTemp"] as? Int, 215)
        t.expect(written["maxTemp"] == nil, "an untouched absent key stays absent")
    },

    test("a record built in memory writes every modelled key") { t in
        // A hand-built record has no absent keys, only values, so nothing is being invented.
        let base = MaterialBase(id: "29001", brand: "Generic", name: "Test PLA", materialType: "PLA")
        t.equal(base.presentKeys, MaterialBase.allModelledKeys)
        let file = MaterialDatabaseFile(list: [Filament(printerIntName: "F008", base: base)])
        guard let written = t.unwrap(firstBase(try MaterialDatabase.encode(file))) else { return }
        t.equal(Set(written.keys), MaterialBase.allModelledKeys)
    },

    // MARK: 3 — one odd record must not kill the catalogue

    test("one unreadable record no longer takes the whole catalogue down") { t in
        // The docstring promised this; the code did not deliver it, because `result.list`
        // decoded as a single `[Filament]` and a lone bad element aborted the array.
        let good = filament(fullBase)
        let badColors = filament("""
        {"id":"01002","brand":"Creality","name":"Bad","meterialType":"PLA","colors":"#ffffff"}
        """)
        let third = filament("""
        {"id":"01003","brand":"eSUN","name":"Third","meterialType":"PETG"}
        """)
        let data = Data("""
        {"code":0,"msg":"ok","reqId":"0","result":{"count":3,"version":"1758907369",
         "list":[\(good),\(badColors),\(third)]}}
        """.utf8)

        let file = try MaterialDatabase.decode(data)
        t.equal(file.result.list.map(\.id), ["01001", "01003"], "the good records still load")
        t.equal(file.recordFailures.count, 1)
        t.equal(file.recordFailures.first?.index, 1, "reported at its position in the file")
        t.expect(file.recordFailures.first?.reason.contains("colors") == true,
                 "the reason should name the offending key: \(file.recordFailures.first?.reason ?? "")")
    },

    test("each of the strict per-record failures is survivable") { t in
        // Every field that throws rather than falling back, one per record, all in one file.
        let cases: [(String, String)] = [
            ("nozzleDiameter", """
             {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":"0.4",
              "kvParam":{},"base":\(sparseBase)}
             """),
            ("kvParam", """
             {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],
              "kvParam":{"nozzle_temperature":220},"base":\(sparseBase)}
             """),
            ("missing id", filament("""
             {"brand":"Creality","name":"No id","meterialType":"PLA"}
             """)),
            ("colors", filament("""
             {"id":"01009","brand":"Creality","name":"Bad","meterialType":"PLA","colors":"#fff"}
             """)),
        ]
        let survivor = filament("""
        {"id":"99999","brand":"Generic","name":"Survivor","meterialType":"PLA"}
        """)
        let records = (cases.map(\.1) + [survivor]).joined(separator: ",")
        let file = try MaterialDatabase.decode(Data("""
        {"code":0,"msg":"ok","reqId":"0","result":{"count":5,"version":"0","list":[\(records)]}}
        """.utf8))

        t.equal(file.result.list.map(\.id), ["99999"], "the one good record loads")
        t.equal(file.recordFailures.map(\.index), [0, 1, 2, 3], "all four are reported, in order")
        // kvParam strictness is deliberate and stays: a numeric value there means the file is
        // not what we think it is, and coercing it would lose "190" vs 190 on the way back out.
        t.expect(file.recordFailures[1].reason.contains("kvParam"),
                 "kvParam is still strict: \(file.recordFailures[1].reason)")
    },

    test("record failures reach MaterialDatabase, and a fully broken list is not mistaken for empty") { t in
        let scratch = Scratch()
        let bad = filament("""
        {"id":"01002","brand":"Creality","name":"Bad","meterialType":"PLA","colors":"#ffffff"}
        """)
        let seed = StaticMaterialSeed([.k2: Data("""
        {"code":0,"msg":"ok","reqId":"0","result":{"count":2,"version":"0",
         "list":[\(filament(fullBase)),\(bad)]}}
        """.utf8)])
        let db = MaterialDatabase(printerType: .k2, storage: scratch.storage, seed: seed)
        try db.load()

        t.equal(db.filaments.map(\.id), ["01001"], "the readable record loaded")
        t.equal(db.recordFailures.count, 1, "and the unreadable one is reported, not hidden")
        t.equal(db.recordFailures.first?.index, 1)
    },

    // MARK: 6 — the envelope must be preserved

    test("code, msg and unknown envelope/result keys survive a save") { t in
        // save()/adopt() dropped `code` and `msg` and re-emitted the 0/"ok" defaults, and
        // neither the envelope nor `result` had an additionalFields catch-all — so a future
        // firmware key at either level was silently stripped on the next save, and that save is
        // what gets uploaded to the printer.
        let scratch = Scratch()
        let source = Data("""
        {"code":42,"msg":"partial","reqId":"cl60202408291655293979","futureTopLevel":"keep me",
         "result":{"count":1,"version":"1758907369","list":[\(filament(fullBase))],
                   "futureResultKey":{"nested":[1,2.5,true,null,"x"]}}}
        """.utf8)

        let db = MaterialDatabase(printerType: .k2, storage: scratch.storage,
                                  seed: StaticMaterialSeed([.k2: source]))
        try db.load()
        t.equal(db.code, 42, "code is read, not assumed")
        t.equal(db.msg, "partial")
        t.equal(db.envelopeFields["futureTopLevel"], .string("keep me"))
        t.equal(db.resultFields["futureResultKey"],
                .object(["nested": .array([.int(1), .double(2.5), .bool(true), .null, .string("x")])]))

        try db.add(sampleRecord(id: "29001"))
        try db.save()

        let onDisk = try MaterialDatabase.decode(try Data(contentsOf: scratch.storage.url(for: .k2)))
        t.equal(onDisk.code, 42, "code must not be reset to 0")
        t.equal(onDisk.msg, "partial", "msg must not be reset to \"ok\"")
        t.equal(onDisk.reqId, "cl60202408291655293979")
        t.equal(onDisk.additionalFields["futureTopLevel"], .string("keep me"))
        t.equal(onDisk.result.additionalFields["futureResultKey"],
                .object(["nested": .array([.int(1), .double(2.5), .bool(true), .null, .string("x")])]))
        t.equal(onDisk.result.count, 2, "count is still recomputed")
    },

    test("a file that says nothing about code and msg still gets the documented defaults") { t in
        let file = try MaterialDatabase.decode(Data("""
        {"reqId":"0","result":{"count":0,"version":"0","list":[]}}
        """.utf8))
        t.equal(file.code, 0)
        t.equal(file.msg, "ok")
    },

    // MARK: The real printer database — still byte-for-byte semantically identical

    test("the real 98-record K2 Plus database round-trips with zero semantic changes") { t in
        // The strongest statement available: not "no key was lost" but "the parsed object graph
        // is identical". Both of the material fixes above could have changed this file's output
        // — the sparse-base gate by dropping a key, the element-wise decode by dropping a record
        // — so it is asserted whole rather than key-set-wise.
        guard let data = t.unwrap(realDatabase(), "real printer fixture") else { return }
        let file = try MaterialDatabase.decode(data)
        t.equal(file.recordFailures.count, 0, "every real record must decode")
        t.equal(file.result.list.count, 98)

        let reencoded = try MaterialDatabase.encode(file)
        guard let before = t.unwrap(parsed(data), "original"),
              let after = t.unwrap(parsed(reencoded), "re-encoded") else { return }
        t.expect(before.isEqual(to: after as! [AnyHashable: Any]),
                 "the real database must survive a decode/encode cycle unchanged")

        // …and the value graph is stable across a second cycle.
        t.equal(try MaterialDatabase.decode(reencoded), file)
    },

    // MARK: 7 — memory and disk must not diverge after a failed save

    test("a failed save rolls the catalogue back to what is actually on disk") { t in
        let scratch = Scratch()
        let seed = StaticMaterialSeed([.k2: try MaterialDatabase.encode(
            MaterialDatabaseFile(list: [sampleRecord(id: "00001")], version: "1746005657"))])
        let db = MaterialDatabase(printerType: .k2, storage: scratch.storage, seed: seed)
        try db.load()
        t.equal(db.hasUnsavedChanges, false, "freshly loaded state is clean")

        try db.add(sampleRecord(id: "29001"))
        try db.remove(id: "00001")
        db.setVersion("1800000000")
        t.equal(db.hasUnsavedChanges, true, "a mutation marks the database dirty")

        // Make the write fail without touching permissions (which behave differently as root):
        // put a directory where the file belongs, so the atomic rename cannot land.
        let fileURL = scratch.storage.url(for: .k2)
        let saved = try Data(contentsOf: fileURL)
        try FileManager.default.removeItem(at: fileURL)
        try FileManager.default.createDirectory(at: fileURL, withIntermediateDirectories: false)

        t.throwsError("saving over a directory") { try db.save() }

        // The defect: the mutation stayed in `filaments` with no dirty flag and no rollback, so
        // the UI showed a catalogue the disk did not have.
        t.equal(db.filaments.map(\.id), ["00001"], "the failed mutation was rolled back")
        t.equal(db.version, "1746005657", "…including the version bump")
        t.equal(db.hasUnsavedChanges, true, "and the database is still known to be unsaved")

        // Clear the obstruction; the same save now succeeds and the state is clean again.
        try FileManager.default.removeItem(at: fileURL)
        try saved.write(to: fileURL)
        try db.add(sampleRecord(id: "29001"))
        try db.save()
        t.equal(db.hasUnsavedChanges, false)
        let onDisk = try MaterialDatabase.decode(try Data(contentsOf: fileURL))
        t.equal(onDisk.result.list.map(\.id), ["00001", "29001"])
    },

    test("adopt marks the database dirty; load does not") { t in
        let scratch = Scratch()
        let seed = StaticMaterialSeed([.k2: try MaterialDatabase.encode(
            MaterialDatabaseFile(list: [sampleRecord(id: "00001")]))])
        let db = MaterialDatabase(printerType: .k2, storage: scratch.storage, seed: seed)
        try db.load()
        t.equal(db.hasUnsavedChanges, false, "load()'s state came straight off the disk")

        // A cloud/printer merge lands in memory only, so it is unsaved by definition.
        db.adopt(MaterialDatabaseFile(list: [sampleRecord(id: "77777")], version: "1800000000"))
        t.equal(db.hasUnsavedChanges, true)
        try db.save()
        t.equal(db.hasUnsavedChanges, false)
    },

    // MARK: 4 — both ssh-keygen paths validate the host and prepare the trust store

    test("both ssh-keygen paths reject a host that would be read as an option") { t in
        // `pinnedHostKeyFingerprints` skipped the validation `forgetHostKey` performs, so a host
        // starting with `-` went through to ssh-keygen as an option.
        let scratch = Scratch()
        var configuration = SSHConfiguration(host: "-oProxyCommand=touch /tmp/spoolworks-pwned")
        configuration.knownHostsPath = scratch.root.appendingPathComponent("known_hosts").path
        let transport = SSHTransport(configuration: configuration, password: "unused")

        t.equal(errorOf { try await transport.forgetHostKey() } as? PrinterTransportError,
                .invalidHost(configuration.host), "forgetHostKey")
        t.equal(errorOf { try await transport.pinnedHostKeyFingerprints() } as? PrinterTransportError,
                .invalidHost(configuration.host), "pinnedHostKeyFingerprints")
        // Validation happens before anything is spawned, so the trust store was never created.
        t.expect(!FileManager.default.fileExists(atPath: configuration.knownHostsPath),
                 "nothing should have been created for a rejected host")
    },

    test("on a fresh install neither ssh-keygen path reports a spurious transport failure") { t in
        // Neither called prepareKnownHostsFile, so before the first successful connection
        // `ssh-keygen -R` exited 255 with "Cannot stat …" and the user was shown
        // `transportUnavailable` for a trust store that was simply not there yet.
        let scratch = Scratch()
        var configuration = SSHConfiguration(host: "10.0.0.5")
        configuration.knownHostsPath = scratch.root
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("known_hosts").path
        let transport = SSHTransport(configuration: configuration, password: "unused")
        t.expect(!FileManager.default.fileExists(atPath: configuration.knownHostsPath), "fresh install")

        // `-l -F` on an absent host is "no fingerprints", not an error.
        let fingerprints = try awaitResult { try await transport.pinnedHostKeyFingerprints() }
        t.equal(fingerprints, [])
        t.expect(FileManager.default.fileExists(atPath: configuration.knownHostsPath),
                 "the trust store is created on demand")

        // …and "Trust New Identity" on a host that was never pinned is a no-op, not a failure.
        t.equal(errorOf { try await transport.forgetHostKey() } as? PrinterTransportError, nil)

        let mode = (try? FileManager.default
            .attributesOfItem(atPath: configuration.knownHostsPath)[.posixPermissions]) as? NSNumber
        t.equal(mode?.int16Value, 0o600, "and it is still owner-only")
    },

    // MARK: 5 — the "copy/pasteable" command line is actually pasteable

    test("commandLine quotes anything a shell could act on, not just spaces") { t in
        // It only quoted arguments containing a space, so `/tmp/x;reboot` was emitted bare and a
        // user pasting the logged line into a terminal would have run it. Display-only, never
        // executed by us — but "copy/pasteable" is a promise.
        let invocation = SSHInvocation(
            executable: "/usr/bin/ssh",
            arguments: ["-p", "22", "/tmp/x;reboot", "$(id)", "`id`", "a|b", "x&y", "q'uote",
                        "with space", "new\nline", ""],
            environment: [:])
        t.equal(invocation.commandLine,
                "/usr/bin/ssh -p 22 '/tmp/x;reboot' '$(id)' '`id`' 'a|b' 'x&y' 'q'\\''uote' "
                + "'with space' 'new\nline' ''")
    },

    test("commandLine leaves genuinely inert arguments unquoted") { t in
        let transport = SSHTransport(configuration: SSHConfiguration(host: "192.168.1.50"),
                                     password: "unused")
        let line = transport.invocation(
            for: .run(command: "reboot"),
            askpass: AskpassLocation(scriptPath: "/tmp/ap/askpass", fifoPath: "/tmp/ap/pw.fifo")).commandLine
        t.expect(line.hasPrefix("/usr/bin/ssh -F /dev/null -T -p 22 -l root "),
                 "readable options stay readable: \(line)")
        t.expect(line.contains("-o 'PreferredAuthentications=password'") == false,
                 "an option with no shell metacharacter is not quoted: \(line)")
        // The quoted UserKnownHostsFile value contains `"` and a space, so it must be quoted.
        t.expect(line.contains("-o 'UserKnownHostsFile="), "the known-hosts option is quoted: \(line)")
    },

    // MARK: 1 — a second password prompt must not deadlock the transport

    test("only the password method is offered, so a second askpass prompt is unreachable") { t in
        let transport = SSHTransport(configuration: SSHConfiguration(host: "h"), password: "x")
        let arguments = transport.invocation(
            for: .run(command: "reboot"),
            askpass: AskpassLocation(scriptPath: "/a", fifoPath: "/b")).arguments

        t.expect(arguments.contains("PreferredAuthentications=password"),
                 "password only: \(arguments)")
        t.expect(!arguments.contains(where: { $0.contains("keyboard-interactive") }),
                 "keyboard-interactive is not bounded by NumberOfPasswordPrompts=1")
        t.expect(arguments.contains("KbdInteractiveAuthentication=no"), "…and is refused outright")
        t.expect(arguments.contains("NumberOfPasswordPrompts=1"), "the password method stays bounded")
    },

    test("the askpass helper's read is time-bounded") { t in
        // The FIFO holds exactly one line. An unbounded `read` in a second helper invocation
        // blocked forever, and because the helper is a grandchild of this process it kept ssh's
        // stderr pipe open — which hung the drain, the deadline and the continuation, so even
        // `defer { askpass.dispose() }` never ran.
        guard let channel = t.unwrap(try? AskpassChannel(), "askpass channel") else { return }
        defer { channel.dispose() }
        guard let script = t.unwrap(try? String(contentsOfFile: channel.location.scriptPath,
                                                encoding: .utf8), "helper script") else { return }
        t.expect(script.contains("read -r -t \(AskpassChannel.readTimeoutSeconds)"),
                 "the helper must not block forever: \(script)")
        t.expect(AskpassChannel.readTimeoutSeconds > 0, "and the bound must be finite")
    },

    test("a grandchild holding the output pipes cannot hang the runner") { t in
        // The exact wedge: `sh` exits but leaves a child holding the inherited stdout/stderr, so
        // readDataToEndOfFile() does not return. `group.wait()` used to be unbounded, so the
        // continuation was never resumed and the operation could not be recovered from at all.
        let invocation = SSHInvocation(executable: "/bin/sh",
                                       arguments: ["-c", "sleep 30 & exit 0"],
                                       environment: ["PATH": "/usr/bin:/bin"])
        let started = Date()
        let result = try awaitResult {
            try await ProcessRunner.run(invocation: invocation, stdin: nil,
                                        timeout: 30, drainGrace: 0.3)
        }
        let elapsed = Date().timeIntervalSince(started)
        t.equal(result.exitStatus, 0, "the child itself exited cleanly")
        t.expect(elapsed < 10, "the drain must be abandoned, not waited out — took \(elapsed)s")
    },

    // MARK: 8 — reboot must not report success for a printer that never restarted

    test("reboot only forgives the connection-teardown message, not every exit 255") { t in
        // 255 is ssh's catch-all for everything it does itself — refused password, rejected host
        // key, failed negotiation — so accepting any 255 reported didReboot == true for a
        // printer that never restarted, which then read as "the upload took effect".
        let torndown = MockPrinterTransport()
        torndown.failRun = .remoteCommandFailed(exitStatus: 255,
                                                message: "Connection to 10.0.0.5 closed by remote host.")
        t.equal(errorOf { try await PrinterService(transport: torndown).reboot() } as? PrinterTransportError,
                nil, "a torn-down connection is still success")

        for message in ["Permission denied (password).",
                        "Host key verification failed.",
                        "Unable to negotiate with 10.0.0.5 port 22: no matching cipher found.",
                        ""] {
            let mock = MockPrinterTransport()
            mock.failRun = .remoteCommandFailed(exitStatus: 255, message: message)
            t.equal(errorOf { try await PrinterService(transport: mock).reboot() } as? PrinterTransportError,
                    .remoteCommandFailed(exitStatus: 255, message: message),
                    "exit 255 with \"\(message)\" must not be reported as a reboot")
        }
    },

    test("an upload whose reboot really failed does not claim didReboot") { t in
        let mock = MockPrinterTransport()
        mock.failRun = .remoteCommandFailed(exitStatus: 255, message: "Permission denied (password).")
        let error = errorOf {
            try await PrinterService(transport: mock).upload(
                database: Data(#"{"result":{"version":"1","count":0,"list":[]}}"#.utf8),
                to: PrinterModel(profileName: "K2 Plus")!)
        }
        t.equal(error as? PrinterTransportError,
                .remoteCommandFailed(exitStatus: 255, message: "Permission denied (password)."))
    },

    // MARK: 10 — one printer-family classifier, with no silent K2 fallback

    test("the transport and database classifiers agree on every name") { t in
        let names = ["K2", "K2 Plus", "K2 Pro", "K1", "K1 Max", "K1C", "CR-K1 Max", "Creality K1 Max",
                     "Hi", "Hi Combo", "Creality Hi", "F008", "F018", "k2.json",
                     "Ender 5", "Ender Chi", "Chiron", "Nebula X", "", "   ",
                     "K1 Max High Flow", "K2 Pro Hi-Speed"]
        for name in names {
            let viaType = PrinterType(identifying: name)
            let viaFamily = PrinterFamily(identifying: name)
            t.equal(viaFamily?.printerType, viaType, "\(name.isEmpty ? "<empty>" : name)")
            t.equal(PrinterModel.family(forProfileName: name), viaFamily, "PrinterModel agrees too")
        }
        // …and the one family PrinterType does not model still resolves, to itself.
        t.equal(PrinterFamily(identifying: "i7"), .i7)
        t.equal(PrinterFamily(identifying: "i7")?.printerType, nil, "the i7 has no bundled catalogue")
        t.equal(PrinterType(identifying: "i7"), nil)
    },

    test("an unknown profile name inherits neither K2's password nor its paths") { t in
        for name in ["Ender 5", "Nebula X", "", "Chiron"] {
            t.equal(PrinterModel(profileName: name)?.family, nil,
                    "\(name.isEmpty ? "<empty>" : name) must not silently become a K2")
        }
        // The old fallback handed an unknown machine exactly this, on a guess.
        t.equal(PrinterFamily.k2.defaultPassword, "creality_2024")
        t.equal(PrinterFamily.k2.remoteBaseDirectory, "/mnt/UDISK/creality/userdata/box/")
    },

    test("the creality prefix is stripped as a leading token, not from anywhere in the string") { t in
        // The old classifier used `range(of: "creality")` — an anywhere match — so a name like
        // "Ultracreality K1" had the middle cut out of it before matching.
        t.equal(PrinterModel(profileName: "Creality K1 Max")?.family, .k1, "leading token is stripped")
        t.equal(PrinterModel(profileName: "creality hi")?.family, .hi)
        t.equal(PrinterModel(profileName: "Nebula Creality K1")?.family, nil,
                "a mid-string 'creality' is not a prefix and must not be excised")
        t.equal(PrinterModel(profileName: "Creality")?.family, nil,
                "the token alone identifies nothing")
    },

    // MARK: 11 — the server-supplied zip URL must be https on a known host

    test("a zipUrl is rejected unless it is https on an allow-listed host") { t in
        let rejected = [
            "file:///etc/passwd",
            "file:///Users/someone/.ssh/id_rsa",
            "http://cdn.crealitycloud.com/k2.zip",
            "https://evil.example/k2.zip",
            "https://crealitycloud.com.evil.example/k2.zip",
            "https://notcrealitycloud.com/k2.zip",
            "ftp://cdn.crealitycloud.com/k2.zip",
            "/local/path.zip",
            "",
        ]
        for value in rejected {
            t.equal(CrealityCloudRequest.validatedZipURL(value), nil, "must reject \(value)")
        }
        let accepted = [
            "https://crealitycloud.com/k2.zip",
            "https://cdn.crealitycloud.com/profiles/k2.zip",
            "https://file.crealitycloud.cn/k2.zip",
            "https://creality-cdn.oss-cn-hangzhou.aliyuncs.com/k2.zip",
        ]
        for value in accepted {
            t.expect(CrealityCloudRequest.validatedZipURL(value) != nil, "must accept \(value)")
        }
    },

    test("a hostile zipUrl is refused before any request is made") { t in
        // `URL(string:)` happily produces file:///…, and URLSession honours it, so an
        // unauthenticated API response could make the app read a local file and treat it as a
        // profile bundle.
        for hostile in ["file:///etc/passwd", "https://evil.example/k2.zip", "http://cdn.crealitycloud.com/k2.zip"] {
            let http = MockHTTPClient()
            http.stub(CrealityCloudRequest.printerListURL, json: """
            {"code":0,"result":{"printerList":[
              {"name":"K2 Plus","nozzleDiameter":["0.4"],"zipUrl":"\(hostile)"}]}}
            """)
            let error = errorOf {
                try await CrealityCloud(http: http).profileZip(forPrinterNamed: "K2 Plus", nozzle: "0.4")
            }
            t.equal(error as? CrealityCloudError, .untrustedProfileURL(hostile))
            t.equal(http.requests.count, 1, "only the printerList call was made, never the zip GET")
        }
    },

    test("an absent zipUrl is still 'no profile', not 'untrusted'") { t in
        // The two are different problems and the UI says different things about them.
        let http = MockHTTPClient()
        http.stub(CrealityCloudRequest.printerListURL, json: """
        {"code":0,"result":{"printerList":[{"name":"K2 Plus","nozzleDiameter":["0.4"],"zipUrl":""}]}}
        """)
        t.equal(errorOf { try await CrealityCloud(http: http)
                    .profileZip(forPrinterNamed: "K2 Plus", nozzle: "0.4") } as? CrealityCloudError,
                .noProfileForNozzle(printer: "K2 Plus", nozzle: "0.4"))
    },
])

// MARK: - Helpers used by several cases

private func sampleRecord(id: String) -> Filament {
    Filament(printerIntName: PrinterType.k2.printerIntName,
             kvParam: ["filament_type": "PLA"],
             base: MaterialBase(id: id, brand: "Generic", name: "Test PLA", materialType: "PLA"))
}
