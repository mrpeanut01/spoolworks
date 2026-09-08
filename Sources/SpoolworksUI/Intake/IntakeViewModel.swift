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

    // MARK: The form

    @Published var brand = ""
    @Published var name = ""
    @Published var materialType = "PLA"
    @Published var netWeightGrams = 1000
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
    var willBeTagged: Bool { tagsRequired > 0 && tagsHandled >= tagsRequired }

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
        if let duplicate { return "Already in stock · \(duplicate.serialLabel)" }
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
        if duplicate != nil { return false }
        if isScan { return decoded != nil }
        return !brand.isEmpty || !name.isEmpty
    }

    var confirmTitle: String {
        if isScan { return "Confirm and add to stock" }
        return tagsHandled >= tagsRequired ? "Add to stock" : "Add to stock (tags pending)"
    }

    var hint: String {
        if let duplicate {
            return "This tag already belongs to \(duplicate.label) in stock. Nothing to add."
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
        if let hex = row.colorHex.isEmpty ? nil : row.colorHex { colorHex = Spool.normaliseHex(hex) }
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
        mismatch = nil
        failure = nil
        uidLabel = result.uid.map { String(format: "%02X", $0) }.joined(separator: " ")
        adopt(record)
        tagsHandled = min(tagsRequired, absorbedUIDs.count)
        toasts.success(tagsHandled >= tagsRequired
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
    /// said it was fine.
    func absorbWrite(uid: [UInt8]) {
        guard !isScan else { return }
        guard !writtenUIDs.contains(uid) else { return }
        writtenUIDs.insert(uid)
        tagsHandled = min(tagsRequired, writtenUIDs.count)
        toasts.success(tagsHandled >= tagsRequired
                       ? (tagsRequired == 1 ? "Tag written and verified"
                                            : "Both tags written and verified")
                       : "Tag \(tagsHandled) of \(tagsRequired) written and verified")
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

    func markTagWritten(_ slot: TagSlot) {
        tagsHandled = max(tagsHandled, slot.index + 1)
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
                                    // What is on the form, not what was on the tag. The picker is
                                    // editable in Method A too, and an edit that the confirm
                                    // silently threw away is worse than not offering it.
                                    netWeightGrams: netWeightGrams,
                                    tagSource: .crealityFactory,
                                    detail: "Intake · tag read")
        } else {
            var made = Spool(identity: composeRecord().map(SpoolIdentity.init(record:)),
                             brand: brand,
                             name: name,
                             materialType: materialType,
                             colorHex: colorHex,
                             colorName: inventory.colorName(forHex: Spool.normaliseHex(colorHex)),
                             netWeightGrams: netWeightGrams,
                             remainingPercent: 100,
                             location: .shelf("Shelf"),
                             remainingSource: willBeTagged
                                 ? "Intake · tagged, assumed full"
                                 : tagsRequired == 0 ? "Counted onto the shelf, assumed full"
                                                     : "Manual record · tag pending",
                             tagSource: willBeTagged ? .spoolworksWritten : .untagged)
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

    func openDuplicate() {
        guard let duplicate else { return }
        inventory.selectedID = duplicate.id
    }

    /// Loads the tag draft from the intake form, so the shared write path can build a plan from it.
    ///
    /// Method B writes through exactly the same machinery as the Write screen — the confirmation
    /// sheet, the pre-write sector dump, the read-back verification. Programming a blank tag
    /// rewrites its sector keys irreversibly, and there should be one way to do that, not two.
    func loadDraft(into tagModel: TagViewModel) {
        tagModel.draft.materialID = materialID
        tagModel.draft.materialLabel = [brand, name].filter { !$0.isEmpty }.joined(separator: " · ")
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
        failure = nil
        mismatch = nil
        absorbedUIDs.removeAll()
        writtenUIDs.removeAll()
        activityLabel = nil
        uidLabel = "—"
        if !keepingMethod { method = .scan }
        brand = ""
        name = ""
        materialType = "PLA"
        netWeightGrams = 1000
        colorHex = "C12E1F"
        filamentId = ""
        materialID = ""
        catalogueBrand = catalogueBrands.first ?? ""
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
