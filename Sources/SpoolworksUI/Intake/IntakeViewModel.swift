import Foundation
import SwiftUI
import Combine
import SpoolworksCore

/// The Intake screen's state machine: get a spool into stock, tag by tag, without leaving the
/// reader.
///
/// ## The two methods, and the thing they share
///
/// **Method A — read a tag.** Read either of the spool's two tags, check what came off it, confirm.
/// Nothing is typed. Usually a Creality factory tag, but a tag this app wrote reads the same way,
/// which is why the button no longer names one vendor.
///
/// **Method B — enter and tag.** Describe a third-party spool, write both of its blank tags, and
/// the spool lands in stock with a serial this app allocated.
///
/// Both converge on the same form and the same `add`. The difference is only which side of the
/// form is authoritative: in A the tag fills the form, in B the form fills the tag.
///
/// ## Why a spool has two tags
///
/// A Creality spool carries a tag on each side of the hub, both holding the identical payload, so
/// the printer can read one whichever way round the spool is loaded. That is why the panel counts
/// "of 2" and why either tag resolves the same inventory record: identity is the payload, not the
/// tag (see ``SpoolworksCore/SpoolIdentity``). Reading the second tag is a confirmation, not a
/// requirement; **writing** the second is close to a requirement, because a spool with one blank
/// side is a spool the printer will fail to read half the time.
@MainActor
final class IntakeViewModel: ObservableObject {

    enum Method: String, CaseIterable, Identifiable, Hashable {
        case scan, manual
        var id: String { rawValue }

        var title: String {
            switch self {
            case .scan: return "Method A · Read a tag"
            case .manual: return "Method B · Enter and tag"
            }
        }

        var subtitle: String {
            switch self {
            case .scan: return "Read, check, add to stock"
            case .manual: return "Fill in, write both tags, add to stock"
            }
        }
    }

    /// Where one of a spool's two tags has got to.
    ///
    /// Replaces a pair of booleans that could only say "done" or "not done". The screen showed
    /// "ready" and "waiting" flickering against each other with nothing to say a tag had actually
    /// been written, because there was no state for *in progress* and no state for *verified* as
    /// distinct from *ticked off*.
    enum SlotState: Equatable {
        /// The other tag has not been done yet; this one is not next.
        case waiting
        /// Present a tag now.
        case ready
        /// The reader is working on it. Carries what it is doing, for the row and its spinner.
        case working(String)
        /// Written and read back byte for byte, or read and decoded.
        case done
        /// Deliberately not being done. See ``IntakeViewModel/tagsRequired``.
        case skipped

        var isWorking: Bool { if case .working = self { return true }; return false }

        var caption: String {
            switch self {
            case .waiting: return "waiting"
            case .ready: return "ready"
            case let .working(what): return what
            case .done: return "verified"
            case .skipped: return "skipped"
            }
        }
    }

    /// One of a spool's two tags, and how far it has got.
    struct TagSlot: Identifiable, Equatable {
        let index: Int
        var state: SlotState
        /// How many tags this intake wants, so a row can name itself honestly.
        var id: Int { index }
        let total: Int
        var name: String { "Tag \(index + 1) of \(total)" }
        var isDone: Bool { state == .done }
    }

    // MARK: Published state

    @Published var method: Method = .scan { didSet { reset(keepingMethod: true) } }
    /// How many of the two tags have been read (method A) or written (method B).
    @Published private(set) var tagsHandled = 0

    /// How many of the spool's two tags this intake needs: two, one, or none.
    ///
    /// A Creality spool carries a tag on each side of the hub so the printer can read one whichever
    /// way round it is loaded, and that is why everything here counted to two. Two other cases are
    /// just as real:
    ///
    /// * **One.** A spool that will only ever sit on the external holder is read from the same side
    ///   every time, and the user may be moving a single reusable tag between such spools rather
    ///   than committing one to each.
    /// * **None.** Unopened stock on a shelf. It is inventory before it is ever tagged, and making
    ///   someone write a tag to admit they own a spool is the wrong shape entirely.
    ///
    /// Deliberately a count and not two flags. "How many tags is this waiting for" is one question,
    /// and as a number every "have we finished" test stays a comparison against one value — as
    /// zero, it also makes ``isArmedToWrite`` false for free, so the no-tag case cannot leave the
    /// reader armed to write at a tag that wanders past.
    @Published private(set) var tagsRequired = 2
    /// The record decoded from the tag, in method A.
    @Published private(set) var decoded: SpoolRecord?
    /// The tag UID, for the "decoded from tag" panel.
    @Published private(set) var uidLabel = "—"
    @Published private(set) var busy = false
    @Published private(set) var failure: String?
    /// Spools added since the screen was opened, newest first — the design's "Logged this session".
    @Published private(set) var session: [Spool] = []
    /// Set when the scanned tag is already in stock, so the screen can offer to open it instead of
    /// silently creating a duplicate.
    @Published private(set) var duplicate: Spool?

    /// Set when the user has said the spool on the reader is **not** ``duplicate``, only alike.
    ///
    /// Offered only for a factory tag (``duplicateIsAmbiguous``). Every Creality spool of one
    /// filament and colour carries the same payload, so a record already holding it is no evidence
    /// the spool in hand is that record — owning two of the same filament is the ordinary reason to
    /// be at Intake at all. A tag with a serial of its own is different: it was written for one
    /// spool, and "another spool with this tag" would be a copy, which stays refused.
    @Published private(set) var addingAnotherLikeDuplicate = false

