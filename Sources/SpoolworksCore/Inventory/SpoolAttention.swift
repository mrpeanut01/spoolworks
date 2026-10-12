import Foundation

/// Something about a spool that will make it print, or design, wrongly until it is put right.
///
/// Three, and each is a different place a filament's description has to arrive before it is any
/// use: the printer has to list its id or the CFS ignores the tag; HueForge has to have it or it
/// cannot be designed with; and its colour has to be the maker's or HueForge is designing with a
/// colour nobody sells. Low stock is deliberately not one of these — it has its own mark in the
/// *Left* column, and it is a fact about the spool rather than something to fix.
///
/// Held as values so the row's triangle and the rail's explanation are the same list and cannot
/// disagree about why a spool is marked.
public enum SpoolAttention: Hashable, Sendable, Identifiable {

    /// The printer's filament list has no entry for this spool's filament id.
    case notOnPrinter(printer: String, filament: String, filamentID: String)
    /// HueForge has not been sent this filament, or was sent an older description of it.
    case notInHueForge(outdated: Bool)
    /// The colour's name is a description, not one from the maker's own list.
    case colourUnmatched(maker: String)

    public var id: String {
        switch self {
        case .notOnPrinter: return "printer"
        case .notInHueForge: return "hueforge"
        case .colourUnmatched: return "colour"
        }
    }

    /// One line, for the row's tooltip and the rail's heading.
    public var title: String {
        switch self {
        case let .notOnPrinter(printer, filament, _):
            return "\(printer) does not list \(filament) yet"
        case let .notInHueForge(outdated):
            return outdated ? "HueForge has an older version of this filament"
                            : "Not synced with HueForge"
        case let .colourUnmatched(maker):
            return maker.isEmpty ? "Colour is not matched to a maker's colour"
                                 : "Colour is not matched to \(maker)'s own colours"
        }
    }

    /// Why it matters, for the rail.
    public var detail: String {
        switch self {
        case let .notOnPrinter(_, _, id):
            return "The CFS ignores a tag for a filament its printer doesn't list. "
                + "Adding \(id) puts that one entry in the printer's filament list."
        case let .notInHueForge(outdated):
            return outdated
                ? "Its name, colour or transmission distance has changed here since it was last sent."
                : "HueForge cannot design with a filament it has not been given."
        case .colourUnmatched:
            return "Its name is the nearest generic colour, not what the maker calls it — so "
                + "HueForge would be given a colour nobody sells. Pick the maker's colour under Colour, "
                + "or type the name off the box."
        }
    }
}
