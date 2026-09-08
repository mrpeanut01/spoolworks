import Foundation
@testable import SpoolworksUI
import SpoolworksCore

/// A store that always fails, to check that a Keychain problem is reported rather than looking
/// like "no password saved".
private struct FailingCredentialStore: CredentialStore {
    struct Boom: Error, CustomStringConvertible { var description: String { "keychain refused" } }
    func password(forHost host: String) throws -> String? { throw Boom() }
    func setPassword(_ password: String, forHost host: String) throws { throw Boom() }
    func deletePassword(forHost host: String) throws { throw Boom() }
}

/// Hosts the adapter should resolve, without touching UserDefaults.
private final class Hosts {
    var map: [PrinterType: String] = [:]
    func host(_ family: PrinterType) -> String { map[family] ?? "" }
}

let keychainCredentialAdapterTests = TestSuite(name: "Keychain credential adapter", cases: [

    // These never touch the real Keychain: the adapter takes a CredentialStore, so the tests
    // supply an in-memory one. A test suite that wrote to the user's login keychain would be
    // leaving litter on the machine that ran it.
    test("a password round-trips through the store, keyed by host") { t in
        let hosts = Hosts()
        hosts.map[.k2] = "192.168.1.42"
        let keychain = InMemoryCredentialStore()
        let store = KeychainPrinterCredentialStore(keychain: keychain,
                                                   hostForFamily: hosts.host)

        t.expect(!store.hasPassword(for: .k2), "nothing saved yet")
        store.setPassword("hunter2", for: .k2)
        t.equal(store.password(for: .k2), "hunter2", "read back")
        t.expect(store.hasPassword(for: .k2), "reported as available")
        // Keyed by the machine, not the model.
        t.equal(try keychain.password(forHost: "192.168.1.42"), "hunter2", "stored under the host")
    },

    test("a printer with no address yet is not an error") { t in
        let hosts = Hosts()
        let store = KeychainPrinterCredentialStore(keychain: InMemoryCredentialStore(),
                                                   hostForFamily: hosts.host)
        t.expect(store.password(for: .k2) == nil, "no password")
        t.expect(!store.hasPassword(for: .k2), "and no claim of one")
    },

    // Typing a password before the address should not silently lose it.
    test("a password set before the address is kept for the session and written later") { t in
        let hosts = Hosts()
        let keychain = InMemoryCredentialStore()
        let store = KeychainPrinterCredentialStore(keychain: keychain, hostForFamily: hosts.host)

        store.setPassword("early", for: .k2)
        t.equal(store.password(for: .k2), "early", "held in the session")

        hosts.map[.k2] = "printer.local"
        store.setPassword("early", for: .k2)
        t.equal(try keychain.password(forHost: "printer.local"), "early", "written once the host is known")
    },

    test("clearing a password deletes the stored item") { t in
        let hosts = Hosts()
        hosts.map[.k1] = "10.0.0.9"
        let keychain = InMemoryCredentialStore()
        let store = KeychainPrinterCredentialStore(keychain: keychain, hostForFamily: hosts.host)

        store.setPassword("secret", for: .k1)
        store.setPassword(nil, for: .k1)
        t.expect(try keychain.password(forHost: "10.0.0.9") == nil, "removed from the store")
        t.expect(!store.hasPassword(for: .k1), "and reported as absent")
    },

    // "The Keychain refused us" must not read as "no password has been saved".
    test("a keychain failure is reported, and the session is not blocked") { t in
        let hosts = Hosts()
        hosts.map[.k2] = "192.168.1.42"
        var reported: [String] = []
        let store = KeychainPrinterCredentialStore(keychain: FailingCredentialStore(),
                                                   hostForFamily: hosts.host,
                                                   onFailure: { reported.append($0) })

        store.setPassword("hunter2", for: .k2)
        t.equal(reported.count, 1, "the failure is surfaced")
        t.expect(reported[0].contains("forgotten when Spoolworks quits"),
                 "and says plainly what the consequence is")
        t.equal(store.password(for: .k2), "hunter2", "still usable for this session")
    },

    // The Keychain is keyed by host, so a re-addressed printer must stop answering with the old
    // machine's password.
    test("re-addressing a printer drops the cached password") { t in
        let hosts = Hosts()
        hosts.map[.k2] = "old.local"
        let keychain = InMemoryCredentialStore()
        let store = KeychainPrinterCredentialStore(keychain: keychain, hostForFamily: hosts.host)

        store.setPassword("old-secret", for: .k2)
        t.equal(store.password(for: .k2), "old-secret", "cached")

        hosts.map[.k2] = "new.local"
        store.invalidate(.k2)
        t.expect(store.password(for: .k2) == nil, "the new machine has no password of its own")
        t.equal(try keychain.password(forHost: "old.local"), "old-secret",
                "the old machine's password is left alone, not deleted")
    },
])
