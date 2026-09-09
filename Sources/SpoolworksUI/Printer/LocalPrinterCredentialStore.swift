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
///
/// A failure is reported **once per host**, not once per read. `hasPassword` and the Printers
/// screen's password field are evaluated on every SwiftUI body pass, so an unreported-and-retried
/// failure produced a toast per render against a damaged file. The failed read is remembered like a
/// successful one, and forgotten by the next write or address change, which are the two things
/// that could have fixed it.
final class LocalPrinterCredentialStore: PrinterCredentialStoring {

    private let backing: CredentialStore
    private let hostForFamily: (PrinterType) -> String
    private let onFailure: (String) -> Void

    /// What the last read (or write) under a family's current host resolved to. `.some(nil)` means
    /// "looked, and there is nothing" — including a read that failed and has already been
    /// reported. Also the session fallback for a family whose write failed, and a small read cache
    /// so the Printers list does not re-read the file once per row per refresh.
    private var cache: [PrinterType: String?] = [:]

    /// A password typed before the printer had an address, held separately from the read cache so
    /// that the address arriving — which drops the cache — cannot wipe it. It is written under the
    /// host the moment one is known (see ``invalidate(_:)``).
    private var pending: [PrinterType: String] = [:]

    init(backing: CredentialStore,
         hostForFamily: @escaping (PrinterType) -> String = { PrinterSettings.host(for: $0) },
         onFailure: @escaping (String) -> Void = { _ in }) {
        self.backing = backing
        self.hostForFamily = hostForFamily
        self.onFailure = onFailure
    }

    // MARK: PrinterCredentialStoring

    func password(for family: PrinterType) -> String? {
        let host = trimmedHost(family)
        // No address means nothing to look the password up under. Not an error — it is the state
        // a printer is in before it has been configured — and the only place a password can live
        // until then is the session.
        guard !host.isEmpty else { return pending[family] }

        if let cached = cache[family] { return cached }

        do {
            let stored = try backing.password(forHost: host)
            cache[family] = .some(stored)
            return stored
        } catch {
            // Remembered as "nothing", so the next body pass does not read the file again and
            // raise the same toast again.
            cache[family] = .some(nil)
            onFailure("Could not read the saved password for \(family.displayName): \(error)")
            return nil
        }
    }

    func setPassword(_ password: String?, for family: PrinterType) {
        let host = trimmedHost(family)
        guard !host.isEmpty else {
            // Hold it for the session so a password typed before the address is not lost; it is
            // written for real once the host is known.
            if let password, !password.isEmpty {
                pending[family] = password
            } else {
                pending.removeValue(forKey: family)
            }
            return
        }
        pending.removeValue(forKey: family)
        write(password, forHost: host, family: family)
    }

    func hasPassword(for family: PrinterType) -> Bool {
        guard let password = password(for: family) else { return false }
        return !password.isEmpty
    }

    /// The printer's address changed. Drops the cached value for the family, so the next read looks
    /// under the new host instead of returning the old machine's password — and writes a password
    /// that was typed before there was an address, now that there is one to file it under.
    func invalidate(_ family: PrinterType) {
        cache.removeValue(forKey: family)
        let host = trimmedHost(family)
        guard !host.isEmpty, let held = pending.removeValue(forKey: family) else { return }
        write(held, forHost: host, family: family)
    }

    private func write(_ password: String?, forHost host: String, family: PrinterType) {
        let value = (password?.isEmpty == false) ? password : nil
        do {
            if let value {
                try backing.setPassword(value, forHost: host)
            } else {
                try backing.deletePassword(forHost: host)
            }
            cache[family] = .some(value)
        } catch {
            // Keep it usable for this session rather than failing the user's task outright, and
            // say plainly that it will not survive a relaunch.
            cache[family] = .some(value)
            onFailure("The password for \(family.displayName) could not be saved and will be "
                      + "forgotten when Spoolworks quits: \(error)")
        }
    }

    private func trimmedHost(_ family: PrinterType) -> String {
        hostForFamily(family).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
