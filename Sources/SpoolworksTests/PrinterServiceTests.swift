import Foundation
import SpoolworksCore

// Tests for the printer communication layer (SPEC-04).
//
// Every one of these runs with no printer, no network, and no ssh invocation. The three
// suites that touch a real subprocess do so against /bin/sh, /bin/cat and /bin/sleep only —
// that is how the deadline, cancellation and password-delivery paths get genuine coverage
// without hardware.

// MARK: - Async bridging

// The harness is synchronous (Harness.swift is not ours to change), so async work is driven to
// completion on a background task and waited for here. Nothing in SpoolworksCore is main-actor bound,
// so blocking this thread cannot deadlock the cooperative pool.

private final class Box<T>: @unchecked Sendable {
    var result: Result<T, Error>?
}

private func runSync<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
    let box = Box<T>()
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
private func errorFrom<T>(_ body: @escaping @Sendable () async throws -> T) -> Error? {
    do { _ = try runSync(body); return nil } catch { return error }
}

/// A minimal, realistic `material_database.json` — the envelope from SPEC-04 §10.3 with two
/// entries that share a brand so the `material_option.json` join has something to do.
private let sampleDatabaseJSON = """
{
  "code": 0,
  "msg": "ok",
  "reqId": "cl602024082916552939795681",
  "result": {
    "count": 3,
    "version": "1746005657",
    "list": [
      {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],
       "kvParam":{"filament_density":"1.24"},
       "base":{"id":"101001","brand":"Creality","name":"Hyper PLA","meterialType":"PLA","colors":"#FFFFFF"}},
      {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],
       "kvParam":{"filament_density":"1.24"},
       "base":{"id":"101002","brand":"Creality","name":"CR-PLA","meterialType":"PLA","colors":"#000000"}},
      {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],
       "kvParam":{"filament_density":"1.27"},
       "base":{"id":"201001","brand":"Polymaker","name":"PolyLite ABS","meterialType":"ABS","colors":"#FF0000"}}
    ]
  }
}
"""

private var sampleDatabase: Data { Data(sampleDatabaseJSON.utf8) }

private func jsonObject(_ data: Data) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
}

// MARK: - Printer model / path selection

let printerModelTests = TestSuite(name: "PrinterModel (SPEC-04 §2, §4)", cases: [

    test("K1 family uses /usr/data, everything else uses /mnt/UDISK") { t in
        t.equal(PrinterModel(profileName: "K1")!.materialDatabasePath,
                "/usr/data/creality/userdata/box/material_database.json", "K1")
        t.equal(PrinterModel(profileName: "K1 Max")!.materialDatabasePath,
                "/usr/data/creality/userdata/box/material_database.json", "K1 Max")
        t.equal(PrinterModel(profileName: "K1C")!.materialDatabasePath,
                "/usr/data/creality/userdata/box/material_database.json", "K1C")
        t.equal(PrinterModel(profileName: "K2 Plus")!.materialDatabasePath,
                "/mnt/UDISK/creality/userdata/box/material_database.json", "K2 Plus")
        t.equal(PrinterModel(profileName: "Hi Combo")!.materialDatabasePath,
                "/mnt/UDISK/creality/userdata/box/material_database.json", "Hi Combo")
        // OPEN QUESTION #3: the Hi inherits the K2 path by default rather than by verification.
        t.equal(PrinterModel(profileName: "Hi")!.family.remoteBaseDirectory,
                "/mnt/UDISK/creality/userdata/box/", "Hi base dir")
    },

    // CHANGED EXPECTATION. This used to assert that an unrecognised name silently became a K2,
    // "matching both existing clients". That fallback handed an unknown machine K2's root
    // password and wrote into K2's /mnt/UDISK paths on nothing but a guess, so the classifier is
    // now total in the honest sense: it says it does not know.
    test("an unknown name is refused rather than silently becoming a K2") { t in
        t.equal(PrinterModel(profileName: "Ender 5")?.family, nil)
        t.equal(PrinterModel(profileName: "")?.family, nil)
        t.equal(PrinterModel(profileName: "Nebula X")?.family, nil)
        t.equal(PrinterModel.family(forProfileName: "Ender 5"), nil)
        // …and a caller who genuinely knows the family can still say so explicitly.
        t.equal(PrinterModel(profileName: "Nebula X", family: .k2).family, .k2)
    },

    test("a leading Creality token is ignored") { t in
        t.equal(PrinterModel(profileName: "Creality K1 Max")!.family, .k1)
        t.equal(PrinterModel(profileName: "CREALITY Hi")!.family, .hi)
    },

    test("classification is anchored, unlike the unanchored substring test both clients use") { t in
        // Windows/Android test `name.contains("hi")` FIRST, so any name containing those two
        // letters anywhere picks the Hi password. Anchoring fixes that.
        t.equal(PrinterModel(profileName: "K1 Max High Flow")!.family, .k1,
                "contains 'hi' but is a K1")
        t.equal(PrinterModel(profileName: "K2 Pro Hi-Speed")!.family, .k2,
                "contains 'hi' but is a K2")
    },

    test("material_option.json path and the K1-family rule") { t in
        t.equal(PrinterModel(profileName: "K1")!.materialOptionPath,
                "/usr/data/creality/userdata/box/material_option.json")
        // Resolution of the Windows/Android divergence (spec OPEN QUESTION #4): Android's
        // substring behaviour wins, so K1 Max and K1C get the file too.
        t.expect(PrinterModel(profileName: "K1")!.family.writesMaterialOption, "K1")
        t.expect(PrinterModel(profileName: "K1 Max")!.family.writesMaterialOption, "K1 Max")
        t.expect(PrinterModel(profileName: "K1C")!.family.writesMaterialOption, "K1C")
        t.expect(!PrinterModel(profileName: "K2 Plus")!.family.writesMaterialOption, "K2 Plus")
        t.expect(!PrinterModel(profileName: "Hi")!.family.writesMaterialOption, "Hi")
    },

    test("vendor default passwords per family, capitalisation included") { t in
        t.equal(PrinterModel(profileName: "K1 Max")!.defaultPassword, "creality_2023", "K1")
        t.equal(PrinterModel(profileName: "K2 Plus")!.defaultPassword, "creality_2024", "K2")
        t.equal(PrinterModel(profileName: "Hi Combo")!.defaultPassword, "Creality2024", "Hi")
        // i7/creality_2025 exists only in Android (MainActivity.java:1136); Windows has no such
        // branch and would hand an i7 the K2 default.
        t.equal(PrinterModel(profileName: "i7")!.defaultPassword, "creality_2025", "i7")
    },

    test("the family can be overridden when the heuristic would guess wrong") { t in
        let model = PrinterModel(profileName: "Nebula X", family: .k1)
        t.equal(model.family, .k1)
        t.equal(model.materialDatabasePath, "/usr/data/creality/userdata/box/material_database.json")
    },
])

// MARK: - Command construction

