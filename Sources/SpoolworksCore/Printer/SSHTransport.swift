import Foundation
#if canImport(Darwin)
import Darwin
#endif

// SPEC-04 §11.3 / §11.5 — the transport shells out to the system /usr/bin/ssh rather than
// linking a pure-Swift SSH stack.
//
// Why (spec's reasoning, restated because it is load-bearing for everything below):
//
//   * Creality printers run an old busybox/Dropbear. swift-nio-ssh implements *only* modern
//     algorithms with no configuration knob to relax them, so it may fail key exchange outright.
//     Apple's OpenSSH speaks the legacy suites and lets us re-enable them per invocation
//     (`-o KexAlgorithms=+…`). Interop certainty beats elegance here.
//   * `ssh host 'cat > path'` / `ssh host 'cat path'` needs only an exec channel. That dodges
//     both the OpenSSH-9 "scp now speaks SFTP" trap and the possibility that the printer has no
//     sftp-server at all, and it reduces the K1/K2 difference to a string substitution.
//   * /usr/bin/ssh is part of the macOS base system, so nothing has to be bundled.
//
// Deltas from the Windows app deliberately introduced here (SPEC-04 §11.5 "port-behaviour
// deltas"): a real transfer timeout, real cancellation, UTF-8 rather than ASCII, an app-private
// known_hosts, write-to-temp-then-rename with a size check, and the password kept out of argv,
// out of the environment, and off disk.

// MARK: - Host-key policy

/// How to treat the printer's host key. SPEC-04 §11.6.
///
/// `StrictHostKeyChecking=no` is deliberately not representable: it is what both existing
/// clients do (Windows accepts any key, Android sets the option literally) and it makes the one
/// case worth surfacing — a *changed* key — invisible.
public enum HostKeyPolicy: String, Equatable, Sendable {
    /// Trust on first use: pin silently the first time, fail loudly if the key later changes.
    case acceptNew = "accept-new"
    /// Refuse anything not already pinned.
    case strict = "yes"

    var sshOptionValue: String { rawValue }
}

// MARK: - Configuration

/// Everything needed to invoke `ssh` for one printer, minus the password.
///
/// The password is *not* a member: it is fetched lazily at connection time from `Credentials`
/// and handed to the child over a private FIFO. Keeping it out of this struct means the
/// configuration can be logged, diffed, and shown in a UI without redaction.
public struct SSHConfiguration: Equatable, Sendable {

    /// Hostname or IP exactly as the user typed it. The Windows app keys its saved settings on
    /// this string too, so a re-addressed printer looks "new" and lands in the silent TOFU path
    /// rather than the scary changed-key path (SPEC-04 §11.6).
    public var host: String

    /// Hardcoded to 22 in all seven construction sites in the Windows app (SPEC-04 §1.1).
    public var port: Int

    /// Hardcoded to `root` everywhere. There is no other account on these printers.
    public var username: String

    /// Mirrors `ConnectionInfo.Timeout = 5s` (SPEC-04 §7).
    public var connectTimeout: TimeInterval

    /// The deadline the Windows app is missing entirely: `ScpClient.OperationTimeout` is never
    /// set there, so a stalled transfer hangs forever with a frozen UI (SPEC-04 §7).
    public var operationTimeout: TimeInterval

    /// App-private known_hosts. Never the user's `~/.ssh/known_hosts` — a 3D-printer utility
    /// must not be able to corrupt the user's real SSH trust store (SPEC-04 §11.6).
    public var knownHostsPath: String

    public var hostKeyPolicy: HostKeyPolicy

    /// Re-enables the legacy algorithms an old Dropbear may be limited to. Off by default;
    /// OPEN QUESTION #1 in the spec — nobody has run `ssh -vv` against real hardware yet — so
    /// this is a switch the UI can flip after a failed negotiation rather than a default.
    public var allowLegacyAlgorithms: Bool

    public var sshExecutablePath: String
    public var sshKeygenExecutablePath: String

