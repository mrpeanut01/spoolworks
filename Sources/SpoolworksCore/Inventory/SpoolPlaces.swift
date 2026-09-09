import Foundation

// MARK: - The result of editing the list

/// Why a place-list edit was or was not applied.
///
/// A `Bool` was tried first and was not enough: the list refuses an edit for four different
/// reasons and the screen has to say which one, otherwise "Add" does nothing and the user is left
/// guessing whether the name was too long, already there, or reserved. The rejection carries its
/// own sentence so the reasoning lives next to the rule it comes from rather than being
/// reconstructed at the call site.
public enum PlaceEditResult: Equatable, Sendable {
    /// Applied. The associated value is the **canonical** name — trimmed, and for a rename the
    /// name the spools were actually moved to.
    case applied(String)
    /// Refused, with a sentence fit to show the user.
    case rejected(String)

    public var isApplied: Bool { if case .applied = self { return true }; return false }
    public var name: String? { if case let .applied(name) = self { return name }; return nil }
    public var problem: String? { if case let .rejected(why) = self { return why }; return nil }
}

// MARK: - The list

/// The user's own names for where a spool lives **when the printer is not holding it**.
///
/// ## Why the list holds only the places the printer cannot see
///
/// ``SpoolLocation`` has four cases and they divide cleanly by who owns them:
/// `.cfs(box:slot:)` and `.externalHolder` are *observed* — `material_box_info.json` reports them
/// and ``SpoolInventory/reconcile(with:at:addingUnknown:)`` overwrites them every 30 s — while
/// `.shelf` and `.unknown` are *asserted* by the user and no poll touches them.
///
/// This list is the vocabulary for the asserted half, and **only** the asserted half. A name maps
/// to `.unknown` (for the reserved ``unplaced`` entry) or to `.shelf(name)`; nothing in here can
/// produce a CFS slot or the external holder. That is deliberate and is the whole seam: a spool's
/// CFS position is a measurement, and a picker that let the user assert one would be inviting them
/// to state something the next poll flatly contradicts. See `docs/DECISIONS.md` D-011.
///
/// ## `CFS` and `Ext…` are seeded, and they are ordinary names
///
/// The tool owner asked for `Unplaced, Shelf, CFS, Ext…` as the starting list, so that is what a
/// first run gets. `CFS` and `Ext…` here are **plain shelf names with no special power** — useful
/// for "the box of spools next to the printer" and "hanging off the back" — and they are not the
/// printer's own `.cfs` / `.externalHolder`. The picker keeps the two apart by labelling the
/// printer's position with where it came from (`"CFS T1 · A · reported by the printer"`), because
/// a row reading plain `CFS` next to a row reading `CFS T1 · A` would otherwise be a genuine trap.
///
/// ## Names, not identifiers
///
/// A `Place` struct with a UUID was considered so a rename would not have to touch anything. It
/// buys nothing: `SpoolLocation.shelf` stores a *string*, so a rename has to walk the inventory
/// either way (see ``SpoolInventory/reassign(place:to:detail:at:)``), and an id would add a second
/// thing that can disagree with the first. The cost is that ``unplaced`` cannot be renamed —
/// accepted, and documented on that property.
public struct SpoolPlaces: Hashable, Sendable {

    /// The one name the list cannot lose, and the only one that maps to `.unknown`.
    ///
    /// Reserved rather than merely defaulted. `.unknown` is not a place the user invented: it is
    /// where a freshly-tagged spool lands, and it is what `reconcile` assigns to a spool the
    /// printer has stopped reporting. If the list could lose it, those spools would sit in a state
    /// no picker row could express and the user could not put anything back into.
    public static let unplaced = "Unplaced"

    /// What a first run gets, as specified by the tool owner.
    public static let seeded: [String] = [unplaced, "Shelf"]

    /// Names that were seeded once and should not have been.
    ///
    /// `CFS` and `Ext…` were offered as ordinary places with no special power, on the reasoning
    /// that a spool can be put anywhere by hand. What they actually did was duplicate the two
    /// locations the *printer* owns — `.cfs(box:slot:)` and `.externalHolder` — which the Inventory
    /// filter already covers under "On printer". So the filter row carried two buttons for a state
    /// another button expressed better, and the Location picker invited a user to hand-assert a
    /// place the poll describes properly.
    ///
    /// Kept as a list rather than deleted outright because an installed copy already has them
    /// written to `UserDefaults`; changing ``seeded`` alone would fix new installs and leave every
    /// existing one carrying them for ever.
    public static let retiredSeeds: [String] = ["CFS", "Ext…"]

