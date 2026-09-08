import Foundation

/// The three printer families this app writes tags for: K1, K2 and Hi.
///
/// ## Why this is an enum, and how it diverges from Windows
///
/// The Windows app (`Windows/CFS-RFID/`) determines "which printer am I talking to" by three
/// mutually inconsistent mechanisms — see SPEC/02-material-db.md §6:
///
/// 1. A hard-coded candidate array `Utils.printerTypes = { "K2", "K1", "HI" }` (`Utils.cs:190`),
///    used only to filter cloud printer names.
/// 2. The *file base name* of the selected database (`MainForm.cs:727`), which comes from a
///    directory listing and is therefore whatever the cloud API happened to call the printer —
///    e.g. `"K2 Plus"`, `"K1 Max"`.
/// 3. Unanchored, case-insensitive substring tests at each branch point:
///    `if (name.ToLower().Contains("hi")) … else if (name.ToLower().Contains("k1")) … else /* K2 */`
///    (`UpdateForm.cs:48-59`, `UploadForm.cs:40-51`).
///
/// Mechanism 3 is a latent bug: `Contains("hi")` is tested **first** and is unanchored, so any name
/// containing the letters "hi" — `"Ender Chi"`, `"Hyper K1"`, `"K2 Chinese Edition"` — is classified
/// as a Hi and gets the Hi SSH password and the Hi filesystem layout. `"K2 Plus"` only survives by
/// luck of ordering. Worse, there is no "unknown" outcome: everything that is not Hi or K1 silently
/// becomes K2. And `UploadForm.cs:161` requires the name to equal exactly `"k1"` for the
/// `material_option.json` side-car to be written, which the cloud naming scheme can never satisfy.
///
/// **Deviation from Windows (deliberate).** This port uses ONE scheme:
///
/// - The canonical identity is this enum. Its `rawValue` (`k1`/`k2`/`hi`) is the *only* token that
///   ever reaches the filesystem, so the on-disk name is always lower-case `k1.json`/`k2.json`/
///   `hi.json` — which is also exactly how `db/` ships them, and which sidesteps the Windows
///   case-sensitivity hazard (`MatDb.cs` lower-cases the type, `Utils.GetPrinterTypes` returns
///   on-disk casing; harmless on NTFS, broken on a case-sensitive APFS volume).
/// - Free-form names (cloud printer names, user input, a stored preference) are converted **once**,
///   at the boundary, through ``PrinterType/init(identifying:)``. That match is anchored and
///   token-based, never a bare substring, and it returns `nil` rather than falling back to K2.
///   Callers must handle the unknown case explicitly.
///
/// Consequence: a machine can hold at most one database per family, keyed by family rather than by
/// marketing name. That is a feature — the material catalogue is per-family, not per-SKU (`db/`
/// ships exactly three files), and it makes "which password / which path / which DB" a single
/// total function instead of three disagreeing string tests.
public enum PrinterType: String, CaseIterable, Codable, Hashable, Sendable {
    case k1
    case k2
    case hi

    /// Human-readable family name for menus and window titles.
    public var displayName: String {
        switch self {
        case .k1: return "K1 / K1 Max"
        case .k2: return "K2 Plus"
        case .hi: return "Hi / Hi Combo"
        }
    }

    /// The `printerIntName` stamped into every `result.list[i]` record for this family.
    ///
    /// Observed 100 % consistently in the shipped databases: `db/k1.json` → `CR-K1 Max`,
    /// `db/k2.json` → `F008`, `db/hi.json` → `F018`.
    ///
    /// Note the Windows cloud-assembly path hard-codes `"F008"` for *every* family
    /// (`Utils.cs:874`), so any DB it builds for a K1 or Hi is mislabelled. This port keeps the
    /// correct per-family value here; whether the printer firmware actually reads the field is an
    /// open question (SPEC/02 OPEN QUESTION 3).
    public var printerIntName: String {
        switch self {
        case .k1: return "CR-K1 Max"
        case .k2: return "F008"
        case .hi: return "F018"
        }
    }

