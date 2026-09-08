import Foundation
import SwiftUI
import SpoolworksCore

// ─────────────────────────────────────────────────────────────────────────────────────────────
// MARK: - Transport contract
//
// TODO(wire): bind to SpoolworksCore PrinterService / SSHTransport when the sibling workstream lands.
// There is no `Sources/SpoolworksCore/Printer/` in this worktree, so the screens are written against the
// narrow protocol below. It is deliberately the *smallest* surface that SPEC/04-printer-net.md
// §2–§3 requires: read the remote version, pull the remote database, push the local one, reboot.
// When SpoolworksCore's PrinterService appears, delete `UnimplementedPrinterTransport`, make the real
// service conform (or adapt it), and nothing in the views changes.
// ─────────────────────────────────────────────────────────────────────────────────────────────

/// Credentials for one SSH session. Never persisted by anything in this file.
struct PrinterCredentials: Sendable {
    /// Hostname or IP, exactly as typed. SPEC/04 §1.1: free text, no format validation, because a
    /// printer is as likely to be reached by `.local` name as by address.
    var host: String
    /// Hardcoded `root` at all seven Windows call sites (SPEC/04 §1.1).
    var username: String = "root"
    /// Hardcoded 22 at all seven Windows call sites.
    var port: Int = 22
    var password: String
}

enum PrinterTransportError: LocalizedError {
    case notImplemented
    case cancelled
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Printer networking is not available in this build yet. The database screens work; the SSH transport is still being wired up."
        case .cancelled:
            return "The transfer was cancelled."
        case let .remote(detail):
            return detail
        }
    }
}

// TODO(wire): bind to SpoolworksCore PrinterService when merged
protocol PrinterTransporting: Sendable {
    /// `result.version` of `…/box/material_database.json` on the printer.
    func remoteDatabaseVersion(_ credentials: PrinterCredentials, family: PrinterType) async throws -> String
    /// The raw bytes of the printer's `material_database.json`.
    func downloadDatabase(_ credentials: PrinterCredentials, family: PrinterType) async throws -> Data
    /// Pushes `data` to `…/box/material_database.json`. `progress` receives 0…1 when the transport
    /// can report it; a transport that cannot should simply never call it and the UI stays
    /// indeterminate.
    func uploadDatabase(_ data: Data,
                        credentials: PrinterCredentials,
                        family: PrinterType,
                        progress: @escaping @Sendable (Double) -> Void) async throws
    /// The one and only remote command the Windows app ever issues (SPEC/04 §1.5).
    func reboot(_ credentials: PrinterCredentials, family: PrinterType) async throws
}

/// Stand-in until SpoolworksCore ships the real thing. Fails loudly and specifically rather than
/// pretending to succeed — the Windows original returns `"0"` from a failed version read
/// (`Utils.cs:678-681`), which silently stamps the local database with a bogus version.
struct UnimplementedPrinterTransport: PrinterTransporting {
    func remoteDatabaseVersion(_: PrinterCredentials, family _: PrinterType) async throws -> String {
        throw PrinterTransportError.notImplemented
    }

    func downloadDatabase(_: PrinterCredentials, family _: PrinterType) async throws -> Data {
        throw PrinterTransportError.notImplemented
    }

    func uploadDatabase(_: Data,
                        credentials _: PrinterCredentials,
                        family _: PrinterType,
                        progress _: @escaping @Sendable (Double) -> Void) async throws {
        throw PrinterTransportError.notImplemented
    }

    func reboot(_: PrinterCredentials, family _: PrinterType) async throws {
        throw PrinterTransportError.notImplemented
    }
}

// MARK: - Credential storage

/// SSH password storage.
///
/// TODO(wire): replace with SpoolworksCore's Keychain-backed credential store once it exists. There is no
/// Keychain wrapper anywhere in SpoolworksCore in this worktree, so the default implementation below keeps
/// passwords **in memory for the lifetime of the process only**.
///
/// What must never happen, and does not happen here: the Windows app writes the printer's *root*
/// password to `HKCU\CFS RFID\Settings\psw_<printer>` in cleartext (SPEC/04 §1.4) and renders it in
/// a `TextBox` with no `PasswordChar`. SPEC/03-ui.md §8.5 lists both as explicit non-goals. Nothing
/// in this app writes a password to `UserDefaults`, to a file, or to a log.
protocol PrinterCredentialStoring: AnyObject {
    func password(for family: PrinterType) -> String?
    func setPassword(_ password: String?, for family: PrinterType)
    /// True when a password is available without asking the user again.
    func hasPassword(for family: PrinterType) -> Bool
}