    /// An untagged spool in stock that the tag looks like, offered before a second record is added.
    ///
    /// The case this exists for: a Creality spool counted onto a shelf while still sealed, whose
    /// factory tag is read here once the bag is opened. Adding it would put a second record beside
    /// the one the user already made. Attaching the tag to that record is almost always what was
    /// meant — but only almost, so it is asked.
    @Published private(set) var lookalike: Spool?

    /// Whether the tag opened with the UID-derived key, for the provenance an attach records.
    private var decodedIsProgrammed = false

    /// True when ``duplicate`` shares only a factory payload with this tag. See
    /// ``addingAnotherLikeDuplicate``.
    var duplicateIsAmbiguous: Bool { duplicate?.identity?.hasGenericSerial == true }

    /// Raised when a tag arrives whose payload is not the one already being intaken — a second
    /// spool presented before the first was confirmed. Filling the empty slot with it would build
    /// a record from two different spools' tags.
    @Published private(set) var mismatch: String?

    /// UIDs already absorbed, so the same physical tag cannot fill both slots.
    ///
    /// A spool's two tags carry the **same payload** but different UIDs, which is exactly why the
    /// UID is the right key here: presenting tag 1 twice must not tick off tag 2, and presenting
    /// tag 2 must.
    private var absorbedUIDs: Set<[UInt8]> = []
    /// UIDs already written, so writing one tag twice cannot claim both slots.
    private var writtenUIDs: Set<[UInt8]> = []

    /// What the first verified write actually put on a tag, in Method B.
    ///
    /// Kept because the form stops being the authority the moment a tag is programmed. The spool
    /// added at ``confirm()`` used to take its identity from the form as it stood *then*, so an
    /// edit made after the write — a colour corrected, a size changed — stored a spool whose tags
    /// held a different payload, or none at all if the edit was invalid; the next CFS poll then
    /// "discovered" the tags as a second spool. This is the record the tags hold, and it is what
    /// the spool is identified by. Cleared by ``reset(keepingMethod:)``.
    @Published private(set) var writtenRecord: SpoolRecord?

    // MARK: The form

    @Published var brand = ""
    @Published var name = ""
    /// Empty until something says what the material is — the catalogue row in Method B, or the
    /// catalogue's answer for the id read off a tag in Method A.
    ///
    /// It defaulted to `"PLA"`, which meant a tag whose id the catalogue did not know was
    /// confirmed as PLA on no evidence at all. ``InventoryViewModel/logWrittenSpool`` already
    /// refuses to guess for the same case, and the two paths should not disagree: a spool of
    /// unknown type is a fact the rail lets the user correct, and a plausible-looking invention
    /// is not.
    @Published var materialType = ""
    /// What a **full** spool of this filament holds — the spool's size, not how much is on it.
    ///
    /// The distinction was not made anywhere and it needed to be: a field labelled "Net weight"
    /// beside nothing else about quantity reads as "how much is here", and every spool taken in
    /// was silently recorded as full.
    @Published var netWeightGrams = 1000

    /// How much of it is actually left, as a percentage.
    ///
    /// Intake used to assume 100 in both methods, which is right for a spool out of its box and
    /// wrong for the reason most people count their stock — they already own it, and some of it is
    /// half used. A tag cannot help here either: the length code is the spool's *size*, and nothing
    /// on the tag says how much has been printed.
    @Published var remainingPercent: Double = 100
    @Published var colorHex = "C12E1F"
    /// Allocated by this app in method B; read off the tag in method A.
    @Published var serial = ""
    @Published var filamentId = ""

    /// The 5-digit catalogue id the tag will carry. Empty until a material is chosen.
    ///
    /// This is the field that makes an app-written tag *work*. The tag stores a filament id, not a
    /// description, and the printer looks that id up in its own `material_database.json`. An id
    /// that is not in the printer's catalogue produces a tag the printer reads and then ignores —
    /// so Method B picks from the catalogue rather than letting brand and material be free text.
    @Published var materialID = "" {
        didSet { adoptCatalogueMaterial() }
    }
    /// The brand filter above the material picker, also from the catalogue.
    @Published var catalogueBrand = "" {
        didSet {
            guard oldValue != catalogueBrand else { return }
            materialID = materials(for: catalogueBrand).first?.id ?? ""
        }
    }
    /// The eleven "how much is left" rungs for the spool size currently chosen.
    var remainingOptions: [(grams: Int, percent: Double, label: String)] {
        Spool.remainingLadder(netWeightGrams: netWeightGrams)
    }

    /// The five weights the tag's length code can express. There is no "other": a weight the tag
    /// cannot encode would be lost the moment the spool was written.
    static let weights: [Int] = FilamentLength.allCases.map(\.grams).sorted(by: >)

    // Strong, not `unowned`. All three are owned by `AppEnvironment` for the app's lifetime
    // and none of them references this model back, so there is no cycle to break — while
    // `unowned` made a caller that passes a freshly-created collaborator crash the moment it
    // was released, which is exactly what the tests do.
    private let monitor: ReaderMonitor
    private let inventory: InventoryViewModel
    private let materials: MaterialsViewModel
    private let toasts: ToastCenter

