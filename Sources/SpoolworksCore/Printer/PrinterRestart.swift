import Foundation

// A printer is never restarted while it is printing.
//
// `reboot` in a root shell takes a Creality printer down at once, and a print in progress goes with
// it. So the command has one way out of this package — `PrinterService.restartIfIdle` — and that
// reads what the printer is doing from Moonraker immediately beforehand and refuses anything but
// idle: a job printing or paused, Klipper running some other command, or a state that could not be
// read at all. There is no override. Uploads and resets do not restart the printer on their own;
// the app asks first (docs/DECISIONS.md D-006).

/// What the printer is doing, as far as restarting it is concerned.
public enum PrinterActivity: Equatable, Sendable {
    /// No job, and Klipper is not running anything.
    case idle
    /// A print job is running, or paused part-way through (`print_stats.state`).
    case printing(paused: Bool)
    /// No job, but Klipper is executing commands — a filament load, a calibration, a macro started
    /// from the touchscreen (`idle_timeout.state` is `"Printing"`).
    case busy
}

/// Reads ``PrinterActivity`` from a printer.
public protocol PrinterActivityReading: Sendable {
    func activity(host: String) async throws -> PrinterActivity
}

/// A fixed or scripted answer, for tests and previews.
public struct PrinterActivityStub: PrinterActivityReading {
    private let answer: @Sendable (String) async throws -> PrinterActivity

    public init(_ activity: PrinterActivity) {
        self.answer = { _ in activity }
    }

    public init(_ answer: @escaping @Sendable (String) async throws -> PrinterActivity) {
        self.answer = answer
    }

    public func activity(host: String) async throws -> PrinterActivity {
        try await answer(host)
    }
}

/// Why ``PrinterService/restartIfIdle(host:checkingWith:)`` sent nothing.
public enum RestartRefusal: Error, Equatable, CustomStringConvertible {
    /// A job is printing, or paused.
    case printing(paused: Bool)
    /// No job, but the printer is running a command.
    case busy
    /// What the printer is doing could not be read, so it could not be confirmed idle.
    case unconfirmed(String)

    public var description: String {
        switch self {
        case .printing(paused: false):
            return "The printer is printing, so it was not restarted."
        case .printing(paused: true):
            return "The printer has a paused print, so it was not restarted."
        case .busy:
            return "The printer is running a command, so it was not restarted."
        case let .unconfirmed(detail):
            return "Spoolworks could not confirm the printer is idle, so it was not restarted: \(detail)"
        }
    }
}

extension RestartRefusal: LocalizedError {
    public var errorDescription: String? { description }
}