/// Session-scoped store. Deliberately volatile: losing the password on quit is a far smaller
/// problem than persisting a root password in plaintext, and the Keychain-backed replacement is a
/// drop-in.
final class InMemoryPrinterCredentialStore: PrinterCredentialStoring {
    private var passwords: [PrinterType: String] = [:]

    init() {}

    func password(for family: PrinterType) -> String? { passwords[family] }

    func setPassword(_ password: String?, for family: PrinterType) {
        if let password, !password.isEmpty {
            passwords[family] = password
        } else {
            passwords.removeValue(forKey: family)
        }
    }

    func hasPassword(for family: PrinterType) -> Bool {
        !(passwords[family] ?? "").isEmpty
    }
}

// MARK: - Non-secret per-printer settings

/// Host / prevent / reboot, in `UserDefaults`.
///
/// Key names match the Windows registry values (`host_<PrinterName>`, `prevent_<…>`,
/// `reboot_<…>` — SPEC/03-ui.md §2) so the documented migration stays trivial. `<PrinterName>` was
/// the free-text combo caption on Windows; here it is the canonical family token upper-cased, which
/// is exactly the spelling the spec's own examples use (`host_K2`, `prevent_HI`).
///
/// `psw_<PrinterName>` is **deliberately absent** — see ``PrinterCredentialStoring``.
enum PrinterSettings {
    private static var defaults: UserDefaults { .standard }

    static func suffix(_ family: PrinterType) -> String { family.rawValue.uppercased() }

    static func host(for family: PrinterType) -> String {
        defaults.string(forKey: "host_\(suffix(family))") ?? ""
    }

    static func setHost(_ host: String, for family: PrinterType) {
        defaults.set(host, forKey: "host_\(suffix(family))")
    }

    /// Windows default is `true` (SPEC/03-ui.md §2), so a missing key must read as `true`, not as
    /// `UserDefaults`' implicit `false`.
    static func preventDatabaseUpdates(for family: PrinterType) -> Bool {
        defaults.object(forKey: "prevent_\(suffix(family))") as? Bool ?? true
    }

    static func setPreventDatabaseUpdates(_ value: Bool, for family: PrinterType) {
        defaults.set(value, forKey: "prevent_\(suffix(family))")
    }

    static func rebootAfterUpload(for family: PrinterType) -> Bool {
        defaults.object(forKey: "reboot_\(suffix(family))") as? Bool ?? true
    }

    static func setRebootAfterUpload(_ value: Bool, for family: PrinterType) {
        defaults.set(value, forKey: "reboot_\(suffix(family))")
    }

    static func forget(_ family: PrinterType) {
        for prefix in ["host_", "prevent_", "reboot_"] {
            defaults.removeObject(forKey: prefix + suffix(family))
        }
    }

    /// The factory root password printed on the printer's own touchscreen (SPEC/04 §1.2). Offered
    /// as a *pre-fill suggestion* only; it is never written anywhere.
    ///
    /// Windows picks this with unanchored `Contains("hi")` tested first, so `"Hyper K1"` gets the
    /// Hi password (SPEC/04 §4). `PrinterType` is already a resolved family here, so the lookup is
    /// total and cannot mis-fire.
    static func factoryPassword(for family: PrinterType) -> String {
        switch family {
        case .k1: return "creality_2023"
        case .k2: return "creality_2024"
        case .hi: return "Creality2024"
        }
    }

    /// SPEC/04 §2. K1 keeps its database on the internal flash, everything else on the UDISK mount.
    static func remoteDatabasePath(for family: PrinterType) -> String {
        let base = family == .k1
            ? "/usr/data/creality/userdata/box/"
            : "/mnt/UDISK/creality/userdata/box/"
        return base + "material_database.json"
    }
}

// MARK: - Printer model

