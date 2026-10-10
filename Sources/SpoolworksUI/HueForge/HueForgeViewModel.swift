import Foundation
import Combine
import SpoolworksCore

/// Drives `Manage ▸ HueForge…`: the inventory as a HueForge filament library, and the ways out.
///
/// The list is always derived — from the live inventory, the user's TDs and exclusions, and
/// whatever HueForge's own libraries say — and never stored, so it cannot disagree with the
/// Inventory screen. Only the user's decisions are persisted (``HueForgePreferences``).
@MainActor
final class HueForgeViewModel: ObservableObject {

    @Published private(set) var entries: [HueForgeExportEntry] = []
    @Published private(set) var reference: HueForgeTDReference
    @Published private(set) var problem: String?
    /// The HueForge folder *Sync* writes into, once the user has chosen one.
    @Published private(set) var syncFolder: URL?
    @Published var sourceName: String { didSet { defaults.set(sourceName, forKey: Keys.sourceName) } }
    @Published var sourceBaseURL: String { didSet { defaults.set(sourceBaseURL, forKey: Keys.sourceBaseURL) } }

    private let inventory: InventoryViewModel
    private let store: HueForgePreferencesStore
    private let toasts: ToastCenter
    private let defaults: UserDefaults
    private var preferences = HueForgePreferences()
    private var observation: AnyCancellable?

    private enum Keys {
        static let syncFolder = "SpoolworksHueForgeFolder"
        static let sourceName = "SpoolworksHueForgeSourceName"
        static let sourceBaseURL = "SpoolworksHueForgeSourceBaseURL"
    }

    init(inventory: InventoryViewModel,
         store: HueForgePreferencesStore,
         toasts: ToastCenter,
         reference: HueForgeTDReference = HueForgeTDReference(),
         defaults: UserDefaults = .standard) {
        self.inventory = inventory
        self.store = store
        self.toasts = toasts
        self.reference = reference
        self.defaults = defaults
        self.sourceName = defaults.string(forKey: Keys.sourceName) ?? "Spoolworks inventory"
        self.sourceBaseURL = defaults.string(forKey: Keys.sourceBaseURL) ?? ""
        self.syncFolder = defaults.string(forKey: Keys.syncFolder).map { URL(fileURLWithPath: $0) }
        do { preferences = try store.load() } catch { problem = error.localizedDescription }
        rebuild(from: inventory.inventory)
        // `$inventory` publishes on willSet, so the new value is the one handed in — reading
        // `inventory.inventory` inside the sink would still see the old one.
        observation = inventory.$inventory.sink { [weak self] in self?.rebuild(from: $0) }
    }

    // MARK: Derived

    var included: [HueForgeExportEntry] { entries.filter(\.isIncluded) }
    var estimatedCount: Int { included.filter { $0.tdSource == .estimated }.count }
    var library: HueForgeLibrary { HueForgeExporter.library(from: entries) }

    var summary: String {
        let spools = entries.reduce(0) { $0 + $1.spoolIDs.count }
        guard !entries.isEmpty else { return "Nothing in stock to send" }
        return "\(entries.count) filament\(entries.count == 1 ? "" : "s") from "
            + "\(spools) spool\(spools == 1 ? "" : "s")"
    }

    private func rebuild(from inventory: SpoolInventory) {
        entries = HueForgeExporter.entries(for: inventory, preferences: preferences,
                                           reference: reference)
    }

    // MARK: Editing

    /// Reads HueForge's own libraries for TDs. Off the main actor: it is twenty-odd files.
    ///
    /// The folder the user chose for Sync comes first — it also holds their personal library, and
    /// so any TD they measured — then the libraries shipped inside the application.
    func loadReference() async {
        let candidates = [syncFolder].compactMap { $0 } + HueForgeInstall.bundledFolders()
        let loaded = await Task.detached { HueForgeInstall.reference(candidates: candidates) }.value
        reference = loaded
        rebuild(from: inventory.inventory)
    }

    func setIncluded(_ included: Bool, for id: String) {
        if included { preferences.excluded.remove(id) } else { preferences.excluded.insert(id) }
        commit()
    }

    /// Returns false when the text is not a TD, so the row can put the old value back.
    @discardableResult
    func setTransmissivity(_ text: String, for id: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value > 0, value <= 100 else {
            problem = "A transmission distance is a number of millimetres above 0 — "
                + "most filaments are between 0.3 and 10."
            return false
        }
        preferences.transmissivity[id] = value
        commit()
        return true
    }

    /// Drops a typed TD, falling back to the library's or the estimate.
    func clearTransmissivity(for id: String) {
        preferences.transmissivity[id] = nil
        commit()
    }

    private func commit() {
        problem = nil
        do { try store.save(preferences) } catch { problem = error.localizedDescription }
        rebuild(from: inventory.inventory)
    }

    // MARK: Out

    func export(to url: URL) {
        do {
            let data = url.pathExtension.lowercased() == "csv"
                ? Data(library.csvString().utf8)
                : try library.jsonData()
            try data.write(to: url, options: .atomic)
            toasts.success("\(included.count) filament\(included.count == 1 ? "" : "s") written to "
                + "\(url.lastPathComponent) — import it with HueForge's Filaments ▸ Import.")
        } catch {
            toasts.error("Could not write \(url.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    func chooseSyncFolder(_ url: URL) {
        // Validated by writing: the checks that matter are the ones `sync` makes anyway.
        guard sync(to: url) else { return }
        syncFolder = url
        defaults.set(url.path, forKey: Keys.syncFolder)
        Task { await loadReference() }
    }

    func syncNow() {
        guard let syncFolder else { return }
        sync(to: syncFolder)
    }

    @discardableResult
    private func sync(to folder: URL) -> Bool {
        do {
            let written = try HueForgeInstall.sync(library, toHueForgeFolder: folder)
            problem = nil
            toasts.success("Synced \(included.count) filament\(included.count == 1 ? "" : "s") to "
                + "\(written.lastPathComponent) — HueForge reads it the next time it starts.")
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    func writeCommunitySource(to folder: URL) {
        do {
            try HueForgeCommunitySource.write(library, to: folder, sourceName: sourceName,
                                              baseURL: sourceBaseURL)
            problem = nil
            toasts.success("Source written to \(folder.lastPathComponent) — push it, then add its "
                + "manifest URL under Filaments ▸ Manage Community Sources.")
        } catch {
            problem = error.localizedDescription
        }
    }

    // MARK: In

    /// Takes TDs from a HueForge export. Values already typed here are replaced: the file is the
    /// newer statement, and it is the user who chose it.
    func importTransmissivities(from url: URL) {
        do {
            let found = HueForgeExporter.transmissivities(in: try HueForgeLibrary(contentsOf: url),
                                                          for: entries)
            guard !found.isEmpty else {
                toasts.warning("\(url.lastPathComponent) has no filament matching anything in stock.")
                return
            }
            preferences.transmissivity.merge(found) { _, new in new }
            commit()
            toasts.success("Took \(found.count) transmission distance\(found.count == 1 ? "" : "s") "
                + "from \(url.lastPathComponent).")
        } catch {
            problem = error.localizedDescription
        }
    }
}