    init(monitor: ReaderMonitor,
         inventory: InventoryViewModel,
         materials: MaterialsViewModel,
         toasts: ToastCenter) {
        self.monitor = monitor
        self.inventory = inventory
        self.materials = materials
        self.toasts = toasts
        self.serial = Self.allocateSerial()
    }

    // MARK: Derived

    /// True while the Intake screen is on show.
    ///
    /// The app logs a spool to stock after any verified write — which is right on the Write tag
    /// screen, where writing *is* the whole operation. It is wrong here: Intake has its own
    /// "Add to stock" step, and the point of that step is to see both tags verified before
    /// committing. Auto-logging landed the spool after the first tag, so the second was written
    /// against a record that already existed.
    @Published var isActive = false

    /// What the reader is doing right now, pushed in by the view from ``TagViewModel``.
    ///
    /// Held rather than observed so the model stays testable without a reader: the view owns the
    /// subscription, this owns the meaning.
    @Published var activityLabel: String?

    var tags: [TagSlot] {
        (0..<2).map { index in
            // Shown, not hidden. A row that vanishes leaves nothing to say the second tag was a
            // deliberate choice, and nothing to press to change your mind.
            if index >= tagsRequired { return TagSlot(index: index, state: .skipped, total: tagsRequired) }
            if tagsHandled > index { return TagSlot(index: index, state: .done, total: tagsRequired) }
            // Only the next undone slot can be in flight — the reader does one tag at a time.
            if index == tagsHandled, let activityLabel {
                return TagSlot(index: index, state: .working(activityLabel), total: tagsRequired)
            }
            return TagSlot(index: index, state: index == tagsHandled ? .ready : .waiting, total: tagsRequired)
        }
    }

    /// `"1 of 2 written and verified"`. The old wording stopped at "written", which is the weaker
    /// claim — a write is only believed here once it has been read back.
    var tagSummary: String {
        let verb = isScan ? "read" : "written and verified"
        return "\(tagsHandled) of \(tagsRequired) \(verb)"
    }

    /// Whether a tag presented now would be written without further asking.
    var isArmedToWrite: Bool { !isScan && canWriteTags && tagsHandled < tagsRequired }

    /// Whether this spool ends up with a tag on it at all.
    ///
    /// Not the same as "finished". A no-tag intake is finished the moment it starts — `0 of 0` —
    /// and marking it `spoolworksWritten` on that basis would put "Custom" in the Tag column of a
    /// spool nobody has written anything to.
    var willBeTagged: Bool { allTagsHandled }

    /// Every tag this intake asked for has been read or written — and it asked for at least one.
    ///
    /// The view's completion marks compared against a literal 2, which was wrong the moment
    /// ``tagsRequired`` could be 1: a one-tag spool never showed as done.
    var allTagsHandled: Bool { tagsRequired > 0 && tagsHandled >= tagsRequired }

    /// Whether the fields a tag encodes — material, colour, spool size, serial — may still change.
    ///
    /// Locked from the first verified write. Before it the form fills the tag; after it the tag
    /// is a physical fact and the form has to describe it, so the view disables those inputs.
    /// The name and the remaining figure stay open: neither is on the tag.
    var isIdentityLocked: Bool { writtenRecord != nil }

    /// Everything ``IntakeView``'s arming depends on, folded into one value it can watch.
    ///
    /// The view used to re-arm on a hand-picked list of fields, and the list was short: the spool
    /// size was not on it, so a tag auto-written after the size was changed carried the length
    /// code of whatever the form held when it was last armed — a 500 g spool tagged as 1 kg. One
    /// value carrying every input cannot go stale that way, and a field that feeds the written
    /// record has to be added here, where a test can see it, rather than to a list in the view.
    struct ArmingKey: Equatable {
        let method: Method
        let tagsHandled: Int
        let tagsRequired: Int
        let materialID: String
        let colorHex: String
        let netWeightGrams: Int
        let serial: String
        let brand: String
        let name: String
        let writtenRecord: SpoolRecord?
    }

    var armingKey: ArmingKey {
        ArmingKey(method: method,
                  tagsHandled: tagsHandled,
                  tagsRequired: tagsRequired,
                  materialID: materialID,
                  colorHex: colorHex,
                  netWeightGrams: netWeightGrams,
                  serial: serial,
                  brand: brand,
                  name: name,
                  writtenRecord: writtenRecord)
    }

    var isScan: Bool { method == .scan }

    /// `"Step 2 · Read either tag"` / `"Step 3 · Write both tags"`.
    var tagPanelLabel: String {
        if isScan { return "Step 2 · Read either tag" }
        switch tagsRequired {
        case 0:  return "Step 3 · No tag"
        case 1:  return "Step 3 · Write one tag"
        default: return "Step 3 · Write both tags"
        }
    }

    var formLabel: String {
        isScan ? "Step 3 · Confirm" : "Step 2 · Describe the spool"
    }

    var tagProgress: String { tagSummary }

    var tagNote: String {
        isScan
            ? "Just present the tags — each is read as it lands and fills the next slot. A Creality spool carries two factory tags with the same payload, so reading either is enough; the second only confirms the pair."
            : tagsRequired == 0
              ? "Nothing is read or written and the reader stays idle. The spool goes into stock untagged; Inventory can write a tag for it whenever you get to it."
              : tagsRequired == 1
              ? "One tag only. That is right for a spool that will live on the external holder, where the same side is always presented — and for a reusable tag you move between spools. Loaded into a CFS, a spool tagged on one side reads only half the time."
              : "A spool carries two tags. Both get the same payload, each verified by read-back — either one identifies the spool later. A spool tagged on one side only will fail to read half the time it is loaded."
    }

