import Foundation

// MARK: - Identity

/// What makes two sightings of a spool the same spool.
///
/// The app cannot key on a tag UID: a spool carries **two** tags with different UIDs and the same
/// payload, and the CFS reports no UID at all. So identity is drawn from the payload, which both
/// sources carry — `venderId` / `filamentId` / `color` / `serialNum` appear on a CFS slot exactly
/// as they do on a tag.
///
/// ## Why colour is part of the key, and why identity is still not unique
///
/// The design says identity is *"the tag's serial + filament ID"*. **On real hardware that is not
/// enough**, and the repository's own K2 Plus dump proves it: all four slots of `T1` report
/// `venderId 0276`, `filamentId 101001` and `serialNum 000001`. Serial is not a serial — Windows
/// hard-codes `000001` (`MainForm.cs`), so every factory spool of one material shares it. Keying
/// on serial + filament alone would collapse four spools into one row and attribute all four
/// slots' consumption to whichever won.
///
/// Colour is therefore part of the key. It separates `T1A` (white), `T1B` (red) and `T1C` (black)
/// — and the firmware agrees, because `same_material` groups slots by filament ID **and** colour.
///
/// It is still not sufficient: `T1B` and `T1D` are both red `0C12E1F`, which is precisely why they
/// are grouped as auto-refill partners. Two spools of the same filament and colour are genuinely
/// indistinguishable from their payloads. ``SpoolInventory/reconcile(with:at:addingUnknown:)``
/// resolves that residue by slot position rather than pretending the payload can, so a spool
/// stays bound to the slot it was last seen in.
public struct SpoolIdentity: Hashable, Codable, Sendable, CustomStringConvertible {

    public let vendorId: String
    public let filamentId: String
    /// `RRGGBB`, normalised. Part of the key because serial is not unique — see the type's note.
    public let colorHex: String
    public let serialNumber: String

    public init(vendorId: String, filamentId: String, colorHex: String, serialNumber: String) {
        self.vendorId = vendorId
        self.filamentId = filamentId
        self.colorHex = Spool.normaliseHex(colorHex)
        self.serialNumber = serialNumber
    }

    /// The identity of a decoded tag record.
    public init(record: SpoolRecord) {
        self.init(vendorId: record.vendorId,
                  filamentId: record.filamentId,
                  colorHex: record.rgbHex,
                  serialNumber: record.serialNumber)
    }

    /// True when this identity is shared by every spool of the same filament and colour — i.e. the
    /// serial carries no information. Used to warn rather than to change behaviour.
    public var hasGenericSerial: Bool { serialNumber == "000001" }

    public var description: String { "\(vendorId)/\(filamentId)/\(colorHex)/\(serialNumber)" }
}

// MARK: - Where a spool is

/// Where the spool physically is.
///
/// `cfs` and `externalHolder` are **observed** — they come from `material_box_info.json` and are
/// overwritten on every poll. `shelf` and `unknown` are **asserted** by the user and are never
/// overwritten by a poll, only by another edit. Keeping the two kinds in one enum is what lets
/// ``SpoolInventory/reconcile(with:at:)`` move a spool out of a slot without losing where the user
/// said it lives when it is not loaded.
public enum SpoolLocation: Hashable, Codable, Sendable, CustomStringConvertible {

    /// Loaded in a CFS slot: box `T1`, slot `A`.
    case cfs(box: String, slot: String)
    /// On the printer's external spool holder — `rackMaterial` in the printer's own vocabulary.
    case externalHolder
    /// Put away somewhere the user named.
    case shelf(String)
    /// Never placed.
    case unknown

    public var description: String {
        switch self {
        case let .cfs(box, slot): return "CFS \(box) · \(slot)"
        case .externalHolder: return "External spool"
        case let .shelf(where_): return where_
        case .unknown: return "Unplaced"
        }
    }

    /// True when the printer is the source of this location, and a poll may therefore replace it.
    public var isOnPrinter: Bool {
        switch self {
        case .cfs, .externalHolder: return true
        case .shelf, .unknown: return false
        }
    }
}

// MARK: - Where the record came from

/// How this spool came to be known, which is also how far its data can be trusted.
public enum TagSource: String, Codable, Sendable, CaseIterable, CustomStringConvertible {

