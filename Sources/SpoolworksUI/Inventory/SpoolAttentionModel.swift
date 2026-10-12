import Foundation
import Combine
import SpoolworksCore

/// Works out, for every spool in stock, what still stands between it and a correct print or a
/// correct HueForge design — the list behind the Inventory's warning triangles.
///
/// Each of the three questions is already answered somewhere: the printer's filament list by its
/// websocket, the HueForge record by ``HueForgeViewModel``, the colour's provenance by
/// ``InventoryViewModel``. What was missing is one place that asks all three about every spool, so
/// a spool that will be ignored by the CFS, or that HueForge has never heard of, says so in the
/// list rather than at the moment it fails.
///
/// The answers are held as a table and recomputed when an input changes, not derived per row per
/// render: naming a legacy spool's colour is a 17,000-colour search, and a list of fifty spools
/// redraws every time a print job draws a gram.
@MainActor
final class SpoolAttentionModel: ObservableObject {

    /// One printer's live filament list.
    struct Listing: Equatable {
        let family: PrinterType
        let printerName: String
        let ids: Set<String>
    }

    /// A printer to ask, as ``FilamentPushModel`` describes one.
    struct Printer: Equatable {
        let family: PrinterType
        let host: String
        let name: String
    }

    @Published private(set) var issues: [Spool.ID: [SpoolAttention]] = [:]
    /// The lists read so far. A printer that could not be reached has no entry — and so raises no
    /// warning: "could not ask" is not "does not list".
    @Published private(set) var listings: [Listing] = []

    private let inventory: InventoryViewModel
    private let filamentList: PrinterFilamentListReading
    private let printers: @MainActor () -> [Printer]
    private let isFactoryFilament: @MainActor (String, PrinterType) -> Bool
    /// The catalogue id a tag for this spool carries, or would carry.
    private let filamentID: @MainActor (Spool) -> String
    /// What the catalogue calls an id, for the sentence the warning is written in.
    private let filamentLabel: @MainActor (String) -> String?

    private var spools: [Spool] = []
    private var syncStates: [UUID: HueForgeSyncState] = [:]
    private var observations: Set<AnyCancellable> = []
    private var lastRefresh: Date?
    private var refreshing: Task<Void, Never>?

    /// How long a printer's list is trusted before the Inventory asks again on its own.
    static let listingLifetime: TimeInterval = 300

    init(inventory: InventoryViewModel,
         hueForge: HueForgeViewModel,
         filamentList: PrinterFilamentListReading,
         printers: @escaping @MainActor () -> [Printer],
         isFactoryFilament: @escaping @MainActor (String, PrinterType) -> Bool,
         filamentID: @escaping @MainActor (Spool) -> String,
         filamentLabel: @escaping @MainActor (String) -> String?) {
        self.inventory = inventory
        self.filamentList = filamentList
        self.printers = printers
        self.isFactoryFilament = isFactoryFilament
        self.filamentID = filamentID
        self.filamentLabel = filamentLabel
        self.spools = inventory.inventory.active
        self.syncStates = hueForge.spoolSyncStates
        recompute()
        // Both publish on willSet, so the new value is the one handed in.
        inventory.$inventory.dropFirst().sink { [weak self] in
            self?.spools = $0.active
            self?.recompute()
        }.store(in: &observations)
        hueForge.$spoolSyncStates.dropFirst().sink { [weak self] in
            self?.syncStates = $0
            self?.recompute()
        }.store(in: &observations)
    }

    func issues(for spool: Spool) -> [SpoolAttention] { issues[spool.id] ?? [] }

    /// The printer family to add a spool's filament to, for the rail's button.
    func family(missing spool: Spool) -> PrinterType? {
        let id = filamentID(spool)
        return listings.first { !$0.ids.contains(id) && !isFactoryFilament(id, $0.family) }?.family
    }

    // MARK: Totals, for fixing a fault everywhere at once

    /// How many spools carry the fault with this ``SpoolAttention/id``.
    func count(_ kind: String) -> Int {
        issues.values.reduce(0) { $0 + ($1.contains { $0.id == kind } ? 1 : 0) }
    }