    var stateLabel: String {
        if lookalike != nil { return "Matches an untagged spool" }
        if let duplicate, !addingAnotherLikeDuplicate { return "Already in stock · \(duplicate.serialLabel)" }
        if isScan { return decoded == nil ? "Method A · waiting for tag" : "Tag read · \(sourceLabel)" }
        return "Method B · enter and tag"
    }

    private var sourceLabel: String {
        guard let decoded else { return "" }
        return decoded.vendorId == "0276" ? "Creality" : "vendor \(decoded.vendorId)"
    }

    /// Method A cannot add a spool it has not read. Method B can add before tagging — the design
    /// offers "Add to stock (tags pending)" — because a spool on a shelf is real whether or not it
    /// has been tagged yet.
    var canConfirm: Bool {
        if duplicate != nil && !addingAnotherLikeDuplicate { return false }
        if isScan { return decoded != nil }
        if writtenDrift != nil { return false }
        return !brand.isEmpty || !name.isEmpty
    }

    /// Why the form no longer describes the tags that were written, or nil while it does.
    ///
    /// The lock (``isIdentityLocked``) is the view's, and a value can still arrive around it: the
    /// colour panel is a separate window, the camera sheet commits when it closes, and a caller
    /// can set a property directly. This is the model's own check, and ``canConfirm`` is false
    /// while it is non-nil — a spool stored under one identity while its tags hold another is
    /// exactly the record the next CFS poll "discovers" as a second spool.
    /// ``restoreWrittenValues()`` is the way back.
    var writtenDrift: String? {
        guard let written = writtenRecord else { return nil }
        if let now = composeRecord(), Self.samePayload(now, written) { return nil }
        return "The form no longer matches what was written to the tag — "
            + "\(written.filamentId) · \(written.rgbHex) · \(Spool.weightLabel(written.weightGrams))"
            + " · serial \(written.serialNumber). Use the tag's values, or start over and rewrite."
    }

    var confirmTitle: String {
        if isScan { return "Confirm and add to stock" }
        return tagsHandled >= tagsRequired ? "Add to stock" : "Add to stock (tags pending)"
    }

    var hint: String {
        if let lookalike {
            return "This tag matches \(lookalike.label), in stock without a tag. Attach it, or add a new spool."
        }
        if let duplicate, !addingAnotherLikeDuplicate {
            return duplicateIsAmbiguous
                ? "This tag reads the same as \(duplicate.label) in stock. Continue as a new spool if it is not that one."
                : "This tag already belongs to \(duplicate.label) in stock. Nothing to add."
        }
        if isScan {
            return decoded == nil
                ? "Place a spool tag on the reader."
                : "Reader stays hot — the next spool starts a new record."
        }
        if tagsRequired == 0 {
            return "No tag. Add it to stock now and write one later from Inventory."
        }
        if tagsHandled >= tagsRequired {
            return tagsRequired == 1 ? "Tag verified." : "Both tags verified."
        }
        return tagsRequired == 1
            ? "Write the tag first, or add now and tag later."
            : "Write both tags first, or add now and tag later."
    }

    /// The 40-character payload, for the "decoded from tag" panel.
    var payload: String { decoded?.encoded ?? "— waiting —" }

    /// The decoded field table beside the form.
    var fields: [(String, String)] {
        guard let record = decoded else {
            return [("Reader", monitor.state.hasReader ? "ready" : "no reader"),
                    ("Tag", "none present")]
        }
        return [
            ("Payload", "40 characters"),
            ("Date", "\(record.date.month) \(record.date.day) \(record.date.year)"),
            ("Vendor ID", record.vendorId),
            ("Batch", record.batch),
            ("Filament ID", record.filamentId),
            ("Colour", record.color),
            ("Length code", "\(record.filamentLength) → \(Spool.weightLabel(record.weightGrams))"),
            ("Serial", record.serialNumber),
            ("Reserve", record.reserve),
        ]
    }

    // MARK: The catalogue

    /// Brands that actually exist in the printer's material database, in a stable order.
    var catalogueBrands: [String] {
        Array(Set(materials.rows.map(\.brand))).filter { !$0.isEmpty }.sorted()
    }

    /// The brand Method B starts on: Creality when the catalogue has it, else the first brand.
    ///
    /// It was simply the first brand alphabetically, which happened to be Creality while the
    /// catalogue held Creality, Generic, Polymaker and eSUN. The vendor catalogue put Anycubic and
    /// Bambu Lab ahead of it, so Method B quietly began opening on an Anycubic filament — for an app
    /// whose tags are Creality tags, read by a Creality printer.
    nonisolated static func defaultCatalogueBrand(in brands: [String]) -> String {
        brands.contains("Creality") ? "Creality" : (brands.first ?? "")
    }

    /// The filaments the catalogue holds for a brand.
    func materials(for brand: String) -> [FilamentRow] {
        materials.rows.filter { $0.brand == brand }.sorted { $0.name < $1.name }
    }