    public init(host: String,
                port: Int = 22,
                username: String = "root",
                connectTimeout: TimeInterval = 5,
                operationTimeout: TimeInterval = 60,
                knownHostsPath: String = SSHConfiguration.defaultKnownHostsPath,
                hostKeyPolicy: HostKeyPolicy = .acceptNew,
                allowLegacyAlgorithms: Bool = false,
                sshExecutablePath: String = "/usr/bin/ssh",
                sshKeygenExecutablePath: String = "/usr/bin/ssh-keygen") {
        self.host = host
        self.port = port
        self.username = username
        self.connectTimeout = connectTimeout
        self.operationTimeout = operationTimeout
        self.knownHostsPath = knownHostsPath
        self.hostKeyPolicy = hostKeyPolicy
        self.allowLegacyAlgorithms = allowLegacyAlgorithms
        self.sshExecutablePath = sshExecutablePath
        self.sshKeygenExecutablePath = sshKeygenExecutablePath
    }

    /// `~/Library/Application Support/Spoolworks/known_hosts`.
    public static let defaultKnownHostsPath: String =
        applicationSupportDirectory.appendingPathComponent("known_hosts").path

    static var applicationSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Spoolworks", isDirectory: true)
    }
}

// MARK: - Operations

/// The five things the transport can ask the printer to do, before shell quoting.
public enum SSHOperation: Equatable, Sendable {
    /// Streams `byteCount` bytes over stdin into `path`, atomically.
    case upload(path: String, byteCount: Int)
    case download(path: String)
    case run(command: String)

    /// Suffix appended to the destination to form the staging file.
    ///
    /// The Windows app writes `material_database.json` in place, so a connection dropped
    /// mid-transfer truncates the printer's database (SPEC-04 §7 "Idempotency / atomicity").
    /// We stage, verify the byte count, fix the mode, then rename — `mv` within one filesystem
    /// is atomic, so the printer either has the old file or the whole new one.
    public static let stagingSuffix = ".spoolworks-tmp"

    /// The exact string handed to the remote shell. Public so it can be asserted verbatim in
    /// tests without executing anything.
    public var remoteCommand: String {
        switch self {
        case .upload(let path, let byteCount):
            let staging = SSHShell.quote(path + SSHOperation.stagingSuffix)
            let destination = SSHShell.quote(path)
            // `wc -c` exists on busybox. The `[ … ]` guard is what makes a short write fail
            // *before* the rename rather than after it.
            // `sync` matters: the printer is rebooted shortly after this returns, and on its
            // flash filesystem an unsynced rename can leave a zero-length database — exactly the
            // corruption the staging dance exists to prevent.
            // The `|| { rm -f …; false; }` wrapper stops a failed size check stranding a 478 KB
            // temp file on a small volume, while preserving the exit-1 signature `classify` reads.
            return "{ cat > \(staging)"
                 + " && [ \"$(wc -c < \(staging))\" -eq \(byteCount) ]"
                 + " && chmod 644 \(staging)"
                 + " && mv -f \(staging) \(destination)"
                 + " && sync; }"
                 + " || { rm -f \(staging); false; }"
        case .download(let path):
            return "cat \(SSHShell.quote(path))"
        case .run(let command):
            return command
        }
    }
}

/// Shell quoting for the single argument we hand to the remote shell.
public enum SSHShell {
    /// Wraps `value` in single quotes, closing and reopening around any embedded quote.
    /// Nothing inside single quotes is special to `sh`, so this is total.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Invocation

/// A fully-formed `ssh` invocation — everything except the bytes on stdin.
///
/// Split out from execution on purpose: the exact argv and environment can be asserted in tests
/// without spawning anything, which is the only way to prove the password never reaches either
/// of them. See `PrinterServiceTests`.
public struct SSHInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    /// A copy/pasteable command line, safe to log *by construction*: the password is not in
    /// argv and not in the environment, so there is nothing here to redact.
    ///
    /// Display only — nothing here is ever executed. It is still quoted properly, because
    /// "copy/pasteable" is a promise: quoting only arguments containing a space emitted
    /// `/tmp/x;reboot` bare, and a user pasting that into a terminal would have run it. The
    /// safe set below is deliberately conservative; anything outside it is single-quoted.
    public var commandLine: String {
        ([executable] + arguments).map(SSHInvocation.quoteForDisplay).joined(separator: " ")
    }

    /// Characters that need no quoting in any POSIX shell.
    private static let displaySafeCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/=:@-")

    /// Single-quotes `value` unless every character is in ``displaySafeCharacters``.
    public static func quoteForDisplay(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        return value.allSatisfy(displaySafeCharacters.contains) ? value : SSHShell.quote(value)
    }
}

