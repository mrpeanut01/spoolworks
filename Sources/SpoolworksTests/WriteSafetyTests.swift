import Foundation
@testable import SpoolworksCore

/// Regression tests for the write-safety defects found in code review.
///
/// Each one corresponds to a way a tag could have been corrupted, or to a failure that would have
/// been reported as success. They are kept together because they share a theme: the expensive
/// mistakes in this project are all "the operation looked fine and wasn't".
private func makeService(_ mock: MockTransport) -> TagService {
    TagService(card: MifareClassicCard(transport: mock), cardType: .mifareClassic1K)
}

private func record() throws -> SpoolRecord {
    try SpoolRecord(materialId: "01001", colorRGB: "00A651", filamentLength: .kg1)
}

/// Blocks actually targeted by an FF D6 update.
private func writtenBlocks(_ mock: MockTransport) -> [Int] {
    mock.log.filter { $0.count == 21 && $0[1] == 0xD6 }.map { Int($0[3]) }
}

let writeSafetyTests = TestSuite(name: "Write safety (review fixes)", cases: [

    // MARK: - Transport failures keep their type

    test("a tag lifted during verification reports the lift, not a key that will not open") { t in
        // Place the fault on the first APDU after the last write, which is verification's
        // re-authentication. The count comes from a clean run so it survives changes to the
        // key order or the backup, rather than being a hard-coded exchange number.
        let clean = MockTransport()
        try makeService(clean).writeTag(record: try record(), allowTrailerWrite: true)
        guard let lastWrite = clean.log.lastIndex(where: { $0.count == 21 && $0[1] == 0xD6 }) else {
            t.expect(false, "the clean run wrote nothing"); return
        }

        let mock = MockTransport()
        mock.failTransmitsAfter = lastWrite + 1
        mock.transportError = PCSCError.cardReset
        // The defect: `try?` around the re-authentication turned the reset into
        // `verificationFailed("the tag would not re-open with the key just written to it")` —
        // a message that says the keys were bricked, for a tag that merely left the field, and
        // a type ReaderMonitor cannot retry. The reset must come out as itself.
        t.throwsError(PCSCError.cardReset) {
            try makeService(mock).writeTag(record: try record(), allowTrailerWrite: true)
        }
    },

    test("a tag lifted while reading sector 2 is reported, not shown as a complete read") { t in
        let programmed = MockTransport()
        try makeService(programmed).writeTag(record: try record(), allowTrailerWrite: true)
        let clean = MockTransport()
        clean.sectorKeys = programmed.sectorKeys
        for block in [4, 5, 6] { clean.setBlock(block, to: programmed.blocks[block]) }
        _ = try makeService(clean).readTag()
        // The last block read of sector 1; the next exchange belongs to sector 2.
        guard let lastRecordRead = clean.log.lastIndex(where: { $0.count == 5 && $0[1] == 0xB0 && $0[3] == 6 }) else {
            t.expect(false, "the clean read never read block 6"); return
        }

        let mock = MockTransport()
        mock.sectorKeys = programmed.sectorKeys
        for block in [4, 5, 6] { mock.setBlock(block, to: programmed.blocks[block]) }
        mock.failTransmitsAfter = lastRecordRead + 1
        // The defect: `try? readSector2` swallowed the dropped card along with a genuinely
        // keyed sector 2, and the read came back looking complete with `sector2 == nil`.
        t.throwsError(PCSCError.noCard) { _ = try makeService(mock).readTag() }
    },

    test("the pre-write backup opens the factory sectors without a reset each") { t in
        // Every failed authentication costs a card reset, and that field churn is what makes
        // the reader drop a stationary tag. Derived-key-first cost a reset on each of the
        // fifteen factory-keyed sectors before the factory key was even tried.
        let mock = MockTransport()
        try makeService(mock).writeTag(record: try record(), allowTrailerWrite: true)
        t.expect(mock.resetCount <= 4, "expected at most a handful of resets, saw \(mock.resetCount)")
    },

    // MARK: - Access-bit validation
    //
    // MIFARE stores C1/C2/C3 twice, plain and inverted. The chip PERMANENTLY LOCKS a sector whose
    // two copies disagree. The original guard rejected exactly one value (00 00 00 00), so a
    // single corrupted bit from a flaky read would be written straight back and brick the sector.

    test("factory access bits are accepted") { t in
        t.expect(TagService.accessBitsAreSelfConsistent([0xFF, 0x07, 0x80]),
                 "FF 07 80 is the factory transport configuration and must pass")
    },

    test("all-zero access bits are rejected") { t in
        t.expect(!TagService.accessBitsAreSelfConsistent([0x00, 0x00, 0x00]))
    },

    test("a single corrupted byte is rejected") { t in
        // FF 07 00: byte 8 corrupted. The old guard passed this and bricked the sector.
        t.expect(!TagService.accessBitsAreSelfConsistent([0xFF, 0x07, 0x00]))
        t.expect(!TagService.accessBitsAreSelfConsistent([0xFF, 0x00, 0x80]))
        t.expect(!TagService.accessBitsAreSelfConsistent([0x00, 0x07, 0x80]))
    },

    test("every single-bit corruption of the factory value is rejected") { t in
        let factory: [UInt8] = [0xFF, 0x07, 0x80]
        var accepted: [String] = []
        for byte in 0..<3 {
            for bit in 0..<8 {
                var corrupted = factory
                corrupted[byte] ^= UInt8(1 << bit)
                if TagService.accessBitsAreSelfConsistent(corrupted) {
                    accepted.append(corrupted.hexString)
                }
            }
        }
        t.equal(accepted, [], "no single-bit corruption may pass validation")
    },

    test("another genuinely valid configuration is accepted") { t in
        // C1=0 C2=0 C3=1 for every block: byte6 = FF, byte7 = 00, byte8 = 0F... verify by
        // construction rather than by memory.
        func encode(c1: UInt8, c2: UInt8, c3: UInt8) -> [UInt8] {
            let b6 = ((~c2 & 0x0F) << 4) | (~c1 & 0x0F)
            let b7 = ((c1 & 0x0F) << 4) | (~c3 & 0x0F)
            let b8 = ((c3 & 0x0F) << 4) | (c2 & 0x0F)
            return [b6, b7, b8]
        }
        for c1: UInt8 in 0...15 {
            let bits = encode(c1: c1, c2: 0x0F - c1, c3: c1 ^ 0x0A)
            t.expect(TagService.accessBitsAreSelfConsistent(bits),
                     "well-formed bits \(bits.hexString) must pass")
        }
    },

    test("rejects a wrong-sized access field") { t in
        t.expect(!TagService.accessBitsAreSelfConsistent([0xFF, 0x07]))
        t.expect(!TagService.accessBitsAreSelfConsistent([]))
    },

    // MARK: - The irreversible operation is gated in the core, not just the UI

    test("programming a blank tag without authorisation writes NOTHING") { t in
        let mock = MockTransport()
        t.throwsError(TagError.trailerWriteNotAuthorised(block: 7)) {
            _ = try makeService(mock).writeTag(record: try record())
        }
        t.equal(writtenBlocks(mock), [],
                "an unauthorised write must not touch a single block, not even the data blocks")
    },

    test("programming a blank tag with authorisation succeeds") { t in
        let mock = MockTransport()
        let result = try makeService(mock).writeTag(record: try record(), allowTrailerWrite: true)
        t.expect(result.wroteTrailer)
        t.expect(writtenBlocks(mock).contains(7))
    },

    // Rewriting an already-programmed tag is reversible, so it needs no authorisation.
    test("rewriting a programmed tag needs no authorisation") { t in
        let mock = MockTransport()
        _ = try makeService(mock).writeTag(record: try record(), allowTrailerWrite: true)
        let second = try makeService(mock).writeTag(record: try record())
        t.expect(!second.wroteTrailer, "the trailer is written once, on first programming")
    },

    // MARK: - An abort must leave the tag untouched
    //
    // The trailer was previously read and validated only AFTER blocks 4-6 were overwritten, so a
    // refusal left new ciphertext on the tag under the old key while reporting that nothing had
    // happened. Validation now precedes the first write.

    test("a corrupt trailer aborts before any data block is written") { t in
        let mock = MockTransport()
        // Corrupt the access bits so validation must refuse.
        var trailer = mock.blocks[7]
        trailer[6] = 0xFF; trailer[7] = 0x07; trailer[8] = 0x00
        mock.setBlock(7, to: trailer)

        t.throwsError("writing against a corrupt trailer") {
            _ = try makeService(mock).writeTag(record: try record(), allowTrailerWrite: true)
        }
        t.equal(writtenBlocks(mock), [],
                "blocks 4-6 must not be written when the trailer is going to be refused")
    },

    // MARK: - The backup survives a failure

    test("the pre-write backup reaches the caller even when the write then fails") { t in
        let mock = MockTransport()
        var trailer = mock.blocks[7]
        trailer[8] = 0x00                     // force a later refusal
        mock.setBlock(7, to: trailer)

        var captured: [MifareClassicCard.SectorDump] = []
        t.throwsError("write that will be refused") {
            _ = try makeService(mock).writeTag(record: try record(),
                                               allowTrailerWrite: true,
                                               onBackup: { captured = $0 })
        }
        t.equal(captured.count, 16, "the backup must be delivered before the failure, not after")
        t.expect(captured.contains { $0.sector == 1 && !$0.authFailed },
                 "and it must include the sector about to be overwritten")
    },

    test("an unreadable record sector aborts rather than writing blind") { t in
        let mock = MockTransport()
        mock.unauthenticatableSectors = [1]
        t.throwsError("write with an uncapturable record sector") {
            _ = try makeService(mock).writeTag(record: try record(), allowTrailerWrite: true)
        }
        t.equal(writtenBlocks(mock), [])
    },

    // MARK: - Sector 2 is verified, not assumed

    test("sector 2 contents are verified after writing") { t in
        let mock = MockTransport()
        let result = try makeService(mock).writeTag(record: try record(),
                                                    printerType: "K2 Plus",
                                                    allowTrailerWrite: true)
        t.expect(result.wroteSector2)
        // Prove the bytes really are on the card, not merely acknowledged.
        let stored = (8...10).flatMap { mock.blocks[$0] }
        let expected = try TagService.sector2Payload(printerType: "K2 Plus")
        t.equal(stored, expected)
    },
])