    var selectedMaterial: FilamentRow? {
        materials.rows.first { $0.id == materialID }
    }

    /// True when the catalogue has nothing to offer — a fresh install, or a load that failed.
    var catalogueIsEmpty: Bool { materials.rows.isEmpty }

    /// Pulls the description and the tag's filament id from the chosen catalogue entry.
    private func adoptCatalogueMaterial() {
        guard let row = selectedMaterial else {
            filamentId = ""
            return
        }
        // The tag's filamentId is a leading class digit plus the catalogue's 5-digit base id.
        // Every implementation writes '1' for the class; see SpoolRecord.filamentClass.
        filamentId = "1" + row.id
        brand = row.brand
        materialType = row.materialType
        // Always, not "unless the user has typed something". The old rule kept a hand-edited name
        // across a change of material, which sounds protective and is the wrong way round: the name
        // describes the material, so a name that outlives the material it describes is simply
        // wrong. Picking CR-ABS and keeping "Hyper PLA" writes a tag whose id and whose name
        // disagree, and the inventory row then reads as a filament the spool is not.
        name = row.name
        // Not the colour. It used to be taken from the catalogue too, and every shipped record's
        // `base.colors` is the `#ffffff`/`#000000` placeholder — so choosing a material quietly
        // replaced the colour you had already set with black or white. A spool's colour is a fact
        // about the spool; the catalogue has nothing to say about it.
    }

    // MARK: Actions

    /// Takes a tag the reader has already read and files it in the next empty slot.
    ///
    /// The user does not press anything: ``TagViewModel`` auto-reads whatever lands on the reader,
    /// and this absorbs the result. Deliberately *not* a second card session of its own — two
    /// models competing for one reader is how a scan ends up half-read, and the auto-read arming
    /// rules in `TagViewModel` are already the thing that makes this reliable.
    ///
    /// Only in scan mode. Method B's slots are for **writing** blank tags, and a write must stay
    /// behind its confirmation sheet; a tag arriving there fills nothing.
    func absorb(_ result: TagReadResult) {
        // Deliberately does not check `busy`: this is called *from* the read that set it, and
        // guarding on it made the manual button read the card and then silently discard the
        // result. Re-entry is prevented by the UID set below, which is the real invariant.
        guard isScan else { return }
        guard let record = result.record else {
            failure = "That tag carries no readable spool record. A blank tag needs Method B."
            return
        }
        // The same physical tag, presented again, is not the second tag.
        guard !absorbedUIDs.contains(result.uid) else { return }

        // A different spool arriving mid-intake is a mistake worth stopping on, not a slot to fill.
        if let decoded, decoded != record {
            mismatch = "That is a different spool (\(record.filamentId) · \(record.rgbHex)). "
                + "Confirm or discard the one in progress first."
            return
        }

        absorbedUIDs.insert(result.uid)
        decodedIsProgrammed = result.isProgrammed
        mismatch = nil
        failure = nil
        uidLabel = result.uid.map { String(format: "%02X", $0) }.joined(separator: " ")
        adopt(record)
        tagsHandled = min(tagsRequired, absorbedUIDs.count)
        // "Both" only when two were asked for. A one-tag spool is finished after one read, and
        // announcing a second tag that was never wanted misdescribes what just happened.
        toasts.success(allTagsHandled && tagsRequired > 1
                       ? "Both tags read — \(record.filamentId) · \(record.rgbHex)"
                       : "Tag read — \(record.filamentId) · \(record.rgbHex)")
    }

    /// Whether a read is in flight, for disabling the slot buttons.
    ///
    /// Owned by ``TagViewModel``: this screen no longer opens a card session of its own. It did,
    /// and that was two models contending for one reader — which is how a reader wedges mid-read.
    /// Everything here now absorbs what the shared auto-read produced.
    func setBusy(_ value: Bool) { busy = value }

    /// Fills the form from a decoded tag, and flags a spool already in stock.
    private func adopt(_ record: SpoolRecord) {
        let isFirstTag = decoded == nil
        decoded = record
        duplicate = inventory.existing(for: record)
        colorHex = record.rgbHex
        serial = record.serialNumber
        filamentId = record.filamentId
        netWeightGrams = record.weightGrams

        // The tag carries a filament *id*, not a description. Resolve it against the catalogue so
        // the row reads "Creality Hyper PLA" rather than "101001"; leave the fields blank rather
        // than inventing a name when the catalogue does not know the id.
        // FilamentRow.id is the catalogue's 5-digit base id; the tag's filamentId carries a
        // leading class digit on top of it. Matching the two raw would never hit.
        if let row = materials.rows.first(where: { $0.id == record.materialId }) {
            brand = row.brand
            name = row.name
            materialType = row.materialType
        }

        // Once per spool, not per tag: the second side carries the same record, and looking again
        // would bring back an offer the user has just answered. After the catalogue lookup, because
        // a spool with no identity can only be compared by brand and name.
        guard isFirstTag else { return }
        lookalike = duplicate == nil || duplicateIsAmbiguous
            ? inventory.untaggedLookalikes(for: record, brand: brand, name: name).first
            : nil
    }

