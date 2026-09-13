import AppKit
import Foundation
import SwiftUI
import SpoolworksCore

// MARK: - Colour bridging

extension Color {
    init(_ rgb: RGB8) {
        self.init(.sRGB,
                  red: Double(rgb.r) / 255,
                  green: Double(rgb.g) / 255,
                  blue: Double(rgb.b) / 255,
                  opacity: 1)
    }
}

// MARK: - Row model

/// One row of the filament `Table`. A value type so `KeyPathComparator` sorting is trivial and the
/// table diffs cleanly.
struct FilamentRow: Identifiable, Hashable {
    var filament: Filament
    // No colour. Every shipped record's `base.colors` is the `#ffffff`/`#000000` placeholder, so a
    // colour column only ever showed black or white as though it meant something — and resolving a
    // name for it was a 31,861-row scan per row. The field still round-trips; it is not presented.

    /// The table's identity for this row: `base.id`, for every record whose id is unique in the
    /// file — all of them, in a well-formed catalogue. `Table` traps on duplicate identifiers, and
    /// a hand-edited or hand-merged file can carry two records with the same id (Core's `add`
    /// refuses them; `load` does not), so a repeat is suffixed with its ordinal. Anything that
    /// needs the record's own id — the ID column, the clipboard, the database — reads
    /// ``materialID`` instead, which does not change which record an edit lands on.
    let id: String

    init(filament: Filament, id: String? = nil) {
        self.filament = filament
        self.id = id ?? filament.base.id
    }

    /// Rows for a catalogue in file order, with duplicate ids made unique.
    static func rows(from filaments: [Filament]) -> [FilamentRow] {
        var seen: [String: Int] = [:]
        return filaments.map { filament in
            let base = filament.base.id
            let ordinal = (seen[base] ?? 0) + 1
            seen[base] = ordinal
            return FilamentRow(filament: filament,
                               id: ordinal == 1 ? base : "\(base)#\(ordinal)")
        }
    }

    /// `base.id` — the catalogue's own key, which is what the printer and a tag refer to.
    var materialID: String { filament.base.id }
    var brand: String { filament.base.brand }
    var name: String { filament.base.name }
    var materialType: String { filament.base.materialType }
    var minTemp: Int { filament.base.minTemp }
    var maxTemp: Int { filament.base.maxTemp }

    /// Rendered as text as well as an icon — see the accessibility rule against colour-only
    /// encoding. Empty when the filament is neither soluble nor support.
    var traits: String {
        var parts: [String] = []
        if filament.base.isSoluble { parts.append("Soluble") }
        if filament.base.isSupport { parts.append("Support") }
        return parts.joined(separator: ", ")
    }

    /// Free-text haystack for the search field.
    var searchHaystack: String {
        [materialID, brand, name, materialType, traits]
            .joined(separator: " ")
            .lowercased()
    }
}

// MARK: - View model

@MainActor
final class MaterialsViewModel: ObservableObject {

    /// Every state the browser can be in. `failed` carries a message because the Windows original
    /// swallowed every load error into an empty list (`MatDb.cs:52`).
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    /// What the editor sheet is doing. `nil` when no sheet is up.
    enum EditorMode: Identifiable, Equatable {
        case add(template: Filament?)
        case edit(Filament)

        var id: String {
            switch self {
            case .add: return "add"
            case let .edit(filament): return "edit-\(filament.base.id)"
            }
        }
    }

    // MARK: Inputs

    /// The family whose catalogue is on screen.
    ///
    /// Switching it reloads, and the reload is both **cancellable** and **generation-guarded**.
    /// It used to be a bare unstructured `Task { await load() }` with neither: flicking through
    /// three families faster than a ~350 KB JSON decode meant three loads in flight, each
    /// assigning `rows` when it happened to finish, so the table could settle on one family's rows
    /// under another family's heading. `MaterialCatalog.load` already does this correctly; this is
    /// the same pattern.
    @Published var printerType: PrinterType {
        didSet {
            guard printerType != oldValue else { return }
            UserDefaults.standard.set(printerType.rawValue, forKey: Self.selectedPrinterDefaultsKey)
            loadTask?.cancel()
            loadTask = Task { [weak self] in await self?.load() }
        }
    }
    @Published var searchText = ""
    @Published var sortOrder: [KeyPathComparator<FilamentRow>] = [
        KeyPathComparator(\FilamentRow.brand, order: .forward),
        KeyPathComparator(\FilamentRow.name, order: .forward),
    ]
    @Published var selection: Set<FilamentRow.ID> = []

