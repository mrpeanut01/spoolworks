import Foundation

// SPEC-04 §1.4 / §11.5 — the Windows app persists the root password in **cleartext** in
// `HKCU\CFS RFID\Settings` under `psw_<PrinterName>` and displays it in a `TextBox` with no
// `PasswordChar`, i.e. unmasked on screen. The Android app keeps it in SharedPreferences.
//
// This app keeps it in a file it owns, and that is a deliberate step *down* from where it was.
//
// ## Why it is no longer the Keychain
//
// It was, and the Keychain is the right place for a password. The problem is what using it looks
// like from the outside. Spoolworks has no Apple Developer ID, so it is ad-hoc signed or signed
// with a local certificate — and a Keychain item records which application may read it by code
// signature. An app with no stable signing identity is therefore a *different app* to the Keychain
// on every build, and the user is asked to authorise it again each time. For someone who has just
// downloaded an unsigned app, a system password prompt appearing on launch is indistinguishable
// from the thing they were told to be afraid of. The security control was costing more trust than
// it bought.
//
// ## What that costs, stated plainly
//
// The password is now **plaintext on disk**. Any process running as this user can read it. The
// mitigations are real but modest: the file is `0600`, its directory is `0700`, and it is excluded
// from Time Machine so the plaintext does not fan out into backups. What it is *not* is protected
// from anything running as you.
//
// That trade is defensible only because of what the secret is: the root password of a 3D printer
// on a home LAN, which for most units is the vendor default printed on the printer's own screen
// (see ``VendorDefaultPassword``). It would not be defensible for anything else, and this file
// should not be reused for anything else.
//
// There is deliberately **no migration** from the old Keychain items. Reading them back would raise
// exactly the authorisation prompt this change exists to remove, so a user who had saved a password
// enters it once more.

/// Storage for one root password per printer host.
///
/// A protocol so tests can run against `InMemoryCredentialStore` and never touch the real
/// Keychain — which, from a plain SwiftPM executable with no bundle identifier, would either
/// prompt the user or fail with `errSecMissingEntitlement`.
public protocol CredentialStore: Sendable {
    /// The stored password for `host`, or `nil` if there is none.
    func password(forHost host: String) throws -> String?
    /// Stores or replaces the password for `host`.
    func setPassword(_ password: String, forHost host: String) throws
    /// Removes the password for `host`. Not an error if there was none.
    func deletePassword(forHost host: String) throws
}

/// Everything that can go wrong talking to the Keychain.
public enum CredentialError: Error, Equatable, CustomStringConvertible {
    case emptyHost
    case emptyPassword
    /// The stored item was not valid UTF-8 — it was not written by us.
    case corruptItem(host: String)
    /// Reading or writing the credentials file failed.
    case storage(String)

    public var description: String {
        switch self {
        case .emptyHost:      return "A printer address is required."
        case .emptyPassword:  return "A password is required."
        case .corruptItem(let host):
            return "The saved password for \(host) is unreadable and should be re-entered."
        case .storage(let detail):
            return "Could not read or write the saved printer password: \(detail)"
        }
    }
}

/// File-backed store. The real implementation.
///
/// One small JSON object, host → password, replaced atomically. See the note at the top of this
/// file for why this is not the Keychain and what it costs.
public struct FileCredentialStore: CredentialStore {

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Application Support/Spoolworks/printer-credentials.json`, beside the inventory.
    public static func applicationSupport(fileManager: FileManager = .default,
                                          fileName: String = "printer-credentials.json") throws -> FileCredentialStore {
        do {
            let base = try fileManager.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: true)
            return FileCredentialStore(
                url: base.appendingPathComponent("Spoolworks", isDirectory: true)
                    .appendingPathComponent(fileName))
        } catch {
            throw CredentialError.storage("locating Application Support: \(error.localizedDescription)")
        }
    }

    // MARK: CredentialStore

    public func password(forHost host: String) throws -> String? {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        return try load()[host]
    }

    public func setPassword(_ password: String, forHost host: String) throws {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        guard !password.isEmpty else { throw CredentialError.emptyPassword }
        var entries = tolerantLoad()
        entries[host] = password
        try save(entries)
    }

    public func deletePassword(forHost host: String) throws {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        var entries = tolerantLoad()
        guard entries.removeValue(forKey: host) != nil else { return }
        try save(entries)
    }

    // MARK: Storage

    /// Missing is empty; unreadable is an error the user should see.
    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CredentialError.storage(error.localizedDescription)
        }
        guard !data.isEmpty else { return [:] }
        guard let entries = try? JSONDecoder().decode([String: String].self, from: data) else {
            throw CredentialError.storage("the saved password file is not readable")
        }
        return entries
    }

    /// Reads for a *write*, where a corrupt file must not be a dead end.
    ///
    /// Throwing here would leave a user whose file had been damaged unable to save a password ever
    /// again, with no way out but finding and deleting the file by hand. Everything it holds is a
    /// password the user can retype, so starting a fresh one is the recoverable choice. Reads still
    /// report the damage — see ``load()`` — so it is not silent.
    private func tolerantLoad() -> [String: String] {
        (try? load()) ?? [:]
    }

    private func save(_ entries: [String: String]) throws {
        let directory = url.deletingLastPathComponent()
        do {
            // 0700 on the directory, 0600 on the file. Not protection from anything running as
            // this user — see the file header — but it does keep the plaintext out of the reach of
            // other accounts on a shared Mac.
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
            // After the write, not before: an atomic write replaces the file, so permissions set on
            // the old one do not survive.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            excludeFromBackup()
        } catch let error as CredentialError {
            throw error
        } catch {
            throw CredentialError.storage(error.localizedDescription)
        }
    }

    /// Keeps the plaintext out of Time Machine.
    ///
    /// Best-effort: failing to set it is not worth failing the save over, and the cost of it not
    /// being set is that a password the user can retype ends up in a backup.
    private func excludeFromBackup() {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}

/// Non-persistent store for tests and previews. Never written to disk.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func password(forHost host: String) throws -> String? {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        lock.lock(); defer { lock.unlock() }
        return storage[host]
    }

    public func setPassword(_ password: String, forHost host: String) throws {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        guard !password.isEmpty else { throw CredentialError.emptyPassword }
        lock.lock(); defer { lock.unlock() }
        storage[host] = password
    }

    public func deletePassword(forHost host: String) throws {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: host)
    }
}

// MARK: - Vendor defaults

/// The factory-default root passwords, per printer family.
///
/// These are **not secrets**. They are printed on the printer's own touchscreen under
/// *Settings → Root account information*, are identical across every unit of a model, and are
/// already published verbatim in both existing clients and in `root/README.md`. They live here
/// as documented constants so a first-time user does not have to type them.
///
/// | Family | Default    | Source |
/// |--------|------------|--------|
/// | K1     | `creality_2023` | Windows `Resources.resx:146-148` (`k1Psw`), Android `MainActivity.java:1134` |
/// | Hi     | `Creality2024`  | Windows `Resources.resx:149-151` (`hiPsw`), Android `MainActivity.java:1132` |
/// | i7     | `creality_2025` | Android `MainActivity.java:1136` only — **absent from Windows** |
/// | K2 &c. | `creality_2024` | Windows `Resources.resx:161-163` (`k2Psw`), Android `MainActivity.java:1138` |
///
/// Note the capitalisation and separator difference between `Creality2024` (Hi) and
/// `creality_2024` (K2) — it is not a typo in this file.
public enum VendorDefaultPassword {
    public static let k1 = "creality_2023"
    public static let k2 = "creality_2024"
    public static let hi = "Creality2024"
    public static let i7 = "creality_2025"
}