/// Where the askpass helper and its FIFO live for one invocation.
public struct AskpassLocation: Equatable, Sendable {
    public let scriptPath: String
    public let fifoPath: String
    public init(scriptPath: String, fifoPath: String) {
        self.scriptPath = scriptPath
        self.fifoPath = fifoPath
    }

    /// Environment variable through which the helper learns where to read the secret from.
    /// It carries a *path*, never the secret — `ps -E` shows this and learns nothing.
    public static let fifoEnvironmentKey = "Spoolworks_ASKPASS_FIFO"
}

// MARK: - Transport

/// `PrinterTransport` over the system `ssh` binary.
public final class SSHTransport: PrinterTransport, CustomStringConvertible {

    public let configuration: SSHConfiguration
    private let passwordProvider: @Sendable () async throws -> String

    /// The password is resolved through a closure so it can come straight from the Keychain at
    /// the moment of use and never be parked in a long-lived property.
    public init(configuration: SSHConfiguration,
                passwordProvider: @escaping @Sendable () async throws -> String) {
        self.configuration = configuration
        self.passwordProvider = passwordProvider
    }

    /// Convenience for a password already in hand (a `SecureField` the user just typed).
    public convenience init(configuration: SSHConfiguration, password: String) {
        self.init(configuration: configuration, passwordProvider: { password })
    }

    /// Deliberately excludes the password — `SSHTransport` is safe to interpolate into a log.
    public var description: String {
        "SSHTransport(\(configuration.username)@\(configuration.host):\(configuration.port), "
            + "hostKeyPolicy: \(configuration.hostKeyPolicy.rawValue))"
    }

    // MARK: Invocation building

    /// Builds the exact argv and environment for one operation. Pure — spawns nothing.
    public func invocation(for operation: SSHOperation, askpass: AskpassLocation) -> SSHInvocation {
        var arguments: [String] = []

        // Ignore the user's ~/.ssh/config entirely. A stray `Host *` block there could set a
        // ProxyCommand, re-point UserKnownHostsFile, or weaken StrictHostKeyChecking behind our
        // back. Everything we rely on is stated explicitly below.
        arguments += ["-F", "/dev/null"]
        // Never allocate a pty: it would let the remote end echo, and it would change how ssh
        // decides to prompt.
        arguments += ["-T"]
        arguments += ["-p", String(configuration.port)]
        arguments += ["-l", configuration.username]

        // Password only, exactly like both existing clients (SPEC-04 §1.1). Skipping pubkey and
        // the agent means we never touch the user's keys and never offer them to a 3D printer.
        //
        // `keyboard-interactive` is deliberately NOT offered. `NumberOfPasswordPrompts=1` bounds
        // the *password* method only, so with keyboard-interactive in the list ssh could invoke
        // the askpass helper a second time — and the FIFO holds exactly one line, so helper #2
        // would block forever in `read`, holding the stderr pipe's write end open and wedging
        // the whole transport. Dropping the method makes a second prompt unreachable. Every
        // Creality firmware seen so far accepts plain `password`; if one is ever found that
        // insists on keyboard-interactive, the fix is a second FIFO line, not this option.
        arguments += ["-o", "BatchMode=no"]
        arguments += ["-o", "NumberOfPasswordPrompts=1"]
        arguments += ["-o", "PreferredAuthentications=password"]
        arguments += ["-o", "KbdInteractiveAuthentication=no"]
        arguments += ["-o", "PubkeyAuthentication=no"]
        arguments += ["-o", "IdentitiesOnly=yes"]

        // App-private trust store, both files pinned so nothing falls back to the user's.
        //
        // The value MUST be quoted. UserKnownHostsFile takes a whitespace-separated LIST, and the
        // default path contains a space ("Application Support"), so an unquoted value made ssh
        // pin the host into a stray file called `Application` inside the user's ~/Library while
        // the real store stayed empty — which also meant "Trust New Identity" could never clear
        // a pin, because ssh-keygen -R was pointed at the empty file. OpenSSH strips the quotes.
        arguments += ["-o", "UserKnownHostsFile=\"\(configuration.knownHostsPath)\""]
        arguments += ["-o", "GlobalKnownHostsFile=/dev/null"]
        arguments += ["-o", "StrictHostKeyChecking=\(configuration.hostKeyPolicy.sshOptionValue)"]

        arguments += ["-o", "ConnectTimeout=\(Int(configuration.connectTimeout.rounded()))"]
        // Detect a wedged link rather than sitting on it until the overall deadline.
        arguments += ["-o", "ServerAliveInterval=15"]
        arguments += ["-o", "ServerAliveCountMax=3"]
        arguments += ["-o", "LogLevel=ERROR"]

        if configuration.allowLegacyAlgorithms {
            arguments += ["-o", "HostKeyAlgorithms=+ssh-rsa"]
            arguments += ["-o", "PubkeyAcceptedAlgorithms=+ssh-rsa"]
            arguments += ["-o", "KexAlgorithms=+diffie-hellman-group14-sha1"]
        }

        arguments += [configuration.host, operation.remoteCommand]

        // A minimal environment: nothing inherited, so no accidental SSH_AUTH_SOCK, no
        // LD_/DYLD_ surprises, and — critically — no place for a secret to hide.
        let environment: [String: String] = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "SSH_ASKPASS": askpass.scriptPath,
            // OpenSSH ≥ 8.4 (macOS ships 9.x): use askpass even with no TTY and no DISPLAY.
            "SSH_ASKPASS_REQUIRE": "force",
            // Belt and braces for older OpenSSH, which refuses askpass without DISPLAY.
            "DISPLAY": ":0",
            AskpassLocation.fifoEnvironmentKey: askpass.fifoPath,
        ]