    // MARK: Outputs

    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var rows: [FilamentRow] = []
    @Published private(set) var version: String = MaterialVersion.unknown
    @Published private(set) var installedTypes: [PrinterType] = []
    /// Non-nil when the last write to disk failed. Rendered as a persistent inline banner with a
    /// Retry button, never as a toast — a failed save must not disappear on a timer.
    @Published var saveFailure: String?
    /// Rows the user asked to delete; non-empty drives the confirmation dialog. Deletion is never
    /// performed without this round-trip (the Windows `ManageForm` deletes with no confirm — an
    /// explicit non-goal in SPEC/03-ui.md §8.5).
    @Published var pendingDeletion: [FilamentRow] = []
    @Published var editor: EditorMode?
    @Published var toast: ToastMessage?
    /// Set when the catalogue on disk changed under edits that are still unsaved — a printer
    /// download landed while a failed write was waiting on Retry. Neither side is a superset of
    /// the other, so nothing is done silently: the banner says so, Retry writes the edits over
    /// the download, and Reload discards them.
    @Published private(set) var diskChangedWhileUnsaved = false
    /// How many filaments the bundled catalogue has that this one does not, when the bundled one
    /// is the newer of the two. Drives the "add them" banner; zero hides it.
    ///
    /// Offered rather than merged on load. The catalogue on disk is the user's — a printer
    /// download, a hand-edited file, a deliberately deleted record — and an app upgrade that
    /// silently poured 30 records into it would be doing the thing this app is careful not to do.
    @Published private(set) var seedAdditions = 0
    /// How many third-party filaments the bundled vendor catalogue has that this one does not.
    ///
    /// A separate offer from ``seedAdditions``, because accepting it has a consequence the
    /// captured records do not: their ids are ours, not Creality's, so a tag written against one
    /// is ignored by the printer until the catalogue has been uploaded to it. The banner says so.
    @Published private(set) var vendorAdditions = 0

    // MARK: Dependencies

    let storage: MaterialStorage
    private var database: MaterialDatabase?
    private var pendingSave: Task<Void, Never>?
    /// The in-flight catalogue load, so switching families cancels the one it supersedes.
    private var loadTask: Task<Void, Never>?

    static let selectedPrinterDefaultsKey = "printerType"

    init(storage: MaterialStorage, printerType: PrinterType? = nil) {
        self.storage = storage
        // Same defaults key as the Windows registry value (`MainForm.cs:86,935`), so a documented
        // migration stays trivial. Windows stored a combo *index*; an index into a list whose order
        // came from a directory listing is not a stable identity, so this stores the family token.
        let stored = UserDefaults.standard.string(forKey: Self.selectedPrinterDefaultsKey)
            .flatMap(PrinterType.init(rawValue:))
        self.printerType = printerType ?? stored ?? .k2
    }

