import Foundation
import SwiftUI
import Combine
import SpoolworksCore

// MARK: - What is on the tag

/// The condition of the tag currently on the reader, after a read.
///
/// The Windows app collapses all of this into four toasts — `Empty tag`, `Data read from tag`,
/// `Unknown or empty tag`, `Error reading tag` (`MainForm.cs:397-432`) — and shows no persistent
/// indication of which one you are in. Each case here is a distinct rendered state.
enum TagCondition: Equatable {
    /// Sector 1 opened with the factory key and holds no valid record: a fresh, unprogrammed tag.
    case blank
    /// Sector 1 opened and decoded to a valid Creality record.
    case programmed(SpoolRecord)
    /// Sector 1 opened with the derived key — so this tag was written by an app in this family —
    /// but the payload does not parse. A newer layout, or a damaged tag.
    case unrecognisedPayload(String)

    var record: SpoolRecord? {
        if case let .programmed(record) = self { return record }
        return nil
    }
}

extension TagReadResult {
    var condition: TagCondition {
        if let record { return .programmed(record) }
        if isProgrammed {
            return .unrecognisedPayload(recordError?.localizedDescription
                                        ?? "The tag's sector 1 did not decode to a spool record.")
        }
        return .blank
    }
}

// MARK: - The write form

/// The values the user composes before writing, and the rules that turn them into a `SpoolRecord`.
///
/// Kept deliberately independent of the material-catalogue screen: `applySelection` is the seam
/// the Materials screen fills in, and until then the id can be typed directly. Validation happens
/// on commit, never by blocking keystrokes — the Windows app suppresses Ctrl+V in its numeric
/// fields (`FilamentForm.cs:430-442`), which is listed as a non-goal.
struct SpoolDraft: Equatable {
    /// `base.id` from the material database: exactly 5 characters.
    ///
    /// This is the single value written to the tag, and it is what the vendor → material cascade
    /// resolves to — exactly `GetMaterialID(vendor, name)` in `MainForm.cs:949-956`.
    var materialID: String = ""
    /// Human label for `materialID`, e.g. `Creality · Hyper PLA`. Display only.
    var materialLabel: String = ""
    /// Optional because "no colour yet" is a real state and blue is not it.
    ///
    /// The Windows app defaults to `0x0000FF` (`MainForm.cs:60`). Carried over literally, the form
    /// opened showing a blue swatch — which reads as a colour that came off a tag, on a screen
    /// that has not read one. An unset colour cannot be written, which is correct: a spool's
    /// colour is not something to guess.
    var color: Color?
    var weight: FilamentLength = .kg1
    /// Written to sector 2 in plaintext. Advisory — the Arduino firmware writes a constant there.
    var printerType: PrinterType? = .k2
    /// `MainForm.cs:451` hard-codes `000001`; exposed because Android and the Arduino do not.
    /// Randomised per draft rather than the Windows constant — see
    /// ``SpoolworksCore/SpoolRecord/randomSerialNumber()`` for why `000001` is actively harmful.
    var serialNumber: String = SpoolRecord.randomSerialNumber()

    /// `RRGGBB`, or empty when no colour has been chosen.
    var colorHex: String { color?.rgb8.hexString ?? "" }

    /// The sector-2 string. `nil` printer type writes 48 spaces, matching a tag whose printer
    /// field was never set.
    var printerTypeString: String { printerType?.rawValue.uppercased() ?? "" }

    /// Field-level problems, in the order they should be reported. Empty means the draft is
    /// writable.
    var validationIssues: [String] {
        var issues: [String] = []
        let id = materialID.trimmingCharacters(in: .whitespaces)
        if id.isEmpty {
            issues.append("Enter a material ID.")
        } else if id.utf8.count != 5 {
            issues.append("Material ID must be exactly 5 characters (it is \(id.utf8.count)).")
        } else if !id.allSatisfy(\.isNumber) {
            issues.append("Material ID must be digits only.")
        }
        // Reported after the material ID because that is the order the form reads in: the ID row
        // sits above the colour row, and a complaint that skips ahead sends the user to the wrong
        // field.
        if color == nil {
            issues.append("Choose a colour.")
        }
        let serial = serialNumber.trimmingCharacters(in: .whitespaces)
        if serial.utf8.count != 6 || !serial.allSatisfy(\.isNumber) {
            issues.append("Serial number must be exactly 6 digits.")
        }
        return issues
    }

    var isValid: Bool { validationIssues.isEmpty }

    /// Value equality that compares the colour by its encoded hex rather than by `Color`'s own
    /// `Equatable`, which compares colour *providers*: two colours built from different spaces
    /// that quantise to the same 8-bit triple are the same draft as far as a tag is concerned.
    ///
    /// Used to tell "the user has changed the form" from "the form is still what we put in it",
    /// which decides whether a fresh read may adopt the form (see ``TagViewModel/draftIsEdited``).
    /// `materialLabel` is compared even though it is display-only, because it is *shown* — on the
    /// confirmation sheet and on the success panel — and a form whose label no longer matches its
    /// id is a form that has changed, whoever changed it. Leaving it out meant a cascade that
    /// swapped the label under a fresh read counted as "untouched" and was silently overwritten.
    func hasSameValues(as other: SpoolDraft) -> Bool {
        materialID == other.materialID
            && materialLabel == other.materialLabel
            && weight == other.weight
            && serialNumber == other.serialNumber
            && printerType == other.printerType
            && colorHex == other.colorHex
    }