let sshInvocationTests = TestSuite(name: "SSHTransport invocation (SPEC-04 §11.5)", cases: [

    test("upload stages, verifies the byte count, chmods, then renames") { t in
        let operation = SSHOperation.upload(path: "/mnt/UDISK/creality/userdata/box/material_database.json",
                                            byteCount: 4242)
        // `sync` because the printer is rebooted seconds later and an unsynced rename on its
        // flash filesystem can leave a zero-length database. The `|| { rm -f …; false; }` wrapper
        // stops a failed size check stranding a 478 KB temp file on a small volume, while keeping
        // the exit-1 signature that `classify` reads.
        let expected = "{ cat > '/mnt/UDISK/creality/userdata/box/material_database.json.spoolworks-tmp'"
            + " && [ \"$(wc -c < '/mnt/UDISK/creality/userdata/box/material_database.json.spoolworks-tmp')\" -eq 4242 ]"
            + " && chmod 644 '/mnt/UDISK/creality/userdata/box/material_database.json.spoolworks-tmp'"
            + " && mv -f '/mnt/UDISK/creality/userdata/box/material_database.json.spoolworks-tmp'"
            + " '/mnt/UDISK/creality/userdata/box/material_database.json'"
            + " && sync; }"
            + " || { rm -f '/mnt/UDISK/creality/userdata/box/material_database.json.spoolworks-tmp'; false; }"
        // The mode is 0644 root:root, matching the SCP `C0644` control record both existing
        // clients send (SPEC-04 §1.6).
        t.equal(operation.remoteCommand, expected)
    },

    test("download is a plain cat, not scp") { t in
        // SPEC-04 §11.5 rationale #2: `cat` over an exec channel dodges both the OpenSSH-9
        // scp-is-now-SFTP change and a possibly missing sftp-server on the printer.
        t.equal(SSHOperation.download(path: "/usr/data/creality/userdata/box/material_database.json").remoteCommand,
                "cat '/usr/data/creality/userdata/box/material_database.json'")
    },

    test("remote paths are single-quoted with embedded quotes escaped") { t in
        t.equal(SSHShell.quote("/tmp/plain"), "'/tmp/plain'")
        t.equal(SSHShell.quote("/tmp/it's here"), "'/tmp/it'\\''s here'")
        t.equal(SSHShell.quote("/tmp/x; rm -rf /"), "'/tmp/x; rm -rf /'")
    },

    test("exact argv for a database upload") { t in
        var configuration = SSHConfiguration(host: "192.168.1.50")
        configuration.knownHostsPath = "/tmp/spoolworks-test/known_hosts"
        let transport = SSHTransport(configuration: configuration, password: "unused")
        let askpass = AskpassLocation(scriptPath: "/tmp/ap/askpass", fifoPath: "/tmp/ap/pw.fifo")
        let path = "/mnt/UDISK/creality/userdata/box/material_database.json"
        let invocation = transport.invocation(for: .upload(path: path, byteCount: 10), askpass: askpass)

        t.equal(invocation.executable, "/usr/bin/ssh")
        t.equal(invocation.arguments, [
            "-F", "/dev/null",
            "-T",
            "-p", "22",
            "-l", "root",
            "-o", "BatchMode=no",
            "-o", "NumberOfPasswordPrompts=1",
            // CHANGED EXPECTATION. `keyboard-interactive` used to be offered alongside
            // `password`. NumberOfPasswordPrompts=1 bounds only the password method, so
            // keyboard-interactive could invoke the askpass helper a second time — and the FIFO
            // holds one line, so helper #2 blocked forever holding ssh's stderr pipe open and
            // wedged the transport. The method is now unreachable, twice over.
            "-o", "PreferredAuthentications=password",
            "-o", "KbdInteractiveAuthentication=no",
            "-o", "PubkeyAuthentication=no",
            "-o", "IdentitiesOnly=yes",
            "-o", "UserKnownHostsFile=\"/tmp/spoolworks-test/known_hosts\"",
            "-o", "GlobalKnownHostsFile=/dev/null",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "LogLevel=ERROR",
            "192.168.1.50",
            SSHOperation.upload(path: path, byteCount: 10).remoteCommand,
        ])
    },

    test("the user's ~/.ssh is never consulted or written") { t in
        let transport = SSHTransport(configuration: SSHConfiguration(host: "printer.local"),
                                     password: "unused")
        let invocation = transport.invocation(
            for: .run(command: "reboot"),
            askpass: AskpassLocation(scriptPath: "/tmp/ap/askpass", fifoPath: "/tmp/ap/pw.fifo"))
        let joined = invocation.arguments.joined(separator: " ")

        t.expect(joined.contains("-F /dev/null"), "the user's ssh_config is bypassed")
        t.expect(joined.contains("GlobalKnownHostsFile=/dev/null"), "system known_hosts bypassed")
        t.expect(!joined.contains(".ssh/known_hosts"), "must never name the user's known_hosts")
        // Quoted on purpose: the default path contains a space ("Application Support") and
        // UserKnownHostsFile takes a whitespace-separated LIST, so an unquoted value made ssh
        // pin into a stray file in the user's ~/Library and leave this store empty.
        t.expect(invocation.arguments.contains("UserKnownHostsFile=\"\(SSHConfiguration.defaultKnownHostsPath)\""),
                 "uses the app-private trust store, quoted so a space cannot split it")
        t.expect(SSHConfiguration.defaultKnownHostsPath.contains("Application Support/Spoolworks"),
                 "app-private path is under Application Support, got \(SSHConfiguration.defaultKnownHostsPath)")
        t.expect(joined.contains("PubkeyAuthentication=no"), "never offers the user's keys")
    },

    test("StrictHostKeyChecking=no is not representable, and accept-new is the default") { t in
        // SPEC-04 §11.6: `no` is what both existing clients effectively do, and it makes a
        // CHANGED key invisible — precisely the case worth surfacing.
        t.equal(SSHConfiguration(host: "h").hostKeyPolicy, .acceptNew)
        for policy in [HostKeyPolicy.acceptNew, .strict] {
            t.expect(policy.rawValue != "no", "policy \(policy) must not disable checking")
        }
    },

    test("legacy algorithm options appear only when explicitly enabled") { t in
        var configuration = SSHConfiguration(host: "h")
        let off = SSHTransport(configuration: configuration, password: "x")
            .invocation(for: .run(command: "reboot"),
                        askpass: AskpassLocation(scriptPath: "/a", fifoPath: "/b"))
        t.expect(!off.arguments.joined().contains("ssh-rsa"), "off by default")

        configuration.allowLegacyAlgorithms = true
        let on = SSHTransport(configuration: configuration, password: "x")
            .invocation(for: .run(command: "reboot"),
                        askpass: AskpassLocation(scriptPath: "/a", fifoPath: "/b"))
        let joined = on.arguments.joined(separator: " ")
        t.expect(joined.contains("HostKeyAlgorithms=+ssh-rsa"), "host key algorithms")
        t.expect(joined.contains("KexAlgorithms=+diffie-hellman-group14-sha1"), "kex algorithms")
    },

    test("hosts and remote paths are validated before anything is spawned") { t in
        t.throwsError(PrinterTransportError.invalidHost("-oProxyCommand=touch /tmp/pwned")) {
            try SSHTransport.validate(host: "-oProxyCommand=touch /tmp/pwned")
        }
        t.throwsError(PrinterTransportError.invalidHost("  ")) { try SSHTransport.validate(host: "  ") }
        t.throwsError(PrinterTransportError.invalidHost("a b")) { try SSHTransport.validate(host: "a b") }
        // The validator used to check a trimmed copy while argv got the original.
        t.throwsError(PrinterTransportError.invalidHost(" 10.0.0.5")) { try SSHTransport.validate(host: " 10.0.0.5") }
        t.noThrow("plain host") { try SSHTransport.validate(host: "192.168.1.50") }
        t.noThrow("hostname") { try SSHTransport.validate(host: "k2.local") }

        t.throwsError(PrinterTransportError.invalidRemotePath("relative/path")) {
            try SSHTransport.validate(remotePath: "relative/path")
        }
        t.throwsError(PrinterTransportError.invalidRemotePath("/tmp/a\nreboot")) {
            try SSHTransport.validate(remotePath: "/tmp/a\nreboot")
        }
        t.noThrow("absolute path") {
            try SSHTransport.validate(remotePath: "/mnt/UDISK/creality/userdata/box/material_database.json")
        }
    },

    test("the transport's own description carries no credential") { t in
        let transport = SSHTransport(configuration: SSHConfiguration(host: "10.0.0.9"),
                                     password: "topsecret-value")
        t.expect(!transport.description.contains("topsecret-value"),
                 "description leaked the password: \(transport.description)")
        t.expect(transport.description.contains("root@10.0.0.9:22"), "still useful for logs")
    },
])