    /// Writes one of the spool's two blank tags (method B).
    ///
    /// Deliberately **not** implemented as a silent write. Programming a blank tag rewrites its
    /// sector keys irreversibly, so this hands off to the existing write path, which asks first and
    /// verifies by read-back — the same guarantees the Write screen gives. See ``WriteModeView``.
    func composeRecord() -> SpoolRecord? {
        guard let length = FilamentLength.forGrams(netWeightGrams) else { return nil }
        let id = materialID.isEmpty
            ? (filamentId.count == 6 ? String(filamentId.dropFirst()) : filamentId)
            : materialID
        guard !id.isEmpty else { return nil }
        return try? SpoolRecord(materialId: id,
                                colorRGB: Spool.normaliseHex(colorHex),
                                filamentLength: length,
                                serialNumber: serial)
    }

    /// Why the tags cannot be written yet, in the user's terms. `nil` when they can.
    var writeBlocker: String? {
        guard !isScan else { return nil }
        // Nothing is going to be written, so a reason it could not be is not a reason for anything.
        guard tagsRequired > 0 else { return nil }
        if catalogueIsEmpty {
            return "The material catalogue is empty, so there is no filament ID to write. "
                + "Load it in Manage ▸ Materials (⇧⌘1)."
        }
        if materialID.isEmpty {
            return "Choose a material — the tag stores a filament ID from the catalogue, not a name."
        }
        if FilamentLength.forGrams(netWeightGrams) == nil {
            return "That net weight has no code on the tag."
        }
        if composeRecord() == nil {
            return "These details do not make a valid tag record."
        }
        return nil
    }

    var canWriteTags: Bool { writeBlocker == nil }

    /// Records a verified write, filling the next slot.
    ///
    /// Keyed on the tag's UID for the same reason reads are: writing the *same* blank tag twice
    /// must not claim both sides of the spool are done. That is the failure this guards — a spool
    /// tagged on one side only fails to read half the time it is loaded, and the screen would have
    /// said it was fine. This is the **only** way a write counts. The confirmation sheet used to
    /// tick its own slot off by index as well, with no UID check, so "Write now" on the second row
    /// rewriting the first row's tag claimed both sides were done.
    ///
    /// `record` is what actually landed on the tag. The first is kept as ``writtenRecord`` and the
    /// form is brought into step with it; a later tag carrying a different payload is refused
    /// rather than counted, because a spool whose two sides disagree is two spools to the printer.
    /// Every real caller passes it — the form's own composition stands in only when none is given,
    /// which is right only while nothing has changed since the write.
    func absorbWrite(uid: [UInt8], record: SpoolRecord? = nil) {
        guard !isScan else { return }
        guard !writtenUIDs.contains(uid) else { return }
        if let record = record ?? composeRecord() {
            if let written = writtenRecord {
                guard Self.samePayload(record, written) else {
                    failure = "That tag was written with a different payload from the first — "
                        + "\(record.filamentId) · \(record.rgbHex) · serial \(record.serialNumber). "
                        + "A spool's two tags must match; rewrite it."
                    return
                }
            } else {
                writtenRecord = record
                adoptWritten(record)
            }
        }
        writtenUIDs.insert(uid)
        failure = nil
        tagsHandled = min(tagsRequired, writtenUIDs.count)
        toasts.success(tagsHandled >= tagsRequired
                       ? (tagsRequired == 1 ? "Tag written and verified"
                                            : "Both tags written and verified")
                       : "Tag \(tagsHandled) of \(tagsRequired) written and verified")
    }

    /// Two records that would identify the same spool and encode the same size.
    ///
    /// Not `==`: a record also carries a date, a batch and a reserve field, none of which the
    /// inventory keys on, and a comparison that failed on those would refuse a matching tag.
    private static func samePayload(_ a: SpoolRecord, _ b: SpoolRecord) -> Bool {
        a.carriesSamePayload(as: b)
    }

    /// Puts the form back in step with what a tag now physically holds.
    ///
    /// The draft is loaded when the reader is armed and the write lands seconds later; a colour
    /// panel left open, or a camera scan that closes after the write, can move the form in
    /// between. Once the bytes are on the tag it is the form that is wrong, so the tag's values
    /// win.
    private func adoptWritten(_ record: SpoolRecord) {
        // The material first: its `didSet` pulls brand, name and type from the catalogue, and the
        // tag's own values have to land after that.
        if record.materialId != materialID,
           let row = materials.rows.first(where: { $0.id == record.materialId }) {
            catalogueBrand = row.brand
            materialID = row.id
        }
        filamentId = record.filamentId
        colorHex = record.rgbHex
        serial = record.serialNumber
        netWeightGrams = record.weightGrams
    }

    /// Restores the identity-bearing fields from ``writtenRecord``, clearing ``writtenDrift``.
    func restoreWrittenValues() {
        guard let written = writtenRecord else { return }
        adoptWritten(written)
    }

    /// How many tags this spool needs: two, one, or none.
    ///
    /// Reversible in both directions, and it never destroys work: a tag already read or written
    /// stays that way, and going back up re-derives the count from the UID sets rather than from a
    /// remembered number that could disagree with them. Going down simply stops counting the
    /// surplus, which is what keeps "1 of 1" from reading as "2 of 1".
    func setTagsRequired(_ count: Int) {
        let wanted = min(2, max(0, count))
        guard wanted != tagsRequired else { return }
        tagsRequired = wanted
        tagsHandled = min(wanted, isScan ? absorbedUIDs.count : writtenUIDs.count)
    }