    /// Builds the record, or throws the first `SpoolRecordError` the domain layer reports.
    func makeRecord() throws -> SpoolRecord {
        try SpoolRecord(materialId: materialID.trimmingCharacters(in: .whitespaces),
                        colorRGB: colorHex,
                        filamentLength: weight,
                        serialNumber: serialNumber.trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - The write plan

/// One row of the pre-write diff.
struct WriteDiffRow: Identifiable, Equatable {
    let id: String
    let label: String
    let before: String
    let after: String
    var changed: Bool { before != after }
}

/// Everything the confirmation sheet needs, computed from a fresh read of the tag in hand.
///
/// DECISIONS D-006: "read-before-write with a full pre-write diff shown to the user; explicit
/// confirmation for any destructive operation; automatic backup dump of all readable sectors
/// before any write; key/trailer modification gated behind an explicit advanced toggle."
///
/// Nothing writes without one of these, and that has not changed. What *has* changed, at the tool
/// owner's explicit instruction, is that the plan is not always **shown**: in Write mode with
/// auto-write on, presenting a tag builds this plan, checks it, and commits it without raising the
/// sheet — see ``TagViewModel/autoWriteIfNeeded(card:allowTrailerWrite:)``. The read-before-write,
/// the diff, the backup and the trailer gate all survive intact; only the confirmation click is
/// gone, because in Write mode the presentation of the tag *is* the confirmation.
struct WritePlan: Identifiable, Equatable {
    let id = UUID()
    /// The tag this plan was computed against. Re-checked at commit time; a swapped tag aborts.
    let uid: [UInt8]
    let record: SpoolRecord
    /// `Creality · Hyper PLA`, when the catalogue could name the id. Display only.
    let materialLabel: String
    let printerTypeString: String
    let currentCondition: TagCondition
    let rows: [WriteDiffRow]
    /// Sector 1 is still on the factory key, so programming it rewrites the sector trailer
    /// (block 7) with the derived key. Irreversible, and the reason for the extra opt-in.
    let requiresTrailerWrite: Bool
    /// Sector 2's current printer string, or nil when sector 2 could not be read.
    let currentPrinterType: String?
    let derivedKey: MifareKey

    var hasChanges: Bool { rows.contains(where: \.changed) || requiresTrailerWrite }
    var changedRows: [WriteDiffRow] { rows.filter(\.changed) }
}

/// The outcome of a completed write.
enum WriteOutcome: Equatable {
    case succeeded(WriteSummary)
    case failed(String)
}

/// What the post-write read-back established.
///
/// A write that reports success is not the same thing as a tag that holds the bytes. `TagService`
/// already verifies blocks 4–6 against what it sent, but that verification is internal and throws
/// away what it read; the panel on screen has to be a record that came **off the card**, or the
/// screen is once again asserting something it has not checked. This is that distinction, made
/// visible.
enum PostWriteReadback: Equatable {
    /// The tag was read again, in the same card session as the write, and the record on screen is
    /// that read.
    case confirmed
    /// The write succeeded but the tag could not be read again — so the tag very likely does hold
    /// the new record, and the app simply cannot show it. Never rendered as a write failure.
    case unavailable(String)
}

/// A flattened, `Equatable` view of `TagWriteResult` — the result type itself is not `Equatable`
/// and carries a whole card dump, which the view layer has no business diffing.
///
/// It also carries the *content* that was written (record, material label, printer string). The
/// success panel has to be able to name what landed on the tag — "Data written to tag" with no
/// values under it is what let a stale record on the rest of the screen read as a failed write.
struct WriteSummary: Equatable {
    let uid: [UInt8]
    let record: SpoolRecord
    /// `Creality · Hyper PLA`, when the catalogue could name the id. Display only.
    let materialLabel: String
    let printerTypeString: String
    let wasAlreadyProgrammed: Bool
    let wroteTrailer: Bool
    let wroteSector2: Bool
    let blocksWritten: [Int]
    let backupSectorCount: Int
    let backupFailedSectors: [Int]
    /// The backup rendered as a text dump, ready to be written to disk on request.
    let backupDump: String

    var uidSpaced: String { uid.hexStringSpaced }
}

// MARK: - Material catalogue

/// The filament catalogue for one printer family, loaded off the main actor.
///
/// This is the data behind the printer → brand → material cascade that `MainForm` drives with
/// three chained `SelectedIndexChanged` handlers (`MainForm.cs:723-736, 938-956`). The cascade is
/// preserved; only its plumbing changes.
///
/// It is deliberately read-only. Adding, editing and deleting filaments belongs to the Materials
/// screen; this is the tag screen's view of the same `MaterialDatabase`.
@MainActor
final class MaterialCatalog: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case ready
        /// No catalogue for this family — typically a shipped bundle with no seed JSON. The write
        /// form falls back to manual ID entry rather than becoming unusable.
        case unavailable(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var printerType: PrinterType?
    @Published private(set) var filaments: [Filament] = []

    /// Distinct brands, sorted. `MainForm` populates this from `GetVendors()`.
    @Published private(set) var vendors: [String] = []

    var isReady: Bool { state == .ready && !filaments.isEmpty }

    /// Filaments for one brand, sorted by name — `GetMaterialsByBrand` (`MainForm.cs:938-947`).
    func materials(forVendor vendor: String) -> [Filament] {
        filaments
            .filter { $0.vendor == vendor }
            .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    func filament(id: String) -> Filament? {
        filaments.first { $0.id == id }
    }

    /// Loads (and seeds, on first run) the catalogue for a family.
    func load(_ type: PrinterType?) async {
        printerType = type
        guard let type else {
            filaments = []
            vendors = []
            state = .unavailable("No printer family selected.")
            return
        }
        state = .loading

        // `MaterialDatabase` is documented as not thread-safe and is not `Sendable`; it is
        // therefore created, used and destroyed entirely inside the detached task, which returns
        // only the `Sendable` `Filament` values.
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[Filament], Error> in
            do {
                let storage = try MaterialStorage.applicationSupport()
                let database = MaterialDatabase(printerType: type, storage: storage)
                return .success(try database.load())
            } catch {
                return .failure(error)
            }
        }.value

        guard printerType == type else { return }   // the user moved on while we loaded

        switch outcome {
        case let .success(list):
            filaments = list
            vendors = Set(list.map(\.vendor)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            state = list.isEmpty
                ? .unavailable("The \(type.displayName) catalogue is empty.")
                : .ready
        case let .failure(error):
            filaments = []
            vendors = []
            state = .unavailable(error.localizedDescription)
        }
    }
}

// MARK: - Prefill

/// A snapshot of the last spool record read off a tag, kept so the write form can offer it once
/// that tag is gone.
///
/// Deliberately a value copy rather than a reference to `TagReadResult`: it has to stay valid
/// after the tag it came from has been lifted off the reader, and it must not be confused with
/// "what is on the tag in hand right now".
struct TagPrefill: Equatable {
    let uid: [UInt8]
    let record: SpoolRecord
    /// Sector 2's plaintext printer string, when sector 2 was readable.
    let printerType: String?

    /// `70 4E 7C 39` — the spacing used everywhere else a UID is shown.
    var uidSpaced: String { uid.hexStringSpaced }
}

// MARK: - View model

/// Drives the tag read/write screen.
///
/// Owns no PC/SC state of its own: every card touch goes through ``ReaderMonitor/withCard(_:)``,
/// which serialises it against presence polling.
@MainActor
final class TagViewModel: ObservableObject {

    enum Activity: Equatable {
        case idle
        case reading
        case preparingWrite
        case writing

        var isRunning: Bool { self != .idle }

        var label: String {
            switch self {
            case .idle: return ""
            case .reading: return "Reading tag…"
            case .preparingWrite: return "Checking tag…"
            case .writing: return "Writing tag, then reading it back…"
            }
        }

        /// What a postponed arrival is waiting for, as a clause that follows "waiting until".
        var waitingReason: String {
            switch self {
            case .idle: return "the reader is free"
            case .reading: return "the read in progress finishes"
            case .preparingWrite: return "the tag check in progress finishes"
            case .writing: return "the write in progress finishes"
            }
        }

        /// True while whatever record is on screen is known not to describe the tag any more.
        ///
        /// A write ends in a read-back inside the same card session, so from the first write APDU
        /// until that read lands there is no trustworthy record to show. Rendering the pre-write
        /// values for those few hundred milliseconds is exactly the flicker that made a successful
        /// write look like nothing had happened, so the in-progress state is shown instead.
        var supersedesTagContents: Bool {
            switch self {
            case .idle, .preparingWrite: return false
            case .reading, .writing: return true
            }
        }
    }

    /// What auto-write is doing, in one value the view can render without knowing the mechanism.
    enum AutoWriteState: Equatable {
        /// The user turned it off. Only ⇧⌘W writes.
        case off
        /// The form cannot produce a record, so there is nothing to arm with.
        case blocked(String)
        /// A read or write is in flight.
        case busy(String)
        /// The tag on the reader arrived while something else held the model, so its write is
        /// waiting rather than happening. The associated value says what it is waiting for.
        ///
        /// This case exists because the indicator used to render this situation as ``armed`` —
        /// "Ready — writing the tag on the reader" — while nothing was writing it and nothing ever
        /// would. An arming that has been *seen* and *postponed* is a third thing, and it is now
        /// said out loud.
        case deferred(String)
        /// A tag is on the reader that this app cannot write at all. Distinct from ``armed``,
        /// which used to swallow it and claim a write was about to happen.
        case unsupportedTag
        /// No tag on the reader, and the next one to arrive will be written.
        case armed
        /// A tag is on the reader that this arming has already dealt with — it was written, it was
        /// already sitting there when Write mode was entered, or its write failed. It will not be
        /// written again until it is lifted and presented anew.
        case handled
    }

    /// A card arrival that has been noticed but not yet acted on, because the model was busy or
    /// the confirmation sheet was up.
    ///
    /// The bug this replaces: `autoWriteIfNeeded` returned on `!activity.isRunning` without
    /// recording anything, and the only things that ever re-ran it were card-*change* signals —
    /// which do not fire when a read finishes. The tag simply sat there. Recording the arrival is
    /// half the fix; re-driving it when ``activity`` falls back to `.idle` is the other half.
    struct DeferredArrival: Equatable {
        let uid: [UInt8]
        /// What the arrival is waiting for, in words, for the indicator.
        let reason: String
    }

    /// Which half of the screen is showing.
    ///
    /// Lives here, not in a view's `@State`, for two reasons. It has to survive the view being
    /// rebuilt — leaving the Tag screen for Materials and coming back would otherwise snap the
    /// screen back to Read — and, more importantly, everything each mode shows (``lastRead``,
    /// ``draft``, ``prefill``, ``writeOutcome``) already lives here, so mode belongs with it.
    /// Switching modes therefore discards nothing in either direction: Write → Read → Write finds
    /// the composed form untouched, Read → Write → Read finds the decoded record untouched.
    @Published var mode: TagMode = .read {
        didSet {
            guard mode != oldValue else { return }
            // Arriving in Write mode with a tag already sitting on the antenna is not a
            // presentation gesture, and auto-writing it would be a write the user never asked
            // for. Consume that UID here so auto-write can only ever fire on a genuine arrival.
            if mode == .write { consumeAutoWriteArming() }
            // Switching *into* Read with a tag already sitting there must read it — otherwise the
            // screen shows a tag it is refusing to look at. This used to be an `onChange` in
            // `TagView`; it lives here now, for the same reason the card subscription does.
            scheduleCardResponse()
        }
    }

    /// What the model is doing to the card right now.
    ///
    /// Returning to `.idle` is a *signal*, not merely a state: it is the moment a deferred arrival
    /// becomes actionable. Nothing else re-evaluates it — `monitor.state.card` has not changed and
    /// `insertionCount` has not moved — so the transition is observed here rather than being left
    /// to a card event that will never come.
    @Published private(set) var activity: Activity = .idle {
        didSet {
            guard oldValue != activity, activity == .idle else { return }
            retryDeferredArrival()
        }
    }

    /// The arrival that is waiting for the model to become free. See ``DeferredArrival``.
    @Published private(set) var deferredArrival: DeferredArrival?

    /// The last tag this app successfully read, **kept after that tag leaves the reader**.
    ///
    /// It used to be cleared the moment the tag was lifted, which threw away the thing the user
    /// had just gone to the trouble of reading: the screen snapped back to "Place a Tag on the
    /// Reader" while they were still looking at it. It now survives removal, and Read mode keeps
    /// rendering it, labelled as the last tag read (``retainedRead``).
    ///
    /// It is still replaced — not accumulated — the moment a *different* tag arrives, so nothing
    /// on screen ever describes a tag other than the one in hand while a tag is in hand. Use
    /// ``lastReadIsLive`` to tell the two apart; the shared form uses it to add the quiet "not on
    /// the reader" note to the Tag ID row rather than swapping in a separate panel.
    @Published private(set) var lastRead: TagReadResult?
    /// Why the last read failed. Distinct from "no tag" — this means a tag was there and would
    /// not open.
    @Published private(set) var readFailure: String?
    @Published private(set) var writeOutcome: WriteOutcome?

    /// Whether the record on screen after the last successful write actually came off the card.
    /// Non-nil only alongside ``writeOutcome`` `== .succeeded`.
    @Published private(set) var readback: PostWriteReadback?

    /// The pending confirmation. Non-nil presents the write sheet.
    ///
    /// While it is non-nil auto-write stands down, so dismissing it — confirmed or cancelled — is
    /// one of the two moments a postponed arrival becomes actionable again. (The other is
    /// ``activity`` falling back to `.idle`.)
    @Published var pendingPlan: WritePlan? {
        didSet {
            guard oldValue != nil, pendingPlan == nil else { return }
            retryDeferredArrival()
        }
    }

    /// Called after a write that verified. Set by ``AppEnvironment`` to log the spool to stock;
    /// nil in tests and previews, where nothing should be persisted.
    var onWriteSucceeded: ((WriteSummary) -> Void)?

    @Published var draft = SpoolDraft()

    /// Nearest named colour for the draft swatch, resolved off the main actor.
    @Published private(set) var draftColorName: String?

    // MARK: Prefill from the last read

    /// The last spool record this app successfully read, kept **after** the tag has left the
    /// reader.
    ///
    /// That outliving is the whole point: the flow the write form exists for is "read the spool I
    /// have, take that tag off, put a fresh tag on, write the same thing". ``lastRead`` is cleared
    /// the moment the tag is lifted (it describes the tag in hand); this does not.
    @Published private(set) var prefill: TagPrefill?

    /// The UID whose values are currently loaded into ``draft``, when any. Drives the
    /// "From tag 70 4E 7C 39" provenance note.
    @Published private(set) var draftSourceUID: [UInt8]?

    /// ``draft`` as this class last set it. Anything else means the user has typed or picked
    /// something since, which is what stops a fresh read from overwriting composed work.
    /// What ``draft`` looked like before the user touched it.
    ///
    /// Seeded from `draft` rather than from a second `SpoolDraft()`. Now that the default serial is
    /// randomised per instance, two independently constructed drafts differ in that one field —
    /// so a freshly built form compared itself against a stranger and reported itself edited
    /// before anyone had typed anything.
    @Published private(set) var draftBaseline: SpoolDraft

    /// True when the form no longer matches what was last loaded into it.
    var draftIsEdited: Bool { !draft.hasSameValues(as: draftBaseline) }

    /// True when the form holds exactly the values read off ``prefill``'s tag.
    var draftMatchesPrefill: Bool {
        guard let prefill else { return false }
        return draftSourceUID == prefill.uid && !draftIsEdited
    }

    // MARK: Recently used colours

    /// Colours this user has actually written to a tag or read off one, most recent first,
    /// de-duplicated and capped at ``recentColorLimit``. Persisted, so the palette is still
    /// useful on the next launch.
    ///
    /// This exists because there is no filament palette to read out of the material database. All
    /// 98 records in the shipped database carry exactly one `base.colors` entry and it is always
    /// `#ffffff` or `#000000` — a placeholder, which is why the Windows app never reads the field.
    /// The palette that is genuinely useful is therefore the one the user's own use builds up.
    @Published private(set) var recentColors: [String] = []

    static let recentColorLimit = 8

    // MARK: Material cascade

    /// The catalogue behind the brand → material pickers.
    let catalog = MaterialCatalog()

    /// Currently selected brand. Empty when the catalogue is not loaded.
    @Published private(set) var selectedVendor: String = ""

    /// True when the user has chosen to type an ID instead of picking one. Forced on whenever the
    /// catalogue is unavailable, so the write form is never a dead end.
    @Published var manualMaterialEntry = false

    var materialsForSelectedVendor: [Filament] {
        catalog.materials(forVendor: selectedVendor)
    }

    /// Whether the pickers can drive the ID, or the user has to type it.
    var usesCatalog: Bool { catalog.isReady && !manualMaterialEntry }

    /// UID the current `lastRead` belongs to, so a tag swap invalidates the panel.
    private var readUID: [UInt8]?

    /// UID the automatic read has already fired for.
    ///
    /// Keyed on the UID, not on a "has read" flag, so a tag is read once per arrival: it is not
    /// re-read while it sits on the antenna, a *different* tag is read immediately, and a failed
    /// read stays failed instead of retrying in a loop against a tag that will not open.
    private var autoReadUID: [UInt8]?

    // MARK: Auto-write

    /// Write mode writes a tag the moment it is presented, with no confirmation sheet.
    ///
    /// This is the tool owner's explicit, informed instruction, and it is how the Windows app's
    /// `AutoWrite` behaves (`MainForm.cs:276-279`). The reasoning it rests on: in Write mode the
    /// user has *already* composed exactly what they want written, so putting a tag on the reader
    /// **is** the deliberate act — the sheet was asking them to confirm a decision they had
    /// already made, one tag at a time, through a batch.
    ///
    /// Three things keep it from being a hazard, and all three are structural rather than advisory:
    /// it only exists in Write mode (``autoWriteIfNeeded(card:allowTrailerWrite:)`` returns
    /// immediately otherwise, so **Read mode can never write**); it fires at most once per UID per
    /// arrival (see ``autoWriteHandledUID``); and a write that would rewrite a sector trailer still
    /// goes through the confirmation sheet unless the persistent advanced opt-in is already on.
    ///
    /// Defaults to on, because that is what was asked for. The off switch is a toggle in Write
    /// mode itself, not a preference pane.
    @Published var autoWriteEnabled: Bool {
        didSet {
            guard autoWriteEnabled != oldValue else { return }
            defaults.set(autoWriteEnabled, forKey: StorageKeys.autoWrite)
            autoWriteSkipped = nil
            // Flipping the switch on is not a presentation gesture either: a tag already sitting
            // on the reader must not be written by the act of enabling auto-write.
            if autoWriteEnabled { consumeAutoWriteArming() }
        }
    }

    /// The UID auto-write has already dealt with.
    ///
    /// Exactly parallel to ``autoReadUID``, and the whole of the "write once per tag" rule. It is
    /// set **before** the write is started, never after, so nothing that happens during the write —
    /// a republished card identity, a second `onChange`, a re-entrant task — can produce a second
    /// write. It is cleared only by ``cardChanged(to:)`` seeing a *different* UID or an empty
    /// reader, which is precisely the definition of an arrival.
    ///
    /// It is also set deliberately, without writing anything, when Write mode is entered or the
    /// toggle is switched on while a tag is already present — see ``consumeAutoWriteArming()``.
    private var autoWriteHandledUID: [UInt8]?

    /// Why the last presentation did not result in a write. Cleared on the next arrival.
    @Published private(set) var autoWriteSkipped: String?

    /// What auto-write will do next, for the armed-state indicator.
    ///
    /// Reads `monitor.state`, which the model does not observe — every view that renders this also
    /// observes the monitor, so it re-evaluates when the reader changes. Same arrangement as
    /// ``canWrite``.
    var autoWriteState: AutoWriteState {
        guard mode == .write else { return .off }
        guard autoWriteEnabled else { return .off }
        if activity.isRunning { return .busy(activity.label) }
        if let issue = draft.validationIssues.first { return .blocked(issue) }
        // No tag at all: the next arrival gets written. A tag that is *present but unwritable* is
        // a different answer, and saying `.armed` for it claimed a write was imminent for a tag
        // this app can never write.
        guard let card = monitor.state.card else { return .armed }
        guard card.isUsable else { return .unsupportedTag }
        if let deferred = deferredArrival, deferred.uid == card.uid { return .deferred(deferred.reason) }
        if pendingPlan != nil { return .deferred("the confirmation sheet is open") }
        return autoWriteHandledUID == card.uid ? .handled : .armed
    }

    private unowned let monitor: ReaderMonitor
    private let toasts: ToastCenter
    private let settings: AppSettings
    private let defaults: UserDefaults

    /// Preference keys owned by this screen. Prefixed like ``AppSettings/Keys`` so they never
    /// collide with the Windows registry values.
    enum StorageKeys {
        static let recentColors = "K2RecentTagColors"
        static let autoWrite = "K2AutoWriteOnPresentation"
    }

    init(monitor: ReaderMonitor,
         toasts: ToastCenter,
         settings: AppSettings,
         defaults: UserDefaults = .standard) {
        self.monitor = monitor
        self.toasts = toasts
        self.settings = settings
        self.defaults = defaults
        // Both sides of the edited-comparison start as the *same* draft, random serial included.
        let initialDraft = SpoolDraft()
        self.draft = initialDraft
        self.draftBaseline = initialDraft
        self.recentColors = Self.sanitisedColors(defaults.stringArray(forKey: StorageKeys.recentColors) ?? [])
        // Absent means never chosen, which is on — `bool(forKey:)` alone would silently default it
        // off for every existing install.
        self.autoWriteEnabled = defaults.object(forKey: StorageKeys.autoWrite) as? Bool ?? true
        observeReader()
    }

    // MARK: Reader subscription

    /// Card arrivals, removals and swaps, for the lifetime of the **app**.
    ///
    /// This used to be two `onChange` modifiers in `TagView`, and `RootView.detail` is a
    /// `@ViewBuilder switch`: selecting Reader, Materials or Printers destroys `TagView` outright.
    /// Every card event during that time was therefore invisible to this model — arrivals,
    /// removals and swaps alike — which left `autoWriteHandledUID` pointing at a tag that had long
    /// since been lifted (so the next tag read as `.armed` and nothing wrote it) and left
    /// `writeOutcome`/`readFailure` on screen next to a *different* tag's UID.
    ///
    /// The subscription belongs to the model because the bookkeeping belongs to the model. A view
    /// that may or may not exist cannot be the thing that keeps it honest.
    private func observeReader() {
        monitor.$state
            .map(\.card)
            .removeDuplicates()
            // `ReaderMonitor` is `@MainActor` and only ever assigns `state` from the main actor,
            // so this delivery is already main-isolated; asserting that is what lets the handler
            // run *synchronously* with the event. Hopping through a `Task` instead would reorder
            // an arrival against the removal that preceded it.
            .sink { [weak self] card in
                MainActor.assumeIsolated { self?.cardEvent(card) }
            }
            .store(in: &readerSubscriptions)
    }

    private var readerSubscriptions = Set<AnyCancellable>()

    /// The single funnel every card event goes through.
    private func cardEvent(_ card: CardIdentity?) {
        cardChanged(to: card)
        scheduleCardResponse(card)
    }

    /// Runs the automatic read/write for `card`, serialised behind whatever response is already
    /// running so two arrivals can never interleave.
    ///
    /// Passing `nil` for `card` means "whatever is on the reader now", which is what the mode
    /// switch and the deferred retry both want.
    private func scheduleCardResponse(_ card: CardIdentity?? = nil) {
        let target = card ?? monitor.state.card
        let previous = cardResponse
        cardResponseGeneration &+= 1
        cardResponse = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            await self.respondToCard(target)
        }
    }

    private var cardResponse: Task<Void, Never>?
    /// Bumped by every ``scheduleCardResponse(_:)``, so a test can tell "the queue is empty" from
    /// "the queue drained and something queued another one".
    private var cardResponseGeneration = 0

    /// The single place a card is turned into work, so read and write can never race each other.
    ///
    /// `internal` rather than `private` so a test can drive one response and await it; nothing in
    /// the view layer calls it.
    func respondToCard(_ card: CardIdentity?) async {
        await autoReadIfNeeded(card: card)
        await autoWriteIfNeeded(card: card,
                                allowTrailerWrite: settings.advancedTagOperations)
    }

    /// Re-drives a postponed arrival now that the model is free again.
    ///
    /// Called from ``activity``'s observer. It is deliberately not conditional on *which* tag is
    /// on the reader: the arming rules inside `autoReadIfNeeded`/`autoWriteIfNeeded` are the only
    /// thing allowed to decide whether anything actually happens.
    private func retryDeferredArrival() {
        guard deferredArrival != nil else { return }
        scheduleCardResponse()
    }

    // MARK: Derived state

    var condition: TagCondition? { lastRead?.condition }

    /// True when ``lastRead`` describes the tag that is on the reader right now.
    ///
    /// The distinction the retained record depends on: everything that claims to describe the tag
    /// in hand has to check this, and everything that is a memory of a tag must not.
    var lastReadIsLive: Bool {
        guard let lastRead else { return false }
        return monitor.state.card?.uid == lastRead.uid
    }

    var canRead: Bool {
        monitor.state.card?.isUsable == true && !activity.isRunning
    }

    var canWrite: Bool {
        monitor.state.card?.isUsable == true && !activity.isRunning && draft.isValid
    }

    // MARK: Material cascade actions

    /// Step 1 of the cascade — `PrinterModel_SelectedIndexChanged` (`MainForm.cs:723-736`):
    /// load that family's catalogue, then repopulate brands and select the first.
    ///
    /// The printer choice does double duty exactly as it does on Windows: it selects the
    /// catalogue *and* it is the string written to sector 2.
    func printerTypeChanged(to type: PrinterType?) async {
        draft.printerType = type
        await catalog.load(type)
        if catalog.isReady {
            manualMaterialEntry = false
            // Deliberately does **not** fall back to the first brand in the catalogue. An
            // unattended default meant the form arrived claiming a specific material — the first
            // one alphabetically — and a write started before anyone looked at it would put that
            // material on the tag. A blank form cannot be written until a choice is made, which is
            // the correct amount of friction for an irreversible operation. A brand already in the
            // draft (from a read, or the user's own pick) is still honoured.
            selectVendor(preferredVendor() ?? "")
        } else {
            // No catalogue: the ID field becomes the input, pre-filled with whatever was there.
            manualMaterialEntry = true
            selectedVendor = ""
        }
    }

    /// Step 2 — `VendorName_SelectedIndexChanged` (`MainForm.cs:938-947`): repopulate materials
    /// for the brand and select index 0.
    func selectVendor(_ vendor: String) {
        selectedVendor = vendor
        let materials = catalog.materials(forVendor: vendor)
        if let keep = materials.first(where: { $0.id == draft.materialID }) {
            selectMaterial(keep)          // the current id is still valid under the new brand
        } else {
            selectMaterial(materials.first)
        }
    }

    /// Step 3 — `MaterialName_SelectedIndexChanged` (`MainForm.cs:949-956`):
    /// `GetMaterialID(vendor, name)` becomes the id written to the tag.
    ///
    /// `nil` means "this brand has no materials", and it now clears the **id** as well as the
    /// label. Clearing only the label left `draft.materialID` pointing at the previous brand's
    /// material while the form and the sheet named nothing at all — a write of one material under
    /// another's heading. An empty id fails validation, which is the honest outcome.
    func selectMaterial(_ filament: Filament?) {
        guard let filament else {
            draft.materialID = ""
            draft.materialLabel = ""
            return
        }
        draft.materialID = filament.id
        draft.materialLabel = "\(filament.vendor) · \(filament.name)"
    }

    /// Points the form at a catalogue id. An id the catalogue does not know keeps the id — it may
    /// well be a valid `base.id` this database simply does not carry — but drops the label, which
    /// would otherwise still be naming whatever was selected before.
    func selectMaterial(id: String) {
        guard let filament = catalog.filament(id: id) else {
            draft.materialLabel = ""
            manualMaterialEntry = true
            return
        }
        selectMaterial(filament)
    }

    /// Keeps the current brand across a family switch when that brand still exists.
    private func preferredVendor() -> String? {
        if let current = catalog.filament(id: draft.materialID)?.vendor { return current }
        return catalog.vendors.contains(selectedVendor) ? selectedVendor : nil
    }

    /// Points the cascade at whichever filament carries `id`, if the catalogue knows it.
    /// Used after a read, so "load into write form" lands on the right rows.
    ///
    /// The early return used to leave `draft.materialLabel` naming the *previous* material while
    /// `draft.materialID` had already been replaced by the tag's, so the confirmation sheet and
    /// the success panel both captioned the write with a material unrelated to the id going onto
    /// the tag. An id the catalogue cannot name has no label; that is what is now said.
    private func syncCascade(toMaterialID id: String) {
        guard let filament = catalog.filament(id: id) else {
            draft.materialLabel = ""
            manualMaterialEntry = true
            return
        }
        manualMaterialEntry = false
        selectedVendor = filament.vendor
        draft.materialLabel = "\(filament.vendor) · \(filament.name)"
    }

    // MARK: Card lifecycle

    /// Reacts to the tag on the reader arriving, leaving or being swapped.
    ///
    /// ``prefill``, ``draft`` and ``mode`` deliberately survive all of it: they are the user's
    /// composition and their memory of the last tag, neither of which the hardware owns. As of the
    /// retained-record change, ``lastRead`` survives *removal* for the same reason — what was on
    /// the tag is knowledge, and lifting the tag does not unlearn it. It is still dropped when a
    /// **different** tag arrives, because then it would be a caption under the wrong photograph.
    func cardChanged(to identity: CardIdentity?) {
        guard identity?.uid != readUID else { return }
        readUID = identity?.uid
        // Cleared before `pendingPlan`, whose observer would otherwise schedule a retry for a tag
        // that is no longer the one on the reader.
        deferredArrival = nil
        pendingPlan = nil
        // A different tag — or an empty reader — re-arms the automatic read.
        if autoReadUID != identity?.uid { autoReadUID = nil }
        // …and, identically, re-arms auto-write. This is the *only* place arming is granted, and
        // it requires the UID to have actually changed, which is why auto-write cannot fire twice
        // for one tag and cannot fire for a tag that was already there.
        if autoWriteHandledUID != identity?.uid {
            autoWriteHandledUID = nil
            autoWriteSkipped = nil
        }

        guard let identity else {
            // The tag was lifted. The decoded record stays on screen; so does the result of the
            // last write — both are knowledge, and lifting the tag does not unlearn either. Only
            // state describing a live attempt against a tag that is no longer there goes.
            readFailure = nil
            return
        }
        // Putting the *same* tag back returns to the live state with nothing reloaded: the record
        // on screen is already this tag's, and `autoReadIfNeeded` will not read it again.
        guard identity.uid != lastRead?.uid else { return }
        lastRead = nil
        readFailure = nil
        writeOutcome = nil
        readback = nil
    }

    /// Marks the tag currently on the reader as already handled by auto-write, without writing it.
    ///
    /// The distinction between "a tag is present" and "a tag was presented" has no hardware
    /// signal behind it, so it has to be held in state. This is that state: entering Write mode,
    /// or switching auto-write on, spends the current tag's arming so the next write needs a real
    /// arrival — either the reader going empty and filling again, or a different UID appearing.
    private func consumeAutoWriteArming() {
        guard let uid = monitor.state.card?.uid else { return }
        autoWriteHandledUID = uid
    }

    /// Forgets the retained record, putting Read mode back to "Place a Tag on the Reader".
    ///
    /// ``prefill`` and ``draft`` are deliberately untouched, the mirror of ``resetDraft()``:
    /// emptying one of the two screens must never quietly destroy the other's work. The write
    /// form keeps its values and keeps saying where they came from.
    func clearRetainedRead() {
        lastRead = nil
        readFailure = nil
        writeOutcome = nil
        readback = nil
        // Whatever is put on the reader next — including this same tag — is read from scratch.
        autoReadUID = nil
    }

    // MARK: Read

    /// Reads the tag as soon as one arrives, in Read mode, once per arrival.
    ///
    /// Read mode showing a tag's UID and then waiting to be asked for its contents is the wrong
    /// model: choosing Read *is* the request. This used to be gated behind an "automatic reading"
    /// preference that defaulted to off, which made the screen's whole purpose opt-in; that
    /// preference is gone.
    ///
    /// Write mode is excluded, and reading is all this does in either case: presenting a tag in
    /// Write mode is handled by ``autoWriteIfNeeded(card:allowTrailerWrite:)``, and no path from
    /// here can reach a write.
    func autoReadIfNeeded(card: CardIdentity?) async {
        guard mode == .read else { return }
        guard let card, card.isUsable else { return }
        guard autoReadUID != card.uid else { return }
        guard lastRead?.uid != card.uid else { return }
        // Busy is checked **before** the arming is spent, matching `autoWriteIfNeeded`. The other
        // order — arm, then call `read()`, which opens with the same busy guard — spent the arming
        // on a read that never happened, and because `autoReadUID` is keyed on the UID that tag
        // was then never read at all. The arrival is recorded instead and retried when the model
        // is free.
        guard !activity.isRunning else {
            deferredArrival = DeferredArrival(uid: card.uid, reason: activity.waitingReason)
            return
        }
        deferredArrival = nil
        autoReadUID = card.uid
        await read()
    }

    func read() async {
        guard !activity.isRunning else { return }
        activity = .reading
        readFailure = nil
        // A read the user asked for supersedes the last write's result panel, and it does so
        // whether or not it succeeds: a read that *fails* against the tag leaves "Write Succeeded"
        // sitting above "This tag could not be read", which is the screen contradicting itself.
        // The post-write read-back deliberately does not come through here, precisely so it does
        // not destroy the panel it exists to confirm.
        writeOutcome = nil
        readback = nil
        defer { activity = .idle }

        do {
            let result = try await monitor.withCard { session, identity in
                guard identity.isUsable else { throw TagError.unsupportedCard(identity.type) }
                return try TagService(session: session).readTag()
            }
            await adopt(result)
            switch result.condition {
            case .blank:
                toasts.info("Empty tag")
            case .programmed:
                toasts.success("Data read from tag")
            case .unrecognisedPayload:
                toasts.warning("Unknown or empty tag")
            }
        } catch {
            lastRead = nil
            readFailure = error.localizedDescription
            // Release the auto-read arming. It is set *before* the read so a tag cannot be read
            // twice, but leaving it set after a failure means the same tag can never be retried by
            // lifting it and putting it back: `autoReadIfNeeded` sees its UID as already handled.
            //
            // Observed on the bench after replugging the reader — the first tag failed, would not
            // read again however many times it was presented, and only came back after a
            // *different* tag was scanned, because that overwrote the single stored UID. A failed
            // read must leave the tag as unread as it actually is.
            autoReadUID = nil
            toasts.error("Error reading tag — \(error.localizedDescription)")
        }
    }

    /// Installs a read as the record on screen, whatever produced it.
    ///
    /// The one place `lastRead` is set from a successful read, so the read UID bookkeeping, the
    /// recent-colour list and the write-form prefill cannot drift apart depending on which caller
    /// got there. `autoReadUID` is set here too: a record that has just been read must not trigger
    /// the automatic read for the same tag a moment later.
    ///
    /// - Parameter prefillingDraft: whether the read may also flow into the write form. False for
    ///   the read a *write* takes of the tag it is about to overwrite: that read exists to build
    ///   the diff, and letting it rewrite the very draft the diff was computed from would produce
    ///   a sheet whose "after" column no longer matched the form behind it.
    private func adopt(_ result: TagReadResult, prefillingDraft: Bool = true) async {
        lastRead = result
        readUID = result.uid
        autoReadUID = result.uid
        readFailure = nil
        if let record = result.record { rememberColor(record.rgbHex) }
        guard prefillingDraft else { return }
        await rememberForWriting(result)
    }

    /// Records a successful read as the write form's prefill, and adopts it when the form has
    /// nothing of the user's in it.
    ///
    /// The condition is the whole design: a pristine form (defaults, or values loaded from an
    /// earlier tag and untouched since) is adopted silently, so read-then-switch-to-write lands on
    /// "write this same spool again". A form the user has edited is never overwritten — Write →
    /// Read → Write has to come back to what they composed — and the read is offered as a button
    /// instead.
    private func rememberForWriting(_ result: TagReadResult) async {
        guard let record = result.record else { return }
        prefill = TagPrefill(uid: result.uid, record: record, printerType: result.printerType)
        guard !draftIsEdited else { return }
        await applyPrefill()
    }

    /// Copies ``prefill`` into the write form. The one path that loads a tag's values.
    func applyPrefill() async {
        guard let prefill else { return }
        if let name = prefill.printerType,
           let resolved = PrinterType(identifying: name),
           resolved != draft.printerType {
            await printerTypeChanged(to: resolved)
        }
        draft.materialID = prefill.record.materialId
        draft.color = Color(tagHex: prefill.record.rgbHex) ?? draft.color
        draft.weight = prefill.record.knownLength ?? .kg1
        draft.serialNumber = prefill.record.serialNumber
        syncCascade(toMaterialID: prefill.record.materialId)
        draftSourceUID = prefill.uid
        draftBaseline = draft
    }

    /// Loads the tag's current contents into the write form and shows it.
    ///
    /// The button behind this sits in Read mode, so it switches modes too — otherwise it would
    /// fill in a form the user cannot see.
    func loadDraftFromTag() async {
        guard let record = condition?.record, let read = lastRead else { return }
        prefill = TagPrefill(uid: read.uid, record: record, printerType: read.printerType)
        await applyPrefill()
        mode = .write
        toasts.info("Tag contents loaded into the write form")
    }

    /// Puts the form back to the app defaults and forgets that it came from a tag.
    ///
    /// ``prefill`` itself survives, so the banner turns from "these are tag X's values" into an
    /// offer to load them again — clearing the form should not also erase the read.
    func resetDraft() async {
        draft = SpoolDraft()
        draftSourceUID = nil
        // Cleared so the cascade falls back to the first brand rather than keeping the one the
        // last tag happened to use — "Reset to Defaults" has to mean it.
        selectedVendor = ""
        await printerTypeChanged(to: draft.printerType)
        draftBaseline = draft
    }

    /// First-run catalogue load. Called once from the view's `.task`.
    func prepareCatalog() async {
        guard catalog.state == .idle else { return }
        await printerTypeChanged(to: draft.printerType)
        // Loading the catalogue is initialisation, not the user editing the form: re-baseline so
        // the first read is still allowed to adopt it.
        draftBaseline = draft
    }

    // MARK: Write

    /// Step 1 of 2. Reads the tag, computes the diff, and presents the confirmation sheet.
    ///
    /// Nothing is written here. This is the whole point of D-006: a write is never one click.
    func prepareWrite() async {
        guard !activity.isRunning else { return }
        // ⇧⌘W and the Tag menu can fire this from Read mode; the form, the sheet's outcome and any
        // validation complaint all live in Write mode, so show it. Only ever reached from an
        // explicit user action — nothing automatic calls this.
        mode = .write
        guard draft.isValid else {
            toasts.error(draft.validationIssues.joined(separator: " "))
            return
        }

        let record: SpoolRecord
        do { record = try draft.makeRecord() }
        catch {
            toasts.error(error.localizedDescription)
            return
        }

        activity = .preparingWrite
        // The previous write's panel describes a write that is now two operations ago. Whether
        // this pre-write read succeeds or fails, leaving "Write Succeeded" on screen next to a
        // fresh diff — or next to a read failure — is the screen asserting something it no longer
        // knows.
        writeOutcome = nil
        readback = nil
        defer { activity = .idle }

        do {
            let current = try await monitor.withCard { session, identity in
                guard identity.isUsable else { throw TagError.unsupportedCard(identity.type) }
                return try TagService(session: session).readTag()
            }
            // Through `adopt`, not around it: setting `lastRead`/`readUID` by hand skipped
            // `autoReadUID`, so switching to Read mode afterwards found a tag that had "already
            // been read" by a read that never registered, and showed nothing.
            await adopt(current, prefillingDraft: false)
            pendingPlan = Self.makePlan(current: current,
                                        record: record,
                                        materialLabel: draft.materialLabel,
                                        printerTypeString: draft.printerTypeString)
        } catch {
            toasts.error("Could not read the tag before writing — \(error.localizedDescription)")
        }
    }

    /// Step 2 of 2. Called from the confirmation sheet's Write button, and from auto-write.
    ///
    /// ## Why this ends in a read
    ///
    /// The defect this method used to carry: it wrote, kept the record `prepareWrite` had read
    /// **before** the write, and then called `read()` — which returned instantly, because
    /// `activity` was still `.writing` and `read()` guards on exactly that. Even if it had run, it
    /// clears `writeOutcome`, so the success panel would have been destroyed by its own refresh.
    /// The net effect was a screen that, after a perfectly good write, kept showing the tag's
    /// *previous* contents with no confirmation of any kind — reported three times as "the
    /// information didn't actually get written". It always had.
    ///
    /// The record is therefore re-read from the card, inside the **same** `withCard` session as
    /// the write. One session, so there is no window in which the tag can be lifted between the
    /// write and its confirmation, and no reconnect to fail. It is a real read off the tag, not a
    /// record synthesised from `plan.record`: reading back is the only thing that proves the bytes
    /// landed, and asserting a write the app has not seen is the failure mode being fixed.
    ///
    /// `TagService.writeTag` does verify blocks 4–6 internally, but `verifyRecord` compares and
    /// discards — it returns `Void` and produces no `TagReadResult` to reuse — so this is the read
    /// that produces one. It costs one extra authenticate plus six block reads on a session that
    /// is already open.
    /// - Parameter allowTrailerWrite: authorises the irreversible sector-key rewrite a blank tag
    ///   needs. SpoolworksCore enforces this too, from its own runtime decision, so a stale UI snapshot
    ///   cannot let one through.
    /// The most recent pre-write dump, captured even when the write then failed. This is the only
    /// record of what a tag held before an aborted or partial write.
    @Published private(set) var lastWriteBackup: [MifareClassicCard.SectorDump] = []

    func commitWrite(_ plan: WritePlan, allowTrailerWrite: Bool) async {
        // Reported, never silent. The sheet's Write button is also disabled while this is true
        // (see `WriteConfirmationSheet`), but a guard that returns without a word is how a click
        // on a live-looking button became "the app did nothing and the sheet stayed up".
        guard !activity.isRunning else {
            toasts.warning("Not written yet — \(activity.label) Try again when it finishes.")
            return
        }
        activity = .writing
        pendingPlan = nil
        defer { activity = .idle }

        // Whatever happens next, the record on screen was read before this write and no longer
        // describes the tag. It goes now, not after the round trip — `Activity.writing` renders
        // the in-progress state in its place, so the stale values are never shown for an instant.
        invalidateRead(of: plan.uid)

        do {
            let (summary, readback) = try await monitor.withCard { session, identity
                -> (WriteSummary, Result<TagReadResult, Error>) in
                // A tag swapped between confirmation and commit must not inherit the
                // confirmation. This is the one check that makes the diff meaningful.
                guard identity.uid == plan.uid else {
                    throw WriteAbort.tagChanged(expected: plan.uid, found: identity.uid)
                }
                // Captured via the callback so it survives a throw; a backup reachable only
                // through a successful return is absent exactly when it is needed.
                var captured: [MifareClassicCard.SectorDump] = []
                defer { Task { @MainActor [captured] in self.lastWriteBackup = captured } }
                let service = try TagService(session: session)
                let result = try service.writeTag(record: plan.record,
                                                  printerType: plan.printerTypeString,
                                                  allowTrailerWrite: allowTrailerWrite,
                                                  onBackup: { captured = $0 })
                // Same session, immediately after the write. A failure here is *not* a write
                // failure and must never be reported as one, so it is captured rather than thrown.
                return (WriteSummary(result, plan: plan), Result { try service.readTag() })
            }

            writeOutcome = .succeeded(summary)
            rememberColor(plan.record.rgbHex)
            autoWriteSkipped = nil
            // The next spool is a different spool. Carrying this serial forward would tag two of
            // them identically, which is the collision the randomisation exists to avoid.
            draft.serialNumber = SpoolRecord.randomSerialNumber()
            // Fired here rather than from the confirmation sheet's completion handler, because a
            // write can also happen through auto-write with no sheet involved — and a spool that
            // reached stock or not depending on which path programmed it would be worse than
            // either behaviour on its own.
            onWriteSucceeded?(summary)

            switch readback {
            case let .success(fresh):
                await adopt(fresh)
                self.readback = .confirmed
                toasts.success("Written to tag \(summary.uidSpaced) — "
                               + "#\(plan.record.rgbHex), serial \(plan.record.serialNumber)")
            case let .failure(error):
                self.readback = .unavailable(error.localizedDescription)
                // The write reported success and was verified block-by-block by `TagService`.
                // Only the confirming read failed, so this is a warning about the *display*, not
                // about the tag.
                toasts.warning("Written to tag \(summary.uidSpaced), but it could not be read "
                               + "back — \(error.localizedDescription)")
            }
        } catch {
            writeOutcome = .failed(error.localizedDescription)
            readback = nil
            autoWriteSkipped = error.localizedDescription
            toasts.error("Write failed — \(error.localizedDescription)")
        }
    }

    /// Drops the retained read for one tag, because something has just changed that tag.
    ///
    /// `readUID` is deliberately left alone: it is the identity bookkeeping that stops
    /// ``cardChanged(to:)`` from treating the monitor's post-operation republish as a new tag.
    /// `autoReadUID` **is** cleared, so that if the read-back fails, switching to Read mode reads
    /// the tag properly instead of finding it already "read".
    private func invalidateRead(of uid: [UInt8]) {
        if lastRead?.uid == uid { lastRead = nil }
        if autoReadUID == uid { autoReadUID = nil }
        readFailure = nil
        readback = nil
    }

    /// Tries the post-write read again, for the "Retry" in the success panel.
    ///
    /// Only ever reads. A write cannot happen from here, however many times it is pressed.
    func retryReadback() async {
        guard case .unavailable = readback,
              case let .succeeded(summary)? = writeOutcome,
              !activity.isRunning else { return }
        activity = .reading
        defer { activity = .idle }

        do {
            let fresh = try await monitor.withCard { session, identity in
                guard identity.uid == summary.uid else {
                    throw WriteAbort.tagChanged(expected: summary.uid, found: identity.uid)
                }
                guard identity.isUsable else { throw TagError.unsupportedCard(identity.type) }
                return try TagService(session: session).readTag()
            }
            await adopt(fresh)
            readback = .confirmed
            toasts.success("Tag \(fresh.uid.hexStringSpaced) read back — "
                           + "the values below are what is on it")
        } catch {
            readback = .unavailable(error.localizedDescription)
            toasts.error("Still could not read the tag back — \(error.localizedDescription)")
        }
    }

    func cancelPendingWrite() {
        pendingPlan = nil
    }

    // MARK: Auto-write

    /// Writes the composed record the moment a supported tag is presented, in Write mode only.
    ///
    /// Called from the two card-*arrival* signals in ``TagView`` and from nowhere else — not from
    /// the mode change, not from the view's `.task`. That is deliberate and is half of why it
    /// cannot fire on entering Write mode with a tag already on the reader; the other half is
    /// ``consumeAutoWriteArming()``, which spends that tag's arming when the mode changes.
    ///
    /// - Parameter allowTrailerWrite: `AppSettings.advancedTagOperations`. Passed in rather than
    ///   held, so this model still owns no preferences. A blank tag needs its sector-1 trailer
    ///   rewritten, which is irreversible; auto-write replaces the *sheet*, not that opt-in, so
    ///   with the opt-in off a blank tag raises the confirmation sheet instead of writing.
    func autoWriteIfNeeded(card: CardIdentity?, allowTrailerWrite: Bool) async {
        // Read mode can never write. First line, no exceptions, no other caller.
        guard mode == .write else { return }
        guard autoWriteEnabled else { return }
        guard let card, card.isUsable else { return }
        guard autoWriteHandledUID != card.uid else { return }
        // Busy, or a confirmation sheet already up. The arming is deliberately **not** spent —
        // nothing was written — and the arrival is recorded so that ``activity`` returning to
        // `.idle`, or the sheet closing, re-drives it. Returning without recording anything is
        // what left a presented tag sitting unwritten forever while the indicator claimed it was
        // being written: neither `monitor.state.card` nor `insertionCount` changes when a read
        // finishes, so nothing ever looked again.
        guard !activity.isRunning, pendingPlan == nil else {
            deferredArrival = DeferredArrival(
                uid: card.uid,
                reason: activity.isRunning ? activity.waitingReason : "the confirmation sheet is closed")
            return
        }
        deferredArrival = nil

        // Spent *before* the first `await`. Nothing that happens from here on — a republished
        // identity, a second `onChange`, two overlapping tasks — can produce a second write for
        // this tag, and the arming is spent whether the attempt succeeds or fails.
        autoWriteHandledUID = card.uid
        autoWriteSkipped = nil

        guard draft.isValid else {
            let issue = draft.validationIssues.joined(separator: " ")
            autoWriteSkipped = issue
            toasts.warning("Not written — \(issue)")
            return
        }
        await autoWrite(card: card, allowTrailerWrite: allowTrailerWrite)
    }

    private func autoWrite(card: CardIdentity, allowTrailerWrite: Bool) async {
        let record: SpoolRecord
        do { record = try draft.makeRecord() }
        catch {
            autoWriteSkipped = error.localizedDescription
            toasts.error(error.localizedDescription)
            return
        }

        // Read-before-write survives intact: the diff still exists, it is simply not always shown.
        activity = .preparingWrite
        // As in `prepareWrite`: the previous write's panel is about a different attempt, and it
        // must not still be claiming success underneath this one's failure.
        writeOutcome = nil
        readback = nil
        let current: TagReadResult
        do {
            current = try await monitor.withCard { session, identity in
                guard identity.uid == card.uid else {
                    throw WriteAbort.tagChanged(expected: card.uid, found: identity.uid)
                }
                guard identity.isUsable else { throw TagError.unsupportedCard(identity.type) }
                return try TagService(session: session).readTag()
            }
        } catch {
            activity = .idle
            autoWriteSkipped = error.localizedDescription
            toasts.error("Could not read the tag before writing — \(error.localizedDescription)")
            return
        }
        // Same invariant as `prepareWrite`: `lastRead` is only ever set through `adopt`. The draft
        // is deliberately left alone — this read is the "before" side of a diff, not a prefill.
        await adopt(current, prefillingDraft: false)
        let plan = Self.makePlan(current: current,
                                 record: record,
                                 materialLabel: draft.materialLabel,
                                 printerTypeString: draft.printerTypeString)
        // Reset before `commitWrite`, which guards on `activity.isRunning`. No `await` in between,
        // so nothing can slip into the gap on the main actor.
        activity = .idle

        guard !plan.requiresTrailerWrite || allowTrailerWrite else {
            pendingPlan = plan
            autoWriteSkipped = "This tag is blank, so programming it rewrites its sector 1 keys."
            toasts.warning("This tag is blank — rewriting its sector 1 keys needs your "
                           + "confirmation, so auto-write stopped here.")
            return
        }
        await commitWrite(plan, allowTrailerWrite: allowTrailerWrite)
    }

    // MARK: Recently used colours

    /// Records a colour the user has actually put on a tag or taken off one.
    ///
    /// Called from the two places a colour is *real* — a successful read of a decoded record, and
    /// a successful write — never from the colour picker, which would fill the list with every
    /// colour dragged past on the way to the intended one.
    func rememberColor(_ rawHex: String) {
        guard let hex = PaletteSwatch.normalisedHex(rawHex) else { return }
        var updated = recentColors.filter { $0 != hex }
        updated.insert(hex, at: 0)
        if updated.count > Self.recentColorLimit {
            updated.removeLast(updated.count - Self.recentColorLimit)
        }
        guard updated != recentColors else { return }
        recentColors = updated
        defaults.set(updated, forKey: StorageKeys.recentColors)
    }

    /// Defends against anything that is not a colour coming back out of `UserDefaults` — a
    /// hand-edited plist, or a value written by a future version with a different shape.
    private static func sanitisedColors(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in raw {
            guard let hex = PaletteSwatch.normalisedHex(value), seen.insert(hex).inserted else { continue }
            out.append(hex)
            if out.count == recentColorLimit { break }
        }
        return out
    }

    // MARK: Colour naming

    /// Resolves the nearest named colour for the draft swatch.
    ///
    /// Runs off the main actor: the lookup is a 31,861-row linear scan, which is 0.037 ms in a
    /// release build but ~14 ms in a debug one (`ColorMatcher` docs) — enough to be felt while
    /// dragging in the colour picker.
    func refreshDraftColorName() async {
        let hex = draft.colorHex
        let name = await Task.detached(priority: .utility) { () -> String? in
            guard let matcher = try? ColorMatcher.shared() else { return nil }
            return try? matcher.nearestName(forHex: hex)
        }.value
        guard hex == draft.colorHex else { return }   // colour moved on while we scanned
        draftColorName = name
    }

    // MARK: Plan construction

    static func makePlan(current: TagReadResult,
                         record: SpoolRecord,
                         materialLabel: String,
                         printerTypeString: String) -> WritePlan {
        let before = current.record
        func row(_ id: String, _ label: String, _ old: String?, _ new: String) -> WriteDiffRow {
            WriteDiffRow(id: id, label: label, before: old ?? "—", after: new)
        }

        var rows: [WriteDiffRow] = [
            row("material", "Material ID", before?.materialId, record.materialId),
            row("colour", "Colour", before.map { "#" + $0.rgbHex }, "#" + record.rgbHex),
            row("weight", "Weight",
                before.map { "\($0.weightGrams) g" },
                "\(record.knownLength?.grams ?? 1000) g"),
            row("length", "Filament length", before?.filamentLength, record.filamentLength),
            row("serial", "Serial number", before?.serialNumber, record.serialNumber),
            row("vendor", "Vendor ID", before?.vendorId, record.vendorId),
            row("batch", "Batch", before?.batch, record.batch),
            row("date", "Date group", before?.date.encoded, record.date.encoded)
        ]
        rows.append(WriteDiffRow(id: "printer",
                                 label: "Printer (sector 2)",
                                 before: current.printerType.flatMap { $0.isEmpty ? nil : $0 } ?? "—",
                                 after: printerTypeString.isEmpty ? "—" : printerTypeString))

        return WritePlan(uid: current.uid,
                         record: record,
                         materialLabel: materialLabel,
                         printerTypeString: printerTypeString,
                         currentCondition: current.condition,
                         rows: rows,
                         requiresTrailerWrite: !current.isProgrammed,
                         currentPrinterType: current.printerType,
                         derivedKey: current.derivedKey)
    }

#if DEBUG
    // MARK: - Test seams
    //
    // Debug-only (`Tools/make-app.sh` builds release), read-only where they can be, and called
    // from nothing in the app. They exist because the rules worth testing here — *when* an arming
    // is spent, and what happens to an arrival that could not be served — are invisible from
    // outside without them, and the alternative is a test that needs a reader and a tag.

    /// The UID the automatic read is armed against, if any.
    var autoReadArmingForTesting: [UInt8]? { autoReadUID }

    /// The UID auto-write has already dealt with, if any.
    var autoWriteArmingForTesting: [UInt8]? { autoWriteHandledUID }

    /// Runs `body` with the model reporting `activity`, then restores `.idle` — which fires the
    /// same deferred-arrival retry a real operation finishing would.
    func withActivityForTesting<T>(_ activity: Activity,
                                   _ body: () async throws -> T) async rethrows -> T {
        let previous = self.activity
        self.activity = activity
        defer { self.activity = previous }
        return try await body()
    }

    /// Runs the card-response queue to quiescence, including anything a response queues in turn.
    func settle() async {
        var seen = -1
        var passes = 0
        while seen != cardResponseGeneration, passes < 16 {
            seen = cardResponseGeneration
            await cardResponse?.value
            passes += 1
        }
    }
#endif
}

// MARK: - Errors raised by the view-model layer itself

enum WriteAbort: Error, LocalizedError {
    case tagChanged(expected: [UInt8], found: [UInt8])

    var errorDescription: String? {
        switch self {
        case let .tagChanged(expected, found):
            return "The tag on the reader changed after you confirmed "
                 + "(expected \(expected.hexStringSpaced), found \(found.hexStringSpaced)). "
                 + "Nothing was written."
        }
    }
}

// MARK: - Backup rendering

extension WriteSummary {
    init(_ result: TagWriteResult, plan: WritePlan) {
        self.uid = result.uid
        self.record = plan.record
        self.materialLabel = plan.materialLabel
        self.printerTypeString = plan.printerTypeString
        self.wasAlreadyProgrammed = result.wasAlreadyProgrammed
        self.wroteTrailer = result.wroteTrailer
        self.wroteSector2 = result.wroteSector2
        self.blocksWritten = result.writtenBlocks.keys.sorted()
        self.backupSectorCount = result.backup.filter { !$0.authFailed }.count
        self.backupFailedSectors = result.backup.filter(\.authFailed).map(\.sector)
        self.backupDump = WriteSummary.renderBackup(result)
    }

    /// The pre-write dump, in the same shape `spooldiag dump` prints, so the two are comparable and
    /// either can be used to reconstruct a tag by hand.
    static func renderBackup(_ result: TagWriteResult) -> String {
        var lines: [String] = [
            "# CFS-RFID pre-write backup",
            "# Taken before the first write APDU (DECISIONS D-006).",
            "# UID:  \(result.uid.hexStringSpaced)",
            "# Key:  \(result.derivedKey.description)",
            "# Date: \(ISO8601DateFormatter().string(from: Date()))",
            ""
        ]
        for dump in result.backup {
            let sector = String(format: "%02d", dump.sector)
            if dump.authFailed {
                lines.append("S\(sector): AUTH FAILED — not backed up")
                continue
            }
            let keyLabel = "\(dump.key?.description ?? "?") key\(dump.keyType?.description ?? "?")"
            lines.append("S\(sector) [\(keyLabel)]:")
            for block in dump.blocks.keys.sorted() {
                let bytes = dump.blocks[block] ?? []
                let marker = MifareClassicCard.isTrailer(block: block) ? "T" : " "
                lines.append("   b\(String(format: "%02d", block))\(marker): "
                             + "\(bytes.hexStringSpaced)  |\(bytes.asciiDump)|")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