// MARK: - The security property that matters most

let sshSecretHandlingTests = TestSuite(name: "SSHTransport secret handling", cases: [

    test("the password appears in no argv element, no environment entry, and no log string") { t in
        let secret = "Corr3ct-H0rse-Battery!"
        var configuration = SSHConfiguration(host: "192.168.1.50")
        configuration.allowLegacyAlgorithms = true
        let transport = SSHTransport(configuration: configuration, password: secret)

        let operations: [SSHOperation] = [
            .upload(path: "/mnt/UDISK/creality/userdata/box/material_database.json", byteCount: 99),
            .download(path: "/mnt/UDISK/creality/userdata/box/material_database.json"),
            .run(command: "reboot"),
        ]
        for operation in operations {
            let invocation = transport.invocation(
                for: operation,
                askpass: AskpassLocation(scriptPath: "/tmp/ap/askpass", fifoPath: "/tmp/ap/pw.fifo"))

            t.expect(!invocation.executable.contains(secret), "executable")
            for (index, argument) in invocation.arguments.enumerated() {
                t.expect(!argument.contains(secret), "argv[\(index)] leaked the password")
            }
            for (key, value) in invocation.environment {
                t.expect(!key.contains(secret), "env key leaked the password")
                t.expect(!value.contains(secret), "env \(key) leaked the password")
            }
            t.expect(!invocation.commandLine.contains(secret), "commandLine leaked the password")
        }
    },

    test("the environment carries only the FIFO path, never the secret itself") { t in
        let transport = SSHTransport(configuration: SSHConfiguration(host: "h"), password: "s3cr3t")
        let invocation = transport.invocation(
            for: .run(command: "reboot"),
            askpass: AskpassLocation(scriptPath: "/tmp/ap/askpass", fifoPath: "/tmp/ap/pw.fifo"))

        t.equal(invocation.environment["SSH_ASKPASS"], "/tmp/ap/askpass")
        t.equal(invocation.environment["SSH_ASKPASS_REQUIRE"], "force")
        t.equal(invocation.environment[AskpassLocation.fifoEnvironmentKey], "/tmp/ap/pw.fifo")
        // A minimal environment: nothing inherited means no SSH_AUTH_SOCK and no DYLD_ surprises.
        t.equal(Set(invocation.environment.keys),
                Set(["PATH", "HOME", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE", "DISPLAY",
                     AskpassLocation.fifoEnvironmentKey]))
    },

    test("the askpass helper on disk contains no secret and is owner-only") { t in
        guard let channel = t.unwrap(try? AskpassChannel(), "askpass channel") else { return }
        defer { channel.dispose() }
        try channel.arm(password: "hunter2-not-on-disk")

        guard let script = t.unwrap(try? String(contentsOfFile: channel.location.scriptPath,
                                                encoding: .utf8), "helper script") else { return }
        t.expect(!script.contains("hunter2-not-on-disk"), "the helper script must not hold the secret")
        t.expect(script.contains(AskpassLocation.fifoEnvironmentKey), "it reads from the FIFO")

        let fm = FileManager.default
        let directoryMode = (try? fm.attributesOfItem(atPath: channel.directoryPath)[.posixPermissions]) as? NSNumber
        let scriptMode = (try? fm.attributesOfItem(atPath: channel.location.scriptPath)[.posixPermissions]) as? NSNumber
        let fifoMode = (try? fm.attributesOfItem(atPath: channel.location.fifoPath)[.posixPermissions]) as? NSNumber
        t.equal(directoryMode?.int16Value, 0o700, "directory mode")
        t.equal(scriptMode?.int16Value, 0o700, "helper mode")
        t.equal(fifoMode?.int16Value, 0o600, "FIFO mode")
    },

    test("the helper really delivers the password to a child process") { t in
        // Runs /bin/sh on the generated helper — the same thing ssh would do — and checks the
        // secret comes back out. No ssh, no network, no printer.
        guard let channel = t.unwrap(try? AskpassChannel(), "askpass channel") else { return }
        defer { channel.dispose() }
        let secret = "p@ss word with spaces"
        try channel.arm(password: secret)

        let invocation = SSHInvocation(
            executable: channel.location.scriptPath,
            arguments: [],
            environment: ["PATH": "/usr/bin:/bin",
                          AskpassLocation.fifoEnvironmentKey: channel.location.fifoPath])
        let result = try runSync { try await ProcessRunner.run(invocation: invocation, stdin: nil, timeout: 5) }

        t.equal(result.exitStatus, 0, "helper exit status (stderr: \(result.stderrText))")
        t.equal(String(decoding: result.stdout, as: UTF8.self), secret + "\n")
    },

    test("disposing the channel unlinks the whole private directory") { t in
        guard let channel = t.unwrap(try? AskpassChannel(), "askpass channel") else { return }
        let directory = channel.directoryPath
        try channel.arm(password: "gone-in-a-moment")
        t.expect(FileManager.default.fileExists(atPath: directory), "exists while armed")
        channel.dispose()
        t.expect(!FileManager.default.fileExists(atPath: directory), "removed on dispose")
    },
])

// MARK: - Error classification

private let k2DatabasePath = "/mnt/UDISK/creality/userdata/box/material_database.json"
private let download = SSHOperation.download(path: k2DatabasePath)
private let upload = SSHOperation.upload(path: k2DatabasePath, byteCount: 100)

