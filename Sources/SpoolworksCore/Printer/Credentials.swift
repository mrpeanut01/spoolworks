import Foundation
import Security

// SPEC-04 §1.4 / §11.5 — the Windows app persists the root password in **cleartext** in
// `HKCU\CFS RFID\Settings` under `psw_<PrinterName>` and displays it in a `TextBox` with no
// `PasswordChar`, i.e. unmasked on screen. The Android app keeps it in SharedPreferences.
//
// The macOS port does neither. User-entered passwords go into the login Keychain, keyed by the
// host string the user typed (the same key the Windows app uses for its saved settings), and
// there is no plaintext fallback: if the Keychain is unavailable the operation fails rather
// than silently degrading to a file.

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
    case keychain(status: OSStatus)

    public var description: String {
        switch self {
        case .emptyHost:      return "A printer address is required."
        case .emptyPassword:  return "A password is required."
        case .corruptItem(let host):
            return "The saved password for \(host) is unreadable and should be re-entered."
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain error: \(detail)"
        }
    }
}

/// Keychain-backed store. The real implementation.
///
/// Items are generic passwords with `kSecAttrService` fixed and `kSecAttrAccount` set to the
/// host. Accessibility is `WhenUnlockedThisDeviceOnly`: a printer password is machine-local
/// operational data and has no business syncing to iCloud or restoring onto another Mac.
public struct KeychainCredentialStore: CredentialStore {

    /// Namespace for our items. Kept out of the account field so `deleteAll` is possible and so
    /// a host named like ours cannot collide with another app's items.
    public let service: String

    public init(service: String = "com.spoolworks.printer.ssh") {
        self.service = service
    }

    private func baseQuery(host: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host,
        ]
    }

    public func password(forHost host: String) throws -> String? {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        var query = baseQuery(host: host)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { throw CredentialError.corruptItem(host: host) }
            guard let password = String(data: data, encoding: .utf8) else {
                throw CredentialError.corruptItem(host: host)
            }
            return password
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialError.keychain(status: status)
        }
    }

    public func setPassword(_ password: String, forHost host: String) throws {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        guard !password.isEmpty else { throw CredentialError.emptyPassword }
        let secret = Data(password.utf8)

        // Update first; SecItemAdd on an existing item returns errSecDuplicateItem.
        let updateStatus = SecItemUpdate(baseQuery(host: host) as CFDictionary,
                                         [kSecValueData as String: secret] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CredentialError.keychain(status: updateStatus)
        }

        var insert = baseQuery(host: host)
        insert[kSecValueData as String] = secret
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        insert[kSecAttrLabel as String] = "Spoolworks printer (\(host))"
        insert[kSecAttrDescription as String] = "Creality printer root SSH password"
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CredentialError.keychain(status: addStatus) }
    }

    public func deletePassword(forHost host: String) throws {
        guard !host.isEmpty else { throw CredentialError.emptyHost }
        let status = SecItemDelete(baseQuery(host: host) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialError.keychain(status: status)
        }
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
/// as documented constants so a first-time user does not have to type them; anything the user
/// actually enters goes to the Keychain (above) and never to a file.
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