    /// Adds the spool to stock and rearms for the next one.
    func confirm() {
        guard canConfirm else { return }

        let spool: Spool
        if let record = decoded, isScan {
            spool = inventory.spool(from: record,
                                    brand: brand,
                                    name: name,
                                    materialType: materialType,
                                    // What is on the form, not what was on the tag. Both are
                                    // editable in Method A too, and an edit the confirm silently
                                    // threw away is worse than not offering it. The tag cannot
                                    // answer the second one at all: its length code is the spool's
                                    // *size*, and nothing on it says how much has been printed.
                                    netWeightGrams: netWeightGrams,
                                    remainingPercent: remainingPercent,
                                    tagSource: .crealityFactory,
                                    detail: "Intake · tag read")
        } else {
            // The tags decide the identity once any has been written; the form's composition
            // stands in only while nothing has been programmed yet.
            let identity = (writtenRecord ?? composeRecord()).map(SpoolIdentity.init(record:))
            // The serial is kept whether or not a record could be composed. Without a catalogue
            // material there is no filament ID and therefore no identity — which is a legitimate
            // way to shelve a third-party spool — but the form has still shown the user a serial
            // under "Serial · generated", and the toast below reports it. It used to be discarded
            // with the identity, so those spools reached the inventory showing "—".
            var made = Spool(identity: identity,
                             brand: brand,
                             name: name,
                             materialType: materialType,
                             colorHex: colorHex,
                             colorName: inventory.colorName(forHex: Spool.normaliseHex(colorHex)),
                             netWeightGrams: netWeightGrams,
                             remainingPercent: remainingPercent,
                             // Unplaced, like every other way in. Nothing here has observed where
                             // the spool is, and asserting a shelf named a location the picker may
                             // no longer offer — `Shelf` is a seeded place the user can rename or
                             // remove. See `docs/DECISIONS.md` D-011.
                             location: .unknown,
                             remainingSource: remainingPercent < 100 ? "Set at intake"
                                 : willBeTagged ? "Intake · tagged, assumed full"
                                 : tagsRequired == 0 ? "Counted onto the shelf, assumed full"
                                                     : "Manual record · tag pending",
                             tagSource: willBeTagged ? .spoolworksWritten : .untagged,
                             plannedSerial: identity == nil ? serial : nil)
            made.note(kind: .intake,
                      detail: willBeTagged
                          ? (tagsRequired == 1 ? "Intake · one tag written, second skipped"
                                               : "Intake · both tags written")
                          : tagsRequired == 0 ? "Intake · counted onto the shelf, no tag"
                                              : "Intake · manual entry")
            spool = made
        }

        inventory.add(spool)
        session.insert(spool, at: 0)
        toasts.success("Added to stock — \(spool.label) · serial \(spool.serialLabel)")

        // Back to Method A once the spool is in stock. Method B is the detour you take *because* a
        // spool has no tag to read; leaving the screen parked there afterwards starts the next
        // spool — which probably does have one — on the wrong branch, and the reader is sitting
        // armed to write rather than to read.
        //
        // Both lines on purpose. `method`'s `didSet` already clears the form, but leaning on that
        // alone would make Method A's own confirm silently stop clearing the day anyone adds an
        // `oldValue` guard to it.
        method = .scan
        reset(keepingMethod: true)
    }

    /// Attaches the tag on the reader to ``lookalike`` instead of adding a record for it.
    ///
    /// Every side already read here goes with it, so a spool whose two tags were both read at
    /// Intake is finished; one read leaves Inventory waiting for the other side, which Read /
    /// identify asks for. Returns false when nothing was attached.
    @discardableResult
    func attachToLookalike() -> Bool {
        guard isScan, let spool = lookalike, let record = decoded else { return false }
        inventory.attachTag(to: spool)
        guard inventory.attachTag(record: record,
                                  materialType: materialType,
                                  source: decodedIsProgrammed ? .spoolworksWritten : .crealityFactory,
                                  readUIDs: Array(absorbedUIDs)) else {
            inventory.cancelTagRequest()
            return false
        }
        // Deliberately not `beginIdentification`, as Discard does: the tag still on the reader
        // would be read straight back in, and would now match the spool it was just attached to.
        reset()
        return true
    }

    /// The spool on the reader is not ``lookalike``: carry on adding it as a spool of its own.
    func dismissLookalike() {
        lookalike = nil
        if duplicateIsAmbiguous { addingAnotherLikeDuplicate = true }
    }

    /// The spool on the reader is not ``duplicate``, only alike: add it as another.
    func addAnotherLikeDuplicate() {
        guard duplicateIsAmbiguous else { return }
        addingAnotherLikeDuplicate = true
        lookalike = nil
    }

    func openDuplicate() {
        guard let duplicate else { return }
        // Revealed, not merely selected: with a filter on that hides it, a bare selection fell
        // back to the first listed row, and "Open it" opened some other spool.
        inventory.reveal(duplicate.id)
    }