        return SSHInvocation(executable: configuration.sshExecutablePath,
                             arguments: arguments,
                             environment: environment)
    }

    // MARK: PrinterTransport

    public func upload(data: Data, to remotePath: String) async throws {
        try SSHTransport.validate(remotePath: remotePath)
        _ = try await execute(.upload(path: remotePath, byteCount: data.count), stdin: data)
    }

    public func download(from remotePath: String) async throws -> Data {
        try SSHTransport.validate(remotePath: remotePath)
        return try await execute(.download(path: remotePath), stdin: nil)
    }

    @discardableResult
    public func run(command: String) async throws -> String {
        let output = try await execute(.run(command: command), stdin: nil)
        return String(decoding: output, as: UTF8.self)
    }

    // MARK: Execution

    private func execute(_ operation: SSHOperation, stdin: Data?) async throws -> Data {
        try SSHTransport.validate(host: configuration.host)
        guard FileManager.default.isExecutableFile(atPath: configuration.sshExecutablePath) else {
            throw PrinterTransportError.transportUnavailable(
                "\(configuration.sshExecutablePath) is missing or not executable")
        }
        try Task.checkCancellation()

        try SSHTransport.prepareKnownHostsFile(at: configuration.knownHostsPath)

        let askpass = try AskpassChannel()
        defer { askpass.dispose() }
        // The password lives in this local for the duration of one invocation and is written
        // straight into a 0600 FIFO. It is never a property, never an argument, never in the
        // environment, and never written to a file.
        try askpass.arm(password: await passwordProvider())

        let invocation = invocation(for: operation, askpass: askpass.location)
        let result = try await ProcessRunner.run(invocation: invocation,
                                                 stdin: stdin,
                                                 timeout: configuration.operationTimeout)

        if let error = SSHTransport.classify(operation: operation,
                                             exitStatus: result.exitStatus,
                                             stderr: result.stderrText,
                                             host: configuration.host) {
            throw error
        }
        return result.stdout
    }

    // MARK: Classification

    /// Turns an exit status plus ssh's stderr into a typed error, or `nil` on success.
    ///
    /// Pure and public so the whole error surface is testable without a printer — which is the
    /// only way to test it at all, since we cannot make a real printer refuse a password.
    public static func classify(operation: SSHOperation,
                                exitStatus: Int32,
                                stderr: String,
                                host: String) -> PrinterTransportError? {
        let lower = stderr.lowercased()

        // Checked before the success case: `reboot` tears the connection down mid-command, so
        // ssh reports 255 for a command that in fact did exactly what we asked. The Windows app
        // papers over this by accident with a 5s CommandTimeout (SPEC-04 §11.5, last bullet).
        if case .run(let command) = operation, command == PrinterCommand.reboot {
            if exitStatus == 0 { return nil }
            if lower.contains("closed by remote host") || lower.contains("connection reset")
                || lower.contains("broken pipe") {
                return nil
            }
        }

        if exitStatus == 0 { return nil }

        if lower.contains("remote host identification has changed") {
            return .hostKeyChanged(host: host)
        }
        if lower.contains("host key verification failed") {
            // With `accept-new`, a *new* key is pinned silently, so reaching here means either
            // the strict policy or a key we already have on file and could not match.
            return lower.contains("changed") ? .hostKeyChanged(host: host) : .hostKeyUnverified(host: host)
        }
        if lower.contains("permission denied") || lower.contains("too many authentication failures") {
            return .authenticationFailed
        }
        if lower.contains("could not resolve hostname") || lower.contains("name or service not known") {
            return .connectionFailed("no such host \"\(host)\"")
        }
        if lower.contains("connection refused") {
            return .connectionFailed("\(host) refused the connection on the SSH port")
        }
        if lower.contains("operation timed out") || lower.contains("connection timed out")
            || lower.contains("timeout, server") {
            return .connectionFailed("\(host) did not answer")
        }
        if lower.contains("no route to host") || lower.contains("network is unreachable") {
            return .connectionFailed("\(host) is unreachable")
        }
        if lower.contains("no matching key exchange method")
            || lower.contains("no matching host key type")
            || lower.contains("no matching cipher") {
            return .connectionFailed(
                "the printer only offers legacy SSH algorithms — enable legacy algorithm support "
                + "and try again")
        }

        // Past this point the failure came from the remote *command*, not from ssh itself.
        switch operation {
        case .download(let path) where lower.contains("no such file"):
            return .remoteFileNotFound(path: path)
        case .download(let path) where lower.contains("permission denied"):
            return .remoteFileNotFound(path: path)
        case .upload(let path, _):
            // `[ "$(wc -c < tmp)" -eq N ]` failing is the only way to exit 1 quietly: the
            // staging file exists but is short, and the rename never ran.
            if exitStatus == 1 && stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .uploadIncomplete(path: path)
            }
            if lower.contains("no such file") || lower.contains("read-only file system") {
                return .remoteCommandFailed(exitStatus: exitStatus,
                                            message: SSHTransport.firstLine(of: stderr))
            }
        default:
            break
        }

        return .remoteCommandFailed(exitStatus: exitStatus, message: SSHTransport.firstLine(of: stderr))
    }

    static func firstLine(of text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }

    // MARK: Validation

    /// Rejects hosts that could be read as options or smuggle a newline into the command line.
    public static func validate(host: String) throws {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("-"),
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !trimmed.contains("\0")
        else { throw PrinterTransportError.invalidHost(host) }
    }

    /// Remote paths are absolute, single-line, and NUL-free. Quoting already makes them safe to
    /// pass to `sh`; this catches nonsense earlier and with a better message.
    public static func validate(remotePath path: String) throws {
        guard path.hasPrefix("/"),
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r")
        else { throw PrinterTransportError.invalidRemotePath(path) }
    }

    // MARK: known_hosts

    /// Creates the app-private known_hosts (0600) and its directory (0700) if absent.
    static func prepareKnownHostsFile(at path: String) throws {
        let fm = FileManager.default
        let directory = (path as NSString).deletingLastPathComponent
        do {
            if !fm.fileExists(atPath: directory) {
                try fm.createDirectory(atPath: directory,
                                       withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            if !fm.fileExists(atPath: path) {
                guard fm.createFile(atPath: path, contents: Data(),
                                    attributes: [.posixPermissions: 0o600]) else {
                    throw PrinterTransportError.transportUnavailable("cannot create \(path)")
                }
            }
        } catch let error as PrinterTransportError {
            throw error
        } catch {
            throw PrinterTransportError.transportUnavailable(
                "cannot prepare the printer trust store at \(path): \(error.localizedDescription)")
        }
    }

    /// Drops the pinned key for `host` from our *own* known_hosts and nothing else.
    ///
    /// Only ever called after the user explicitly chooses "Trust New Identity" in response to
    /// `PrinterTransportError.hostKeyChanged` (SPEC-04 §11.6). Never automatic.
    public func forgetHostKey() async throws {
        let result = try await runKeygen(["-R", configuration.host, "-f", configuration.knownHostsPath])
        guard result.exitStatus == 0 else {
            throw PrinterTransportError.transportUnavailable(
                "could not update the printer trust store: \(SSHTransport.firstLine(of: result.stderrText))")
        }
    }

    /// The SHA256 fingerprints currently pinned for this host, for a "Printer identity" row.
    ///
    /// Same preconditions as ``forgetHostKey()``: the host is validated (a host beginning with
    /// `-` would otherwise be read by `ssh-keygen` as an option) and the trust store is created
    /// if absent. An empty store simply yields no fingerprints.
    public func pinnedHostKeyFingerprints() async throws -> [String] {
        let result = try await runKeygen(["-l", "-F", configuration.host, "-f", configuration.knownHostsPath])
        // `-F` exits 1 when the host is simply not pinned; that is "no fingerprints", not an
        // error, so the status is deliberately not checked here.
        return String(decoding: result.stdout, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("SHA256:") }
    }

    /// Shared preamble for both `ssh-keygen` paths.
    ///
    /// Both used to skip ``prepareKnownHostsFile(at:)``, so on a fresh install — before any
    /// connection had created the store — `ssh-keygen` exited 255 with `Cannot stat …` and the
    /// user was shown a spurious `transportUnavailable`. And only `forgetHostKey` validated the
    /// host, so `pinnedHostKeyFingerprints` would happily pass `-oProxyCommand=…` through as an
    /// option. Both preconditions now live in one place.
    private func runKeygen(_ arguments: [String]) async throws -> ProcessRunner.Result {
        try SSHTransport.validate(host: configuration.host)
        try SSHTransport.prepareKnownHostsFile(at: configuration.knownHostsPath)
        let invocation = SSHInvocation(
            executable: configuration.sshKeygenExecutablePath,
            arguments: arguments,
            environment: ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()])
        return try await ProcessRunner.run(invocation: invocation, stdin: nil, timeout: 10)
    }
}

