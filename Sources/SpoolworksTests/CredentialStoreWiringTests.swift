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
        let store = LocalPrinterCredentialStore(backing: keychain,
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
        let store = LocalPrinterCredentialStore(backing: InMemoryCredentialStore(),
                                                   hostForFamily: hosts.host)
        t.expect(store.password(for: .k2) == nil, "no password")
        t.expect(!store.hasPassword(for: .k2), "and no claim of one")
    },

    // Typing a password before the address should not silently lose it.
    test("a password set before the address is kept for the session and written later") { t in
        let hosts = Hosts()
        let keychain = InMemoryCredentialStore()
        let store = LocalPrinterCredentialStore(backing: keychain, hostForFamily: hosts.host)

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
        let store = LocalPrinterCredentialStore(backing: keychain, hostForFamily: hosts.host)

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
        let store = LocalPrinterCredentialStore(backing: FailingCredentialStore(),
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
        let store = LocalPrinterCredentialStore(backing: keychain, hostForFamily: hosts.host)

        store.setPassword("old-secret", for: .k2)
        t.equal(store.password(for: .k2), "old-secret", "cached")

        hosts.map[.k2] = "new.local"
        store.invalidate(.k2)
        t.expect(store.password(for: .k2) == nil, "the new machine has no password of its own")
        t.equal(try keychain.password(forHost: "old.local"), "old-secret",
                "the old machine's password is left alone, not deleted")
    },
])

// MARK: - The file the passwords actually live in

private func withTemporaryStore(_ body: (FileCredentialStore, URL) throws -> Void) rethrows {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-creds-\(UUID().uuidString)", isDirectory: true)
    let url = directory.appendingPathComponent("printer-credentials.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(FileCredentialStore(url: url), url)
}

let fileCredentialStoreTests = TestSuite(name: "File credential store", cases: [

    test("a password round-trips, and an unknown host has none") { t in
        try withTemporaryStore { store, _ in
            t.equal(try store.password(forHost: "192.168.10.19"), nil, "nothing saved yet")
            try store.setPassword("hunter2", forHost: "192.168.10.19")
            t.equal(try store.password(forHost: "192.168.10.19"), "hunter2", "saved")
            t.equal(try store.password(forHost: "192.168.10.20"), nil, "a different host is separate")
        }
    },

    test("the file is owner-only, and stays that way after a rewrite") { t in
        try withTemporaryStore { store, url in
            try store.setPassword("hunter2", forHost: "printer")
            // An atomic write replaces the file, so permissions have to be reapplied every time —
            // getting this right once and losing it on the second save would be the easy mistake.
            try store.setPassword("hunter3", forHost: "printer")

            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
            t.equal(mode, 0o600, "file is rw for the owner and nothing else")

            let directory = try FileManager.default.attributesOfItem(
                atPath: url.deletingLastPathComponent().path)
            t.equal((directory[.posixPermissions] as? NSNumber)?.intValue, 0o700, "and so is its directory")
        }
    },

    test("passwords for several printers coexist and delete independently") { t in
        try withTemporaryStore { store, _ in
            try store.setPassword("a", forHost: "k1.local")
            try store.setPassword("b", forHost: "k2.local")
            try store.deletePassword(forHost: "k1.local")
            t.equal(try store.password(forHost: "k1.local"), nil, "the deleted one is gone")
            t.equal(try store.password(forHost: "k2.local"), "b", "the other is untouched")

            // Deleting something that was never there is not an error.
            t.noThrow("deleting a missing host") { try store.deletePassword(forHost: "nope.local") }
        }
    },

    test("a damaged file is reported on read but does not become a dead end") { t in
        try withTemporaryStore { store, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data("not json".utf8).write(to: url)

            // Read says so, rather than pretending no password was ever saved.
            t.throwsError("reading a damaged file") { _ = try store.password(forHost: "printer") }

            // But a write recovers: everything in here is a password the user can retype, and
            // throwing would leave them unable to save one ever again without finding the file.
            t.noThrow("writing over it") { try store.setPassword("fresh", forHost: "printer") }
            t.equal(try store.password(forHost: "printer"), "fresh", "and it reads back")
        }
    },

    test("empty host and empty password are refused, as they were before") { t in
        withTemporaryStore { store, _ in
            t.throwsError(CredentialError.emptyHost) { try store.setPassword("x", forHost: "") }
            t.throwsError(CredentialError.emptyPassword) { try store.setPassword("", forHost: "h") }
            t.throwsError(CredentialError.emptyHost) { _ = try store.password(forHost: "") }
            t.throwsError(CredentialError.emptyHost) { try store.deletePassword(forHost: "") }
        }
    },

    test("nothing is written until there is something to write") { t in
        try withTemporaryStore { store, url in
            _ = try store.password(forHost: "printer")
            t.expect(!FileManager.default.fileExists(atPath: url.path),
                     "a read does not create the file")
        }
    },
])