/// Regressions for the data-integrity and SSH defects found in code review.
let integrityTests = TestSuite(name: "Integrity (review fixes)", cases: [

    // Int(Double) traps when the value does not fit. A printer database carrying 1e300 aborted
    // the whole process instead of failing to decode.
    test("an out-of-range number does not trap the process") { t in
        t.equal(JSONValue.double(1e300).intValue, nil, "1e300 must decline, not crash")
        t.equal(JSONValue.double(-1e300).intValue, nil)
        t.equal(JSONValue.double(.infinity).intValue, nil)
        t.equal(JSONValue.double(.nan).intValue, nil)
        t.equal(JSONValue.string("1e300").intValue, nil)
        t.equal(JSONValue.string("not a number").intValue, nil)
    },

    test("in-range numbers still convert") { t in
        t.equal(JSONValue.int(42).intValue, 42)
        t.equal(JSONValue.double(42.7).intValue, 42, "truncates toward zero")
        t.equal(JSONValue.double(-42.7).intValue, -42)
        t.equal(JSONValue.string("42").intValue, 42)
        t.equal(JSONValue.string("42.7").intValue, 42)
    },

    // A real database with an absurd number must produce a decoding error, not an abort.
    test("a database with an absurd number decodes or errors, but never crashes") { t in
        let json = """
        {"code":0,"msg":"ok","reqId":"0","result":{"count":1,"version":"1","list":[
          {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],
           "kvParam":{},"base":{"id":"01001","name":"X","brand":"Y","meterialType":"PLA",
           "diameter":"1.75","density":1.24,"minTemp":1e300,"maxTemp":240}}]}}
        """
        // The assertion is simply that this returns rather than aborting the test process.
        let decoded = try? MaterialDatabase.decode(Data(json.utf8))
        t.expect(decoded != nil || decoded == nil, "must not trap")
    },
])

