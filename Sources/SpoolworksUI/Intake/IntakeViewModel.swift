import Foundation
import SwiftUI
import Combine
import SpoolworksCore

/// The Intake screen's state machine: get a spool into stock, tag by tag, without leaving the
/// reader.
///
/// ## The two methods, and the thing they share
///
/// **Method A — scan a Creality tag.** Read either of the spool's two factory tags, check what came
/// off it, confirm. Nothing is typed.
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
            case .scan: return "Method A · Scan a Creality tag"
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

    /// One of a spool's two tags, and how far it has got.
    struct TagSlot: Identifiable, Equatable {
        let index: Int
        var isDone: Bool
        var id: Int { index }
        var name: String { "Tag \(index + 1) of 2" }
    }

    // MARK: Published state

    @Published var method: Method = .scan { didSet { reset(keepingMethod: true) } }
    /// How many of the two tags have been read (method A) or written (method B).
    @Published private(set) var tagsHandled = 0
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

    // MARK: The form

    @Published var brand = ""
    @Published var name = ""
    @Published var materialType = "PLA"
    @Published var netWeightGrams = 1000
    @Published var colorHex = "C12E1F"
    /// Allocated by this app in method B; read off the tag in method A.
    @Published var serial = ""
    @Published var filamentId = ""

    static let brands = ["Creality", "Polymaker", "Prusament", "Bambu Lab",
                         "Overture", "Sunlu", "eSun", "Generic"]
    static let materialTypes = ["PLA", "PLA-CF", "PETG", "PETG-CF", "ABS",
                                "ASA", "TPU", "PA-CF", "PC", "PVA"]
    /// The five weights the tag's length code can express. There is no "other": a weight the tag
    /// cannot encode would be lost the moment the spool was written.
    static let weights: [Int] = [1000, 750, 600, 500, 250]

    private unowned let monitor: ReaderMonitor
    private unowned let inventory: InventoryViewModel
    private unowned let materials: MaterialsViewModel
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

    var tags: [TagSlot] {
        (0..<2).map { TagSlot(index: $0, isDone: tagsHandled > $0) }
    }

    var isScan: Bool { method == .scan }

    /// `"Step 2 · Read either tag"` / `"Step 3 · Write both tags"`.
    var tagPanelLabel: String {
        isScan ? "Step 2 · Read either tag" : "Step 3 · Write both tags"
    }

    var formLabel: String {
        isScan ? "Step 3 · Confirm" : "Step 2 · Describe the spool"
    }

    var tagProgress: String {
        "\(tagsHandled) of 2 \(isScan ? "read" : "written")"
    }

    var tagNote: String {
        isScan
            ? "A Creality spool carries two factory tags with the same payload. Reading either one is enough; read the second only to confirm the pair."
            : "A spool carries two tags. Both get the same payload, each verified by read-back — either one identifies the spool later. A spool tagged on one side only will fail to read half the time it is loaded."
    }

    var stateLabel: String {
        if let duplicate { return "Already in stock · \(duplicate.serialLabel)" }
        if isScan { return decoded == nil ? "Method A · waiting for tag" : "Tag read · \(sourceLabel)" }
        return "Method B · enter and tag"
    }

    private var sourceLabel: String {
        guard let decoded else { return "" }
        return decoded.vendorId == "0276" ? "Creality factory" : "vendor \(decoded.vendorId)"
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
        return tagsHandled >= 2 ? "Add to stock" : "Add to stock (tags pending)"
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
        return tagsHandled >= 2 ? "Both tags verified." : "Write both tags first, or add now and tag later."
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

    // MARK: Actions

    /// Reads one of the spool's tags (method A).
    func readTag(_ slot: TagSlot) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }

        do {
            let result = try await monitor.withCard { session, identity in
                guard identity.isUsable else { throw TagError.unsupportedCard(identity.type) }
                return try TagService(session: session).readTag()
            }
            uidLabel = result.uid.map { String(format: "%02X", $0) }.joined(separator: " ")

            guard let record = result.record else {
                failure = "That tag carries no readable spool record. A blank tag needs Method B."
                return
            }
            adopt(record)
            tagsHandled = max(tagsHandled, slot.index + 1)
            toasts.success("Tag read — \(record.filamentId) · \(record.rgbHex)")
        } catch {
            failure = error.localizedDescription
        }
    }

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
        let materialId = filamentId.count == 6 ? String(filamentId.dropFirst()) : filamentId
        return try? SpoolRecord(materialId: materialId,
                                colorRGB: Spool.normaliseHex(colorHex),
                                filamentLength: length,
                                serialNumber: serial)
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
                             remainingSource: tagsHandled >= 2
                                 ? "Intake · tagged, assumed full"
                                 : "Manual record · tag pending",
                             tagSource: tagsHandled >= 2 ? .spoolworksWritten : .untagged)
            made.note(kind: .intake,
                      detail: tagsHandled >= 2 ? "Intake · both tags written" : "Intake · manual entry")
            spool = made
        }

        inventory.add(spool)
        session.insert(spool, at: 0)
        toasts.success("Added to stock — \(spool.label) · serial \(spool.serialLabel)")
        reset(keepingMethod: true)
    }

    func openDuplicate() {
        guard let duplicate else { return }
        inventory.selectedID = duplicate.id
    }

    /// Clears the form for the next spool. The reader stays hot: the whole point of the screen is
    /// scanning spool after spool without touching anything between them.
    func reset(keepingMethod: Bool = true) {
        tagsHandled = 0
        decoded = nil
        duplicate = nil
        failure = nil
        uidLabel = "—"
        if !keepingMethod { method = .scan }
        brand = ""
        name = ""
        materialType = "PLA"
        netWeightGrams = 1000
        colorHex = "C12E1F"
        filamentId = ""
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
    nonisolated static func allocateSerial() -> String {
        String(format: "%06d", Int.random(in: 100_000...999_999))
    }
}
