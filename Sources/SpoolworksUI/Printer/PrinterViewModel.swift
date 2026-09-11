import Foundation
import SwiftUI
import SpoolworksCore

// ─────────────────────────────────────────────────────────────────────────────────────────────
// MARK: - Transport contract
//
// The screens are written against the narrow protocol below rather than against
// `SpoolworksCore.PrinterService` directly. It is deliberately the *smallest* surface that
// SPEC/04-printer-net.md §2–§3 requires — read the remote version, pull the remote database, push
// the local one, read the CFS — so that the views can be driven by a stand-in in previews and
// tests. `LivePrinterTransport` adapts the real service to it.
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

/// Errors raised on the UI side of the printer screens: the stand-in transport's refusal, and a
/// cancellation the sheets phrase themselves.
///
/// Named apart from Core's `PrinterTransportError` on purpose. This type used to share that
/// name, and within this module the local declaration shadowed the Core one — so a `catch` or
/// `as?` written against `PrinterTransportError` here would have matched this enum and never a
/// real SSH failure.
enum PrinterUIError: LocalizedError {
    case notImplemented
    case cancelled
    case remote(String)

    var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "This build has no printer transport; previews and tests run against a stand-in that cannot reach a printer."
        case .cancelled:
            return "The transfer was cancelled."
        case let .remote(detail):
            return detail
        }
    }
}

/// What the UI needs from a printer. ``LivePrinterTransport`` is the real conformer;
/// ``UnimplementedPrinterTransport`` remains for previews and tests.
protocol PrinterTransporting: Sendable {
    /// `result.version` of `…/box/material_database.json` on the printer.
    func remoteDatabaseVersion(_ credentials: PrinterCredentials, family: PrinterType) async throws -> String
    /// The raw bytes of the printer's `material_database.json`.
    func downloadDatabase(_ credentials: PrinterCredentials, family: PrinterType) async throws -> Data
    /// Pushes `data` to `…/box/material_database.json`, stamped as `options` say, plus the K1
    /// `material_option.json` side-car. Returns the version that was stamped on the wire, so the
    /// caller can mirror it on the local file. `progress` is coarse and per-step. Never restarts
    /// the printer.
    func uploadDatabase(_ data: Data,
                        credentials: PrinterCredentials,
                        family: PrinterType,
                        options: UploadOptions,
                        progress: @escaping @Sendable (PrinterProgress) -> Void) async throws -> String
    /// Replaces the printer's database with the factory catalogue in `data`, version untouched —
    /// the reset semantics SPEC/04 §3.1 spells out, less its unconditional reboot.
    func resetDatabase(_ data: Data,
                       credentials: PrinterCredentials,
                       family: PrinterType,
                       progress: @escaping @Sendable (PrinterProgress) -> Void) async throws
    /// What the printer is doing, read without a password.
    func activity(host: String) async throws -> PrinterActivity
    /// Restarts the printer only if it reports itself idle immediately beforehand; otherwise throws
    /// `RestartRefusal` and sends nothing. The one restart the UI can ask for (D-006).
    func restartIfIdle(_ credentials: PrinterCredentials, family: PrinterType) async throws
    /// The CFS's live report of what is loaded, for the Printer & CFS screen.
    func downloadBoxInfo(_ credentials: PrinterCredentials,
                         family: PrinterType) async throws -> MaterialBoxInfo
}

extension PrinterTransporting {
    /// A transport with no way to read the printer — the stand-in, test doubles — cannot confirm
    /// it is idle, so it never restarts it.
    func activity(host _: String) async throws -> PrinterActivity {
        throw PrinterUIError.notImplemented
    }

    func restartIfIdle(_: PrinterCredentials, family _: PrinterType) async throws {
        throw PrinterUIError.notImplemented
    }
}

/// Stand-in for previews and tests. Fails loudly and specifically rather than pretending to
/// succeed — the Windows original returns `"0"` from a failed version read (`Utils.cs:678-681`),
/// which silently stamps the local database with a bogus version.
struct UnimplementedPrinterTransport: PrinterTransporting {
    func remoteDatabaseVersion(_: PrinterCredentials, family _: PrinterType) async throws -> String {
        throw PrinterUIError.notImplemented
    }

    func downloadDatabase(_: PrinterCredentials, family _: PrinterType) async throws -> Data {
        throw PrinterUIError.notImplemented
    }

    func uploadDatabase(_: Data,
                        credentials _: PrinterCredentials,
                        family _: PrinterType,
                        options _: UploadOptions,
                        progress _: @escaping @Sendable (PrinterProgress) -> Void) async throws -> String {
        throw PrinterUIError.notImplemented
    }