    /// Read off a tag Creality programmed.
    case crealityFactory
    /// Read off a tag this app wrote.
    case spoolworksWritten
    /// Typed in. There may be no tag at all, or one that was never read.
    case untagged

    public var description: String {
        switch self {
        case .crealityFactory: return "Creality factory"
        case .spoolworksWritten: return "Spoolworks-written"
        case .untagged: return "Untagged · manual"
        }
    }
}

// MARK: - Usage

/// One line of a spool's history.
///
/// Every change to ``Spool/remainingPercent`` appends one of these, so the number on screen can
/// always be explained. `deltaGrams` is signed: intake is positive, consumption negative, and a
/// correction is whichever direction it corrected.
public struct UsageEntry: Identifiable, Hashable, Codable, Sendable {

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The spool entered stock.
        case intake
        /// A CFS poll reported a different `remainLen` than the app last recorded.
        case cfsPoll
        /// Attributed to a named print job.
        case job
        /// The user corrected the figure by hand — a weigh-in, typically.
        case adjustment
        /// Taken out of a slot, or put into one.
        case movement
        /// Removed from stock.
        case retirement
    }

    public let id: UUID
    public let date: Date
    public let kind: Kind
    /// Free text: `"job bracket_v3.gcode"`, `"CFS poll · delta"`, `"Intake · tag read"`.
    public let detail: String
    /// Signed grams. **Fractional on purpose.**
    ///
    /// A print job is polled every few seconds and draws a fraction of a gram between readings.
    /// Held as an `Int`, every one of those rounded to zero: the remaining percentage drifted down
    /// correctly while the log sat next to it reading "0 g", which is the log failing at the one
    /// job it has. Whole grams are still what gets *displayed* above about 10 g — see
    /// ``amountLabel`` — but the arithmetic is done at full precision.
    public let deltaGrams: Double

    public init(id: UUID = UUID(), date: Date = .now, kind: Kind, detail: String, deltaGrams: Double) {
        self.id = id
        self.date = date
        self.kind = kind
        self.detail = detail
        self.deltaGrams = deltaGrams
    }

    /// `"−38 g"`, `"1000 g"`, `"−0.4 g"`. Uses U+2212 MINUS, not a hyphen, so the columns line up
    /// in a tabular-numerals font.
    ///
    /// A decimal appears only below 10 g, where it is the difference between a figure and nothing
    /// at all; above that it is noise on a number the CFS only knows to the nearest 10 g anyway.
    public var amountLabel: String {
        let magnitude = abs(deltaGrams)
        let sign = deltaGrams < 0 ? "−" : ""
        if magnitude > 0 && magnitude < 10 {
            return String(format: "%@%.1f g", sign, magnitude)
        }
        return "\(sign)\(Int(magnitude.rounded())) g"
    }
}

// MARK: - The spool

/// One physical spool in stock.
///
/// The fields divide into three groups, and the division matters because
/// ``SpoolInventory/reconcile(with:at:)`` treats them differently:
///
/// 1. **Identity** — ``identity``, and nothing else, decides whether two sightings are the same
///    spool. It is `nil` only for a manual record of a spool with no tag.
/// 2. **Description** — brand, name, material, colour, net weight. Set at intake from the tag or
///    by hand; a CFS poll may fill in blanks but never overwrites what the user typed.
/// 3. **Observation** — ``remainingPercent``, ``location`` and ``remainingSource``. A poll owns
///    these outright.
public struct Spool: Identifiable, Hashable, Codable, Sendable {

    /// Below this, the Inventory screen counts a spool as low.
    ///
    /// 35 %, not a rounder 20 %, because a 1 kg spool at 20 % is ~200 g — already too little for
    /// most of a plate, and by then "order more" is late. Exposed rather than inlined so a caller
    /// can show the same threshold it filters on.
    public static let lowStockThresholdPercent: Double = 35

    public let id: UUID

    // -- identity ------------------------------------------------------------------------------
    public var identity: SpoolIdentity?