let sshErrorClassificationTests = TestSuite(name: "SSHTransport error surfaces (SPEC-04 §8)", cases: [

    test("success is success") { t in
        t.equal(SSHTransport.classify(operation: download, exitStatus: 0, stderr: "", host: "h"), nil)
    },

    test("a wrong password becomes authenticationFailed, not raw ssh text") { t in
        // The Windows app puts SSH.NET's own message straight into a toast (SPEC-04 §8.1).
        t.equal(SSHTransport.classify(operation: download, exitStatus: 255,
                                      stderr: "root@10.0.0.5: Permission denied (password).",
                                      host: "10.0.0.5"),
                .authenticationFailed)
    },

    test("a changed host key is its own case, never auto-accepted") { t in
        let stderr = """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        Host key verification failed.
        """
        t.equal(SSHTransport.classify(operation: download, exitStatus: 255, stderr: stderr, host: "k2.local"),
                .hostKeyChanged(host: "k2.local"))
    },

    test("an unpinned key under the strict policy is hostKeyUnverified") { t in
        t.equal(SSHTransport.classify(operation: download, exitStatus: 255,
                                      stderr: "No RSA host key is known for k2.local.\nHost key verification failed.",
                                      host: "k2.local"),
                .hostKeyUnverified(host: "k2.local"))
    },

    test("network failures are distinguishable from each other") { t in
        t.equal(SSHTransport.classify(operation: download, exitStatus: 255,
                                      stderr: "ssh: Could not resolve hostname nope: nodename nor servname provided",
                                      host: "nope"),
                .connectionFailed("no such host \"nope\""))
        t.equal(SSHTransport.classify(operation: download, exitStatus: 255,
                                      stderr: "ssh: connect to host 10.0.0.5 port 22: Connection refused",
                                      host: "10.0.0.5"),
                .connectionFailed("10.0.0.5 refused the connection on the SSH port"))
        t.equal(SSHTransport.classify(operation: download, exitStatus: 255,
                                      stderr: "ssh: connect to host 10.0.0.5 port 22: Operation timed out",
                                      host: "10.0.0.5"),
                .connectionFailed("10.0.0.5 did not answer"))
        t.equal(SSHTransport.classify(operation: download, exitStatus: 255,
                                      stderr: "ssh: connect to host k2 port 22: No route to host",
                                      host: "k2"),
                .connectionFailed("k2 is unreachable"))
    },

    test("an old Dropbear's algorithm set produces an actionable message") { t in
        // Spec OPEN QUESTION #1: nobody has probed real hardware, so this is the error that
        // tells a user to turn on legacy algorithm support.
        let error = SSHTransport.classify(
            operation: download, exitStatus: 255,
            stderr: "Unable to negotiate with 10.0.0.5 port 22: no matching key exchange method found.",
            host: "10.0.0.5")
        guard case .connectionFailed(let detail)? = error else {
            t.expect(false, "expected connectionFailed, got \(String(describing: error))")
            return
        }
        t.expect(detail.contains("legacy"), "message should mention legacy algorithms: \(detail)")
    },

    test("a remote permission problem is not reported as a wrong password") { t in
        // ssh itself exits 255; a remote `cat` that cannot open the file exits 1. The text
        // check alone put this down as authenticationFailed, sending the user to re-enter a
        // password that was fine.
        let path = "/mnt/UDISK/creality/userdata/box/material_database.json"
        t.equal(SSHTransport.classify(operation: download, exitStatus: 1,
                                      stderr: "cat: can't open '\(path)': Permission denied",
                                      host: "h"),
                .remoteFileNotFound(path: path))
    },

    test("an error's own sentence is what localizedDescription shows") { t in
        // Every UI surface shows `error.localizedDescription`, which reads `errorDescription`,
        // not `description`. Without the conformance it showed "The operation couldn't be
        // completed. (SpoolworksCore.PrinterTransportError error 3.)".
        let error: Error = PrinterTransportError.authenticationFailed
        t.equal(error.localizedDescription, PrinterTransportError.authenticationFailed.description)
    },

    test("a missing remote database is remoteFileNotFound") { t in
        t.equal(SSHTransport.classify(operation: download, exitStatus: 1,
                                      stderr: "cat: can't open '/mnt/UDISK/creality/userdata/box/material_database.json': No such file or directory",
                                      host: "h"),
                .remoteFileNotFound(path: "/mnt/UDISK/creality/userdata/box/material_database.json"))
    },

    test("a short upload fails the size guard and never reaches the rename") { t in
        // The `[ "$(wc -c < tmp)" -eq N ]` guard exits 1 silently. The printer's database is
        // untouched — which is the whole point, since the Windows app truncates it instead.
        t.equal(SSHTransport.classify(operation: upload, exitStatus: 1, stderr: "", host: "h"),
                .uploadIncomplete(path: "/mnt/UDISK/creality/userdata/box/material_database.json"))
    },

    test("a read-only remote filesystem surfaces the remote message") { t in
        let error = SSHTransport.classify(operation: upload, exitStatus: 1,
                                          stderr: "sh: can't create ...: Read-only file system",
                                          host: "h")
        guard case .remoteCommandFailed(let status, let message)? = error else {
            t.expect(false, "expected remoteCommandFailed, got \(String(describing: error))")
            return
        }
        t.equal(status, 1)
        t.expect(message.contains("Read-only file system"), "message: \(message)")
    },

    test("reboot tearing down the connection is success, not failure") { t in
        // SPEC-04 §11.5: `reboot` always kills the connection. The Windows app only survives
        // this by accident via a 5s CommandTimeout.
        let reboot = SSHOperation.run(command: "reboot")
        t.equal(SSHTransport.classify(operation: reboot, exitStatus: 255,
                                      stderr: "Connection to 10.0.0.5 closed by remote host.",
                                      host: "10.0.0.5"),
                nil)
        t.equal(SSHTransport.classify(operation: reboot, exitStatus: 0, stderr: "", host: "h"), nil)
        // But a genuine auth failure on reboot is still a failure.
        t.equal(SSHTransport.classify(operation: reboot, exitStatus: 255,
                                      stderr: "Permission denied (password).", host: "h"),
                .authenticationFailed)
    },
])

// MARK: - Deadline and cancellation (real subprocess, no ssh)

