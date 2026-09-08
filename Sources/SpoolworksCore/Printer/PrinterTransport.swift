import Foundation

// SPEC-04 §11.1 — the printer transport only ever has to do five things:
//
//   1. exec "reboot"
//   2. write material_database.json
//   3. write material_option.json (K1 family)
//   4. read  material_database.json
//   5. (nothing else — no PTY, no port forwarding, no subsystems)
//
// Everything above the transport is written against this protocol so the whole printer layer
// is testable with `MockPrinterTransport`, with no printer and no network. See
// `SSHTransport` for the real implementation over /usr/bin/ssh.

/// Anything that can move bytes to and from a printer and run a command on it.
///
/// Implementations are expected to be *stateless per call*: each method opens and closes its
/// own session, matching the Windows app's one-connection-per-operation behaviour
/// (SPEC-04 §1.6). That keeps cancellation simple — there is never a half-open session to
/// unwind — at the cost of one authentication per operation.
public protocol PrinterTransport: Sendable {

    /// Writes `data` to `remotePath`, replacing whatever is there.
    ///
    /// Implementations must make this as close to atomic as the remote end allows: the Windows
    /// app overwrites `material_database.json` in place with no temp file and no size check, so
    /// a dropped connection leaves a truncated database on the printer (SPEC-04 §7).
    func upload(data: Data, to remotePath: String) async throws

    /// Reads `remotePath` in full.
    func download(from remotePath: String) async throws -> Data

    /// Runs `command` on the printer and returns its standard output.
    ///
    /// The only command the existing clients ever issue is `reboot` (SPEC-04 §1.5).
    @discardableResult
    func run(command: String) async throws -> String
}

// MARK: - Errors

/// Every way a transport operation can fail, in a form the UI can branch on.
///
/// The Windows app surfaces raw SSH.NET exception text in a toast (SPEC-04 §8.1); this enum
/// exists so the macOS port can say something useful instead. No case carries a password —
/// see `PrinterServiceTests.noSecretsInCommandLine`.
public enum PrinterTransportError: Error, Equatable, CustomStringConvertible {

    /// TCP/DNS level: host unresolvable, refused, unreachable.
    case connectionFailed(String)

    /// The printer rejected the password. Root SSH must be enabled from the printer's
    /// touchscreen (Settings → Root account information) before it will accept one at all.
    case authenticationFailed

    /// The pinned host key for this host no longer matches. Deliberately *not* handled
    /// automatically: SPEC-04 §11.6 requires this to be an explicit user decision.
    case hostKeyChanged(host: String)

    /// Trust-on-first-use was refused (e.g. policy set to `.strict` and no pin exists yet).
    case hostKeyUnverified(host: String)

    /// The operation exceeded its deadline and the child process was killed. The Windows app
    /// has no transfer timeout at all — a stalled SCP hangs forever (SPEC-04 §7).
    case timedOut(seconds: Double)

    /// The enclosing `Task` was cancelled.
    case cancelled

    /// `cat <path>` reported the file missing.
    case remoteFileNotFound(path: String)

    /// The remote command exited non-zero for a reason we could not classify further.
    case remoteCommandFailed(exitStatus: Int32, message: String)

    /// The bytes that arrived on the printer did not match the bytes we sent, so the temp file
    /// was *not* moved into place. The database on the printer is untouched.
    case uploadIncomplete(path: String)

    /// A remote path failed validation before we ever spawned a process.
    case invalidRemotePath(String)

    /// A host string failed validation before we ever spawned a process.
    case invalidHost(String)

    /// The local side could not be set up: /usr/bin/ssh missing, askpass channel unusable, …
    case transportUnavailable(String)

    public var description: String {
        switch self {
        case .connectionFailed(let detail):
            return "Could not reach the printer: \(detail)"
        case .authenticationFailed:
            return "The printer rejected the password. Check that root access is enabled on the "
                 + "printer (Settings → Root account information) and that the password matches."
        case .hostKeyChanged(let host):
            return "The identity of \(host) has changed. This is normal after a firmware update "
                 + "or factory reset, but it can also mean another device is answering at that address."
        case .hostKeyUnverified(let host):
            return "The identity of \(host) is not trusted yet."
        case .timedOut(let seconds):
            return "The printer stopped responding after \(Int(seconds))s."
        case .cancelled:
            return "Cancelled."
        case .remoteFileNotFound(let path):
            return "The printer has no file at \(path)."
        case .remoteCommandFailed(let status, let message):
            return message.isEmpty ? "The printer returned an error (exit \(status))."
                                   : "The printer returned an error (exit \(status)): \(message)"
        case .uploadIncomplete(let path):
            return "The transfer to \(path) was incomplete, so the printer's file was left unchanged."
        case .invalidRemotePath(let path):
            return "Invalid remote path: \(path)"
        case .invalidHost(let host):
            return "Invalid printer address: \(host)"
        case .transportUnavailable(let detail):
            return "SSH is unavailable: \(detail)"
        }
    }
}

// MARK: - Mock