/// The remote commands we are willing to issue. There is exactly one (SPEC-04 §1.5).
public enum PrinterCommand {
    public static let reboot = "reboot"
}

// MARK: - Askpass channel

/// Hands the root password to `ssh` without it ever appearing in argv, in the environment, or
/// on disk.
///
/// `ssh` reads passwords from `/dev/tty`, never stdin, so piping is not an option, and
/// `sshpass` does not exist on macOS. The supported mechanism is `SSH_ASKPASS` +
/// `SSH_ASKPASS_REQUIRE=force`, which needs an executable to run.
///
/// SPEC-04 §11.3 recommends shipping that executable as a second SwiftPM product inside
/// `Contents/MacOS/`. **This implementation does not**, because adding a product means editing
/// `Package.swift`, which is out of scope for this change. Instead:
///
///   * a `mkdtemp` directory is created with mode 0700 (owner-only, unguessable name);
///   * a ~5-line `/bin/sh` helper is written there with mode 0700 — **it contains no secret**,
///     only the *name* of an environment variable;
///   * a FIFO is created there with mode 0600 and the password is written into it, so the
///     secret exists only in kernel pipe buffers, never in a file's contents;
///   * the environment carries the FIFO's *path*, so `ps -E` reveals nothing;
///   * the whole directory is unlinked when the invocation ends, in a `defer`.
///
/// Why that is still safe: the three exposures that matter for a same-machine attacker are
/// argv (world-readable via `ps`), the environment (readable via `ps -E`), and files on disk.
/// None of them ever holds the password. What remains is a same-uid attacker, who could open
/// the FIFO first — but a same-uid process can already read our memory and our Keychain items,
/// so this adds no new exposure.
///
/// What is lost versus the spec's recommendation: the helper is not code-signed as part of the
/// app bundle, so it is not covered by the app's signature and would not survive a Library
/// Validation / hardened-runtime policy that forbids executing unsigned helpers. Promote it to
/// a bundled `cfsrfid-askpass` product the next time `Package.swift` is editable.
/// Public so its security properties can be tested directly — that the helper script contains
/// no secret, that the directory is 0700 and the FIFO 0600, and that a `/bin/sh` child really
/// does receive the password through it. None of that is observable through `SSHTransport`
/// alone, and it is the part of this file most worth proving.
public final class AskpassChannel {