let processRunnerTests = TestSuite(name: "ProcessRunner deadline & cancellation (SPEC-04 §7)", cases: [

    test("stdin is streamed to the child and stdout comes back whole") { t in
        // This is the exact path a database upload uses: bytes in on stdin, `cat` on the far end.
        let payload = Data(String(repeating: "material_database", count: 5_000).utf8)
        let invocation = SSHInvocation(executable: "/bin/cat", arguments: [],
                                       environment: ["PATH": "/usr/bin:/bin"])
        let result = try runSync { try await ProcessRunner.run(invocation: invocation,
                                                               stdin: payload, timeout: 10) }
        t.equal(result.exitStatus, 0)
        t.equal(result.stdout.count, payload.count, "large payloads must not deadlock the pipes")
        t.expect(result.stdout == payload, "bytes round-tripped unchanged")
    },

    test("a child that exits without reading a large stdin does not kill the process") { t in
        // The defect: ssh failing authentication with a 478 KB database queued behind a full
        // 64 KiB pipe closed the read end under a blocked write, and SIGPIPE — which `try?`
        // cannot catch — terminated the whole app. This harness would have died with status
        // 141 here instead of reporting anything.
        let payload = Data(repeating: 0x41, count: 512 * 1024)
        let invocation = SSHInvocation(executable: "/bin/sh", arguments: ["-c", "sleep 0.3; exit 255"],
                                       environment: ["PATH": "/usr/bin:/bin"])
        let result = try runSync { try await ProcessRunner.run(invocation: invocation,
                                                               stdin: payload, timeout: 10) }
        t.equal(result.exitStatus, 255, "the child's own status is what comes back")
    },

    test("a stalled transfer hits the deadline instead of hanging forever") { t in
        // The Windows app never sets ScpClient.OperationTimeout, so a stall is infinite.
        let invocation = SSHInvocation(executable: "/bin/sleep", arguments: ["30"],
                                       environment: ["PATH": "/usr/bin:/bin"])
        let started = Date()
        let error = errorFrom { try await ProcessRunner.run(invocation: invocation, stdin: nil, timeout: 0.4) }
        let elapsed = Date().timeIntervalSince(started)

        t.equal(error as? PrinterTransportError, .timedOut(seconds: 0.4))
        t.expect(elapsed < 10, "should have given up promptly, took \(elapsed)s")
    },

    test("cancelling the task kills the child") { t in
        let invocation = SSHInvocation(executable: "/bin/sleep", arguments: ["30"],
                                       environment: ["PATH": "/usr/bin:/bin"])
        let box = Box<PrinterTransportError?>()
        let done = DispatchSemaphore(value: 0)
        let started = Date()

        let task = Task {
            do {
                _ = try await ProcessRunner.run(invocation: invocation, stdin: nil, timeout: 30)
                box.result = .success(nil)
            } catch {
                box.result = .success(error as? PrinterTransportError)
            }
            done.signal()
        }
        // Give the child a moment to actually exist, then cancel.
        Thread.sleep(forTimeInterval: 0.3)
        task.cancel()

        t.equal(done.wait(timeout: .now() + 10), .success, "cancellation must unblock promptly")
        t.equal(try? box.result?.get() ?? nil, PrinterTransportError.cancelled)
        t.expect(Date().timeIntervalSince(started) < 10, "did not wait out the 30s child")
    },

    test("a missing executable is a typed error, not a crash") { t in
        let invocation = SSHInvocation(executable: "/nonexistent/ssh", arguments: [],
                                       environment: [:])
        let error = errorFrom { try await ProcessRunner.run(invocation: invocation, stdin: nil, timeout: 5) }
        guard case .transportUnavailable? = error as? PrinterTransportError else {
            t.expect(false, "expected transportUnavailable, got \(String(describing: error))")
            return
        }
    },
])

// MARK: - Upload flow