    func resetDatabase(_: Data,
                       credentials _: PrinterCredentials,
                       family _: PrinterType,
                       progress _: @escaping @Sendable (PrinterProgress) -> Void) async throws {
        throw PrinterUIError.notImplemented
    }

    func downloadBoxInfo(_: PrinterCredentials,
                         family _: PrinterType) async throws -> MaterialBoxInfo {
        throw PrinterUIError.notImplemented
    }
}

// MARK: - Credential storage

/// SSH password storage.
///
/// ``LocalPrinterCredentialStore`` is the real conformer and what the app uses: it keeps the
/// password in a file the app owns, `0600` in a `0700` directory under Application Support, keyed
/// by host (D-012). ``InMemoryPrinterCredentialStore`` below remains for tests and previews, where
/// nothing should touch the user's files.
///
/// The password is **plaintext at rest**, and that is a stated trade rather than an oversight:
/// the Keychain it replaced authorises readers by code signature, and an ad-hoc-signed app is a
/// different app on every build, so macOS raised a system password prompt each launch. That is
/// defensible only because of what the secret is — a printer's root password on a home LAN,
/// usually the vendor default printed on its touchscreen — and the store must not be reused for
/// anything else. What the Windows app did remains a non-goal: it wrote the password to the
/// registry *and* rendered it in a `TextBox` with no `PasswordChar` (SPEC/04 §1.4); here it never
/// goes to `UserDefaults` or a log, and is only ever shown in a `SecureField`.
protocol PrinterCredentialStoring: AnyObject {
    func password(for family: PrinterType) -> String?
    func setPassword(_ password: String?, for family: PrinterType)
    /// True when a password is available without asking the user again.
    func hasPassword(for family: PrinterType) -> Bool
    /// Tells the store that a printer's address changed, so anything it cached under the old one
    /// is dropped. A store keyed by family has nothing to do here; the file-backed one is keyed
    /// by *host* and would otherwise keep serving the previous machine's password.
    func invalidate(_ family: PrinterType)
}

extension PrinterCredentialStoring {
    func invalidate(_ family: PrinterType) {}
}