    public let location: AskpassLocation
    /// The 0700 directory holding the helper and the FIFO. Unlinked by `dispose()`.
    public let directoryPath: String
    private var fifoDescriptor: Int32 = -1
    private var disposed = false

    /// How long the helper will wait for a line before giving up, in seconds.
    ///
    /// The FIFO holds exactly one line. An unbounded `read` in a *second* helper invocation
    /// would block forever, and because the helper is a grandchild of this process it keeps the
    /// ssh stderr pipe's write end open — which used to hang the drain, the deadline, and the
    /// enclosing continuation. macOS `/bin/sh` is bash, so `read -t` is available.
    public static let readTimeoutSeconds = 10

    private static let script = """
    #!/bin/sh
    # k2-rfid askpass helper. Reads one line from the FIFO named by the environment variable
    # below and prints it. Contains no secret; the secret never touches the filesystem.
    # The read is time-bounded: the FIFO carries a single line, so a second invocation (which
    # only an unexpected auth retry could cause) must fail rather than block forever.
    IFS= read -r -t \(AskpassChannel.readTimeoutSeconds) __k2_secret < "$\(AskpassLocation.fifoEnvironmentKey)" || exit 1
    printf '%s\\n' "$__k2_secret"

    """

    public init() throws {
        let template = NSTemporaryDirectory() + "spoolworks-askpass.XXXXXXXX"
        var buffer = Array(template.utf8CString)
        guard let made = buffer.withUnsafeMutableBufferPointer({ mkdtemp($0.baseAddress!) }) else {
            throw PrinterTransportError.transportUnavailable(
                "cannot create a private directory for the credential channel")
        }
        directoryPath = String(cString: made)

        let scriptPath = directoryPath + "/askpass"
        let fifoPath = directoryPath + "/pw.fifo"
        location = AskpassLocation(scriptPath: scriptPath, fifoPath: fifoPath)

        guard FileManager.default.createFile(atPath: scriptPath,
                                             contents: Data(AskpassChannel.script.utf8),
                                             attributes: [.posixPermissions: 0o700]) else {
            dispose()
            throw PrinterTransportError.transportUnavailable("cannot create the askpass helper")
        }
        guard mkfifo(fifoPath, 0o600) == 0 else {
            dispose()
            throw PrinterTransportError.transportUnavailable(
                "cannot create the credential channel (errno \(errno))")
        }
    }

