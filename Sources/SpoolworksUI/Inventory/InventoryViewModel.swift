import Foundation
import SwiftUI
import Combine
import SpoolworksCore

// MARK: - What the Location picker offers

/// One row of the Location picker.
///
/// Two kinds, because a spool's location has two possible owners and only one of them is the user.
///
/// * ``place`` is an **assertion** — a row from the user's own list, mapping to `.unknown` or
///   `.shelf(name)`. Choosing one is the user saying where the spool is.
/// * ``printer`` is an **observation** — `"CFS T1 · A"`, straight from the last poll. It exists so
///   the picker can display the truth about a loaded spool instead of rendering blank, and it is
///   never produced by a choice — `InventoryViewModel.setLocation(_:for:)` ignores it.
///
/// So the picker can move a spool **off** the printer but never **onto** it, which is the CFS
/// conflict rule in one sentence. `docs/DECISIONS.md` D-011 has the reasoning and what happens on
/// the next poll in each direction.
enum LocationOption: Hashable, Identifiable {
    case place(String)
    case printer(String)

    var id: String {
        switch self {
        case let .place(name): return "place:\(name)"
        case let .printer(text): return "printer:\(text)"
        }
    }

    /// What the picker row reads. The printer's own position says where it came from, because a
    /// user-created place called `CFS` sitting next to a measured `CFS T1 · A` would otherwise be
    /// two indistinguishable rows meaning entirely different things.
    var title: String {
        switch self {
        case let .place(name): return name
        case let .printer(text): return "\(text) · reported by the printer"
        }
    }

    var isPrinterOwned: Bool { if case .printer = self { return true }; return false }
}

// MARK: - How a hand correction was arrived at

/// The two ways the user can correct what is left of a spool.
///
/// Both land as `UsageEntry.Kind.adjustment`: the model has exactly one kind for "the user
/// corrected this by hand", and splitting it would fragment a spool's history for no gain. What
/// differs is the **wording**, so the log and the detail rail say which was actually done — a
/// figure someone measured on scales and a figure someone eyeballed deserve different amounts of
/// trust when they are read back six months later.
///
/// Held as one type rather than two `adjust` methods so the weigh-in and the percentage edit are
/// provably the same code path. They were briefly two, and the percentage edit immediately grew
/// its own clamping rule that disagreed with the weigh-in's.
enum AdjustmentMethod: String, CaseIterable, Identifiable, Sendable {
    /// Filament grams off a set of scales.
    case weighed
    /// A percentage typed in, for a spool no one is going to unmount and weigh.
    case byHand

    var id: String { rawValue }

    /// The segmented control's label. Kept for anywhere that still offers the choice.
    var title: String {
        switch self {
        case .weighed: return "By weight"
        case .byHand: return "By percent"
        }
    }

    /// The usage log's line.
    var detail: String {
        switch self {
        case .weighed: return "Weighed in"
        case .byHand: return "Set by hand"
        }
    }

