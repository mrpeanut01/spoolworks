import Foundation
import SwiftUI
import Combine
import SpoolworksCore

/// The Inventory screen's state, and the one place spools are created, changed and persisted.
///
/// Every mutation saves immediately rather than on a timer or at quit. An inventory that loses the
/// last spool you logged because the app was force-quit is worse than useless, and the file is
/// small enough that an atomic rewrite per change costs nothing measurable.
@MainActor
final class InventoryViewModel: ObservableObject {

    @Published private(set) var inventory = SpoolInventory()
    @Published var filter: InventoryFilter = .all
    @Published var selectedID: UUID?
    /// Set to raise the retire confirmation; the design's one-tap, no-form dialog.
    @Published var retireTarget: Spool?

    /// A load or save that failed, shown in place rather than silently swallowed.
    @Published private(set) var storageError: String?

    private let store: InventoryStore
    private let toasts: ToastCenter

    /// Loaded once and cached: the table is 636 KB and naming a colour on every row render would
    /// re-read it. `nil` when the resource is missing, in which case spools simply carry no colour
    /// name — a degraded label, not a crash.
    private lazy var matcher: ColorMatcher? = try? ColorMatcher.shared()

    init(store: InventoryStore, toasts: ToastCenter) {
        self.store = store
        self.toasts = toasts
    }

    // MARK: Derived

    var rows: [Spool] { inventory.filtered(by: filter) }

    var summary: String { inventory.summary }

    /// The spool the detail rail shows. Falls back to the first row so the rail is never empty
    /// while the table has content — and follows the filter, so selecting "Low" then reading the
    /// rail does not show a spool that is no longer listed.
    var selected: Spool? {
        if let selectedID, let match = rows.first(where: { $0.id == selectedID }) { return match }
        return rows.first
    }

    var isEmpty: Bool { inventory.active.isEmpty }

    // MARK: Loading

    func load() {
        do {
            inventory = try store.load()
            storageError = nil
        } catch {
            // The inventory stays empty, but the screen says why rather than looking like a
            // first run.
            storageError = "\(error)"
        }
    }

    private func persist() {
        do {
            try store.save(inventory)
            storageError = nil
        } catch {
            storageError = "\(error)"
            toasts.error("The inventory could not be saved. \(error)")
        }
    }

    // MARK: Mutation

    func add(_ spool: Spool) {
        inventory.add(spool)
        selectedID = spool.id
        persist()
    }

    func update(_ spool: Spool) {
        inventory.update(spool)
        persist()
    }

    func confirmRetire(_ spool: Spool) {
        inventory.retire(id: spool.id)
        retireTarget = nil
        if selectedID == spool.id { selectedID = nil }
        persist()
        toasts.info("Retired — \(spool.label) · serial \(spool.serialLabel)")
    }

    /// Records a hand-corrected remaining figure — a weigh-in.
    func adjust(_ spool: Spool, toPercent percent: Double) {
        guard var current = inventory.spool(id: spool.id) else { return }
        current.record(percent: percent,
                       kind: .adjustment,
                       detail: "Weighed in",
                       source: "Weighed \(Date.now.formatted(date: .abbreviated, time: .omitted))")
        inventory.update(current)
        persist()
    }

    /// Records a weigh-in: the user put the spool on scales and this is what is left.
    ///
    /// Takes **grams of filament**, not gross weight — a spool's own core is 150–250 g depending
    /// on the maker, and silently treating gross as net would overstate every corrected spool by
    /// about a fifth. The UI says so at the point of entry; this method simply believes what it is
    /// given.
    ///
    /// Returns false when the figure is not usable, so the caller can keep the field open with the
    /// value still in it rather than appearing to accept and discard it.
    @discardableResult
    func adjust(_ spool: Spool, toGrams grams: Int) -> Bool {
        guard grams >= 0, spool.netWeightGrams > 0 else { return false }
        // More than a full spool is a mis-keyed figure or the wrong net weight, not a real
        // reading. Refusing beats clamping to 100% and losing what the user actually measured.
        guard grams <= spool.netWeightGrams else { return false }
        adjust(spool, toPercent: Double(grams) / Double(spool.netWeightGrams) * 100)
        return true
    }

    func setLocation(_ location: SpoolLocation, for spool: Spool) {
        guard var current = inventory.spool(id: spool.id) else { return }
        current.location = location
        current.note(kind: .movement, detail: "Moved to \(location.description)")
        inventory.update(current)
        persist()
    }

    // MARK: CFS reconciliation

    /// Folds a printer poll into the inventory and reports what moved.
    @discardableResult
    func reconcile(with info: MaterialBoxInfo) -> SpoolInventory.ReconcileReport {
        let report = inventory.reconcile(with: info)
        if !report.isEmpty {
            persist()
            if !report.discovered.isEmpty {
                let n = report.discovered.count
                toasts.info("Added \(n) spool\(n == 1 ? "" : "s") found in the CFS")
            }
        }
        return report
    }

    // MARK: Building a spool

    /// The nearest named colour, for a spool's label. Empty when the table is unavailable.
    func colorName(forHex hex: String) -> String {
        guard let matcher, let name = try? matcher.nearestName(forHex: hex) else { return "" }
        return name ?? ""
    }

    /// Builds an inventory record from a decoded tag.
    ///
    /// `brand`, `name` and `materialType` are not on the tag — it carries a filament *id*, not a
    /// description — so a caller that has resolved the id against the material catalogue passes
    /// them in. Left blank, the spool is still valid and still identifiable; it simply shows its
    /// filament id where a name would go.
    func spool(from record: SpoolRecord,
               brand: String = "",
               name: String = "",
               materialType: String = "",
               location: SpoolLocation = .unknown,
               tagSource: TagSource = .crealityFactory,
               detail: String = "Intake · tag read") -> Spool {
        var spool = Spool(identity: SpoolIdentity(record: record),
                          brand: brand,
                          name: name,
                          materialType: materialType,
                          colorHex: record.rgbHex,
                          colorName: colorName(forHex: record.rgbHex),
                          netWeightGrams: record.weightGrams,
                          remainingPercent: 100,
                          location: location,
                          remainingSource: "Intake · assumed full",
                          tagSource: tagSource)
        spool.note(kind: .intake, detail: detail)
        return spool
    }

    /// Whether a tag already belongs to a spool in stock — the Intake screen's duplicate guard.
    func existing(for record: SpoolRecord) -> Spool? {
        inventory.spool(matching: record)
    }
}
