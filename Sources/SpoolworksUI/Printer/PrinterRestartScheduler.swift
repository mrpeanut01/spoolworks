import Foundation
import SpoolworksCore

/// Restarts a printer once its print has finished — the "automatically" answer to the question the
/// Upload sheet asks when a new database lands while the printer is printing.
///
/// It never restarts a printer that is printing (docs/DECISIONS.md D-006). It reads what the printer
/// is doing every ``pollInterval``, and only once the printer has stayed idle for ``quietPeriod`` —
/// long enough for end-of-print moves to finish, and for someone to start the next job, which starts
/// the wait again — does it ask `restartIfIdle`. That reads the state once more, immediately before
/// sending, and refuses if anything has started since.
///
/// Held in memory only. Quitting Spoolworks drops a pending restart rather than restarting the
/// printer on whichever launch comes next.
@MainActor
final class PrinterRestartScheduler: ObservableObject {

    struct Pending: Equatable, Identifiable {
        let family: PrinterType
        let printerName: String
        let host: String
        var status: Status

        var id: PrinterType { family }
    }

    enum Status: Equatable {
        /// A print, or some other command, is still running.
        case waitingForPrint
        /// Idle since `since`; restarts once that has lasted the quiet period.
        case waitingForQuiet(since: Date)
        /// The restart is being sent.
        case restarting
        /// The last check could not read the printer. Still waiting.
        case unreachable(String)
    }

    enum Event: Equatable {
        case restarted(printerName: String)
        case gaveUp(printerName: String, reason: String)
    }

    @Published private(set) var pending: [PrinterType: Pending] = [:]

    let pollInterval: TimeInterval
    let quietPeriod: TimeInterval

    /// Looked up when the restart is sent, rather than held for the length of a print.
    var credentials: (PrinterType) -> PrinterCredentials? = { _ in nil }
    /// A restart that waited for a print happens with no sheet open; this is how it is reported.
    var onEvent: ((Event) -> Void)?

    private let transport: PrinterTransporting
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private var tasks: [PrinterType: Task<Void, Never>] = [:]

    init(transport: PrinterTransporting,
         pollInterval: TimeInterval = 15,
         quietPeriod: TimeInterval = 120,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
             try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000))
         }) {
        self.transport = transport
        self.pollInterval = pollInterval
        self.quietPeriod = quietPeriod
        self.now = now
        self.sleep = sleep
    }

    // MARK: Requests

    /// Waits for the printer to finish what it is doing, then restarts it. Replaces any restart
    /// already pending for the same printer.
    func schedule(family: PrinterType, printerName: String, host: String) {
        tasks[family]?.cancel()
        pending[family] = Pending(family: family, printerName: printerName, host: host,
                                  status: .waitingForPrint)
        tasks[family] = Task { [weak self] in await self?.watch(family) }
    }

    /// Stops waiting. The printer is not restarted.
    func cancel(family: PrinterType) {
        tasks[family]?.cancel()
        tasks[family] = nil
        pending[family] = nil
    }

    /// Waits for the watch on `family` to end. For tests.
    func settle(_ family: PrinterType) async {
        await tasks[family]?.value
    }

    // MARK: Wording

    func statusText(for pending: Pending) -> String {
        let quiet = Self.describe(quietPeriod)
        switch pending.status {
        case .waitingForPrint:
            return "\(pending.printerName) restarts automatically once its print has finished and it has been idle for \(quiet)."
        case .waitingForQuiet:
            return "The print has finished. \(pending.printerName) restarts after \(quiet) idle, unless another print starts."
        case .restarting:
            return "Restarting \(pending.printerName)…"
        case let .unreachable(detail):
            return "Couldn't reach \(pending.printerName) on the last check (\(detail)). Still waiting: it won't be restarted until it reports that it is idle."
        }
    }

    static func describe(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        if interval >= 60 {
            return minutes == 1 ? "a minute" : "\(minutes) minutes"
        }
        return "\(Int(interval.rounded())) seconds"
    }

    // MARK: Watching

    private func watch(_ family: PrinterType) async {
        while !Task.isCancelled, let entry = pending[family] {
            let activity: PrinterActivity
            do {
                activity = try await transport.activity(host: entry.host)
            } catch {
                guard !Task.isCancelled else { return }
                update(family) { $0.status = .unreachable(error.localizedDescription) }
                guard await pause() else { return }
                continue
            }
            guard !Task.isCancelled, pending[family] != nil else { return }

            switch activity {
            case .printing, .busy:
                update(family) { $0.status = .waitingForPrint }
            case .idle:
                let since: Date
                if case let .waitingForQuiet(start)? = pending[family]?.status {
                    since = start
                } else {
                    since = now()
                    update(family) { $0.status = .waitingForQuiet(since: since) }
                }
                if now().timeIntervalSince(since) >= quietPeriod, await restart(family) {
                    return
                }
            }
            guard await pause() else { return }
        }
    }

    /// Sleeps one poll interval. False once the watch has been cancelled.
    private func pause() async -> Bool {
        do {
            try await sleep(pollInterval)
        } catch {
            return false
        }
        return !Task.isCancelled
    }

    /// Sends the restart. True when the watch is over — restarted, or given up.
    private func restart(_ family: PrinterType) async -> Bool {
        guard let entry = pending[family] else { return true }
        guard let credentials = credentials(family) else {
            finish(family, .gaveUp(printerName: entry.printerName, reason: "it has no saved password"))
            return true
        }
        update(family) { $0.status = .restarting }
        do {
            try await transport.restartIfIdle(credentials, family: family)
            finish(family, .restarted(printerName: entry.printerName))
            return true
        } catch let refusal as RestartRefusal {
            // Something started between the check and the command, or the printer stopped
            // answering. Not restarting was the right call; the wait goes on.
            switch refusal {
            case .printing, .busy:
                update(family) { $0.status = .waitingForPrint }
            case let .unconfirmed(detail):
                update(family) { $0.status = .unreachable(detail) }
            }
            return false
        } catch {
            guard !Task.isCancelled else { return true }
            finish(family, .gaveUp(printerName: entry.printerName, reason: error.localizedDescription))
            return true
        }
    }

    private func update(_ family: PrinterType, _ change: (inout Pending) -> Void) {
        guard var entry = pending[family] else { return }
        change(&entry)
        pending[family] = entry
    }

    private func finish(_ family: PrinterType, _ event: Event) {
        pending[family] = nil
        tasks[family] = nil
        onEvent?(event)
    }
}
