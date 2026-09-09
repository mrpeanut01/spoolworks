import Foundation
import SpoolworksCore

/// The credential store the app actually uses: a file it owns, keyed by host.
///
/// ## Why this file exists
///
/// The same gap as ``LivePrinterTransport``: `SpoolworksCore` shipped a complete, tested
/// ``SpoolworksCore/FileCredentialStore`` and `PrinterViewModel` defaulted to
/// ``InMemoryPrinterCredentialStore``, which keeps passwords for the lifetime of the process and
/// no longer. The visible symptom was a printer that had to be given its password again on every
/// launch — and, once the CFS poll existed, a 30 s auto-poll that could never run after a restart
/// because `canPoll` was false until someone re-typed it.
///
/// ## The two stores key on different things, deliberately
///
/// `PrinterCredentialStoring` is keyed by ``PrinterType`` because that is what the Printers screen
/// is a list of. The backing store is keyed by **host**, because that is what a password actually
/// belongs to — a machine, not a model of printer. This adapter resolves one to the other through
/// ``PrinterSettings/host(for:)``.
///
/// Keying by host is the better of the two and worth keeping: re-address a printer and it correctly
/// stops finding the old machine's password, rather than silently offering it to a different
/// device.
///
/// ## Failures are reported, not swallowed
///
/// `PrinterCredentialStoring` is non-throwing, so a storage error has nowhere to go through the
/// protocol. Dropping it would make "the file could not be read" look identical to "no password has
/// been saved" — the exact confusion this app avoids elsewhere. Failures therefore go to
/// `onFailure`, which the app wires to the toast centre, and the password is kept in memory for
/// the rest of the session so the user is not blocked mid-task by a storage problem.
final class LocalPrinterCredentialStore: PrinterCredentialStoring {

    private let backing: CredentialStore
    private let hostForFamily: (PrinterType) -> String
    private let onFailure: (String) -> Void

    /// Session fallback for a family whose write failed, plus a small read cache so the Printers
    /// list does not re-read the file once per row per refresh.
    private var cache: [PrinterType: String?] = [:]

    init(backing: CredentialStore,
         hostForFamily: @escaping (PrinterType) -> String = { PrinterSettings.host(for: $0) },
         onFailure: @escaping (String) -> Void = { _ in }) {
        self.backing = backing
        self.hostForFamily = hostForFamily
        self.onFailure = onFailure
    }

    // MARK: PrinterCredentialStoring

    func password(for family: PrinterType) -> String? {
        if let cached = cache[family] { return cached }

        let host = trimmedHost(family)
        // No address means nothing to look the password up under. Not an error — it is the state
        // a printer is in before it has been configured.
        guard !host.isEmpty else { return nil }

        do {
            let stored = try backing.password(forHost: host)
            cache[family] = stored
            return stored
        } catch {
            onFailure("Could not read the saved password for \(family.displayName): \(error)")
            return nil
        }
    }

    func setPassword(_ password: String?, for family: PrinterType) {
        let host = trimmedHost(family)
        guard !host.isEmpty else {
            // Hold it for the session so a password typed before the address is not lost; it is
            // written for real once the host is known and `setPassword` is called again.
            cache[family] = password
            return
        }

        do {
            if let password, !password.isEmpty {
                try backing.setPassword(password, forHost: host)
            } else {
                try backing.deletePassword(forHost: host)
            }
            cache[family] = password
        } catch {
            // Keep it usable for this session rather than failing the user's task outright, and
            // say plainly that it will not survive a relaunch.
            cache[family] = password
            onFailure("The password for \(family.displayName) could not be saved and will be "
                      + "forgotten when Spoolworks quits: \(error)")
        }
    }

    func hasPassword(for family: PrinterType) -> Bool {
        guard let password = password(for: family) else { return false }
        return !password.isEmpty
    }

    /// Drops the cached value for a family — call when its address changes, so the next read looks
    /// under the new host instead of returning the old machine's password.
    func invalidate(_ family: PrinterType) {
        cache[family] = nil
        cache.removeValue(forKey: family)
    }

    private func trimmedHost(_ family: PrinterType) -> String {
        hostForFamily(family).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