    // -- description ---------------------------------------------------------------------------
    public var brand: String
    public var name: String
    public var materialType: String
    /// `RRGGBB`, uppercase, no `#`. The tag's 7-character colour field drops its unknown leading
    /// nibble on the way in — see ``SpoolRecord/rgbHex``.
    public var colorHex: String
    /// The nearest named colour, for the `"Creality Hyper PLA · White"` label. Stored rather than
    /// derived so the domain layer does not need the 636 KB colour table to render a list.
    public var colorName: String
    public var netWeightGrams: Int

    // -- observation ---------------------------------------------------------------------------
    /// 0...100. Clamped on write; a CFS `remainLen` of `"54"` means 54 %.
    public var remainingPercent: Double {
        didSet { remainingPercent = Self.clamp(remainingPercent) }
    }
    public var location: SpoolLocation
    /// How ``remainingPercent`` was last established, verbatim for display:
    /// `"CFS remainLen · 12 s ago"`, `"Manual record · tag optional"`.
    public var remainingSource: String

    // -- bookkeeping ---------------------------------------------------------------------------
    public var tagSource: TagSource
    public var intakeDate: Date
    public var usage: [UsageEntry]
    /// Retired spools stay in the file so their usage history survives, and are filtered out of
    /// every default view. The design's Retire dialog promises exactly this: *"it stays on the
    /// usage record."*
    public var isRetired: Bool

    public init(id: UUID = UUID(),
                identity: SpoolIdentity? = nil,
                brand: String,
                name: String,
                materialType: String,
                colorHex: String,
                colorName: String = "",
                netWeightGrams: Int = 1000,
                remainingPercent: Double = 100,
                location: SpoolLocation = .unknown,
                remainingSource: String = "",
                tagSource: TagSource = .untagged,
                intakeDate: Date = .now,
                usage: [UsageEntry] = [],
                isRetired: Bool = false) {
        self.id = id
        self.identity = identity
        self.brand = brand
        self.name = name
        self.materialType = materialType
        self.colorHex = Self.normaliseHex(colorHex)
        self.colorName = colorName
        self.netWeightGrams = netWeightGrams
        self.remainingPercent = Self.clamp(remainingPercent)
        self.location = location
        self.remainingSource = remainingSource
        self.tagSource = tagSource
        self.intakeDate = intakeDate
        self.usage = usage
        self.isRetired = isRetired
    }

    // MARK: Derived

    /// `"Creality Hyper PLA · White"`. Falls back to brand + name when the colour has no name,
    /// rather than printing a trailing separator.
    public var label: String {
        let head = [brand, name].filter { !$0.isEmpty }.joined(separator: " ")
        guard !colorName.isEmpty else { return head.isEmpty ? "Untitled spool" : head }
        return head.isEmpty ? colorName : "\(head) · \(colorName)"
    }

    /// `"PLA · 1 kg net · Ø1.75"`. The temperature range is not on the spool — it belongs to the
    /// material profile — so callers that have one append it themselves.
    public var subtitle: String {
        var parts: [String] = []
        if !materialType.isEmpty { parts.append(materialType) }
        parts.append("\(Self.weightLabel(netWeightGrams)) net")
        return parts.joined(separator: " · ")
    }

    /// `"54%"`.
    public var remainingLabel: String { "\(Int(remainingPercent.rounded()))%" }

    /// Grams left, rounded. Derived rather than stored: net weight and percentage are the two
    /// things actually observed, and storing a third value that must agree with them invites the
    /// three to drift.
    public var remainingGrams: Int {
        Int((Double(netWeightGrams) * remainingPercent / 100).rounded())
    }

    /// `"≈ 540 g"` — approximate, because it is derived from a percentage the CFS reports in whole
    /// units. A spool that has never been drawn from reports its net weight exactly.
    public var remainingGramsLabel: String {
        remainingPercent >= 100 ? "\(netWeightGrams) g" : "≈ \(remainingGrams) g"
    }

    public var isLow: Bool { remainingPercent < Self.lowStockThresholdPercent }
    public var isUntagged: Bool { identity == nil || tagSource == .untagged }

    /// The serial for display. Untagged spools show an em dash rather than an empty cell.
    public var serialLabel: String { identity?.serialNumber ?? "—" }
    public var filamentIdLabel: String { identity?.filamentId ?? "—" }
    public var vendorIdLabel: String { identity?.vendorId ?? "—" }