    /// File name used both for the seed resource and for the on-disk copy. Always lower-case.
    public var databaseFileName: String { "\(rawValue).json" }

    /// Whether this family also expects the `material_option.json` side-car
    /// (`Utils.SaveMatOption`, `Utils.cs:692-733`). K1 only.
    ///
    /// On Windows this is gated on `SelectedPrinter.Equals("k1", …)` — an exact match against a
    /// name the cloud path never produces. With the canonical-token scheme above the gate is simply
    /// `type == .k1`, so the side-car is written whenever it should be.
    public var usesMaterialOptionSidecar: Bool { self == .k1 }

    /// Every token this port recognises for a family, lower-cased and normalised. Matching is on
    /// whole tokens (see ``init(identifying:)``), never on bare substrings.
    ///
    /// The `F008`/`F018`/`CR-K1 Max` entries let a `printerIntName` read out of an unknown database
    /// identify its family.
    private var aliases: Set<String> {
        switch self {
        case .k1: return ["k1", "k1 max", "cr-k1 max", "cr k1 max", "k1c", "k1 c", "k1 se", "k1 max se"]
        case .k2: return ["k2", "k2 plus", "k2 pro", "k2 max", "f008"]
        case .hi: return ["hi", "hi combo", "creality hi", "f018"]
        }
    }

    /// Resolves a free-form printer name to a family, or `nil` if it is not recognisably one of the
    /// three. There is intentionally **no** default-to-K2 fallback.
    ///
    /// The rules, in order:
    /// 1. Normalise: trim, lower-case, collapse internal whitespace, drop a leading `creality`.
    /// 2. Exact match against ``aliases``.
    /// 3. First-token match: `"k2 plus (0.4)"` → first token `k2` → `.k2`. This is what makes
    ///    cloud names such as `"K1 Max"` work without the unanchored-`Contains` hazard — `"Ender Chi"`
    ///    has first token `ender` and resolves to `nil`, where Windows would call it a Hi.
    ///
    /// Order of evaluation across cases does not matter here, because a token equals exactly one
    /// family's alias. That is the property Windows lacked.
    public init?(identifying rawName: String) {
        let normalised = PrinterType.normalise(rawName)
        guard !normalised.isEmpty else { return nil }

        if let exact = PrinterType.allCases.first(where: { $0.aliases.contains(normalised) }) {
            self = exact
            return
        }

        let firstToken = String(normalised.split(separator: " ").first ?? "")
        if let byToken = PrinterType.allCases.first(where: { $0.aliases.contains(firstToken) }) {
            self = byToken
            return
        }

        return nil
    }

    /// The normalisation half of ``init(identifying:)``, exposed so the printer-transport layer
    /// (`PrinterFamily`, which has one extra family this enum does not model) can share exactly
    /// one tokenisation instead of hand-rolling a second, subtly different one.
    ///
    /// Trims, lower-cases, splits on whitespace/underscore, drops a **leading** `creality`
    /// token, drops a trailing `.json`, and rejoins with single spaces.
    public static func normalisedName(_ raw: String) -> String { normalise(raw) }

    /// The first whitespace-separated token of ``normalisedName(_:)``, or `""`.
    public static func leadingToken(of raw: String) -> String {
        String(normalisedName(raw).split(separator: " ").first ?? "")
    }

    private static func normalise(_ raw: String) -> String {
        var tokens = raw
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "_" || $0 == "\n" })
            .map(String.init)
        if tokens.first == "creality", tokens.count > 1 { tokens.removeFirst() }
        // Strip a trailing ".json" so a file name resolves as readily as a printer name.
        if let last = tokens.last, last.hasSuffix(".json") {
            tokens[tokens.count - 1] = String(last.dropLast(5))
        }
        return tokens.joined(separator: " ")
    }
}