let printerUploadTests = TestSuite(name: "PrinterService upload (SPEC-04 §3.1)", cases: [

    test("K2: database only, then reboot") { t in
        let mock = MockPrinterTransport()
        let service = PrinterService(transport: mock)
        let model = PrinterModel(profileName: "K2 Plus")!

        let result = try runSync {
            try await service.upload(database: sampleDatabase, to: model)
        }

        t.equal(mock.uploadedPaths, ["/mnt/UDISK/creality/userdata/box/material_database.json"])
        t.equal(mock.commands, ["reboot"])
        t.expect(!result.wroteMaterialOption, "K2 must not get material_option.json")
        t.expect(result.didReboot)
    },

    test("K1: database, then material_option.json, then a single reboot") { t in
        let mock = MockPrinterTransport()
        let service = PrinterService(transport: mock)

        _ = try runSync { try await service.upload(database: sampleDatabase,
                                                   to: PrinterModel(profileName: "K1")!) }

        t.equal(mock.uploadedPaths, [
            "/usr/data/creality/userdata/box/material_database.json",
            "/usr/data/creality/userdata/box/material_option.json",
        ])
        t.equal(mock.commands, ["reboot"], "exactly one reboot, after the option file")
        // Ordering matters: the option file must be in place before the restart, which is why
        // Android hands the reboot to saveMatOption on K1 (Utils.java:478-484).
        t.equal(mock.calls.last, .run(command: "reboot"))
    },

    test("K1 Max gets material_option.json — Android's behaviour, not Windows'") { t in
        // Windows tests pType.Equals("k1", OrdinalIgnoreCase) exactly (UploadForm.cs:161), so
        // K1 Max never gets the file even though its database goes to the K1 path.
        let mock = MockPrinterTransport()
        _ = try runSync { try await PrinterService(transport: mock)
            .upload(database: sampleDatabase, to: PrinterModel(profileName: "K1 Max")!) }
        t.equal(mock.uploadedPaths, [
            "/usr/data/creality/userdata/box/material_database.json",
            "/usr/data/creality/userdata/box/material_option.json",
        ])
    },

    test("the material_option override wins over the family default in both directions") { t in
        let off = MockPrinterTransport()
        _ = try runSync { try await PrinterService(transport: off).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K1")!,
            options: UploadOptions(writeMaterialOption: false)) }
        t.equal(off.uploadedPaths.count, 1, "override off")

        let on = MockPrinterTransport()
        _ = try runSync { try await PrinterService(transport: on).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K2 Plus")!,
            options: UploadOptions(writeMaterialOption: true)) }
        t.equal(on.uploadedPaths.count, 2, "override on")
        t.equal(on.uploadedPaths.last, "/mnt/UDISK/creality/userdata/box/material_option.json")
    },

    test("prevent DB updates stamps 9876543210 and never contacts the printer for a version") { t in
        let mock = MockPrinterTransport()
        let result = try runSync { try await PrinterService(transport: mock).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K2")!,
            options: UploadOptions(preventDatabaseUpdates: true, reboot: false)) }

        t.equal(result.version, "9876543210")
        t.equal(try MaterialDatabaseDocument.version(in: result.uploadedDatabase), "9876543210")
        t.expect(!mock.calls.contains(.download(path: "/mnt/UDISK/creality/userdata/box/material_database.json")),
                 "no version read is needed when preventing updates")
        // The bytes that went over the wire carry the stamp, not the originals.
        let uploaded = t.unwrap(mock.uploads["/mnt/UDISK/creality/userdata/box/material_database.json"])
        t.equal(try MaterialDatabaseDocument.version(in: uploaded ?? Data()), "9876543210")
    },

    test("without prevent, the printer's own version is read and stamped") { t in
        let mock = MockPrinterTransport()
        mock.seed("/mnt/UDISK/creality/userdata/box/material_database.json",
                  text: #"{"code":0,"result":{"version":"1758907369","count":0,"list":[]}}"#)

        let result = try runSync { try await PrinterService(transport: mock).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K2")!,
            options: UploadOptions(preventDatabaseUpdates: false, reboot: false)) }

        t.equal(result.version, "1758907369")
        t.equal(mock.calls.first, .download(path: "/mnt/UDISK/creality/userdata/box/material_database.json"))
    },

    test("an unreachable printer fails the version read instead of silently stamping 0") { t in
        // Windows' GetPrinterVersion swallows everything and returns "0" (Utils.cs:678-681).
        let mock = MockPrinterTransport()
        mock.failDownload = .connectionFailed("10.0.0.5 did not answer")

        let error = errorFrom { try await PrinterService(transport: mock).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K2")!,
            options: UploadOptions(preventDatabaseUpdates: false)) }

        t.equal(error as? PrinterTransportError, .connectionFailed("10.0.0.5 did not answer"))
        t.expect(mock.uploadedPaths.isEmpty, "nothing must be written after a failed version read")
    },

    test("reboot can be declined") { t in
        let mock = MockPrinterTransport()
        let result = try runSync { try await PrinterService(transport: mock).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K2")!,
            options: UploadOptions(reboot: false)) }
        t.equal(mock.commands, [])
        t.expect(!result.didReboot)
    },

    test("reboot dropping the connection counts as success") { t in
        let mock = MockPrinterTransport()
        mock.failRun = .remoteCommandFailed(exitStatus: 255,
                                            message: "Connection to 10.0.0.5 closed by remote host.")
        let result = try runSync { try await PrinterService(transport: mock).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K2")!) }
        t.expect(result.didReboot, "a torn-down connection after reboot is expected, not an error")
    },

    test("a genuine failure during reboot still propagates") { t in
        let mock = MockPrinterTransport()
        mock.failRun = .authenticationFailed
        let error = errorFrom { try await PrinterService(transport: mock)
            .upload(database: sampleDatabase, to: PrinterModel(profileName: "K2")!) }
        t.equal(error as? PrinterTransportError, .authenticationFailed)
    },

    test("a failed database upload never writes material_option.json or reboots") { t in
        let mock = MockPrinterTransport()
        mock.failUpload = .uploadIncomplete(path: "/usr/data/creality/userdata/box/material_database.json")
        let error = errorFrom { try await PrinterService(transport: mock)
            .upload(database: sampleDatabase, to: PrinterModel(profileName: "K1")!) }

        t.equal(error as? PrinterTransportError,
                .uploadIncomplete(path: "/usr/data/creality/userdata/box/material_database.json"))
        t.equal(mock.commands, [], "must not reboot after a failed upload")
    },

    test("malformed input is rejected before anything is sent") { t in
        let mock = MockPrinterTransport()
        let error = errorFrom { try await PrinterService(transport: mock)
            .upload(database: Data("not json".utf8), to: PrinterModel(profileName: "K2")!) }
        t.equal(error as? PrinterServiceError, .databaseNotJSON)
        t.expect(mock.calls.isEmpty, "nothing should reach the printer")
    },

    test("progress is reported in order and reaches 1.0") { t in
        let collected = Box<[PrinterProgress]>()
        collected.result = .success([])
        let lock = NSLock()
        let mock = MockPrinterTransport()

        _ = try runSync {
            try await PrinterService(transport: mock).upload(
                database: sampleDatabase, to: PrinterModel(profileName: "K1")!,
                progress: { progress in
                    lock.lock()
                    var current = (try? collected.result?.get()) ?? []
                    current.append(progress)
                    collected.result = .success(current)
                    lock.unlock()
                })
        }

        let stages = (try collected.result!.get()).map(\.stage)
        t.equal(stages, [.preparing, .uploadingDatabase, .uploadingMaterialOption, .rebooting, .finished])
        t.equal((try collected.result!.get()).last?.fractionCompleted, 1.0)
    },

    test("cancellation stops the flow mid-upload") { t in
        let mock = MockPrinterTransport()
        let reached = DispatchSemaphore(value: 0)
        mock.beforeCall = { _ in
            reached.signal()
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }

        let box = Box<Error?>()
        let done = DispatchSemaphore(value: 0)
        let task = Task {
            do {
                _ = try await PrinterService(transport: mock)
                    .upload(database: sampleDatabase, to: PrinterModel(profileName: "K1")!)
                box.result = .success(nil)
            } catch {
                box.result = .success(error)
            }
            done.signal()
        }
        t.equal(reached.wait(timeout: .now() + 5), .success, "flow should have started")
        task.cancel()
        t.equal(done.wait(timeout: .now() + 5), .success, "cancellation must unblock promptly")

        let thrown = try box.result!.get()
        t.expect(thrown is CancellationError || (thrown as? PrinterTransportError) == .cancelled,
                 "expected cancellation, got \(String(describing: thrown))")
        t.equal(mock.commands, [], "must not have rebooted")
    },

    test("reset pushes a cloud database, keeps its version, and always reboots") { t in
        // SPEC-04 §3.1 reset path: the reboot checkbox is hidden and ignored in this mode, and
        // Windows uploads the cloud JSON verbatim without touching result.version.
        let mock = MockPrinterTransport()
        let result = try runSync { try await PrinterService(transport: mock)
            .reset(to: PrinterModel(profileName: "K2 Plus")!, withCloudDatabase: sampleDatabase) }
        t.expect(result.didReboot)
        t.equal(mock.commands, ["reboot"])
        t.equal(result.version, "1746005657", "the factory version must survive a reset")
        t.expect(mock.calls.first != .download(path: "/mnt/UDISK/creality/userdata/box/material_database.json"),
                 "reset must not need to read the printer's version")
    },

    test("the version stamp can be chosen explicitly") { t in
        let mock = MockPrinterTransport()
        let result = try runSync { try await PrinterService(transport: mock).upload(
            database: sampleDatabase, to: PrinterModel(profileName: "K2")!,
            options: UploadOptions(versionStamp: .keepDocumentVersion, reboot: false)) }
        t.equal(result.version, "1746005657")
        t.expect(!UploadOptions(versionStamp: .keepDocumentVersion).preventsDatabaseUpdates)
        t.expect(UploadOptions().preventsDatabaseUpdates, "the checkbox defaults to on")
    },
])

// MARK: - Database document