    /// Loads the password into the FIFO.
    ///
    /// Opened `O_RDWR` so the write does not block waiting for `ssh` to spawn the helper — a
    /// FIFO opened for both ends by one process is writable immediately, and the pipe buffer is
    /// orders of magnitude larger than any password. If `ssh` never gets as far as prompting,
    /// `dispose()` closes the descriptor, the reader (if any) sees EOF, and nothing leaks.
    public func arm(password: String) throws {
        let descriptor = open(location.fifoPath, O_RDWR | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw PrinterTransportError.transportUnavailable(
                "cannot open the credential channel (errno \(errno))")
        }
        fifoDescriptor = descriptor

        var bytes = Array((password + "\n").utf8)
        defer { for i in bytes.indices { bytes[i] = 0 } }   // scrub our copy

        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { raw -> Int in
                write(descriptor, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if written > 0 { offset += written; continue }
            if errno == EINTR { continue }
            throw PrinterTransportError.transportUnavailable(
                "cannot arm the credential channel (errno \(errno))")
        }
    }

    public func dispose() {
        guard !disposed else { return }
        disposed = true
        if fifoDescriptor >= 0 { close(fifoDescriptor); fifoDescriptor = -1 }
        try? FileManager.default.removeItem(atPath: directoryPath)
    }

    deinit { dispose() }
}

// MARK: - Process runner

/// Runs a child process with a hard deadline and real cancellation.
///
/// Public so the deadline and cancellation semantics — the two behaviours the Windows app is
/// missing outright (SPEC-04 §7) — can be tested against a harmless local command such as
/// `/bin/sleep`, with no printer and nothing on the network.
public enum ProcessRunner {

    public struct Result {
        public let exitStatus: Int32
        public let stdout: Data
        public let stderr: Data
        public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// - Parameter drainGrace: how long to keep reading the child's pipes after it has exited.
    ///   Only a test has any reason to shorten it; see ``drainGracePeriod``.
    public static func run(invocation: SSHInvocation, stdin: Data?, timeout: TimeInterval,
                           drainGrace: TimeInterval = ProcessRunner.drainGracePeriod) async throws -> Result {
        let box = RunBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let result = try box.runBlocking(invocation: invocation,
                                                         stdin: stdin,
                                                         timeout: timeout,
                                                         drainGrace: drainGrace)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// How long to wait for the output pipes to reach EOF after the child has exited.
    ///
    /// Normally this is instantaneous: ssh exits, the pipes close, `readDataToEndOfFile()`
    /// returns. It is not instantaneous when a *grandchild* still holds a write end — the
    /// askpass helper is a child of ssh, so killing ssh does not close its copy of stderr. The
    /// helper's own bounded `read` means that resolves on its own, but an unbounded
    /// `group.wait()` here would still park the calling thread on it, never resume the
    /// continuation, and never run `defer { askpass.dispose() }` — an unrecoverable UI hang.
    /// So the drain is bounded and, past the bound, abandoned.
    public static let drainGracePeriod: TimeInterval = 5

    /// How long a terminated child gets to honour SIGTERM before it is sent SIGKILL.
    public static let killGracePeriod: TimeInterval = 2

    /// Owns the child so `onCancel` — which runs on some other thread, possibly before the
    /// process has even launched — has something safe to talk to.
    private final class RunBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false
        private var timedOut = false

        func cancel() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            RunBox.stop(running)
        }