    /// Every distinct filament in stock that a printer does not list, and the printer to add them to.
    var missingFilaments: (family: PrinterType, printerName: String, ids: [String])? {
        var ids: [String] = []
        for list in issues.values {
            for case let .notOnPrinter(_, _, id) in list where !ids.contains(id) { ids.append(id) }
        }
        guard !ids.isEmpty,
              let listing = listings.first(where: { listing in ids.contains { !listing.ids.contains($0) } })
        else { return nil }
        return (listing.family, listing.printerName, ids.sorted())
    }

    // MARK: The printers' lists

    /// Reads each configured printer's filament list, unless that was done recently.
    ///
    /// One read-only websocket question per printer, no password — the same one a verified write
    /// already asks (D-013). Nothing is sent that changes the printer.
    func refreshListings(force: Bool = false) {
        if !force, let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < Self.listingLifetime {
            return
        }
        guard refreshing == nil else { return }
        let asked = printers()
        lastRefresh = .now
        let reader = filamentList
        refreshing = Task { [weak self] in
            var found: [Listing] = []
            for printer in asked {
                guard let ids = try? await reader.filamentIDs(host: printer.host) else { continue }
                found.append(Listing(family: printer.family, printerName: printer.name, ids: ids))
            }
            guard let self else { return }
            self.refreshing = nil
            if found != self.listings { self.listings = found }
            self.recompute()
        }
    }

    /// A filament was just added to a printer: its list has it now, without asking again.
    func noteAdded(filamentID: String, family: PrinterType) {
        listings = listings.map {
            $0.family == family
                ? Listing(family: $0.family, printerName: $0.printerName, ids: $0.ids.union([filamentID]))
                : $0
        }
        recompute()
    }

    /// The catalogue changed, so ids may resolve differently.
    func catalogueChanged() { recompute() }

    /// Waits for the read in flight. For tests.
    func settle() async { await refreshing?.value }

    // MARK: Working it out

    private func recompute() {
        var table: [Spool.ID: [SpoolAttention]] = [:]
        for spool in spools {
            let found = attention(for: spool)
            if !found.isEmpty { table[spool.id] = found }
        }
        if table != issues { issues = table }
    }

    private func attention(for spool: Spool) -> [SpoolAttention] {
        var found: [SpoolAttention] = []

        // Missing only when *no* printer whose list could be read has it. With two printers of
        // different families, a K2 filament is not a fault for being absent from the K1.
        let id = filamentID(spool)
        if !id.isEmpty, !listings.isEmpty,
           !listings.contains(where: { $0.ids.contains(id) || isFactoryFilament(id, $0.family) }),
           let printer = listings.first {
            let named = filamentLabel(id)
                ?? [spool.brand, spool.name].filter { !$0.isEmpty }.joined(separator: " ")
            found.append(.notOnPrinter(printer: printer.printerName,
                                       filament: named.isEmpty ? id : named,
                                       filamentID: id))
        }

        switch syncStates[spool.id] {
        case .notSent: found.append(.notInHueForge(outdated: false))
        case .outdated: found.append(.notInHueForge(outdated: true))
        case .current, .excluded, nil: break
        }

        if colourSource(of: spool) == .generic {
            found.append(.colourUnmatched(maker: inventory.maker(of: spool) ?? ""))
        }
        return found
    }

    /// Remembered per description, because a spool recorded before the source was stored has to
    /// be resolved against the colour lists to find out.
    private var sourceMemo: [String: ColourNameSource] = [:]

    private func colourSource(of spool: Spool) -> ColourNameSource {
        if let stored = spool.colorNameSource { return stored }
        let key = [spool.brand, spool.name, spool.materialType, spool.colorHex, spool.colorName,
                   spool.identity?.filamentId ?? ""].joined(separator: "|")
        if let known = sourceMemo[key] { return known }
        let source = inventory.colourNameSource(for: spool)
        sourceMemo[key] = source
        return source
    }
}