let materialDatabaseDocumentTests = TestSuite(name: "material_database.json handling (SPEC-04 §10.3)", cases: [

    test("version is read from result.version") { t in
        t.equal(try MaterialDatabaseDocument.version(in: sampleDatabase), "1746005657")
    },

    test("a numeric version is accepted as well as a string one") { t in
        let data = Data(#"{"result":{"version":1746005657,"list":[]}}"#.utf8)
        t.equal(try MaterialDatabaseDocument.version(in: data), "1746005657")
    },

    test("missing or malformed documents throw rather than defaulting") { t in
        t.throwsError(PrinterServiceError.databaseNotJSON) {
            _ = try MaterialDatabaseDocument.version(in: Data("nope".utf8))
        }
        t.throwsError(PrinterServiceError.missingVersionField) {
            _ = try MaterialDatabaseDocument.version(in: Data(#"{"result":{}}"#.utf8))
        }
    },

    test("stamping replaces the version and repairs result.count") { t in
        let stamped = try MaterialDatabaseDocument.stamping(sampleDatabase, version: "9876543210")
        t.equal(try MaterialDatabaseDocument.version(in: stamped), "9876543210")
        let result = jsonObject(stamped)["result"] as? [String: Any]
        t.equal(result?["count"] as? Int, 3, "count must equal list.length")
        t.equal((result?["list"] as? [Any])?.count, 3, "entries survive the round trip")
    },

    test("stamping preserves non-ASCII text, unlike the Windows ASCII round trip") { t in
        // Utils.cs:524/639/674 and MatDb.cs:89/186 use Encoding.ASCII, turning these into '?'.
        let source = Data(#"""
        {"result":{"version":"1","count":1,"list":[
          {"base":{"brand":"Créalité","name":"Grün — 緑","meterialType":"PLA"}}]}}
        """#.utf8)
        let stamped = try MaterialDatabaseDocument.stamping(source, version: "9876543210")
        let text = String(decoding: stamped, as: UTF8.self)
        t.expect(text.contains("Créalité"), "accented brand survived")
        t.expect(text.contains("Grün — 緑"), "non-Latin name survived")
        t.expect(!text.contains("?"), "nothing was mangled into '?'")
    },

    test("material_option.json is a brand → meterialType → newline-joined names index") { t in
        let document = try MaterialDatabaseDocument.materialOptionDocument(from: sampleDatabase)
        let options = jsonObject(document)
        t.equal((options["Creality"] as? [String: String])?["PLA"], "Hyper PLA\nCR-PLA")
        t.equal((options["Polymaker"] as? [String: String])?["ABS"], "PolyLite ABS")
        t.equal(options.count, 2, "one key per brand")
        // `meterialType` is misspelled in the firmware format and must stay that way.
        t.expect(String(decoding: document, as: UTF8.self).contains("PLA"))
    },

    test("entries with an incomplete base block are skipped, not fatal") { t in
        let source = Data(#"""
        {"result":{"list":[
          {"base":{"brand":"A","name":"good","meterialType":"PLA"}},
          {"base":{"brand":"B"}},
          {"nobase":true}]}}
        """#.utf8)
        let options = jsonObject(try MaterialDatabaseDocument.materialOptionDocument(from: source))
        t.equal(options.count, 1)
        t.equal((options["A"] as? [String: String])?["PLA"], "good")
    },
])

// MARK: - Update / download flow

let printerUpdateTests = TestSuite(name: "PrinterService update (SPEC-04 §3.2)", cases: [

    test("download reads material_database.json from the per-type path") { t in
        let mock = MockPrinterTransport()
        mock.seed("/usr/data/creality/userdata/box/material_database.json", with: sampleDatabase)
        let data = try runSync { try await PrinterService(transport: mock)
            .downloadDatabaseFromPrinter(PrinterModel(profileName: "K1 Max")!) }
        t.equal(data, sampleDatabase)
        t.equal(mock.calls, [.download(path: "/usr/data/creality/userdata/box/material_database.json")])
    },

    test("a missing remote database surfaces remoteFileNotFound") { t in
        let mock = MockPrinterTransport()
        let error = errorFrom { try await PrinterService(transport: mock)
            .downloadDatabaseFromPrinter(PrinterModel(profileName: "K2")!) }
        t.equal(error as? PrinterTransportError,
                .remoteFileNotFound(path: "/mnt/UDISK/creality/userdata/box/material_database.json"))
    },

    test("version comparison is numeric, matching long.Parse in UpdateForm.cs:112") { t in
        let mock = MockPrinterTransport()
        mock.seed("/mnt/UDISK/creality/userdata/box/material_database.json", with: sampleDatabase)
        let service = PrinterService(transport: mock)
        let model = PrinterModel(profileName: "K2")!

        t.equal(try runSync { try await service.checkForUpdate(on: model, localVersion: "1746005656") },
                .available(printerVersion: "1746005657", localVersion: "1746005656"))
        t.equal(try runSync { try await service.checkForUpdate(on: model, localVersion: "1746005657") },
                .upToDate(version: "1746005657"))
        t.equal(try runSync { try await service.checkForUpdate(on: model, localVersion: "9876543210") },
                .upToDate(version: "1746005657"))
    },

    test("an unparsable version is reported rather than swallowed") { t in
        let mock = MockPrinterTransport()
        mock.seed("/mnt/UDISK/creality/userdata/box/material_database.json",
                  text: #"{"result":{"version":"not-a-number"}}"#)
        let error = errorFrom { try await PrinterService(transport: mock)
            .checkForUpdate(on: PrinterModel(profileName: "K2")!, localVersion: "1") }
        t.equal(error as? PrinterServiceError, .unparsableVersion("not-a-number"))
    },

    test("cloud calls fail cleanly when no cloud client was supplied") { t in
        let error = errorFrom { try await PrinterService(transport: MockPrinterTransport())
            .cloudPrinterModels() }
        t.equal(error as? PrinterServiceError, .cloudUnavailable)
    },
])

// MARK: - Creality Cloud

let crealityCloudTests = TestSuite(name: "CrealityCloud (SPEC-04 §5)", cases: [

    test("the two API URLs are exactly the documented ones") { t in
        t.equal(CrealityCloudRequest.printerListURL.absoluteString,
                "https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/printerList")
        t.equal(CrealityCloudRequest.materialListURL.absoluteString,
                "https://api.crealitycloud.com/api/cxy/v2/slice/profile/official/materialList")
    },

    test("the __CXY_ header set matches both existing clients byte for byte") { t in
        let request = CrealityCloudRequest.apiRequest(url: CrealityCloudRequest.printerListURL,
                                                      duid: "DUID-1", requestID: "REQ-1")
        t.equal(request.httpMethod, "POST")
        t.equal(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        t.equal(request.value(forHTTPHeaderField: "__CXY_BRAND_"), "creality")
        t.equal(request.value(forHTTPHeaderField: "__CXY_UID_"), "")
        t.equal(request.value(forHTTPHeaderField: "__CXY_OS_LANG_"), "0")
        t.equal(request.value(forHTTPHeaderField: "__CXY_DUID_"), "DUID-1")
        t.equal(request.value(forHTTPHeaderField: "__CXY_APP_VER_"), "1.0")
        t.equal(request.value(forHTTPHeaderField: "__CXY_APP_CH_"), "CP_Beta")
        t.equal(request.value(forHTTPHeaderField: "__CXY_TIMEZONE_"), "28800")
        t.equal(request.value(forHTTPHeaderField: "__CXY_APP_ID_"), "creality_model")
        t.equal(request.value(forHTTPHeaderField: "__CXY_REQUESTID_"), "REQ-1")
        t.equal(request.value(forHTTPHeaderField: "__CXY_PLATFORM_"), "11")
        // The User-Agent impersonates Bambu Studio in both clients; preserved deliberately.
        t.equal(request.value(forHTTPHeaderField: "__CXY_OS_VER_"), CrealityCloudRequest.userAgent)
        t.expect(CrealityCloudRequest.userAgent.hasPrefix("BBL-Slicer/v01.09.03.50"),
                 "User-Agent: \(CrealityCloudRequest.userAgent)")
    },

    test("request bodies differ only by pageSize on materialList") { t in
        t.equal(String(decoding: CrealityCloudRequest.body(for: CrealityCloudRequest.printerListURL), as: UTF8.self),
                #"{"engineVersion":"3.0.0"}"#)
        t.equal(String(decoding: CrealityCloudRequest.body(for: CrealityCloudRequest.materialListURL), as: UTF8.self),
                #"{"engineVersion":"3.0.0","pageSize":500}"#)
    },

    test("the zip GET carries no headers at all") { t in
        let request = CrealityCloudRequest.zipRequest(url: URL(string: "https://cdn.example/x.zip")!)
        t.equal(request.httpMethod, "GET")
        t.equal(request.allHTTPHeaderFields ?? [:], [:])
    },

    test("printerList is parsed and filtered to the requested nozzle") { t in
        let http = MockHTTPClient()
        http.stub(CrealityCloudRequest.printerListURL, json: """
        {"code":0,"msg":"ok","result":{"printerList":[
          {"name":"K2 Plus","nozzleDiameter":["0.4","0.6"],"zipUrl":"https://cdn.example/k2.zip","version":"1758907369"},
          {"name":"Big Nozzle Only","nozzleDiameter":["0.8"],"zipUrl":"https://cdn.example/x.zip"}
        ]}}
        """)
        let cloud = CrealityCloud(http: http, identifierProvider: { "fixed" })
        let printers = try runSync { try await cloud.printerList(nozzle: "0.4") }

        t.equal(printers.count, 1, "0.8-only models are invisible, as in both existing clients")
        t.equal(printers.first?.name, "K2 Plus")
        t.equal(printers.first?.version, "1758907369")
    },

    test("an API-level error code is surfaced, not swallowed") { t in
        // Windows swallows every cloud failure with no user feedback at all (SPEC-04 §8.3).
        let http = MockHTTPClient()
        http.stub(CrealityCloudRequest.printerListURL, json: #"{"code":401,"msg":"unauthorized"}"#)
        let error = errorFrom { try await CrealityCloud(http: http).printerList(nozzle: "0.4") }
        t.equal(error as? CrealityCloudError, .apiError(code: 401, message: "unauthorized"))
    },

    test("an HTTP error status is its own case") { t in
        let http = MockHTTPClient()
        http.stub(CrealityCloudRequest.printerListURL, json: "{}", statusCode: 503)
        let error = errorFrom { try await CrealityCloud(http: http).printerList(nozzle: "0.4") }
        t.equal(error as? CrealityCloudError, .httpStatus(503))
    },

    // CHANGED EXPECTATION. The stub host used to be `cdn.example`. The zipUrl is now required to
    // be https on an allow-listed Creality host before it is fetched at all — see the
    // zipUrl-validation cases in IntegrityFixTests — so the fixture uses a host that passes.
    test("the zipUrl GET follows the server-supplied URL") { t in
        let http = MockHTTPClient()
        http.stub(CrealityCloudRequest.printerListURL, json: """
        {"code":0,"result":{"printerList":[
          {"name":"K2 Plus","nozzleDiameter":["0.4"],"zipUrl":"https://cdn.crealitycloud.com/k2.zip"}]}}
        """)
        http.stub(URL(string: "https://cdn.crealitycloud.com/k2.zip")!,
                  with: .init(body: Data([0x50, 0x4B, 0x03, 0x04])))

        let zip = try runSync { try await CrealityCloud(http: http)
            .profileZip(forPrinterNamed: "k2 plus", nozzle: "0.4") }
        t.equal(Array(zip), [0x50, 0x4B, 0x03, 0x04], "the PK zip header came back")
        t.equal(http.requests.count, 2)
        t.equal(http.requests.last?.allHTTPHeaderFields ?? [:], [:], "the CDN GET stays header-free")
    },

    test("a model with no zipUrl is distinguishable from a model that does not exist") { t in
        let http = MockHTTPClient()
        http.stub(CrealityCloudRequest.printerListURL, json: """
        {"code":0,"result":{"printerList":[{"name":"K2 Plus","nozzleDiameter":["0.4"],"zipUrl":""}]}}
        """)
        let cloud = CrealityCloud(http: http)
        t.equal(errorFrom { try await cloud.profileZip(forPrinterNamed: "K2 Plus", nozzle: "0.4") }
                    as? CrealityCloudError,
                .noProfileForNozzle(printer: "K2 Plus", nozzle: "0.4"))
        t.equal(errorFrom { try await cloud.profileZip(forPrinterNamed: "Nebula", nozzle: "0.4") }
                    as? CrealityCloudError,
                .printerNotFound("Nebula"))
    },

    test("an unstubbed URL fails loudly, so no test can reach the real API by accident") { t in
        let http = MockHTTPClient()
        let error = errorFrom { try await CrealityCloud(http: http).materialList() }
        guard case .transport(let detail)? = error as? CrealityCloudError else {
            t.expect(false, "expected a transport error, got \(String(describing: error))")
            return
        }
        t.expect(detail.contains("no stub"), detail)
    },
])

// MARK: - Credentials

let credentialStoreTests = TestSuite(name: "Credentials (SPEC-04 §1.4)", cases: [

    // These run against the in-memory store only. The Keychain-backed store is never exercised
    // here: from a plain SwiftPM executable with no bundle identifier it would either prompt the
    // user or fail with errSecMissingEntitlement, and a test must not touch a real keychain.

    test("round trip, overwrite, delete") { t in
        let store = InMemoryCredentialStore()
        t.equal(try store.password(forHost: "10.0.0.5"), nil, "nothing stored yet")

        try store.setPassword("first", forHost: "10.0.0.5")
        t.equal(try store.password(forHost: "10.0.0.5"), "first")

        try store.setPassword("second", forHost: "10.0.0.5")
        t.equal(try store.password(forHost: "10.0.0.5"), "second", "set must overwrite")

        try store.deletePassword(forHost: "10.0.0.5")
        t.equal(try store.password(forHost: "10.0.0.5"), nil)
        t.noThrow("deleting twice") { try store.deletePassword(forHost: "10.0.0.5") }
    },

    test("credentials are keyed per host") { t in
        let store = InMemoryCredentialStore()
        try store.setPassword("a", forHost: "k1.local")
        try store.setPassword("b", forHost: "k2.local")
        t.equal(try store.password(forHost: "k1.local"), "a")
        t.equal(try store.password(forHost: "k2.local"), "b")
    },

    test("empty host or password is rejected") { t in
        let store = InMemoryCredentialStore()
        t.throwsError(CredentialError.emptyHost) { try store.setPassword("x", forHost: "") }
        t.throwsError(CredentialError.emptyPassword) { try store.setPassword("", forHost: "h") }
        t.throwsError(CredentialError.emptyHost) { _ = try store.password(forHost: "") }
    },

    test("vendor defaults are the documented factory values") { t in
        t.equal(VendorDefaultPassword.k1, "creality_2023")
        t.equal(VendorDefaultPassword.k2, "creality_2024")
        t.equal(VendorDefaultPassword.hi, "Creality2024", "capitalised, unlike the K2 default")
        t.equal(VendorDefaultPassword.i7, "creality_2025")
    },

    test("a transport can be built from a store without the password being held anywhere else") { t in
        let store = InMemoryCredentialStore()
        try store.setPassword("from-keychain", forHost: "10.0.0.5")

        let transport = SSHTransport(configuration: SSHConfiguration(host: "10.0.0.5"),
                                     passwordProvider: { try store.password(forHost: "10.0.0.5") ?? "" })
        let invocation = transport.invocation(
            for: .run(command: "reboot"),
            askpass: AskpassLocation(scriptPath: "/tmp/ap/askpass", fifoPath: "/tmp/ap/pw.fifo"))
        t.expect(!invocation.commandLine.contains("from-keychain"),
                 "the provider's secret must not reach the command line")
        t.expect(!transport.description.contains("from-keychain"))
    },
])
