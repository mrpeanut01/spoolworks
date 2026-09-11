import Foundation
import SpoolworksCore

/// The question the Upload sheet asks once a printer has a new database, decided from what the
/// printer is doing. Pure, so every branch can be tested without a sheet.
///
/// Only an idle printer is ever offered a restart now. A print running or paused, or Klipper busy,
/// is offered a restart once it has finished, or none; a printer that cannot be read is offered
/// none (docs/DECISIONS.md D-006).
enum PrinterRestartPrompt: Equatable {
    /// Nothing is running: "Restart the printer?" Yes or No.
    case confirmRestart
    /// A job is printing or paused: restart automatically once it finishes, or manually.
    case printInProgress(paused: Bool)
    /// No job, but the printer is running a command: the same two choices.
    case printerBusy
    /// What the printer is doing could not be read. Nothing is restarted.
    case cannotConfirm(String)

    init(activity: PrinterActivity) {
        switch activity {
        case .idle: self = .confirmRestart
        case let .printing(paused): self = .printInProgress(paused: paused)
        case .busy: self = .printerBusy
        }
    }

    /// The question to ask again when a restart was refused at the last moment.
    init(refusal: RestartRefusal) {
        switch refusal {
        case let .printing(paused): self = .printInProgress(paused: paused)
        case .busy: self = .printerBusy
        case let .unconfirmed(detail): self = .cannotConfirm(detail)
        }
    }

    /// Whether "restart now" is one of the answers. True for exactly one case.
    var offersRestartNow: Bool { self == .confirmRestart }

    /// Whether "restart automatically once it finishes" is one of the answers.
    var offersAutomaticRestart: Bool {
        switch self {
        case .printInProgress, .printerBusy: return true
        case .confirmRestart, .cannotConfirm: return false
        }
    }

    var title: String {
        switch self {
        case .confirmRestart: return "Restart the printer?"
        case .printInProgress(paused: false): return "A print is running"
        case .printInProgress(paused: true): return "A print is paused"
        case .printerBusy: return "The printer is busy"
        case .cannotConfirm: return "Couldn't check the printer"
        }
    }

    func message(printerName: String) -> String {
        let takesEffect = "The new database takes effect when the printer restarts."
        switch self {
        case .confirmRestart:
            return "\(printerName) isn't printing. \(takesEffect)"
        case .printInProgress(paused: false):
            return "\(printerName) is printing, so Spoolworks won't restart it now. \(takesEffect)"
        case .printInProgress(paused: true):
            return "\(printerName) has a paused print, so Spoolworks won't restart it now. \(takesEffect)"
        case .printerBusy:
            return "\(printerName) is running a command, so Spoolworks won't restart it now. \(takesEffect)"
        case let .cannotConfirm(detail):
            return "Spoolworks couldn't confirm that \(printerName) isn't printing, so it won't restart it. \(detail)"
        }
    }

    /// The label for the automatic answer.
    var automaticRestartLabel: String {
        self == .printerBusy
            ? "Automatically Restart When It's Idle"
            : "Automatically Restart When the Print Finishes"
    }
}