/// One configured printer: a family whose material database is installed locally, plus how to
/// reach it.
///
/// A "printer" is keyed by family rather than by marketing name because the catalogue is
/// per-family — `db/` ships exactly three files, and `PrinterType`'s documentation spells out why
/// one-database-per-family is the deliberate scheme.
struct PrinterConfiguration: Identifiable, Hashable {
    var family: PrinterType
    var host: String
    var preventDatabaseUpdates: Bool
    var rebootAfterUpload: Bool
    var hasStoredPassword: Bool
    var databaseVersion: String
    var filamentCount: Int
    /// Non-nil when the local file exists but could not be read.
    var loadFailure: String?

    var id: PrinterType { family }
    var displayName: String { family.displayName }
    var isReachableOnPaper: Bool { !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var remotePath: String { PrinterSettings.remoteDatabasePath(for: family) }
}

// MARK: - View model

@MainActor
final class PrinterViewModel: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case loaded
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var printers: [PrinterConfiguration] = []
    @Published var selection: PrinterType?
    /// Non-nil drives the "remove this printer?" confirmation. Removal is never done without it —
    /// the Windows `ManageForm` deletes a printer's database with no prompt at all
    /// (`ManageForm.cs:63-70`), which SPEC/03-ui.md §8.3 calls out as something to fix.
    @Published var pendingRemoval: PrinterConfiguration?
    @Published var addSheetPresented = false
    @Published var uploadTarget: PrinterConfiguration?
    @Published var updateTarget: PrinterConfiguration?
    @Published var toast: ToastMessage?
    /// Persistent failure banner for add/remove.
    @Published var actionFailure: String?

    let storage: MaterialStorage
    let transport: PrinterTransporting
    let credentials: PrinterCredentialStoring
    /// Called after the local database for a family changes, so the material browser can reload.
    var onDatabaseChanged: ((PrinterType) -> Void)?

    init(storage: MaterialStorage,
         transport: PrinterTransporting = UnimplementedPrinterTransport(),
         credentials: PrinterCredentialStoring = InMemoryPrinterCredentialStore()) {
        self.storage = storage
        self.transport = transport
        self.credentials = credentials
    }