    /// Fills the form from a spool already in stock, ready to log another like it.
    ///
    /// Buying two of something is the ordinary case, and re-typing a spool you already own to
    /// record the second one is work the app can do. It lands on Method B because a clone is a new
    /// physical spool with no tag yet — there is nothing to read.
    ///
    /// **The serial is not cloned.** It is allocated fresh, because this is a different spool and
    /// two records sharing a serial, a filament and a colour are indistinguishable — the collision
    /// ``SpoolIdentity`` exists to avoid, and the one thing a clone must not copy.
    ///
    /// Nor is the remaining figure: a clone starts full, which is what Intake gives every spool it
    /// adds. Cloning a half-used spool to record a fresh one is the point.
    ///
    /// The tag count is mirrored from the source rather than defaulted. A clone of a spool sitting
    /// untagged on a shelf is almost always another unopened spool going onto the same shelf, and a
    /// clone of a tagged one is a spool about to be tagged.
    func clone(_ spool: Spool) {
        // Resets the form through `method`'s `didSet`, so everything below is written onto a clean
        // one rather than over whatever the last spool left.
        method = .manual

        // Order matters. Setting `materialID` runs `adoptCatalogueMaterial`, which overwrites
        // brand, name and type from the catalogue — so the catalogue goes first and the spool's
        // own values go last, or the clone would come back described as the catalogue row rather
        // than as the spool it is a clone of.
        let byID = spool.identity.flatMap { identity -> FilamentRow? in
            let base = identity.filamentId
            guard !base.isEmpty else { return nil }
            let id = base.count == 6 ? String(base.dropFirst()) : base
            return materials.rows.first { $0.id == id }
        }
        // The name is the fallback whenever the id does not resolve, not only when there is no
        // id. A spool this app tagged for a filament the catalogue has since dropped still names
        // its material, and refusing to use that left Method B blocked with "Choose a material"
        // for a spool whose material was written on the row.
        let byName = byID == nil ? materials.rows.first(where: {
            $0.brand.caseInsensitiveCompare(spool.brand) == .orderedSame
                && $0.name.caseInsensitiveCompare(spool.name) == .orderedSame
        }) : nil
        if let row = byID ?? byName {
            catalogueBrand = row.brand
            materialID = row.id
        }

        brand = spool.brand
        name = spool.name
        materialType = spool.materialType
        colorHex = Spool.normaliseHex(spool.colorHex)
        netWeightGrams = spool.netWeightGrams
        serial = Self.allocateSerial()
        setTagsRequired(spool.isUntagged ? 0 : 2)
    }

    /// Loads the tag draft from the intake form, so the shared write path can build a plan from it.
    ///
    /// Method B writes through exactly the same machinery as the Write screen — the confirmation
    /// sheet, the pre-write sector dump, the read-back verification. Programming a blank tag
    /// rewrites its sector keys irreversibly, and there should be one way to do that, not two.
    func loadDraft(into tagModel: TagViewModel) {
        tagModel.draft.materialLabel = [brand, name].filter { !$0.isEmpty }.joined(separator: " · ")
        // Once a tag has been written the second one has to carry the first one's exact payload —
        // that is what makes the two sides one spool — so the draft comes from the written record,
        // not from a form that may have moved since.
        if let written = writtenRecord {
            tagModel.draft.materialID = written.materialId
            tagModel.draft.serialNumber = written.serialNumber
            tagModel.draft.weight = written.knownLength ?? .kg1
            if let color = Color(tagHex: written.rgbHex) { tagModel.draft.color = color }
            return
        }
        tagModel.draft.materialID = materialID
        tagModel.draft.serialNumber = serial
        tagModel.draft.weight = FilamentLength.forGrams(netWeightGrams) ?? .kg1
        if let color = Color(tagHex: colorHex) { tagModel.draft.color = color }
    }

    /// Clears the form for the next spool. The reader stays hot: the whole point of the screen is
    /// scanning spool after spool without touching anything between them.
    func reset(keepingMethod: Bool = true) {
        tagsHandled = 0
        tagsRequired = 2
        decoded = nil
        duplicate = nil
        addingAnotherLikeDuplicate = false
        lookalike = nil
        decodedIsProgrammed = false
        failure = nil
        mismatch = nil
        absorbedUIDs.removeAll()
        writtenUIDs.removeAll()
        writtenRecord = nil
        activityLabel = nil
        uidLabel = "—"
        if !keepingMethod { method = .scan }
        brand = ""
        name = ""
        materialType = ""
        netWeightGrams = 1000
        remainingPercent = 100
        colorHex = "C12E1F"
        filamentId = ""
        materialID = ""
        // The catalogue pre-fill is Method B's: it is where the tag's filament id comes from. In
        // Method A the tag is the authority and the form has to start empty. Picking a brand here
        // regardless ran `adoptCatalogueMaterial` whenever the brand *changed* — so switching back
        // from Method B with a non-first brand chosen left Method A showing a brand, name, type and
        // colour that had been read off nothing, and a tag whose id the catalogue did not know was
        // then confirmed with those invented values.
        catalogueBrand = isScan ? "" : Self.defaultCatalogueBrand(in: catalogueBrands)
        serial = Self.allocateSerial()
    }

    // MARK: Serial allocation

    /// A serial for a spool this app is tagging.
    ///
    /// Six digits, because that is the tag field's width (``SpoolRecord/Field/serialNumber``), and
    /// random rather than sequential because there is nowhere to keep a counter that survives a
    /// reinstall. Deliberately **not** `000001`: that is the value Windows hard-codes, so every
    /// factory spool already shares it, and reusing it would make an app-written spool collide with
    /// the entire Creality catalogue.
    nonisolated static func allocateSerial() -> String { SpoolRecord.randomSerialNumber() }
}
