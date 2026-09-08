import Foundation
@testable import SpoolworksCore

// Regression tests for the reader / PC/SC layer's failure handling.
//
// Every case here pins a distinction the code used to collapse: a wrong key versus a dead link,
// a complete backup versus a partial one, a bad index versus a crash, a malformed buffer versus
// a walk off the end of it. The common shape of all four bugs was the same — a `try?` or an
// unbounded read turning "something went wrong" into "nothing went wrong", which is exactly the
// class of failure a backup-before-write flow cannot tolerate.

private let secretKey = MifareKey(hex: "A0A1A2A3A4A5")!

/// A transport error that is not a `PCSCError` at all, to prove nothing is being caught by type
/// alone. Modelled on what a real driver-level failure looks like from Swift: opaque.
private struct LinkDown: Error, Equatable {}

let readerRobustnessTests = TestSuite(name: "Reader robustness", cases: [

    // MARK: - A dead link is not a wrong key

    // `authenticateAny` used to wrap `authenticate` in `try?`, which swallowed every transport
    // error along with the wrong-key case. A tag lifted off the antenna mid-sequence therefore
    // walked the whole key x keytype matrix and then reported `authenticationFailed`, sending the
    // user hunting for a key problem that did not exist.
    test("a transport error during authenticateAny propagates instead of becoming authenticationFailed") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.transportError = PCSCError.noCard
        mock.failTransmitsAfter = 1          // loadKey succeeds; the authenticate that follows dies

        t.throwsError(PCSCError.noCard) {
            _ = try card.authenticateAny(sector: 1, keys: [.default, secretKey])
        }
    },

    test("a non-PCSC transport error propagates too") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.transportError = LinkDown()
        mock.failTransmitsAfter = 1

        t.throwsError(LinkDown()) {
            _ = try card.authenticateAny(sector: 1, keys: [.default])
        }
    },

    // The other half of the distinction: a card-level status word still means "try the next key".
    test("a card status word is still treated as a failed key, not an error") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.sectorKeys[1] = .init(keyA: secretKey, keyB: secretKey)

        let result = try card.authenticateAny(sector: 1, keys: [.default, secretKey])
        t.equal(result.key, secretKey, "the wrong first key must not abort the search")
    },

    test("a locked sector still reports authenticationFailed, naming the sector") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.unauthenticatableSectors = [3]

        t.throwsError(PCSCError.authenticationFailed(sector: 3)) {
            _ = try card.authenticateAny(sector: 3, keys: [.default])
        }
    },

    // MARK: - dumpAll reports what it could not capture

    // The old `SectorDump` collapsed every outcome to `authFailed: Bool`, and `try? readBlock`
    // dropped unreadable blocks without trace. A sector could therefore come back marked good
    // with blocks missing from it — and that dump is the safety backup taken before a write.
    test("dumpAll reports a partial capture rather than a silently short sector") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.unreadableBlocks = [14]         // sector 3 opens, but block 14 will not come back

        let dumps = try card.dumpAll()
        guard let sector3 = t.unwrap(dumps.first { $0.sector == 3 }, "sector 3") else { return }

        let expected = MifareClassicCard.SectorDump.Failure.read(
            block: 14, error: PCSCError.statusWord(sw1: 0x6A, sw2: 0x82))
        t.equal(sector3.blocks.count, 3, "the three readable blocks must still be captured")
        t.expect(sector3.blocks[14] == nil, "the unreadable block must be absent")
        t.equal(sector3.failure, expected, "the dump must say which block failed and why")
        t.expect(!sector3.isComplete, "a partial sector is not a complete capture")
        t.expect(sector3.authFailed, "and must not present to callers as a usable backup")
        t.expect(sector3.key != nil, "the key that did open the sector is still worth reporting")
    },

    test("dumpAll distinguishes an unopened sector from a partially read one") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.unauthenticatableSectors = [5]
        mock.unreadableBlocks = [8]

        let dumps = try card.dumpAll()
        t.equal(dumps[5].failure, MifareClassicCard.SectorDump.Failure.authentication,
                "sector 5 never opened")
        t.expect(dumps[5].blocks.isEmpty)
        t.expect(dumps[5].key == nil)

        guard let sector2 = t.unwrap(dumps[2].failure, "sector 2 failure") else { return }
        if case let .read(block, _) = sector2 {
            t.equal(block, 8, "sector 2 opened but block 8 did not read")
        } else {
            t.expect(false, "sector 2 must report a read failure, got \(sector2)")
        }
        t.equal(dumps[2].blocks.count, 3, "the rest of sector 2 is still captured")
    },

    test("dumpAll of a healthy card reports no failures at all") { t in
        let card = MifareClassicCard(transport: MockTransport())
        let dumps = try card.dumpAll()
        t.equal(dumps.count, 16)
        t.expect(dumps.allSatisfy(\.isComplete), "nothing should be flagged on a blank card")
        t.expect(dumps.allSatisfy { $0.blocks.count == 4 }, "every block of every sector")
    },

    // The manufactured-empty-backup case: a card that dies mid-dump must not return a dump.
    test("dumpAll rethrows a transport failure rather than manufacturing an empty backup") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.transportError = PCSCError.noCard
        mock.failTransmitsAfter = 6          // a few sectors in, then the card is gone

        t.throwsError(PCSCError.noCard) { _ = try card.dumpAll() }
    },

    test("a SectorDump failure describes itself for the UI and the diagnostics dump") { t in
        let auth = MifareClassicCard.SectorDump.Failure.authentication
        t.equal(auth.description, "no key opened the sector")
        let read = MifareClassicCard.SectorDump.Failure.read(block: 14,
                                                            error: .statusWord(sw1: 0x6A, sw2: 0x82))
        t.expect(read.description.contains("block 14"), "got: \(read.description)")
    },

    // MARK: - Block bounds

    // `authenticate`, `readBlock` and `writeBlock` are public, take an `Int`, and used to convert
    // it with `UInt8(block)` — a `fatalError` outside 0...255, and no `< blockCount` check at all.
    // A trap is not something a caller can handle, so these have to be errors.
    test("out-of-range block indices throw rather than trapping") { t in
        let card = MifareClassicCard(transport: MockTransport())
        let sixteen = [UInt8](repeating: 0, count: 16)

        for block in [64, 256, 300, -1] {
            t.throwsError(PCSCError.blockOutOfRange(block: block, count: 64)) {
                _ = try card.readBlock(block)
            }
            t.throwsError(PCSCError.blockOutOfRange(block: block, count: 64)) {
                _ = try card.authenticate(block: block, keyType: .keyA)
            }
            t.throwsError(PCSCError.blockOutOfRange(block: block, count: 64)) {
                try card.writeBlock(block, data: sixteen)
            }
        }
    },

    test("the bounds check runs before anything is transmitted") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        t.throwsError("write to block 200") {
            try card.writeBlock(200, data: [UInt8](repeating: 0xAA, count: 16))
        }
        t.expect(mock.log.isEmpty, "an out-of-range write must not reach the card")
    },

    test("authenticateAny rejects a sector outside the card before loading a key") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        t.throwsError("authenticateAny on sector 20") {
            _ = try card.authenticateAny(sector: 20, keys: [.default])
        }
        t.expect(mock.log.isEmpty, "no key should have been loaded for a sector that cannot exist")
    },

    test("every in-range block is accepted") { t in
        let card = MifareClassicCard(transport: MockTransport())
        for block in MifareClassicCard.blockRange {
            t.noThrow("validate block \(block)") { try MifareClassicCard.validate(block: block) }
        }
        _ = try card.authenticateAny(sector: 15, keys: [.default])
        t.noThrow("read the last block") { _ = try card.readBlock(63) }
    },

    // MARK: - Trailer geometry

    // `block % 4 == 3` is 1K arithmetic. On a 4K card, sectors 32-39 hold sixteen blocks, so
    // their trailers are at `block % 16 == 15` — and 1K arithmetic would call block 131 a trailer
    // (it is data) while waving block 143 through as data (it is a real trailer), defeating the
    // `allowTrailer` gate on the one operation that can permanently brick a sector.
    test("trailer detection is card-type aware above block 128") { t in
        t.expect(MifareClassicCard.isTrailer(block: 143, cardType: .mifareClassic4K),
                 "block 143 is the trailer of 4K sector 32")
        t.expect(!MifareClassicCard.isTrailer(block: 131, cardType: .mifareClassic4K),
                 "block 131 is data on a 4K card")
        t.expect(MifareClassicCard.isTrailer(block: 127, cardType: .mifareClassic4K),
                 "below 128 a 4K card has the same four-block sectors as a 1K")
        t.expect(!MifareClassicCard.isTrailer(block: 126, cardType: .mifareClassic4K))
    },

    test("the 1K default is unchanged and enforced by the block range") { t in
        t.expect(MifareClassicCard.isTrailer(block: 3))
        t.expect(MifareClassicCard.isTrailer(block: 63))
        t.expect(!MifareClassicCard.isTrailer(block: 4))
        t.equal(MifareClassicCard.blockRange, 0..<64)
        // The 1K assumption cannot be reached with a 4K block index, because no public entry
        // point accepts one.
        t.throwsError("a 4K block index on a 1K card") {
            try MifareClassicCard.validate(block: 143)
        }
    },

    // MARK: - Reader-name multi-string parsing

    // `String(cString:)` walks to the next NUL with no upper bound: the old `while offset < len`
    // guarded only where each name STARTED. And its U+FFFD substitution for invalid UTF-8 made
    // `utf8.count` larger than the bytes consumed, desynchronising the cursor for every name
    // after a non-UTF-8 one.
    test("parses a well-formed reader multi-string") { t in
        let buf = multiString(["ACS ACR1552 1S CL Reader(1)", "ACS ACR1552 1S CL Reader(2)"])
        t.equal(PCSCContext.parseReaderNames(buf, length: buf.count),
                ["ACS ACR1552 1S CL Reader(1)", "ACS ACR1552 1S CL Reader(2)"])
    },

    test("an unterminated final name does not read past the buffer") { t in
        // No trailing NUL at all: the strlen walk had nothing to stop it.
        let buf = chars("Reader One") + [0] + chars("Reader Two")
        t.equal(PCSCContext.parseReaderNames(buf, length: buf.count), ["Reader One", "Reader Two"])
    },

    test("a length larger than the buffer is clamped, not trusted") { t in
        let buf = multiString(["Reader"])
        t.equal(PCSCContext.parseReaderNames(buf, length: 4096), ["Reader"])
        t.equal(PCSCContext.parseReaderNames([], length: 4096), [])
        t.equal(PCSCContext.parseReaderNames(buf, length: -1), [])
        t.equal(PCSCContext.parseReaderNames(buf, length: 0), [])
    },

    test("a length shorter than the buffer truncates rather than over-reading") { t in
        let buf = multiString(["Reader One", "Reader Two"])
        // Stop the parse inside the first name; it must yield that prefix and nothing more.
        t.equal(PCSCContext.parseReaderNames(buf, length: 6), ["Reader"])
    },

    test("an invalid-UTF-8 name does not desynchronise the names after it") { t in
        // 0xFF is not valid UTF-8 anywhere. `String(cString:)` replaced it with a 3-byte U+FFFD,
        // so `utf8.count` over-counted and the cursor landed mid-way through the next name.
        let buf = chars("Bad") + [CChar(bitPattern: 0xFF)] + [0]
                + chars("Good Reader") + [0, 0]
        let names = PCSCContext.parseReaderNames(buf, length: buf.count)
        t.equal(names.count, 2, "got \(names)")
        t.equal(names.last, "Good Reader", "the name after a non-UTF-8 one must survive intact")
    },

    test("the double NUL ends the list and trailing padding is ignored") { t in
        let buf = chars("Reader") + [0, 0] + [CChar](repeating: 0x41, count: 8)
        t.equal(PCSCContext.parseReaderNames(buf, length: buf.count), ["Reader"])
    },

    test("no readers is an empty list, not an empty name") { t in
        t.equal(PCSCContext.parseReaderNames([0, 0], length: 2), [])
    },

    // MARK: - Key derivation guards

    // `deriveSectorKey` guarded only `!uid.isEmpty`, so a 7-byte UID tiled happily into a
    // plausible six-byte key that no tag would ever accept. `TagService` checks the length, but
    // `TagMemoryView` and `SpoolworksDiag` call this directly.
    test("deriveSectorKey rejects a 7-byte UID") { t in
        t.throwsError(CrealityCrypto.CryptoError.badUIDLength(7)) {
            _ = try CrealityCrypto.deriveSectorKey(uid: [1, 2, 3, 4, 5, 6, 7])
        }
    },

    test("deriveSectorKey rejects every non-4-byte UID") { t in
        for length in [0, 1, 3, 5, 8, 10, 16] {
            t.throwsError(CrealityCrypto.CryptoError.badUIDLength(length)) {
                _ = try CrealityCrypto.deriveSectorKey(uid: [UInt8](repeating: 0xAB, count: length))
            }
        }
        t.noThrow("a 4-byte UID") {
            _ = try CrealityCrypto.deriveSectorKey(uid: [0x80, 0xA6, 0x79, 0x39])
        }
    },

    // MARK: - Status-code mapping

    // These three codes were declared and never mapped. SCARD_W_RESET_CARD is the one that
    // matters: it means another application reset the card, it is recoverable mid-write, and it
    // used to surface as an opaque hex string.
    test("previously unmapped PC/SC status codes now have meanings") { t in
        t.equal(PCSCError.from(PCSCError.Code.resetCard), PCSCError.cardReset)
        t.equal(PCSCError.from(PCSCError.Code.timeout), PCSCError.timedOut)
        t.equal(PCSCError.from(PCSCError.Code.cancelled), PCSCError.cancelled)
        t.expect(PCSCError.from(0) == nil, "success is not an error")
        // Anything genuinely unknown still falls through to the raw code.
        guard let unknown = t.unwrap(PCSCError.from(Int32(bitPattern: 0x8010_00FF))) else { return }
        if case .pcsc = unknown {} else {
            t.expect(false, "an unknown code must still report itself, got \(unknown)")
        }
    },

    test("mapped codes carry a message a user can act on") { t in
        t.expect(PCSCError.cardReset.errorDescription?.contains("reset") == true,
                 "got: \(PCSCError.cardReset.errorDescription ?? "nil")")
        t.expect(PCSCError.blockOutOfRange(block: 99, count: 64).errorDescription?.contains("99") == true)
        t.expect(PCSCError.timedOut.errorDescription != nil)
        t.expect(PCSCError.cancelled.errorDescription != nil)
    },

    // MARK: - Key-type order

    // `MifareClassicCard` defaulted to [.keyB, .keyA] while `TagService` passed [.keyA, .keyB],
    // each with a comment claiming its order was the right one. Behaviour was well-defined only
    // because TagService always passed its own; the defaults now agree with it.
    test("the default key-type order is key A first, matching TagService") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        // Both key types hold the default key, so whichever is tried first is the one that wins.
        let result = try card.authenticateAny(sector: 2, keys: [.default])
        t.equal(result.keyType, .keyA, "key A must be attempted before key B")

        // And the emitted APDU says so: byte 8 of the authenticate command is the key type.
        guard let auth = t.unwrap(mock.log.first { $0.count == 10 && $0[1] == 0x86 },
                                  "authenticate APDU") else { return }
        t.equal(auth[8], MifareKeyType.keyA.rawValue)
    },

    test("key B is still reached as a fallback") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.sectorKeys[1] = .init(keyA: secretKey, keyB: .default)
        let result = try card.authenticateAny(sector: 1, keys: [.default])
        t.equal(result.keyType, .keyB, "key A fails 69 82, key B must be tried with the same key")
    },
])

// MARK: - Helpers

private func chars(_ s: String) -> [CChar] {
    Array(s.utf8).map { CChar(bitPattern: $0) }
}

/// Builds a PC/SC multi-string: NUL-separated names, double-NUL terminated.
private func multiString(_ names: [String]) -> [CChar] {
    names.flatMap { chars($0) + [0] } + [0]
}