    static func previewValue() -> PrinterViewModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("k2-printers-preview", isDirectory: true)
        return PrinterViewModel(storage: MaterialStorage(directory: dir))
    }

    // MARK: Derived

    var configurableFamilies: [PrinterType] {
        PrinterType.allCases.filter { family in !printers.contains { $0.family == family } }
    }

    var selectedPrinter: PrinterConfiguration? {
        printers.first { $0.family == selection }
    }

    var isEmpty: Bool { state == .loaded && printers.isEmpty }

    // MARK: Loading

    func refresh() async {
        if state == .idle { state = .loading }
        let families = storage.installedTypes()
        var built: [PrinterConfiguration] = []
        for family in families {
            built.append(await configuration(for: family))
        }
        printers = built
        if let selection, !families.contains(selection) {
            self.selection = families.first
        } else if selection == nil {
            self.selection = families.first
        }
        state = .loaded
    }

    private func configuration(for family: PrinterType) async -> PrinterConfiguration {
        var version = MaterialVersion.unknown
        var count = 0
        var failure: String?

        let url = storage.url(for: family)
        do {
            let file = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: url)
                return try MaterialDatabase.decode(data)
            }.value
            version = file.result.version
            count = file.result.list.count
        } catch {
            failure = MaterialsViewModel.message(for: error)
        }

        return PrinterConfiguration(
            family: family,
            host: PrinterSettings.host(for: family),
            preventDatabaseUpdates: PrinterSettings.preventDatabaseUpdates(for: family),
            rebootAfterUpload: PrinterSettings.rebootAfterUpload(for: family),
            hasStoredPassword: credentials.hasPassword(for: family),
            databaseVersion: version,
            filamentCount: count,
            loadFailure: failure
        )
    }

    // MARK: Mutations

    /// Installs the bundled catalogue for a family, creating `<family>.json` locally.
    ///
    /// The Windows equivalent downloads from Creality Cloud (`ManageForm.cs:58`). SpoolworksCore ships the
    /// three catalogues in the app bundle, so first run works with no network at all; pulling a
    /// fresher copy is what the Update sheet is for.
    func addPrinter(_ family: PrinterType) async {
        actionFailure = nil
        let database = MaterialDatabase(printerType: family, storage: storage)
        do {
            try database.seedFromBundle()
        } catch {
            actionFailure = MaterialsViewModel.message(for: error)
            return
        }
        await refresh()
        selection = family
        onDatabaseChanged?(family)
        toast = ToastMessage("Printer added")
    }

    /// Confirmed removal: deletes the local database and forgets the connection settings.
    func confirmRemoval() async {
        guard let doomed = pendingRemoval else { return }
        pendingRemoval = nil
        actionFailure = nil
        do {
            try FileManager.default.removeItem(at: storage.url(for: doomed.family))
        } catch {
            actionFailure = "Could not remove the \(doomed.displayName) database: \(error.localizedDescription)"
            return
        }
        PrinterSettings.forget(doomed.family)
        credentials.setPassword(nil, for: doomed.family)
        await refresh()
        onDatabaseChanged?(doomed.family)
        toast = ToastMessage("Printer removed")
    }

    func requestRemoval(of printer: PrinterConfiguration) {
        pendingRemoval = printer
    }

    // MARK: Settings edits

    func setHost(_ host: String, for family: PrinterType) {
        PrinterSettings.setHost(host, for: family)
        apply(family) { $0.host = host }
    }

    func setPreventDatabaseUpdates(_ value: Bool, for family: PrinterType) {
        PrinterSettings.setPreventDatabaseUpdates(value, for: family)
        apply(family) { $0.preventDatabaseUpdates = value }
    }

    func setRebootAfterUpload(_ value: Bool, for family: PrinterType) {
        PrinterSettings.setRebootAfterUpload(value, for: family)
        apply(family) { $0.rebootAfterUpload = value }
    }

    func setPassword(_ password: String?, for family: PrinterType) {
        credentials.setPassword(password, for: family)
        apply(family) { $0.hasStoredPassword = self.credentials.hasPassword(for: family) }
    }

    func password(for family: PrinterType) -> String {
        credentials.password(for: family) ?? ""
    }

    private func apply(_ family: PrinterType, _ mutate: (inout PrinterConfiguration) -> Void) {
        guard let index = printers.firstIndex(where: { $0.family == family }) else { return }
        mutate(&printers[index])
    }

    // MARK: Database access for the transfer sheets

    /// The local catalogue as bytes, ready to push.
    func localDatabaseData(for family: PrinterType) throws -> Data {
        try Data(contentsOf: storage.url(for: family))
    }

    func localVersion(for family: PrinterType) -> String {
        printers.first { $0.family == family }?.databaseVersion ?? MaterialVersion.unknown
    }

    /// Rewrites `result.version` on the local file without touching the catalogue.
    ///
    /// This is what "Prevent DB updates" does: stamp `9876543210` so the printer's own updater
    /// believes it is already ahead of anything the cloud offers (SPEC/04 §3.1 step 2).
    func setLocalVersion(_ version: String, for family: PrinterType) throws {
        let url = storage.url(for: family)
        var file = try MaterialDatabase.decode(try Data(contentsOf: url))
        file.result.version = version
        try MaterialDatabase.encode(file).write(to: url, options: .atomic)
    }

    /// Merges a downloaded catalogue into the local one: upsert by `base.id`, then adopt the
    /// remote version (`UpdateForm.cs:143-179`). Returns how many records were added and updated.
    @discardableResult
    func mergeDownloadedDatabase(_ data: Data, into family: PrinterType) throws -> (added: Int, updated: Int) {
        let incoming = try MaterialDatabase.decode(data)
        let database = MaterialDatabase(printerType: family, storage: storage)
        try database.load()

        var added = 0
        var updated = 0
        for filament in incoming.result.list {
            if database.contains(id: filament.base.id) {
                try database.update(filament)
                updated += 1
            } else {
                try database.add(filament)
                added += 1
            }
        }
        database.setVersion(incoming.result.version)
        try database.save()
        return (added, updated)
    }

    func makeCredentials(host: String, password: String) -> PrinterCredentials {
        PrinterCredentials(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                           password: password)
    }
}