    /// Test/preview seam: build a view model over a scratch directory.
    static func previewValue() -> MaterialsViewModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("k2-materials-preview", isDirectory: true)
        return MaterialsViewModel(storage: MaterialStorage(directory: dir))
    }

    // MARK: Derived

    var filteredRows: [FilamentRow] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = needle.isEmpty ? rows : rows.filter { $0.searchHaystack.contains(needle) }
        return base.sorted(using: sortOrder)
    }

    var selectedFilaments: [Filament] {
        filteredRows.filter { selection.contains($0.id) }.map(\.filament)
    }

    var singleSelection: Filament? {
        selection.count == 1 ? selectedFilaments.first : nil
    }

    var isEmptyDatabase: Bool {
        if case .loaded = loadState { return rows.isEmpty }
        return false
    }

    var versionDescription: String {
        Self.describe(version: version)
    }

    /// `result.version` is unix epoch seconds in a string (SPEC/02 §5). `"0"` means "unknown", and
    /// `9876543210` is the sentinel written by *Prevent DB updates* — both need spelling out rather
    /// than being shown as a bare integer nobody can read.
    static func describe(version: String) -> String {
        if version == MaterialVersion.unknown { return "Unknown" }
        if version == MaterialVersion.preventUpdateSentinel { return "Locked (updates prevented)" }
        guard let seconds = MaterialVersion.number(version) else { return version }
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: Loading

    /// Loads the catalogue for whichever family is selected when the call starts.
    ///
    /// Every assignment past an `await` is gated on the family still being the one this call was
    /// started for. Cancellation alone is not enough — a task cancelled while suspended in a
    /// detached decode still resumes and runs its continuation — so the generation check is what
    /// actually makes a superseded load harmless.
    func load() async {
        let generation = printerType
        loadState = .loading
        saveFailure = nil
        diskChangedWhileUnsaved = false
        installedTypes = storage.installedTypes()

        let db = MaterialDatabase(printerType: generation, storage: storage)
        do {
            // Seeding writes a file, so it stays on this actor where the database object lives;
            // the expensive part (read + JSON decode of a ~350 KB catalogue) goes to a detached
            // task. `MaterialDatabaseFile` is `Sendable`, the database object is not.
            if !storage.exists(generation) {
                try db.seedFromBundle()
            }
            let url = db.fileURL
            let file = try await Task.detached(priority: .userInitiated) {
                let data = try Data(contentsOf: url)
                return try MaterialDatabase.decode(data)
            }.value

            guard printerType == generation else { return }   // the user moved on while we loaded

            db.adopt(file)
            // Records nobody changed are brought up to the catalogue this version ships; anything
            // that differs from every shipped version is left alone. Idempotent, so it costs nothing
            // once the Write tab's load at launch has already done it.
            let refreshed = (try? db.refreshUntouchedRecords()) ?? MaterialRefreshOutcome()
            database = db
            version = db.version
            rows = FilamentRow.rows(from: db.filaments)
            installedTypes = storage.installedTypes()
            seedAdditions = db.pendingSeedAdditions().count
            vendorAdditions = db.pendingVendorAdditions().count
            loadState = .loaded
            if let summary = refreshed.summary { toast = ToastMessage(summary, style: .success) }
        } catch {
            guard printerType == generation else { return }
            database = nil
            rows = []
            version = MaterialVersion.unknown
            loadState = .failed(Self.message(for: error))
        }
    }

    /// Adds the filaments the newer bundled catalogue has and this one lacks, and says how many.
    ///
    /// The user's own records are never touched: ids already present are skipped, whatever they
    /// hold now. See ``MaterialDatabase/topUpFromSeed()``.
    func applySeedAdditions() async {
        guard let database else { return }
        do {
            let added = try database.topUpFromSeed()
            rows = FilamentRow.rows(from: database.filaments)
            version = database.version
            seedAdditions = database.pendingSeedAdditions().count
            saveFailure = nil
            toast = ToastMessage(added.isEmpty
                                 ? "The catalogue already had every bundled filament"
                                 : "\(added.count) filament\(added.count == 1 ? "" : "s") added",
                                 style: .success)
        } catch {
            saveFailure = Self.message(for: error)
        }
    }

    /// Adds the bundled third-party catalogue — Bambu, Elegoo, Overture, SUNLU and Polymaker's
    /// consumer line — and says how many landed. Ids already present are left alone.
    func applyVendorCatalogue() async {
        guard let database else { return }
        do {
            let added = try database.addVendorCatalogue()
            rows = FilamentRow.rows(from: database.filaments)
            vendorAdditions = database.pendingVendorAdditions().count
            saveFailure = nil
            toast = ToastMessage(added.isEmpty
                                 ? "The catalogue already had every third-party filament"
                                 : "\(added.count) third-party filament\(added.count == 1 ? "" : "s") added"
                                   + " — upload the catalogue to the printer before writing tags",
                                 style: .success)
        } catch {
            saveFailure = Self.message(for: error)
        }
    }

    /// The Printers window changed `family`'s catalogue on disk — a download merged in, a reset,
    /// a version re-stamped, a family added or removed.
    ///
    /// This model holds its own in-memory `MaterialDatabase` and `persist()` writes that copy, so
    /// without hearing about the change the next filament edit wrote the pre-download catalogue
    /// back over the download. Reloading is safe whenever memory has nothing the disk lacks; the
    /// one case where it does — a write that failed and is waiting on Retry — is flagged instead,
    /// because reloading would throw away the edits the banner has just promised to keep.
    func noteExternalChange(to family: PrinterType) {
        installedTypes = storage.installedTypes()
        guard family == printerType else { return }
        if saveFailure != nil {
            diskChangedWhileUnsaved = true
            return
        }
        guard storage.exists(family) else {
            // Removed on the Printers screen. `load()` would seed the family afresh from the
            // bundle, which is right when the user asks for a family and wrong here: it would put
            // the printer they just removed straight back. Say what happened and stop writing.
            database = nil
            rows = []
            version = MaterialVersion.unknown
            loadState = .failed("The \(family.displayName) database was removed on the Printers screen. Add the printer again to recreate it.")
            return
        }
        loadTask?.cancel()
        loadTask = Task { [weak self] in await self?.load() }
    }

    // MARK: Mutations

    func add(_ filament: Filament) async -> String? {
        guard let database else { return "The material database is not loaded." }
        do {
            try database.add(filament)
        } catch {
            return Self.message(for: error)
        }
        await persist(after: database, note: "Filament added")
        selection = [filament.base.id]
        return nil
    }

    func update(_ filament: Filament) async -> String? {
        guard let database else { return "The material database is not loaded." }
        do {
            try database.update(filament)
        } catch {
            return Self.message(for: error)
        }
        await persist(after: database, note: "Filament saved")
        return nil
    }

    /// Confirmed delete. The confirmation itself lives in the view; this is the commit step.
    func confirmDeletion() async {
        guard let database else { return }
        let doomed = pendingDeletion
        pendingDeletion = []
        guard !doomed.isEmpty else { return }
        do {
            for row in doomed {
                try database.remove(id: row.materialID)
            }
        } catch {
            saveFailure = Self.message(for: error)
            return
        }
        selection.subtract(doomed.map(\.id))
        let note = doomed.count == 1
            ? "Deleted \(doomed[0].brand) \(doomed[0].name)"
            : "Deleted \(doomed.count) filaments"
        await persist(after: database, note: note)
    }

    func requestDeletion(of rows: [FilamentRow]) {
        guard !rows.isEmpty else { return }
        pendingDeletion = rows
    }

    func requestDeletionOfSelection() {
        requestDeletion(of: filteredRows.filter { selection.contains($0.id) })
    }

    /// Re-runs the last failed write.
    func retrySave() async {
        guard let database else { return }
        await persist(after: database, note: nil)
    }

    private func persist(after database: MaterialDatabase, note: String?) async {
        rows = FilamentRow.rows(from: database.filaments)
        version = database.version

        let snapshot = database.snapshot()
        let url = database.fileURL
        let directory = storage.directory
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try MaterialDatabase.encode(snapshot)
                try data.write(to: url, options: .atomic)
            }.value
            saveFailure = nil
            // Whatever was on disk, this write is now what is on disk.
            diskChangedWhileUnsaved = false
            if let note { toast = ToastMessage(note) }
        } catch {
            // The in-memory catalogue keeps the change; the banner tells the user it is not on disk
            // yet and offers Retry. Windows swallowed this entirely (`MatDb.cs:161-190`).
            saveFailure = Self.message(for: error)
        }
    }

    // MARK: Templates

    /// The record a new filament is cloned from — the Windows behaviour (`MainForm.cs:738-763`),
    /// which seeds the 90-odd `kvParam` slicer keys from an existing profile so the printer gets a
    /// complete record rather than a stub.
    var addTemplate: Filament? {
        singleSelection ?? filteredRows.first?.filament ?? rows.first?.filament
    }

    /// Ids already in use, for the editor's duplicate check.
    var existingIDs: Set<String> {
        Set(rows.map(\.materialID))
    }

    var knownBrands: [String] {
        Array(Set(rows.map(\.brand))).filter { !$0.isEmpty }.sorted()
    }

    var knownMaterialTypes: [String] {
        // Union of what the catalogue actually contains and the 25 types the Windows add-form
        // offered (`Utils.cs:1096-1121`). The shipped data contains `PA612-CF`, which is *not* in
        // that list — proof the list was never authoritative, so it is a suggestion source only and
        // never a validation rule.
        let windowsList = [
            "ABS", "ASA", "HIPS", "PA", "PA-CF", "PC", "PLA", "PLA-CF", "PVA", "PP", "TPU",
            "PETG", "BVOH", "PET-CF", "PETG-CF", "PA6-CF", "PAHT-CF", "PPS", "PPS-CF", "PET",
            "ASA-CF", "PA-GF", "PETG-GF", "PP-CF", "PCTG",
        ]
        return Array(Set(rows.map(\.materialType)).union(windowsList))
            .filter { !$0.isEmpty }
            .sorted()
    }

    // MARK: Errors

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