    /// Long enough for "Garage shelf, second from the top"; short enough that the Inventory
    /// table's 118 pt Location column is not being asked to render a paragraph.
    public static let maximumNameLength = 40

    /// Ordered as the picker shows them, ``unplaced`` always first.
    public private(set) var names: [String]

    /// Where a spool goes when the printer stops reporting it. Always one of ``names``.
    ///
    /// `Unplaced` unless the user says otherwise, which is the honest answer before anyone has
    /// told the app where their spools live. Once they have, "back on the shelf" is almost always
    /// right and saying so once beats correcting it after every print.
    ///
    /// Kept normalised by the same rules as the list itself: a rename carries it, and removing the
    /// place it names puts it back to ``unplaced`` rather than leaving it pointing at nothing.
    public private(set) var unloadDestination: String = SpoolPlaces.unplaced

    /// Normalises whatever it is handed: trims, drops blanks, removes case-insensitive duplicates
    /// keeping the first spelling, and puts ``unplaced`` back at the front if it is missing.
    ///
    /// Normalising in the initialiser rather than only in the mutators is what makes a corrupted
    /// or hand-edited `UserDefaults` array harmless — the app has one code path for "a list of
    /// names" and it always produces a usable one.
    public init(names: [String] = SpoolPlaces.seeded,
                unloadDestination: String = SpoolPlaces.unplaced) {
        var out: [String] = [Self.unplaced]
        var seen: Set<String> = [Self.unplaced.lowercased()]
        for raw in names {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= Self.maximumNameLength else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        self.names = out
        // Normalised against the list that was actually kept, so a destination naming a place the
        // list does not contain — a hand-edited plist, a name that failed validation — cannot leave
        // spools being sent somewhere the picker has never heard of.
        let wanted = unloadDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        self.unloadDestination = out.first { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            ?? Self.unplaced
    }

    /// Sets where unloaded spools go. Rejected if the place is not in the list.
    public mutating func setUnloadDestination(_ raw: String) -> PlaceEditResult {
        let wanted = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let match = names.first(where: { $0.caseInsensitiveCompare(wanted) == .orderedSame })
        else { return .rejected("There is no place called “\(wanted)”.") }
        unloadDestination = match
        return .applied(match)
    }

    // MARK: Mapping to and from a location

    /// True when `name` is the reserved entry, however it was capitalised on the way in.
    public static func isUnplaced(_ name: String) -> Bool {
        name.caseInsensitiveCompare(unplaced) == .orderedSame
    }

    public func contains(_ name: String) -> Bool {
        names.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// The location a picker row asserts. Never a printer-owned case — see the type's note.
    public func location(for name: String) -> SpoolLocation {
        Self.isUnplaced(name) ? .unknown : .shelf(name)
    }

    /// Which row of the list a spool's location corresponds to, or `nil` when the **printer** owns
    /// it and no row can.
    ///
    /// A `.shelf` whose name is no longer in the list still answers with that name rather than
    /// `nil`: the caller needs to be able to tell "the printer has it" (nothing to offer) from
    /// "the user is at a place that has since been deleted" (offer it, so the row is not blank).
    public func name(for location: SpoolLocation) -> String? {
        switch location {
        case .unknown: return Self.unplaced
        case let .shelf(name): return name
        case .cfs, .externalHolder: return nil
        }
    }

    // MARK: Editing

    public mutating func add(_ raw: String) -> PlaceEditResult {
        switch validate(raw) {
        case let .rejected(why): return .rejected(why)
        case let .applied(name):
            names.append(name)
            return .applied(name)
        }
    }

    /// Renames a place. The caller is responsible for moving the spools that referenced the old
    /// name — ``SpoolInventory/reassign(place:to:detail:at:)`` — because this type deliberately
    /// knows nothing about the inventory.
    public mutating func rename(_ old: String, to raw: String) -> PlaceEditResult {
        guard let index = names.firstIndex(where: { $0.caseInsensitiveCompare(old) == .orderedSame })
        else { return .rejected("There is no place called “\(old)”.") }
        guard !Self.isUnplaced(old) else {
            return .rejected("“\(Self.unplaced)” is where a spool sits when it is nowhere in "
                             + "particular, so it cannot be renamed.")
        }
        // A rename that only changes capitalisation is still a rename, so the duplicate check has
        // to forgive the entry being renamed — otherwise "shelf" → "Shelf" reports a clash with
        // itself.
        switch validate(raw, ignoring: index) {
        case let .rejected(why): return .rejected(why)
        case let .applied(name):
            let previous = names[index]
            names[index] = name
            // The destination is stored as a name, so a rename has to carry it — otherwise it
            // would quietly fall back to Unplaced the next time a spool came off the printer.
            if unloadDestination.caseInsensitiveCompare(previous) == .orderedSame {
                unloadDestination = name
            }
            return .applied(name)
        }
    }

    /// Removes a place. The caller must re-point the spools that were on it; nothing here can
    /// leave a spool at a name the picker no longer offers, because nothing here touches spools.
    public mutating func remove(_ name: String) -> PlaceEditResult {
        guard !Self.isUnplaced(name) else {
            return .rejected("“\(Self.unplaced)” cannot be removed — it is where spools go when "
                             + "they leave everywhere else.")
        }
        guard let index = names.firstIndex(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return .rejected("There is no place called “\(name)”.") }
        let removed = names.remove(at: index)
        // Removing the place unloaded spools were going to sends them back to Unplaced rather than
        // to a name nothing answers to.
        if unloadDestination.caseInsensitiveCompare(removed) == .orderedSame {
            unloadDestination = Self.unplaced
        }
        return .applied(removed)
    }

    /// Trim, length, blank and case-insensitive-duplicate checks, in one place so add and rename
    /// cannot drift apart.
    private func validate(_ raw: String, ignoring index: Int? = nil) -> PlaceEditResult {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .rejected("Give the place a name.") }
        guard name.count <= Self.maximumNameLength else {
            return .rejected("Keep it under \(Self.maximumNameLength) characters — it has to fit "
                             + "the Location column.")
        }
        let clash = names.enumerated().first {
            $0.offset != index && $0.element.caseInsensitiveCompare(name) == .orderedSame
        }
        if let clash {
            return .rejected("“\(clash.element)” is already on the list.")
        }
        return .applied(name)
    }
}

// MARK: - Keeping the inventory in step with the list

extension SpoolInventory {

    /// Active spools the user has asserted are at `name`.
    ///
    /// Matched case-insensitively for the same reason the list de-duplicates that way: a
    /// `.shelf("shelf")` written before the name was re-capitalised is the same physical place,
    /// and leaving it behind is precisely the orphan this exists to prevent.
    public func spools(atPlace name: String) -> [Spool] {
        active.filter {
            if case let .shelf(where_) = $0.location {
                return where_.caseInsensitiveCompare(name) == .orderedSame
            }
            return false
        }
    }

    /// Moves every spool asserted to be at `name` to `destination`, logging `detail` on each.
    ///
    /// The one operation behind both renaming and removing a place, so the two cannot diverge.
    /// **This is what stops a place edit orphaning spools**: the list and the spools that
    /// reference it are changed together, and a spool is never left at a name the picker no longer
    /// offers.
    ///
    /// A `.movement` line rather than a silent rewrite even for a rename, where the spool has not
    /// physically moved. The log is the app's answer to "why does it say that?", and a spool whose
    /// location changed from `Bin 3` to `Shelf B` with nothing in its history saying so is exactly
    /// the question the log exists to answer. It carries 0 g, so nothing it writes can affect a
    /// remaining figure.
    ///
    /// Retired spools are skipped: ``retire(id:date:)`` already forces them to `.unknown`, so
    /// there is nothing to move, and appending to a closed record would be noise.
    @discardableResult
    public mutating func reassign(place name: String,
                                  to destination: SpoolLocation,
                                  detail: String,
                                  at date: Date = .now) -> [UUID] {
        // Collect first, mutate second. `update(_:)` writes into the same array this is reading,
        // and iterating it while it is being replaced is both an exclusivity hazard and a way to
        // skip elements once indices shift.
        let targets = spools(atPlace: name)
        guard !targets.isEmpty else { return [] }
        for var spool in targets {
            spool.location = destination
            spool.note(kind: .movement, detail: detail, date: date)
            update(spool)
        }
        return targets.map(\.id)
    }
}