        private func markTimedOut() {
            lock.lock()
            timedOut = true
            let running = process
            lock.unlock()
            RunBox.stop(running)
        }

        /// SIGTERM, then SIGKILL if the child is still there.
        ///
        /// `Process.terminate()` alone is a request. ssh normally honours it, but a child
        /// wedged in a syscall may not, and the one thing this path must guarantee is that the
        /// deadline actually ends the operation.
        ///
        /// Note what this deliberately does *not* do: `kill(-pid, …)`. Foundation gives no way
        /// to put the child in its own process group, so the child shares ours — a group kill
        /// would signal this application. The askpass grandchild is instead bounded by its own
        /// `read -t`, and the drain below by `drainGracePeriod`.
        private static func stop(_ running: Process?) {
            guard let running, running.isRunning else { return }
            let pid = running.processIdentifier
            running.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGracePeriod) {
                guard running.isRunning else { return }
                kill(pid, SIGKILL)
            }
        }

        func runBlocking(invocation: SSHInvocation, stdin: Data?, timeout: TimeInterval,
                         drainGrace: TimeInterval) throws -> Result {
            lock.lock()
            if cancelled { lock.unlock(); throw PrinterTransportError.cancelled }
            lock.unlock()

            let process = Process()
            process.executableURL = URL(fileURLWithPath: invocation.executable)
            process.arguments = invocation.arguments
            process.environment = invocation.environment

            let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = inPipe

            lock.lock(); self.process = process; lock.unlock()

            do { try process.run() }
            catch {
                throw PrinterTransportError.transportUnavailable(
                    "cannot start \(invocation.executable): \(error.localizedDescription)")
            }

            // Cancellation can land between the check above and `run()`; catch it here.
            lock.lock()
            let alreadyCancelled = cancelled
            lock.unlock()
            if alreadyCancelled { RunBox.stop(process) }

            // Drain both pipes concurrently. Reading them serially deadlocks as soon as the
            // child fills the other one's 64 KiB buffer.
            let group = DispatchGroup()
            let outBox = DataBox(), errBox = DataBox()
            for (pipe, sink) in [(outPipe, outBox), (errPipe, errBox)] {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    sink.set(pipe.fileHandleForReading.readDataToEndOfFile())
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let handle = inPipe.fileHandleForWriting
                if let stdin, !stdin.isEmpty {
                    // The remote `cat` can die (disk full, bad path) while we are still writing,
                    // which surfaces as EPIPE. That is the remote command's failure to report,
                    // not ours, so swallow it and let the exit status speak.
                    try? handle.write(contentsOf: stdin)
                }
                try? handle.close()
                group.leave()
            }

            // The deadline the Windows app is missing (SPEC-04 §7).
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in self?.markTimedOut() }
            timer.resume()
            defer { timer.cancel() }

            process.waitUntilExit()
            // Bounded: see `drainGracePeriod`. On expiry the reader threads are abandoned —
            // they hold nothing but their own pipe handles and finish when the last write end
            // closes — and whatever `DataBox` has so far is what we report.
            _ = group.wait(timeout: .now() + .milliseconds(Int(drainGrace * 1000)))

            lock.lock()
            let didCancel = cancelled
            let didTimeOut = timedOut
            self.process = nil
            lock.unlock()

            if didCancel { throw PrinterTransportError.cancelled }
            if didTimeOut { throw PrinterTransportError.timedOut(seconds: timeout) }

            return Result(exitStatus: process.terminationStatus,
                          stdout: outBox.value,
                          stderr: errBox.value)
        }
    }

    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
        func set(_ newValue: Data) { lock.lock(); data = newValue; lock.unlock() }
    }
}