/// Session-scoped store. Deliberately volatile, so a preview or a test can never leave a password
/// behind on the machine that ran it; the file-backed store is a drop-in.
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

    static func host(for family: PrinterType, in store: UserDefaults = defaults) -> String {
        store.string(forKey: "host_\(suffix(family))") ?? ""
    }

    static func setHost(_ host: String, for family: PrinterType, in store: UserDefaults = defaults) {
        store.set(host, forKey: "host_\(suffix(family))")
    }

    /// Windows default is `true` (SPEC/03-ui.md §2), so a missing key must read as `true`, not as
    /// `UserDefaults`' implicit `false`.
    /// Whether the printer may keep updating its own material database after an upload.
    ///
    /// Stored as `allow_`, and **off by default** — the safe answer, because leaving it on means
    /// the printer's updater can overwrite the filaments you just pushed. It replaces an earlier
    /// `prevent_` key that held the same fact inverted; that value is migrated on first read so a
    /// printer configured before the rename keeps the behaviour its owner chose rather than
    /// silently flipping to the opposite.
    static func allowDatabaseUpdates(for family: PrinterType,
                                     in store: UserDefaults = defaults) -> Bool {
        if let allow = store.object(forKey: "allow_\(suffix(family))") as? Bool { return allow }
        if let prevent = store.object(forKey: "prevent_\(suffix(family))") as? Bool {
            return !prevent
        }
        return false
    }

    static func setAllowDatabaseUpdates(_ value: Bool, for family: PrinterType,
                                        in store: UserDefaults = defaults) {
        store.set(value, forKey: "allow_\(suffix(family))")
        // Drop the superseded key so a later read cannot resurrect the old answer.
        store.removeObject(forKey: "prevent_\(suffix(family))")
    }

    static func forget(_ family: PrinterType, in store: UserDefaults = defaults) {
        // `reboot_` is no longer read or written — the app asks before every restart (D-006) — but
        // printers configured before that still carry it.
        for prefix in ["host_", "prevent_", "allow_", "reboot_"] {
            store.removeObject(forKey: prefix + suffix(family))
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
    var allowDatabaseUpdates: Bool
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
    /// Where the non-secret connection settings live. Injectable so a test can drive add, remove
    /// and re-address without leaving `host_K2` behind in the real preferences.
    let defaults: UserDefaults
    /// Called after the local database for a family changes on disk — added, removed, merged
    /// from a download, reset or re-stamped — so the material browser can reload. `AppEnvironment`
    /// wires it to `MaterialsViewModel`; without that the browser kept writing its own stale copy
    /// back over every download.
    var onDatabaseChanged: ((PrinterType) -> Void)?
    /// Restarts waiting for a print to finish — the "automatically" answer to the Upload sheet's
    /// question. Owned here, not by the sheet, because it has to outlive the sheet.
    let restarts: PrinterRestartScheduler

    init(storage: MaterialStorage,
         transport: PrinterTransporting = UnimplementedPrinterTransport(),
         credentials: PrinterCredentialStoring = InMemoryPrinterCredentialStore(),
         defaults: UserDefaults = .standard) {
        self.storage = storage
        self.transport = transport
        self.credentials = credentials
        self.defaults = defaults
        self.restarts = PrinterRestartScheduler(transport: transport)
        // Looked up when the restart is sent rather than captured when it is scheduled, so a
        // password is not held for the length of a print.
        restarts.credentials = { [weak self] family in self?.restartCredentials(for: family) }
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
            host: PrinterSettings.host(for: family, in: defaults),
            allowDatabaseUpdates: PrinterSettings.allowDatabaseUpdates(for: family, in: defaults),
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
    ///
    /// Returns whether it worked. The failure is also kept in `actionFailure` for the detail
    /// banner, but on first run there is no detail column to show a banner in, so the sheet that
    /// asked needs the answer directly.
    @discardableResult
    func addPrinter(_ family: PrinterType) async -> Bool {
        actionFailure = nil
        let database = MaterialDatabase(printerType: family, storage: storage)
        do {
            try database.seedFromBundle()
        } catch {
            actionFailure = MaterialsViewModel.message(for: error)
            return false
        }
        await refresh()
        selection = family
        onDatabaseChanged?(family)
        toast = ToastMessage("Printer added")
        return true
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
        // The password first, while the address is still known: the store files passwords by
        // host, so forgetting the address first left it with nothing to delete under and the root
        // password stayed in the credential file.
        credentials.setPassword(nil, for: doomed.family)
        PrinterSettings.forget(doomed.family, in: defaults)
        await refresh()
        onDatabaseChanged?(doomed.family)
        toast = ToastMessage("Printer removed")
    }

    func requestRemoval(of printer: PrinterConfiguration) {
        pendingRemoval = printer
    }

    // MARK: Settings edits

    /// Records a printer's address. Called once the address is settled, not per keystroke — the
    /// store re-keys the password under the new host here, and doing that for every partial
    /// address as it was typed would have filed the password under each of them in turn.
    func setHost(_ host: String, for family: PrinterType) {
        PrinterSettings.setHost(host, for: family, in: defaults)
        // The credential file is keyed by host, so a re-addressed printer must not keep answering
        // with the password of the machine it used to point at. Whether there *is* a password
        // has to be re-read in the same breath: the CFS poll trusts `hasStoredPassword`, and a
        // stale `true` here sent it looking for a password that no longer resolved.
        credentials.invalidate(family)
        apply(family) {
            $0.host = host
            $0.hasStoredPassword = self.credentials.hasPassword(for: family)
        }
    }

    func setAllowDatabaseUpdates(_ value: Bool, for family: PrinterType) {
        PrinterSettings.setAllowDatabaseUpdates(value, for: family, in: defaults)
        apply(family) { $0.allowDatabaseUpdates = value }
    }

    /// The credentials a scheduled restart sends with, looked up at the moment it is sent. Nil when
    /// the printer has no address or no saved password, which makes the scheduler give up rather
    /// than guess.
    private func restartCredentials(for family: PrinterType) -> PrinterCredentials? {
        guard let printer = printers.first(where: { $0.family == family }),
              printer.isReachableOnPaper, printer.hasStoredPassword else { return nil }
        return makeCredentials(host: printer.host, password: password(for: family))
    }

    func setPassword(_ password: String?, for family: PrinterType) {
        credentials.setPassword(password, for: family)
        apply(family) { $0.hasStoredPassword = self.credentials.hasPassword(for: family) }
    }

    /// Removes a printer's password from the credential file.
    func forgetPassword(for family: PrinterType) {
        credentials.setPassword(nil, for: family)
        apply(family) { $0.hasStoredPassword = false }
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

    /// Rewrites `result.version` on the local file without touching the catalogue.
    ///
    /// Called after an upload with whatever the service stamped on the wire — `9876543210` when
    /// updates are blocked, so the printer's own updater believes it is already ahead of anything
    /// the cloud offers (SPEC/04 §3.1 step 2), or the printer's own version otherwise — so the
    /// local file describes the database the printer actually has.
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