/// An in-memory printer, so every flow above the transport is testable with no hardware.
///
/// Records every call in order, serves seeded files to `download`, and can be scripted to fail
/// at any point. `beforeCall` is an async hook, which is what makes cancellation and timeout
/// behaviour testable without a real process.
public final class MockPrinterTransport: PrinterTransport, @unchecked Sendable {

    /// One recorded operation. `upload` records the byte count rather than the bytes so that
    /// `Call` stays cheap to compare; the bytes themselves are in `uploads`.
    public enum Call: Equatable, CustomStringConvertible {
        case upload(path: String, byteCount: Int)
        case download(path: String)
        case run(command: String)

        public var description: String {
            switch self {
            case .upload(let p, let n): return "upload(\(n) bytes → \(p))"
            case .download(let p):      return "download(\(p))"
            case .run(let c):           return "run(\(c))"
            }
        }
    }

    private let lock = NSLock()
    private var _calls: [Call] = []
    private var _uploads: [String: Data] = [:]
    private var _files: [String: Data] = [:]
    private var _runOutput: [String: String] = [:]
    private var _failUpload: PrinterTransportError?
    private var _failDownload: PrinterTransportError?
    private var _failRun: PrinterTransportError?
    private var _failAtCallIndex: (index: Int, error: PrinterTransportError)?
    private var _beforeCall: (@Sendable (Call) async throws -> Void)?

    public init() {}

    // MARK: Inspection

    /// Every call made so far, in order.
    public var calls: [Call] { lock.withLock { _calls } }

    /// The bytes handed to `upload`, keyed by remote path.
    public var uploads: [String: Data] { lock.withLock { _uploads } }

    /// The paths passed to `upload`, in order.
    public var uploadedPaths: [String] {
        calls.compactMap { if case .upload(let p, _) = $0 { return p } else { return nil } }
    }

    /// The commands passed to `run`, in order.
    public var commands: [String] {
        calls.compactMap { if case .run(let c) = $0 { return c } else { return nil } }
    }

    // MARK: Scripting

    /// Seeds a file the printer will serve to `download`.
    public func seed(_ path: String, with data: Data) { lock.withLock { _files[path] = data } }

    /// Seeds a file from a UTF-8 string.
    public func seed(_ path: String, text: String) { seed(path, with: Data(text.utf8)) }

    /// Canned stdout for a given command.
    public func setRunOutput(_ output: String, for command: String) {
        lock.withLock { _runOutput[command] = output }
    }

    /// Makes every `upload` throw.
    public var failUpload: PrinterTransportError? {
        get { lock.withLock { _failUpload } }
        set { lock.withLock { _failUpload = newValue } }
    }

    /// Makes every `download` throw.
    public var failDownload: PrinterTransportError? {
        get { lock.withLock { _failDownload } }
        set { lock.withLock { _failDownload = newValue } }
    }

    /// Makes every `run` throw. Used to model `reboot` tearing down the connection.
    public var failRun: PrinterTransportError? {
        get { lock.withLock { _failRun } }
        set { lock.withLock { _failRun = newValue } }
    }

    /// Fails the *n*-th call (0-based) whatever it is, so partial-failure states are testable.
    public func fail(atCallIndex index: Int, with error: PrinterTransportError) {
        lock.withLock { _failAtCallIndex = (index, error) }
    }

    /// Runs before every call, after it has been recorded. Use it to sleep (timeouts) or to
    /// cancel the enclosing task (cancellation).
    public var beforeCall: (@Sendable (Call) async throws -> Void)? {
        get { lock.withLock { _beforeCall } }
        set { lock.withLock { _beforeCall = newValue } }
    }

    // MARK: PrinterTransport

    public func upload(data: Data, to remotePath: String) async throws {
        let call = Call.upload(path: remotePath, byteCount: data.count)
        try await record(call)
        if let error = failUpload { throw error }
        lock.withLock {
            _uploads[remotePath] = data
            _files[remotePath] = data
        }
    }

    public func download(from remotePath: String) async throws -> Data {
        let call = Call.download(path: remotePath)
        try await record(call)
        if let error = failDownload { throw error }
        guard let data = lock.withLock({ _files[remotePath] }) else {
            throw PrinterTransportError.remoteFileNotFound(path: remotePath)
        }
        return data
    }

    @discardableResult
    public func run(command: String) async throws -> String {
        let call = Call.run(command: command)
        try await record(call)
        if let error = failRun { throw error }
        return lock.withLock { _runOutput[command] } ?? ""
    }

    private func record(_ call: Call) async throws {
        let (index, hook, scheduled): (Int, (@Sendable (Call) async throws -> Void)?, (Int, PrinterTransportError)?) =
            lock.withLock {
                _calls.append(call)
                return (_calls.count - 1, _beforeCall, _failAtCallIndex)
            }
        try await hook?(call)
        if Task.isCancelled { throw PrinterTransportError.cancelled }
        if let scheduled, scheduled.0 == index { throw scheduled.1 }
    }
}