    /// `Spool.remainingSource` — the one line under the big figure that says where it came from.
    func source(on date: Date) -> String {
        let day = date.formatted(date: .abbreviated, time: .omitted)
        switch self {
        case .weighed: return "Weighed \(day)"
        case .byHand: return "Set by hand \(day)"
        }
    }
}

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

    /// The user's names for where a spool lives when the printer is not holding it.
    ///
    /// Owned here rather than by a settings object of its own because the list and the spools that
    /// reference it have to change together — renaming or removing a place walks the inventory,
    /// and this view model is the app's only writer of spool state. A second owner would be a
    /// second source of truth with no way to keep the two honest.
    @Published private(set) var places: SpoolPlaces

    private let store: InventoryStore
    private let toasts: ToastCenter
    private let defaults: UserDefaults

    /// Loaded once and cached: the table is 636 KB and naming a colour on every row render would
    /// re-read it. `nil` when the resource is missing, in which case spools simply carry no colour
    /// name — a degraded label, not a crash.
    private lazy var matcher: ColorMatcher? = try? ColorMatcher.shared()

    init(store: InventoryStore, toasts: ToastCenter, defaults: UserDefaults = .standard) {
        self.store = store
        self.toasts = toasts
        self.defaults = defaults
        self.places = SpoolPlacesStore.load(from: defaults)
    }

    // MARK: Derived

    var rows: [Spool] { inventory.filtered(by: filter) }

    /// The figures the "what's left" picker offers for one spool, fullest first.
    ///
    /// A 100 g ladder, the same step the net-weight picker uses, each rung labelled in **both**
    /// units — `700 g · 70%` — because the two answer different questions and neither is the
    /// obvious one. Grams is what a set of scales says; percent is what the inventory stores and
    /// what the bar shows. Making the user pick a unit first, then type a number in it, was two
    /// decisions for a value most people are eyeballing to the nearest tenth of a spool.
    ///
    /// The spool's own net weight is always the top rung even when it is not a multiple of 100 —
    /// a 750 g spool has to be able to say "full".
    ///
    /// Nothing here is precise to the gram any more. That is the trade: a picker cannot express
    /// 437 g. It is the right one for a list you scroll past, and the wrong one for a scale, so
    /// this is the place to look if weighing to the gram is ever wanted back.
    nonisolated func remainingOptions(for spool: Spool) -> [(grams: Int, percent: Double, label: String)] {
        let net = spool.netWeightGrams
        guard net > 0 else { return [] }
        var rungs = stride(from: (net / 100) * 100, through: 0, by: -100).map { $0 }
        if rungs.first != net { rungs.insert(net, at: 0) }
        return rungs.map { grams in
            let percent = Double(grams) / Double(net) * 100
            return (grams, percent, "\(grams) g · \(Int(percent.rounded()))%")
        }
    }

    /// The filter row: the two states that are not places, then every place the user has
    /// configured, then the two conditions.
    ///
    /// Built from ``places`` rather than from a fixed list, which is the whole point — a location
    /// the user added has to be filterable, and one they renamed has to stop being offered under
    /// the old name.
    var filterOptions: [InventoryFilter] {
        [.all, .onPrinter]
            + places.names.map { .at(places.location(for: $0)) }
            + [.low, .untagged]
    }

    /// Drops a filter that no longer names anything.
    ///
    /// Renaming or removing the place you are currently filtered by would otherwise leave the table
    /// empty with a selected button that matches nothing — the list would look as though every
    /// spool had vanished.
    private func normaliseFilter() {
        guard case .at = filter, !filterOptions.contains(filter) else { return }
        filter = .all
    }

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

    /// Records a hand-corrected remaining figure. **The only way the user can move that number.**
    ///
    /// Both the weigh-in and the inline percentage edit come through here, so the invariant on
    /// ``UsageEntry`` — every change to `remainingPercent` appends a line explaining it — is
    /// enforced once rather than at each entry point. ``Spool/record(percent:kind:detail:date:source:)``
    /// derives the delta from the figure it is given, so the log can never disagree with the
    /// number it sits under.
    ///
    /// Returns false when the figure is unusable, so the caller can keep the field open with the
    /// value still in it rather than appearing to accept and discard it.
    @discardableResult
    func adjust(_ spool: Spool, toPercent percent: Double, method: AdjustmentMethod) -> Bool {
        // Refused rather than clamped, for the same reason the weigh-in refuses a gross weight:
        // clamping 130 % to 100 % silently discards what the user actually typed and leaves them
        // believing the app agreed with them.
        guard (0...100).contains(percent) else { return false }
        guard var current = inventory.spool(id: spool.id) else { return false }
        // Re-typing the figure already on record is not a correction, and a "0 g" line in the log
        // explains nothing. Anything that genuinely moves the number is written however small —
        // a 4 g correction on a 1 kg spool is 0.4 % and still real — so this is an exact
        // comparison, not a tolerance.
        guard current.remainingPercent != percent else { return true }
        let now = Date.now
        current.record(percent: percent,
                       kind: .adjustment,
                       detail: method.detail,
                       date: now,
                       source: method.source(on: now))
        inventory.update(current)
        persist()
        return true
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
        return adjust(spool,
                      toPercent: Double(grams) / Double(spool.netWeightGrams) * 100,
                      method: .weighed)
    }

    /// Deducts filament a print job drew from this spool.
    func consume(_ spool: Spool, grams: Double, detail: String) {
        guard var current = inventory.spool(id: spool.id) else { return }
        current.consume(grams: grams, detail: detail)
        inventory.update(current)
        persist()
    }

    func setLocation(_ location: SpoolLocation, for spool: Spool) {
        guard var current = inventory.spool(id: spool.id) else { return }
        // Choosing the row that is already selected is not a move, and a movement line for a
        // spool that did not move makes the log harder to read, not easier.
        guard current.location != location else { return }
        let previous = current.location
        current.location = location

        if previous.isOnPrinter {
            // Taking a spool off the printer by hand ends the live measurement, so the source line
            // has to stop claiming one. This is deliberately the same wording
            // `SpoolInventory.reconcile` uses when the *printer* stops reporting a slot — the user
            // did the same thing the poll would have noticed within 30 s, and the rail should not
            // read differently depending on who spotted it first.
            current.remainingSource = "Last reading from \(previous.description)"
            current.note(kind: .movement,
                         detail: "Taken off \(previous.description) by hand — now "
                             + location.description)
        } else {
            current.note(kind: .movement, detail: "Moved to \(location.description)")
        }
        inventory.update(current)
        persist()
    }

    /// Sets a spool's material type by hand.
    ///
    /// The type is not on the tag — a record carries a filament *id*, and the type is whatever the
    /// catalogue says that id is. So a spool tagged for an id the catalogue does not know arrives
    /// with no type at all, and before this there was no way to say what it was: the field was
    /// written once at intake and never again.
    ///
    /// Deliberately **not** a usage entry. The usage log exists to explain
    /// ``Spool/remainingPercent`` and nothing else — every line in it carries a gram delta — and a
    /// metadata correction that logged `0 g` would be noise in the one place this app promises is
    /// never noise. Nothing is lost: the type is either right or it is not, and it is on screen.
    func setMaterialType(_ raw: String, for spool: Spool) {
        guard var current = inventory.spool(id: spool.id) else { return }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != current.materialType else { return }
        current.materialType = value
        inventory.update(current)
        persist()
    }

    /// Applies a picker choice.
    ///
    /// **A `.printer` row is ignored, and that is the CFS conflict rule.** `.cfs(box:slot:)` and
    /// `.externalHolder` are measurements the poll owns and rewrites every 30 s; letting the user
    /// assert one would be letting them state a fact about their own hardware that the next poll
    /// contradicts, which is the failure mode ``CFSViewModel`` already documents for the design's
    /// "CFS units attached" picker. So the printer's position is shown, never chosen.
    ///
    /// Moving a loaded spool **to** a place is allowed, because it means something honest: "I have
    /// taken this out". The poll then settles it, correctly in both directions —
    ///
    /// * the spool really was removed: the next snapshot does not list it, and `reconcile`'s
    ///   unload pass only touches spools whose location `isOnPrinter`, so the place the user chose
    ///   **survives**;
    /// * the spool is still in the slot: pass 2 rebinds it by identity, restores `.cfs` and writes
    ///   `"Loaded into T1 · A"`, so the assertion is **overruled by measurement, in writing**.
    ///
    /// Both are covered by tests; see `docs/DECISIONS.md` D-011.
    func setLocation(_ option: LocationOption, for spool: Spool) {
        guard case let .place(name) = option else { return }
        setLocation(places.location(for: name), for: spool)
    }

    // MARK: The place list

    /// The picker's rows for one spool, in the order they are shown.
    func locationOptions(for spool: Spool) -> [LocationOption] {
        var options: [LocationOption] = []
        // First, so a loaded spool's real position is the thing the closed picker shows.
        if spool.location.isOnPrinter {
            options.append(.printer(spool.location.description))
        }
        options.append(contentsOf: places.names.map(LocationOption.place))
        // A spool at a place that is no longer on the list. Editing keeps the two in step, so this
        // can only come from an inventory file written before the list existed — but a picker with
        // no row matching its own selection renders blank, and a blank Location on a spool that
        // has one is worse than an extra row.
        if let name = places.name(for: spool.location), !places.contains(name) {
            options.append(.place(name))
        }
        return options
    }

    /// Which row is currently selected.
    func locationOption(for spool: Spool) -> LocationOption {
        if spool.location.isOnPrinter { return .printer(spool.location.description) }
        return .place(places.name(for: spool.location) ?? SpoolPlaces.unplaced)
    }

    /// How many spools would be moved if this place were removed. Shown next to the button, so a
    /// removal that shuffles a dozen spools is not a surprise.
    func spoolCount(atPlace name: String) -> Int { inventory.spools(atPlace: name).count }

    @discardableResult
    func addPlace(_ raw: String) -> PlaceEditResult {
        var updated = places
        let result = updated.add(raw)
        guard result.isApplied else { return result }
        places = updated
        SpoolPlacesStore.save(places, to: defaults)
        normaliseFilter()
        return result
    }

    /// Renames a place and carries its spools with it.
    ///
    /// The rename and the re-pointing happen together and unconditionally — that is the whole
    /// point. A list edit that left spools at the old string would leave them at a location no
    /// picker row offers, which is the orphan this feature must not create.
    @discardableResult
    func renamePlace(_ old: String, to raw: String) -> PlaceEditResult {
        var updated = places
        let result = updated.rename(old, to: raw)
        guard case let .applied(name) = result else { return result }
        places = updated
        SpoolPlacesStore.save(places, to: defaults)
        normaliseFilter()
        let moved = inventory.reassign(place: old,
                                       to: updated.location(for: name),
                                       detail: "Place renamed — “\(old)” is now “\(name)”")
        if !moved.isEmpty { persist() }
        return result
    }

    /// Removes a place, moving anything on it to `Unplaced`.
    ///
    /// Removal is allowed even when spools are on it. Refusing would be the other obvious answer
    /// and was rejected: nothing is lost by the move — the spool, its history and its remaining
    /// figure are untouched, only a label goes — and a list you cannot tidy without first hunting
    /// down every spool that mentions a name is a list people stop using. What it must not do is
    /// leave a spool somewhere the picker cannot express, so the cascade is not optional, each
    /// moved spool gets a line saying why, and the toast reports the count.
    @discardableResult
    func removePlace(_ name: String) -> PlaceEditResult {
        var updated = places
        let result = updated.remove(name)
        guard case let .applied(removed) = result else { return result }
        places = updated
        SpoolPlacesStore.save(places, to: defaults)
        normaliseFilter()
        let moved = inventory.reassign(
            place: removed,
            to: .unknown,
            detail: "Place “\(removed)” removed — moved to \(SpoolPlaces.unplaced)")
        if !moved.isEmpty {
            persist()
            let n = moved.count
            toasts.info("Removed “\(removed)” — \(n) spool\(n == 1 ? "" : "s") "
                        + "moved to \(SpoolPlaces.unplaced)")
        }
        return result
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
    /// `netWeightGrams` overrides the record's own figure.
    ///
    /// The tag's length code is the *nominal* weight and the user can see the spool. A 250 g sample
    /// wound onto a 1 kg-coded tag is a real thing, and so is a tag whose code no Creality client
    /// recognises — those all report 1 KG. Intake lets the figure be corrected before the spool is
    /// added, and this is what makes that correction survive: it used to be discarded, because this
    /// took the weight from the record and nothing else.
    func spool(from record: SpoolRecord,
               brand: String = "",
               name: String = "",
               materialType: String = "",
               netWeightGrams: Int? = nil,
               location: SpoolLocation = .unknown,
               tagSource: TagSource = .crealityFactory,
               detail: String = "Intake · tag read") -> Spool {
        var spool = Spool(identity: SpoolIdentity(record: record),
                          brand: brand,
                          name: name,
                          materialType: materialType,
                          colorHex: record.rgbHex,
                          colorName: colorName(forHex: record.rgbHex),
                          netWeightGrams: netWeightGrams ?? record.weightGrams,
                          remainingPercent: 100,
                          location: location,
                          remainingSource: "Intake · assumed full",
                          tagSource: tagSource)
        spool.note(kind: .intake, detail: detail)
        return spool
    }

    /// Logs a spool whose tag this app has just written and verified.
    ///
    /// Lands **unplaced**. The tag carries no location and the write says nothing about where the
    /// spool physically is, so asserting a shelf would be inventing a fact; the next CFS poll
    /// claims it the moment it is loaded. Re-tagging a spool already in stock updates that record
    /// rather than creating a second one — a replacement tag is not a new spool.
    ///
    /// Returns the spool it logged, or nil when the preference is off.
    /// `materialType` is resolved by the caller, which is the only layer holding the material
    /// catalogue. It is left empty rather than guessed when the tag's filament id is not in the
    /// catalogue: a spool of unknown type is a fact, and writing "PLA" over it would be a
    /// plausible-looking invention. The rail lets the user set it — see ``setMaterialType(_:for:)``.
    @discardableResult
    func logWrittenSpool(record: SpoolRecord,
                         materialLabel: String,
                         materialType: String = "",
                         enabled: Bool) -> Spool? {
        guard enabled else { return nil }

        if var existing = inventory.spool(matching: record) {
            existing.tagSource = .spoolworksWritten
            existing.note(kind: .movement, detail: "Tag rewritten and verified")
            inventory.update(existing)
            persist()
            return existing
        }

        // "Creality · Hyper PLA" is how the write form labels a material; split it back out so the
        // inventory row reads the way every other row does.
        let parts = materialLabel.components(separatedBy: " · ")
        let brand = parts.count > 1 ? parts[0] : ""
        let name = parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : materialLabel

        var spool = spool(from: record,
                          brand: brand,
                          name: name,
                          materialType: materialType,
                          location: .unknown,
                          tagSource: .spoolworksWritten,
                          detail: "Intake · tag written by Spoolworks")
        spool.remainingSource = "Tagged here · assumed full"
        inventory.add(spool)
        persist()
        toasts.success("Added to stock — \(spool.label) · serial \(spool.serialLabel)")
        return spool
    }

    /// Whether a tag already belongs to a spool in stock — the Intake screen's duplicate guard.
    func existing(for record: SpoolRecord) -> Spool? {
        inventory.spool(matching: record)
    }
}
