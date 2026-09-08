import Foundation
@testable import SpoolworksCore

let hexTests = TestSuite(name: "Hex helpers", cases: [
    test("round-trips bytes and hex") { t in
        let bytes: [UInt8] = [0x80, 0xA6, 0x79, 0x39, 0x00, 0xFF]
        t.equal(bytes.hexString, "80A6793900FF")
        t.equal(bytes.hexStringSpaced, "80 A6 79 39 00 FF")
        t.equal([UInt8](hexString: "80A6793900FF"), bytes)
        t.equal([UInt8](hexString: "80 A6 79 39 00 FF"), bytes, "spaces must be tolerated")
    },

    test("rejects malformed hex") { t in
        t.expect([UInt8](hexString: "ABC") == nil, "odd-length hex must fail")
        t.expect([UInt8](hexString: "ZZ") == nil, "non-hex digits must fail")
    },

    test("ASCII dump replaces non-printables") { t in
        t.equal(Array("AB\u{01}c".utf8).asciiDump, "AB.c")
    },
])

let mifareKeyTests = TestSuite(name: "MIFARE key", cases: [
    test("default key is FFFFFFFFFFFF") { t in
        t.equal(MifareKey.default.bytes, [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        t.equal(MifareKey.default.description, "FFFFFFFFFFFF")
    },

    test("rejects wrong length") { t in
        t.expect(MifareKey(bytes: [0xFF, 0xFF]) == nil, "2-byte key must be rejected")
        t.expect(MifareKey(hex: "FFFF") == nil, "short hex must be rejected")
    },

    test("parses hex") { t in
        t.equal(MifareKey(hex: "A0A1A2A3A4A5")?.bytes, [0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5])
    },
])

let cardTypeTests = TestSuite(name: "Card type from ATR", cases: [
    // The exact ATR read from the ACR1552 during hardware probing.
    test("identifies the real Classic 1K ATR from hardware") { t in
        guard let atr = t.unwrap([UInt8](hexString: "3B8F8001804F0CA000000306030001000000006A"),
                                 "ATR") else { return }
        t.equal(CardType.from(atr: atr), .mifareClassic1K)
        t.expect(CardType.from(atr: atr).isSupported, "Classic 1K must be supported")
    },

    test("identifies other card types") { t in
        func atr(_ code: String) -> [UInt8] {
            [UInt8](hexString: "3B8F8001804F0CA0000003060300" + code + "000000006A") ?? []
        }
        t.equal(CardType.from(atr: atr("02")), .mifareClassic4K)
        t.equal(CardType.from(atr: atr("03")), .mifareUltralight)
        t.expect(!CardType.from(atr: atr("03")).isSupported, "Ultralight carries no spool layout")
    },

    test("unrecognised ATR is unknown") { t in
        t.equal(CardType.from(atr: [0x3B, 0x00]), .unknown)
    },
])

let mifareGeometryTests = TestSuite(name: "MIFARE geometry", cases: [
    test("block and sector arithmetic") { t in
        t.equal(MifareClassicCard.firstBlock(ofSector: 0), 0)
        t.equal(MifareClassicCard.firstBlock(ofSector: 1), 4)
        t.equal(MifareClassicCard.trailerBlock(ofSector: 1), 7)
        t.equal(MifareClassicCard.sector(ofBlock: 6), 1)
        t.equal(MifareClassicCard.sector(ofBlock: 63), 15)
    },

    test("trailer and manufacturer block detection") { t in
        t.expect(MifareClassicCard.isTrailer(block: 3), "block 3 is a trailer")
        t.expect(MifareClassicCard.isTrailer(block: 63), "block 63 is a trailer")
        t.expect(!MifareClassicCard.isTrailer(block: 4), "block 4 is data")
        t.expect(MifareClassicCard.isManufacturer(block: 0), "block 0 is the manufacturer block")
        t.expect(!MifareClassicCard.isManufacturer(block: 1), "block 1 is not")
    },
])

private func makeCard() -> (MockTransport, MifareClassicCard) {
    let mock = MockTransport()
    return (mock, MifareClassicCard(transport: mock))
}

let mifareCardTests = TestSuite(name: "MIFARE Classic card operations", cases: [
    test("reads UID") { t in
        let (_, card) = makeCard()
        t.equal(try card.readUID(), [0x80, 0xA6, 0x79, 0x39])
    },

    test("authenticates with the default key") { t in
        let (_, card) = makeCard()
        try card.loadKey(.default)
        t.expect(try card.authenticate(block: 4, keyType: .keyA), "default key should open a blank sector")
    },

    // A wrong key is an expected outcome during key discovery, not an error condition.
    test("wrong key returns false rather than throwing") { t in
        let (mock, card) = makeCard()
        mock.sectorKeys[1].keyA = MifareKey(hex: "A0A1A2A3A4A5")!
        try card.loadKey(.default)
        t.equal(try card.authenticate(block: 4, keyType: .keyA), false)
    },

    test("authenticateAny finds the working key") { t in
        let (mock, card) = makeCard()
        let secret = MifareKey(hex: "A0A1A2A3A4A5")!
        mock.sectorKeys[1] = .init(keyA: secret, keyB: secret)
        let result = try card.authenticateAny(sector: 1, keys: [.default, secret])
        t.equal(result.key, secret)
    },

    test("authenticateAny throws when no key works") { t in
        let (mock, card) = makeCard()
        mock.unauthenticatableSectors = [1]
        t.throwsError(PCSCError.authenticationFailed(sector: 1)) {
            _ = try card.authenticateAny(sector: 1, keys: [.default])
        }
    },

    test("reading requires prior authentication") { t in
        let (_, card) = makeCard()
        t.throwsError(PCSCError.statusWord(sw1: 0x69, sw2: 0x82)) {
            _ = try card.readBlock(4)
        }
    },

    test("write then read round-trips") { t in
        let (_, card) = makeCard()
        guard let payload = t.unwrap([UInt8](hexString: "AB1240276A21010010FFFFFF01650000")) else { return }
        _ = try card.authenticateAny(sector: 1, keys: [.default])
        try card.writeBlock(4, data: payload)
        t.equal(try card.readBlock(4), payload)
    },

    // MARK: - Safety rails (DECISIONS D-006)

    test("refuses to write the manufacturer block") { t in
        let (_, card) = makeCard()
        _ = try card.authenticateAny(sector: 0, keys: [.default])
        t.throwsError("writing block 0") {
            try card.writeBlock(0, data: [UInt8](repeating: 0, count: 16))
        }
    },

    test("refuses a trailer write without explicit opt-in") { t in
        let (_, card) = makeCard()
        _ = try card.authenticateAny(sector: 1, keys: [.default])
        t.throwsError("writing block 7 without opt-in") {
            try card.writeBlock(7, data: [UInt8](repeating: 0, count: 16))
        }
    },

    test("allows a trailer write with explicit opt-in") { t in
        let (_, card) = makeCard()
        _ = try card.authenticateAny(sector: 1, keys: [.default])
        // Write a trailer that installs a NEW key, so the re-key path is exercised.
        guard let newKey = t.unwrap(MifareKey(hex: "A0A1A2A3A4A5")),
              let trailer = t.unwrap([UInt8](hexString: "A0A1A2A3A4A5FF078069A0A1A2A3A4A5")) else { return }
        t.noThrow("opted-in trailer write") { try card.writeBlock(7, data: trailer, allowTrailer: true) }

        // A real card drops authentication when a sector is re-keyed, and the old key no longer
        // opens it. Reading back therefore requires re-authenticating with the key just written.
        t.throwsError("reading a re-keyed sector without re-authenticating") {
            _ = try card.readBlock(7)
        }
        t.throwsError(PCSCError.authenticationFailed(sector: 1)) {
            _ = try card.authenticateAny(sector: 1, keys: [.default])
        }
        _ = try card.authenticateAny(sector: 1, keys: [newKey])
        t.equal(try card.readBlock(7), trailer)
    },

    test("rejects a wrong-sized write") { t in
        let (_, card) = makeCard()
        _ = try card.authenticateAny(sector: 1, keys: [.default])
        t.throwsError("2-byte write") { try card.writeBlock(4, data: [0x01, 0x02]) }
    },

    // MARK: - Whole-card

    // Mirrors the real tag, where sector 1 refused every key we tried.
    test("dumpAll skips unauthenticatable sectors instead of failing") { t in
        let (mock, card) = makeCard()
        mock.unauthenticatableSectors = [1]
        let dumps = try card.dumpAll()
        t.equal(dumps.count, 16, "sector count")
        t.expect(dumps[1].authFailed, "sector 1 must be flagged as auth-failed")
        t.expect(dumps[1].blocks.isEmpty, "no blocks readable from a locked sector")
        t.expect(!dumps[0].authFailed, "sector 0 must still be readable")
        t.equal(dumps[0].blocks.count, 4, "sector 0 block count")
    },

    test("dumpAll reads the manufacturer block containing the UID") { t in
        let (_, card) = makeCard()
        let dumps = try card.dumpAll()
        guard let block0 = t.unwrap(dumps[0].blocks[0], "block 0") else { return }
        t.equal(Array(block0.prefix(4)), [0x80, 0xA6, 0x79, 0x39])
    },

    // MARK: - Session-poisoning regression
    //
    // Real hardware: an ACR1552 with a programmed tag reported auth failure on EVERY sector,
    // including factory-key sector 0, because one wrong-key attempt poisoned the session and
    // nothing reset it. The Arduino firmware avoids this by re-selecting the card between key
    // attempts. These tests pin that behaviour so the fix cannot silently regress.

    test("a failed auth poisons the session until reset") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.sectorKeys[0] = .init(keyA: .default, keyB: .default)

        // Wrong key on sector 1 poisons the session...
        mock.sectorKeys[1] = .init(keyA: MifareKey(hex: "A0A1A2A3A4A5")!,
                                   keyB: MifareKey(hex: "A0A1A2A3A4A5")!)
        try card.loadKey(.default)
        _ = try? card.authenticate(block: 4, keyType: .keyA)
        t.expect(mock.sessionPoisoned, "a wrong key must poison the session")

        // ...so even a correct key on a factory sector now fails.
        try card.loadKey(.default)
        t.equal(try? card.authenticate(block: 0, keyType: .keyA), false,
                "poisoned session must reject even a correct key")

        // Reset clears it.
        try mock.reset()
        try card.loadKey(.default)
        t.equal(try card.authenticate(block: 0, keyType: .keyA), true,
                "reset must restore the ability to authenticate")
    }

    ,test("authenticateAny recovers after a wrong first key") { t in
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        let secret = MifareKey(hex: "A0A1A2A3A4A5")!
        mock.sectorKeys[1] = .init(keyA: secret, keyB: secret)

        // Deliberately put the WRONG key first — this is the ordering that broke real hardware.
        let result = try card.authenticateAny(sector: 1, keys: [.default, secret])
        t.equal(result.key, secret, "must find the correct key despite a failed first attempt")
        t.expect(mock.resetCount > 0, "must have reset the card after the failed attempt")
    }

    ,test("dumpAll still reads factory sectors after a wrong key on an earlier sector") { t in
        // The exact real-world scenario: sector 1 is locked, sectors 0 and 2+ are factory.
        // Without reset, the sector-1 failure cascades and the whole card reads as locked.
        let mock = MockTransport()
        let card = MifareClassicCard(transport: mock)
        mock.unauthenticatableSectors = [1]

        let dumps = try card.dumpAll(keys: [.default])
        t.expect(dumps[1].authFailed, "sector 1 is genuinely locked")
        t.expect(!dumps[0].authFailed, "sector 0 must still be readable")
        t.expect(!dumps[2].authFailed, "sector 2 must still be readable after the sector-1 failure")
        t.equal(dumps.filter { !$0.authFailed }.count, 15, "15 of 16 sectors must be readable")
    }

    // End-to-end: lock a sector with the derived key exactly as a programmed tag would,
    // then prove the factory key fails and the derived key opens it.
    ,test("derived key opens a sector locked to that derived key") { t in
        let (mock, card) = makeCard()
        let uid: [UInt8] = [0x80, 0xA6, 0x79, 0x39]
        let derived = try CrealityCrypto.deriveSectorKey(uid: uid)
        mock.sectorKeys[1] = .init(keyA: derived, keyB: derived)

        t.throwsError(PCSCError.authenticationFailed(sector: 1)) {
            _ = try card.authenticateAny(sector: 1, keys: [.default])
        }
        let result = try card.authenticateAny(sector: 1, keys: [.default, derived])
        t.equal(result.key, derived, "derived key must open the programmed sector")
    },
])

let apduResponseTests = TestSuite(name: "APDU response parsing", cases: [
    test("parses payload and status words") { t in
        let r = try APDUResponse(raw: [0x01, 0x02, 0x90, 0x00])
        t.equal(r.data, [0x01, 0x02])
        t.expect(r.isSuccess, "90 00 is success")
        t.equal(try r.checked(), [0x01, 0x02])
    },

    test("checked() throws on a failure status") { t in
        let r = try APDUResponse(raw: [0x69, 0x82])
        t.expect(!r.isSuccess, "69 82 is not success")
        t.throwsError(PCSCError.statusWord(sw1: 0x69, sw2: 0x82)) { _ = try r.checked() }
    },

    test("rejects a truncated response") { t in
        t.throwsError(PCSCError.truncatedResponse(length: 1)) {
            _ = try APDUResponse(raw: [0x90])
        }
    },

    test("describes the status words the readers actually emit") { t in
        t.equal(PCSCError.describeSW(0x69, 0x82), "Security status not satisfied — wrong key")
        t.equal(PCSCError.describeSW(0x90, 0x00), "Success")
    },
])

// MARK: - Reader grouping
//
// A single ACS ACR1552 enumerates as two PC/SC slots. Reporting "2 readers" to a user who owns
// one device is simply wrong, and it is what the first version of this CLI did.
let readerDeviceTests = TestSuite(name: "Reader device grouping", cases: [
    test("groups the real ACR1552's two slots into one device") { t in
        let devices = ReaderDevice.group(slotNames: [
            "ACS ACR1552 1S CL Reader(1)",
            "ACS ACR1552 1S CL Reader(2)",
        ])
        t.equal(devices.count, 1, "one physical device")
        t.equal(devices.first?.displayName, "ACS ACR1552 1S CL Reader")
        t.equal(devices.first?.slotNames.count, 2, "two slots")
        t.expect(devices.first?.hasMultipleSlots == true)
    },

    test("keeps genuinely distinct readers separate") { t in
        let devices = ReaderDevice.group(slotNames: [
            "ACS ACR1552 1S CL Reader(1)",
            "ACS ACR122U PICC Interface(1)",
        ])
        t.equal(devices.count, 2, "two different devices")
    },

    test("leaves a name without a numeric suffix alone") { t in
        t.equal(ReaderDevice.baseName(of: "Some Reader"), "Some Reader")
        // Only a purely numeric suffix is a slot index; a descriptive one is part of the name.
        t.equal(ReaderDevice.baseName(of: "Some Reader (Contactless)"), "Some Reader (Contactless)")
    },

    test("a single-slot reader is still one device") { t in
        let devices = ReaderDevice.group(slotNames: ["ACS ACR122U PICC Interface(0)"])
        t.equal(devices.count, 1)
        t.equal(devices.first?.displayName, "ACS ACR122U PICC Interface")
        t.expect(devices.first?.hasMultipleSlots == false, "one slot is not 'multiple'")
    },
])