    // MARK: Mutation

    /// Records a change in what is left, appending the usage line that explains it.
    ///
    /// Takes the **new percentage** rather than a delta because that is what both real sources
    /// report — the CFS gives an absolute `remainLen`, and a weigh-in gives an absolute mass. The
    /// delta is computed here so it can never disagree with the figure it accompanies.
    public mutating func record(percent newPercent: Double,
                                kind: UsageEntry.Kind,
                                detail: String,
                                date: Date = .now,
                                source: String? = nil) {
        let clamped = Self.clamp(newPercent)
        let delta = Double(netWeightGrams) * (clamped - remainingPercent) / 100
        remainingPercent = clamped
        if let source { remainingSource = source }
        usage.insert(UsageEntry(date: date, kind: kind, detail: detail, deltaGrams: delta), at: 0)
    }

    /// Deducts a known mass, for consumption measured at the extruder rather than at the spool.
    ///
    /// The counterpart to ``record(percent:kind:detail:date:source:)``, which takes an absolute
    /// figure because that is what the CFS reports. A print job reports a *delta* — how much
    /// filament went through — so this is the one place a delta is the input.
    ///
    /// ## The two sources disagree, on purpose
    ///
    /// A CFS-loaded spool has both: the CFS measures what is left, in whole percent (10 g steps on
    /// a 1 kg spool), and the job reports what was extruded, to a fraction of a gram. Job
    /// consumption is deducted as it happens so the figure moves between the CFS's coarse
    /// readings; the next poll then overwrites it with an absolute measurement, correcting any
    /// drift. Neither is treated as gospel and the log records both, so a small positive
    /// correction after a job is the CFS saying "actually there was more left than you thought" —
    /// information, not an error.
    public mutating func consume(grams: Double, detail: String, date: Date = .now) {
        guard grams > 0, netWeightGrams > 0 else { return }
        let percentUsed = grams / Double(netWeightGrams) * 100
        let newPercent = Self.clamp(remainingPercent - percentUsed)
        // Derived from the clamped result rather than from `grams`, so the line can never claim a
        // spool gave up more than it held.
        let actual = Double(netWeightGrams) * (remainingPercent - newPercent) / 100
        remainingPercent = newPercent
        guard actual > 0 else { return }

        // Coalesce into the running entry for the same job rather than appending.
        //
        // A job is polled every few seconds, so appending would write hundreds of lines for one
        // print — burying the intake, the CFS readings and the movements that make the log worth
        // having. One line per job, growing as the print runs, says the same thing and stays
        // readable.
        if let latest = usage.first, latest.kind == .job, latest.detail == detail {
            usage[0] = UsageEntry(id: latest.id,
                                  date: date,
                                  kind: .job,
                                  detail: detail,
                                  deltaGrams: latest.deltaGrams - actual)
        } else {
            usage.insert(UsageEntry(date: date, kind: .job, detail: detail, deltaGrams: -actual),
                         at: 0)
        }
    }

    /// Appends a usage line that does not change the remaining figure — a movement, a retirement.
    public mutating func note(kind: UsageEntry.Kind, detail: String, date: Date = .now) {
        usage.insert(UsageEntry(date: date, kind: kind, detail: detail, deltaGrams: 0), at: 0)
    }

    /// Grams consumed across the whole history, for "used since intake".
    public var consumedGrams: Double {
        usage.filter { $0.deltaGrams < 0 }.reduce(0) { $0 - $1.deltaGrams }
    }

    // MARK: Helpers

    public static func clamp(_ percent: Double) -> Double { min(100, max(0, percent)) }

    /// Uppercases, drops a leading `#`, and drops the tag's unknown leading nibble when handed all
    /// seven characters. Anything else is passed through — a caller that supplies rubbish gets its
    /// rubbish back rather than a silent black swatch.
    public static func normaliseHex(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 7 { s.removeFirst() }
        return s
    }

    /// `1000 -> "1 kg"`, `750 -> "750 g"`.
    public static func weightLabel(_ grams: Int) -> String {
        grams % 1000 == 0 && grams >= 1000 ? "\(grams / 1000) kg" : "\(grams) g"
    }
}