/// The SSH invocation is assembled as argv, so these assert on the constructed command without
/// running anything.
let sshInvocationSafetyTests = TestSuite(name: "SSH invocation (review fixes)", cases: [

    // UserKnownHostsFile takes a whitespace-separated LIST. The default path contains a space
    // ("Application Support"), so an unquoted value made ssh pin into a stray `Application` file
    // in the user's ~/Library and left the app-private store empty and unusable.
    test("the known-hosts path is quoted so a space cannot split it") { t in
        let path = "/Users/someone/Library/Application Support/Spoolworks/known_hosts"
        let config = SSHConfiguration(host: "192.168.10.198", knownHostsPath: path)
        let askpass = AskpassLocation(scriptPath: "/tmp/ask.sh", fifoPath: "/tmp/fifo")
        // The invocation is assembled as argv; nothing is spawned and no password is used.
        let invocation = SSHTransport(configuration: config, passwordProvider: { "" })
            .invocation(for: .download(path: "/tmp/x"), askpass: askpass)

        guard let option = t.unwrap(
            invocation.arguments.first(where: { $0.hasPrefix("UserKnownHostsFile=") }),
            "UserKnownHostsFile option") else { return }

        t.equal(option, "UserKnownHostsFile=\"\(path)\"",
                "the value must be quoted, or ssh reads it as two separate files")
        // Nothing carrying that spaced path may reach argv unquoted.
        let unquotedSpaced = invocation.arguments.filter {
            $0.contains("Application Support") && !$0.contains("\"")
        }
        t.equal(unquotedSpaced, [], "no unquoted spaced path may reach argv")
    },
])
