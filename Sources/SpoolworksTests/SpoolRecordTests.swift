import Foundation
@testable import SpoolworksCore

// Golden material. Row 1 of the README tag table is also entry 1 of docs/tn_data.json, so it is
// the one record three independent sources agree on; it is used as the primary vector throughout.
//
// The ciphertexts below were confirmed against an independent AES-128-ECB implementation, not
// copied from the spec's prose. That matters: SPEC/01-tag-codec.md §9.2 and §11.4 assert that
// "block 6 is always FAC8F075… because bytes 32..47 are always the 16 ASCII zeros". The
// ciphertext is right; the reason is wrong, and so is the word "always" — see
// `spoolRecordGoldenTests` below.
private let readmeRow1 = "AB1240276A21010010FFFFFF0165000001000000"
private let readmeRow1Padded = "AB1240276A21010010FFFFFF016500000100000000000000"
private let readmeRow1Block4 = "57F25B78076D4C1797B1BE35CA269540"
private let readmeRow1Block5 = "D80EE25C0E3EDD25A3C1079BC52DD3AC"
private let readmeRow1Block6 = "FAC8F07509292DF943D4CDF64CBA06A1"

/// The mock's default UID, and the sector-1 key it derives to.
private let mockUID: [UInt8] = [0x80, 0xA6, 0x79, 0x39]
private let mockDerivedKeyHex = "E05E87259A4F"

private func derivedKey(_ uid: [UInt8] = mockUID) throws -> MifareKey {
    try CrealityCrypto.deriveSectorKey(uid: uid)
}

/// A record equal to README row 1, built through the ergonomic initialiser.
private func row1Record() throws -> SpoolRecord {
    try SpoolRecord(materialId: "01001", colorRGB: "FFFFFF", filamentLength: .g500)
}

// MARK: - Record codec

let spoolRecordTests = TestSuite(name: "Spool record codec", cases: [

    // MARK: Layout

    // A single wrong offset would corrupt every field after it, and nothing else in the stack
    // would notice — the format has no checksum of any kind (SPEC §4). So the layout is asserted
    // directly rather than only through round-trips.
    test("field offsets are contiguous and total 40 characters") { t in
        var cursor = 0
        for field in SpoolRecord.Field.allCases {
            t.equal(field.offset, cursor, "offset of \(field.rawValue)")
            cursor += field.width
        }
        t.equal(cursor, SpoolRecord.recordLength, "sum of field widths")
        // The widths Android validates on write: 1,2,2,4,2,6,7,4,6,6.
        t.equal(SpoolRecord.Field.allCases.map(\.width), [1, 2, 2, 4, 2, 6, 7, 4, 6, 6])
    },

    // MARK: Round-trip

    test("golden: README row 1 decodes into the documented fields") { t in
        guard let r = t.unwrap(SpoolRecord(decoding: readmeRow1), "record") else { return }
        t.equal(r.date.month, "A", "month")
        t.equal(r.date.day, "B1", "day")
        t.equal(r.date.year, "24", "year")
        t.equal(r.vendorId, "0276", "vendorId")
        t.equal(r.batch, "A2", "batch")
        t.equal(r.filamentId, "101001", "filamentId")
        t.equal(r.color, "0FFFFFF", "color")
        t.equal(r.filamentLength, "0165", "filamentLength")
        t.equal(r.serialNumber, "000001", "serialNumber")
        t.equal(r.reserve, "000000", "reserve")
        // The two slices the Windows read path actually takes (MainForm.cs:414-419).
        t.equal(r.materialId, "01001", "materialId == Substring(12, 5)")
        t.equal(r.rgbHex, "FFFFFF", "rgbHex == Substring(18, 6)")
        t.equal(r.weightGrams, 500, "GetMaterialWeight(\"0165\")")
        t.equal(r.knownLength, .g500)
    },

    test("encode is the exact inverse of decode") { t in
        guard let r = t.unwrap(SpoolRecord(decoding: readmeRow1)) else { return }
        t.equal(r.encoded, readmeRow1)
        t.equal(r.encoded.count, 40, "record length")
        t.equal(r.encodedBytes.count, 40, "record byte count")
    },

    test("builder reproduces the three spec construction vectors") { t in
        t.equal(try SpoolRecord(materialId: "01001", colorRGB: "0000FF", filamentLength: .kg1).encoded,
                "AB1240276A210100100000FF0330000001000000")
        t.equal(try SpoolRecord(materialId: "01001", colorRGB: "FFFFFF", filamentLength: .g500).encoded,
                readmeRow1)
        t.equal(try SpoolRecord(materialId: "02001", colorRGB: "C12E1F", filamentLength: .g750).encoded,
                "AB1240276A21020010C12E1F0247000001000000")
    },

    test("builder emits the unknown colour nibble as '0' and uppercases the hex") { t in
        let r = try SpoolRecord(materialId: "01001", colorRGB: "c12e1f", filamentLength: .g500)
        t.equal(r.color, "0C12E1F", "leading nibble must be '0', hex must be uppercase")
        t.equal(r.colorPrefix, "0")
    },

    // The nibble's meaning is unknown (SPEC OPEN QUESTION 2), so a foreign tag that sets it must
    // survive a read/write round-trip unchanged rather than being normalised away.
    test("decoded colour nibble is preserved verbatim, not forced to '0'") { t in
        // date+vendorId+batch+filamentId = 17 characters, then the 7-character colour field.
        let foreign = "AB124" + "0276" + "A2" + "101001" + "9FFFFFF" + "0165" + "000001" + "000000"
        t.equal(foreign.count, 40, "fixture length")
        guard let r = t.unwrap(SpoolRecord(decoding: foreign), "foreign record") else { return }
        t.equal(r.colorPrefix, "9", "an unknown nibble must survive the round-trip")
        t.equal(r.rgbHex, "FFFFFF")
        t.equal(r.encoded, foreign, "re-encoding must not rewrite the nibble")
    },

    test("lowercase hex on a foreign tag decodes and re-encodes byte-identically") { t in
        let lower = "AB1240276A21010010ffffff0165000001000000"
        guard let r = t.unwrap(SpoolRecord(decoding: lower), "lowercase record") else { return }
        t.equal(r.encoded, lower, "decode must preserve, not normalise")
        t.equal(r.rgbHex, "ffffff")
    },

    test("decodes from bytes in both the bare and padded forms") { t in
        let bare = SpoolRecord(decoding: Array(readmeRow1.utf8))
        let padded = SpoolRecord(decoding: Array(readmeRow1Padded.utf8))
        t.expect(bare != nil, "40-byte form must decode")
        t.expect(padded != nil, "48-byte form must decode")
        t.equal(bare, padded, "the 8 filler bytes carry no information")
    },

    // MARK: Padding

    test("paddedPayload is 48 bytes ending in eight ASCII '0', not NUL") { t in
        let payload = try row1Record().paddedPayload
        t.equal(payload.count, 48, "sector 1 data area")
        t.equal(Array(payload[40..<48]), [UInt8](repeating: 0x30, count: 8),
                "filler must be ASCII '0' (0x30); NUL padding would change block 6 entirely")
        t.equal(String(decoding: payload, as: UTF8.self), readmeRow1Padded)
    },

    // MARK: Accessors

    test("filament length table matches the Windows weight table") { t in
        t.equal(FilamentLength.kg1.grams, 1000)
        t.equal(FilamentLength.g750.grams, 750)
        t.equal(FilamentLength.g600.grams, 600)
        t.equal(FilamentLength.g500.grams, 500)
        t.equal(FilamentLength.g250.grams, 250)
        t.equal(FilamentLength.forGrams(600), .g600)
        t.equal(FilamentLength.forGrams(1234), nil, "an unknown weight has no length")
    },

    // The field is four digits, not an enum: an unknown value is legal on the wire and the Windows
    // app reports it as 1 KG (Utils.cs:169). Rejecting it would make foreign tags unreadable.
    test("unknown filament length is accepted and defaults to 1 KG") { t in
        let odd = "AB1240276A21010010FFFFFF9999000001000000"
        guard let r = t.unwrap(SpoolRecord(decoding: odd), "record with unknown length") else { return }
        t.equal(r.knownLength, nil, "9999 is not in the table")
        t.equal(r.weightGrams, 1000, "GetMaterialWeight defaults to 1 KG")
    },

    test("filament class digit is exposed rather than discarded") { t in
        guard let r = t.unwrap(SpoolRecord(decoding: readmeRow1)) else { return }
        t.equal(r.filamentClass, "1")
        t.equal(r.materialId, "01001")
    },

    // MARK: Codable

    test("Codable round-trips through JSON") { t in
        let original = try row1Record()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SpoolRecord.self, from: data)
        t.equal(decoded, original)
        t.equal(decoded.encoded, readmeRow1)
    },

    // Synthesised Codable would bypass the validating initialiser and let malformed records in
    // through the back door.
    test("Codable decoding enforces the same validation as parsing") { t in
        let json = """
        {"date":{"month":"A","day":"B1","year":"24"},"vendorId":"0276","batch":"A2",
         "filamentId":"101001","color":"0FFFFFF","filamentLength":"0165",
         "serialNumber":"12345678","reserve":"000000"}
        """
        t.throwsError("decoding a record with an 8-digit serial") {
            _ = try JSONDecoder().decode(SpoolRecord.self, from: Data(json.utf8))
        }
    },
])

// MARK: - Validation

let spoolRecordValidationTests = TestSuite(name: "Spool record validation", cases: [

    test("rejects every wrong record length") { t in
        for length in [0, 1, 39, 41, 47, 49, 96] {
            let bytes = [UInt8](repeating: 0x30, count: length)
            t.throwsError(SpoolRecordError.wrongRecordLength(actual: length)) {
                _ = try SpoolRecord(validating: bytes)
            }
            t.expect(SpoolRecord(decoding: bytes) == nil, "decoding \(length) bytes must return nil")
        }
    },

    // Out-of-range values are rejected, never truncated. A silently truncated 7-digit serial
    // would write a tag that reads back as a different spool.
    test("rejects over-long values rather than truncating them") { t in
        t.throwsError(SpoolRecordError.wrongFieldWidth(field: .serialNumber, expected: 6, actual: 7)) {
            _ = try SpoolRecord(filamentId: "101001", color: "0FFFFFF",
                                filamentLength: "0165", serialNumber: "1234567")
        }
        t.throwsError(SpoolRecordError.wrongFieldWidth(field: .vendorId, expected: 4, actual: 5)) {
            _ = try SpoolRecord(vendorId: "02760", filamentId: "101001", color: "0FFFFFF",
                                filamentLength: "0165")
        }
        t.throwsError(SpoolRecordError.wrongFieldWidth(field: .color, expected: 7, actual: 6)) {
            _ = try SpoolRecord(filamentId: "101001", color: "FFFFFF", filamentLength: "0165")
        }
    },

    test("the ergonomic builder blames the right field for a bad component") { t in
        // 4-digit material id: the error must name filamentId at its assembled width, not report
        // a confusing "5 characters" after concatenation.
        t.throwsError(SpoolRecordError.wrongFieldWidth(field: .filamentId, expected: 6, actual: 5)) {
            _ = try SpoolRecord(materialId: "0100", colorRGB: "FFFFFF", filamentLength: .g500)
        }
        t.throwsError(SpoolRecordError.wrongFieldWidth(field: .color, expected: 7, actual: 4)) {
            _ = try SpoolRecord(materialId: "01001", colorRGB: "FFF", filamentLength: .g500)
        }
    },

    // The deepest of the three places a Polymaker id was refused. `Field.filamentId` was `0-9`,
    // so `1P1003` failed alphabet validation and no tag could be built for any of the 31 lettered
    // ids in the shipped K2 catalogue - the app could list the filament, let you pick it, and then
    // refuse to encode it.
    test("a lettered catalogue id makes a tag and reads back the same") { t in
        for id in ["P1003", "P1001", "P7005", "E1001", "01001"] {
            let record = try SpoolRecord(materialId: id, colorRGB: "C12E1F",
                                         filamentLength: .kg1, serialNumber: "424242")
            t.equal(record.filamentId, "1" + id, "the class digit and the catalogue id")
            t.equal(record.materialId, id, "which reads back as the id it was made from")
            // And it survives the wire, which is the claim that actually matters.
            let decoded = try SpoolRecord(validating: record.encoded)
            t.equal(decoded, record, "\(id) round-trips through the 40-character record")
        }
    },

    // Widened, not removed. Lowercase and punctuation are still not a filament id.
    test("the filamentId alphabet is capitals and digits, and no more") { t in
        for bad in ["p1003", "P100-", "P10 3"] {
            t.throwsError("\(bad) must be refused") {
                _ = try SpoolRecord(materialId: bad, colorRGB: "C12E1F", filamentLength: .kg1)
            }
        }
    },

    test("every field rejects a byte outside its alphabet") { t in
        // (field, the 40-char record with one character corrupted, the offending byte)
        let cases: [(SpoolRecord.Field, String, UInt8)] = [
            (.month,          "aB1240276A21010010FFFFFF0165000001000000", 0x61),  // lowercase
            (.day,            "AB!240276A21010010FFFFFF0165000001000000", 0x21),  // punctuation
            (.year,           "AB12X0276A21010010FFFFFF0165000001000000", 0x58),  // letter in a digit field
            (.vendorId,       "AB124027XA21010010FFFFFF0165000001000000", 0x58),
            (.batch,          "AB1240276A-1010010FFFFFF0165000001000000", 0x2D),
            // Punctuation, not a letter: `filamentId` carries the catalogue's `base.id`, which is
            // alphanumeric (`1P1003` for Polymaker Panchroma PLA Matte). See `Field.alphabet`.
            (.filamentId,     "AB1240276A2101-010FFFFFF0165000001000000", 0x2D),
            (.color,          "AB1240276A21010010FFFFFG0165000001000000", 0x47),  // 'G' is not hex
            (.filamentLength, "AB1240276A21010010FFFFFF01X5000001000000", 0x58),
            (.serialNumber,   "AB1240276A21010010FFFFFF0165X00001000000", 0x58),
            (.reserve,        "AB1240276A21010010FFFFFF0165000001 00000", 0x20),  // space
        ]
        for (field, corrupted, byte) in cases {
            t.equal(corrupted.count, 40, "fixture for \(field.rawValue) must still be 40 chars")
            do {
                _ = try SpoolRecord(validating: corrupted)
                t.expect(false, "\(field.rawValue) accepted an illegal byte")
            } catch let error as SpoolRecordError {
                guard case let .illegalByte(gotField, gotByte, _, _) = error else {
                    t.expect(false, "\(field.rawValue): expected illegalByte, got \(error)")
                    continue
                }
                t.equal(gotField, field, "field blamed")
                t.equal(gotByte, byte, "byte reported for \(field.rawValue)")
            } catch {
                t.expect(false, "\(field.rawValue): unexpected error \(error)")
            }
        }
    },

    // Letters are legal in month/day/batch/reserve — "AB124" and "A2" are the whole known corpus,
    // so a purely-numeric alphabet there would reject every real tag.
    test("accepts the alphanumeric values the real corpus uses") { t in
        t.expect(SpoolRecord(decoding: readmeRow1) != nil, "AB124 / A2 must be legal")
        // The second observed date, from README row 3 / tn_data.json entry 3.
        t.expect(SpoolRecord(decoding: "9A2240276A210100100000000165000001000000") != nil,
                 "9A224 must be legal")
    },

    test("rejects non-ASCII bytes") { t in
        var bytes = Array(readmeRow1.utf8)
        bytes[0] = 0xE9   // lone Latin-1 'é': invalid UTF-8, decodes to U+FFFD (3 bytes)
        t.throwsError(SpoolRecordError.wrongFieldWidth(field: .month, expected: 1, actual: 3)) {
            _ = try SpoolRecord(validating: bytes)
        }
        var control = Array(readmeRow1.utf8)
        control[0] = 0x7F  // DEL: valid ASCII, still not in the alphabet
        t.throwsError(SpoolRecordError.illegalByte(field: .month, byte: 0x7F, index: 0,
                                                   allowed: "0-9A-Z")) {
            _ = try SpoolRecord(validating: control)
        }
    },

    // A formatted tag is 48 zero bytes (Utils.cs:283-314), and .NET's Trim() does not strip NUL,
    // which is why Android has to special-case startsWith("\0") (MainActivity.java:915).
    test("a formatted (all-NUL) tag is rejected cleanly, not parsed as garbage") { t in
        let blank = [UInt8](repeating: 0x00, count: 48)
        t.expect(SpoolRecord(decoding: blank) == nil, "48 NUL bytes must not parse as a record")
        do {
            _ = try SpoolRecord(validating: blank)
            t.expect(false, "should have thrown")
        } catch let error as SpoolRecordError {
            guard case let .illegalByte(field, byte, _, _) = error else {
                t.expect(false, "expected illegalByte, got \(error)"); return
            }
            t.equal(field, .month, "the first field is where it should fail")
            t.equal(byte, 0x00)
        }
    },

    test("errors describe themselves usefully") { t in
        let width = SpoolRecordError.wrongFieldWidth(field: .serialNumber, expected: 6, actual: 7)
        t.expect(width.description.contains("serialNumber"), "error must name the field")
        let byte = SpoolRecordError.illegalByte(field: .color, byte: 0x47, index: 6, allowed: "0-9A-Fa-f")
        t.expect(byte.description.contains("'G'"), "printable bytes should be shown as characters")
        let nonPrintable = SpoolRecordError.illegalByte(field: .month, byte: 0x00, index: 0, allowed: "0-9A-Z")
        t.expect(nonPrintable.description.contains("0x00"), "non-printables should be shown as hex")
    },
])

// MARK: - Golden ciphertexts, and a spec correction

let spoolRecordGoldenTests = TestSuite(name: "Spool record golden vectors", cases: [

    test("golden: README row 1 encrypts to the reference blocks 4, 5 and 6") { t in
        let blocks = try CrealityCrypto.encryptPayload(row1Record().paddedPayload)
        t.equal(blocks[0].hexString, readmeRow1Block4, "block 4")
        t.equal(blocks[1].hexString, readmeRow1Block5, "block 5")
        t.equal(blocks[2].hexString, readmeRow1Block6, "block 6")
    },

    test("golden: the other two documented records encrypt correctly") { t in
        let a = try CrealityCrypto.encryptPayload(
            SpoolRecord(materialId: "01001", colorRGB: "0000FF", filamentLength: .kg1).paddedPayload)
        t.equal(a[0].hexString, "57F25B78076D4C1797B1BE35CA269540", "block 4")
        t.equal(a[1].hexString, "451BBCE6FDE582AB501B41101C3741C0", "block 5")

        let b = try CrealityCrypto.encryptPayload(
            SpoolRecord(materialId: "02001", colorRGB: "C12E1F", filamentLength: .g750).paddedPayload)
        t.equal(b[0].hexString, "58CB1E98A91234508C8796F46A73EE2F", "block 4")
        t.equal(b[1].hexString, "AF07DFC05C79707E8298D3BB7F2BBE57", "block 5")
    },

    // SPEC CORRECTION. SPEC/01-tag-codec.md §9.2 and §11.4 D both claim block 6 is "always"
    // FAC8F075… "because bytes 32..47 are always the 16 ASCII zeros". The ciphertext is correct,
    // the reasoning is not, and the conclusion does not generalise:
    //
    //   * bytes 32..47 are "0100000000000000", not "0000000000000000" — serialNumber occupies
    //     28..33, so its trailing '1' lands at offset 33;
    //   * AES-ECB of sixteen ASCII zeros is DE87F593DB8A918A3CF47A0FC224FA9C, a different value;
    //   * block 6 is constant only while serialNumber ends "01" and reserve is "000000". The
    //     Arduino firmware randomises the serial (Spool_ID.ino:393) and Android substitutes a
    //     Spoolman id, so on tags from either of those, block 6 varies.
    //
    // Treating block 6 as a fixed constant would therefore mis-verify real tags.
    test("spec correction: block 6 is not the encryption of sixteen ASCII zeros") { t in
        let tail = Array(try row1Record().paddedPayload[32..<48])
        t.equal(String(decoding: tail, as: UTF8.self), "0100000000000000",
                "the serial's trailing '1' lands at offset 33, so the tail is not all zeros")

        let allZeros = try CrealityCrypto.encryptBlock(Array("0000000000000000".utf8),
                                                       key: CrealityCrypto.payloadKey)
        t.equal(allZeros.hexString, "DE87F593DB8A918A3CF47A0FC224FA9C")
        t.expect(allZeros.hexString != readmeRow1Block6,
                 "if these matched, the spec's stated reason would hold; they do not")
    },

    test("spec correction: block 6 varies with the serial number") { t in
        let standard = try CrealityCrypto.encryptPayload(row1Record().paddedPayload)
        let arduinoStyle = try CrealityCrypto.encryptPayload(
            SpoolRecord(materialId: "01001", colorRGB: "FFFFFF", filamentLength: .g500,
                        serialNumber: "483921").paddedPayload)
        t.equal(standard[2].hexString, readmeRow1Block6)
        t.expect(arduinoStyle[2].hexString != standard[2].hexString,
                 "a random serial must change block 6 — it is not a constant")
        t.equal(arduinoStyle[2].hexString, "FABA7742B30CF9469071E4297B88BFAA")
        // Blocks 4 and 5 are unaffected: the serial only touches bytes 28..33, in block 5's
        // tail — so block 4 stays constant while block 5 changes.
        t.equal(arduinoStyle[0].hexString, standard[0].hexString, "block 4 must be unaffected")
        t.expect(arduinoStyle[1].hexString != standard[1].hexString, "block 5 must change")
    },

    test("golden: sector 2 payloads match the reference bytes") { t in
        let k2 = try TagService.sector2Payload(printerType: "K2")
        t.equal(k2.count, 48)
        t.equal(Array(k2[0..<16]).hexString, "4B322020202020202020202020202020", "block 8")
        t.equal(Array(k2[16..<32]).hexString, "20202020202020202020202020202020", "block 9")
        t.equal(Array(k2[32..<48]).hexString, "20202020202020202020202020202020", "block 10")
        t.equal(Array(try TagService.sector2Payload(printerType: "K1")[0..<2]).hexString, "4B31")
        t.equal(Array(try TagService.sector2Payload(printerType: "HI")[0..<2]).hexString, "4849")
    },

    test("sector 2 rejects over-long and non-ASCII printer types") { t in
        t.throwsError("49-character printer type") {
            _ = try TagService.sector2Payload(printerType: String(repeating: "K", count: 49))
        }
        t.throwsError("non-ASCII printer type") {
            _ = try TagService.sector2Payload(printerType: "Küche")
        }
        t.noThrow("exactly 48 characters") {
            _ = try TagService.sector2Payload(printerType: String(repeating: "K", count: 48))
        }
    },

    test("printer type survives a sector-2 round-trip, and NULs are trimmed") { t in
        let payload = try TagService.sector2Payload(printerType: "K2 Plus")
        t.equal(TagService.printerType(fromSector2: payload), "K2 Plus")
        // A formatted tag: 48 NUL bytes. .NET's Trim() would leave these in place.
        t.equal(TagService.printerType(fromSector2: [UInt8](repeating: 0, count: 48)), "")
    },
])

// MARK: - TagService

/// Builds a mock card, optionally pre-programmed with a record.
private func makeMock(uid: [UInt8] = mockUID,
                      programmedWith record: SpoolRecord? = nil,
                      printerType: String = "K2") throws -> MockTransport {
    let mock = MockTransport(uid: uid)
    guard let record else { return mock }
    let key = try derivedKey(uid)
    mock.sectorKeys[1] = MockTransport.SectorKeys(keyA: key, keyB: key)
    for (block, data) in zip(TagService.recordBlocks,
                             try CrealityCrypto.encryptPayload(record.paddedPayload)) {
        mock.setBlock(block, to: data)
    }
    let payload = try TagService.sector2Payload(printerType: printerType)
    for (index, block) in TagService.printerBlocks.enumerated() {
        mock.setBlock(block, to: Array(payload[(index * 16)..<((index + 1) * 16)]))
    }
    // The trailer a first-time programming would have left behind.
    mock.setBlock(7, to: key.bytes + [0xFF, 0x07, 0x80, 0x69] + key.bytes)
    return mock
}

private func makeService(_ mock: MockTransport, cardType: CardType = .mifareClassic1K) -> TagService {
    TagService(card: MifareClassicCard(transport: mock), cardType: cardType)
}

/// Every write APDU (`FF D6`) in the log, as (block, data).
private func writes(_ mock: MockTransport) -> [(block: Int, data: [UInt8])] {
    mock.log.filter { $0.count == 21 && $0[0] == 0xFF && $0[1] == 0xD6 }
        .map { (block: Int($0[3]), data: Array($0[5..<21])) }
}

let tagServiceTests = TestSuite(name: "Tag service", cases: [

    // MARK: Read

    test("reads a programmed tag and parses the record") { t in
        let mock = try makeMock(programmedWith: row1Record())
        let result = try makeService(mock).readTag()
        t.equal(result.uid, mockUID)
        t.equal(result.derivedKey.description, mockDerivedKeyHex)
        t.expect(result.isProgrammed, "sector 1 opened with the derived key")
        t.equal(result.sector1Key.description, mockDerivedKeyHex)
        t.equal(result.record?.encoded, readmeRow1)
        t.equal(result.recordError, nil)
        t.equal(result.printerType, "K2")
        t.equal(result.sector2?.count, 48)
        t.equal(String(decoding: result.decryptedSector1, as: UTF8.self), readmeRow1Padded)
    },

    // The key that opens sector 1 is derived from the UID, so a different UID must fail even
    // though the ciphertext on the card is identical. This is the property the whole scheme rests
    // on — if it broke, one tag's key would open every tag.
    test("derived-key authentication is UID-specific") { t in
        let mock = try makeMock(programmedWith: row1Record())
        mock.uid = [0x01, 0x02, 0x03, 0x04]   // same card contents, different UID
        t.throwsError(PCSCError.authenticationFailed(sector: 1)) {
            _ = try makeService(mock).readTag()
        }
    },

    // SPEC OPEN QUESTION 8: on the ACR1552 here, key B authenticates where key A does not. A port
    // that hard-coded keyType 0x60, as all eleven Windows call sites do, would fail on this card.
    test("falls back to key B when key A does not open the sector") { t in
        let mock = try makeMock(programmedWith: row1Record())
        let key = try derivedKey()
        // Key A is something else entirely; only key B carries the derived value.
        mock.sectorKeys[1] = MockTransport.SectorKeys(keyA: MifareKey(hex: "A0A1A2A3A4A5")!, keyB: key)
        let result = try makeService(mock).readTag()
        t.equal(result.sector1KeyType, .keyB, "must have fallen back to key B")
        t.expect(result.isProgrammed)
        t.equal(result.record?.encoded, readmeRow1)
    },

    // A blank tag authenticates fine with the factory key; the zeros then decrypt to noise. That
    // must surface as "unreadable record", not as a hard failure, or the UI cannot tell a blank
    // tag from a broken reader.
    test("a blank tag reads without a record instead of throwing") { t in
        let mock = try makeMock()
        let result = try makeService(mock).readTag()
        t.expect(!result.isProgrammed, "a factory tag is not programmed")
        t.equal(result.sector1Key, .default)
        t.equal(result.record, nil)
        t.expect(result.recordError != nil, "the parse failure must be reported, not swallowed")
    },

    test("throws when sector 1 answers no key at all") { t in
        let mock = try makeMock(programmedWith: row1Record())
        mock.unauthenticatableSectors = [1]
        t.throwsError(PCSCError.authenticationFailed(sector: 1)) {
            _ = try makeService(mock).readTag()
        }
    },

    // Windows skips sector 2 silently on auth failure (MainForm.cs:501-511). Sector 1 is the part
    // that matters, so the read still succeeds — but the gap is reported.
    test("an unreadable sector 2 degrades gracefully") { t in
        let mock = try makeMock(programmedWith: row1Record())
        mock.unauthenticatableSectors = [2]
        let result = try makeService(mock).readTag()
        t.equal(result.record?.encoded, readmeRow1, "sector 1 must still be read")
        t.equal(result.sector2, nil)
        t.equal(result.printerType, nil)
    },

    // MARK: Card and UID guards

    test("refuses every card that is not a Classic 1K, before touching it") { t in
        for type: CardType in [.mifareClassic4K, .mifareUltralight, .mifarePlus, .desfire,
                               .mifareMini, .unknown, .other(code: 0x1234)] {
            let mock = try makeMock(programmedWith: row1Record())
            let service = makeService(mock, cardType: type)
            t.throwsError(TagError.unsupportedCard(type)) { _ = try service.readTag() }
            t.throwsError(TagError.unsupportedCard(type)) {
                _ = try service.writeTag(record: row1Record(), allowTrailerWrite: true)
            }
            t.equal(mock.log.count, 0, "\(type): must refuse before sending any APDU")
        }
    },

    test("refuses a non-4-byte UID") { t in
        let mock = try makeMock(uid: [0x04, 0x1A, 0x2B, 0x3C, 0xDE, 0xAD, 0xBE])
        t.throwsError(TagError.unsupportedUID(length: 7)) { _ = try makeService(mock).readTag() }
        t.throwsError(TagError.unsupportedUID(length: 7)) {
            _ = try makeService(mock).writeTag(record: row1Record(), allowTrailerWrite: true)
        }
        t.equal(writes(mock).count, 0, "nothing may be written to a tag we cannot key")
    },

    // MARK: Write

    test("full write-then-read cycle through the mock") { t in
        let mock = try makeMock()
        let service = makeService(mock)
        let record = try SpoolRecord(materialId: "02001", colorRGB: "C12E1F", filamentLength: .g750)

        let write = try service.writeTag(record: record, printerType: "K1C", allowTrailerWrite: true)
        t.expect(!write.wasAlreadyProgrammed, "a factory tag is not yet programmed")
        t.expect(write.wroteTrailer, "first programming must key sector 1")
        t.expect(write.wroteSector2)

        // The mock keys off `sectorKeys`, not off the trailer block, so the card is told to adopt
        // the keys the trailer write just installed.
        let key = try derivedKey()
        mock.sectorKeys[1] = MockTransport.SectorKeys(keyA: key, keyB: key)

        let read = try service.readTag()
        t.equal(read.record, record, "what went on must come back")
        t.expect(read.isProgrammed)
        t.equal(read.printerType, "K1C")
    },

    test("written blocks are byte-identical to the reference ciphertexts") { t in
        let mock = try makeMock()
        _ = try makeService(mock).writeTag(record: row1Record(), printerType: "K2", allowTrailerWrite: true)
        t.equal(mock.blocks[4].hexString, readmeRow1Block4, "block 4")
        t.equal(mock.blocks[5].hexString, readmeRow1Block5, "block 5")
        t.equal(mock.blocks[6].hexString, readmeRow1Block6, "block 6")
        t.equal(mock.blocks[8].hexString, "4B322020202020202020202020202020", "block 8")
    },

    // MARK: Backup

    test("a full backup is captured before the first write APDU") { t in
        let mock = try makeMock()
        // Distinctive pre-write content, so the backup cannot accidentally match post-write state.
        let marker = [UInt8](repeating: 0xA5, count: 16)
        mock.setBlock(4, to: marker)
        mock.setBlock(5, to: marker)

        let result = try makeService(mock).writeTag(record: row1Record(), allowTrailerWrite: true)
        t.equal(result.backup.count, MifareClassicCard.sectorCount, "every sector must be visited")
        guard let sector1 = t.unwrap(result.backup.first { $0.sector == 1 }, "sector 1 backup") else { return }
        t.equal(sector1.blocks[4], marker, "backup must hold the pre-write bytes")
        t.equal(sector1.blocks[5], marker)
        t.expect(mock.blocks[4] != marker, "the card itself must have been overwritten")
        // Block 0 is in the backup even though it can never be written back.
        guard let sector0 = t.unwrap(result.backup.first { $0.sector == 0 }, "sector 0 backup") else { return }
        t.equal(Array(sector0.blocks[0]?.prefix(4) ?? []), mockUID, "the manufacturer block is backed up")
    },

    test("the backup records sectors it could not authenticate rather than dropping them") { t in
        let mock = try makeMock()
        mock.unauthenticatableSectors = [5, 9]
        let result = try makeService(mock).writeTag(record: row1Record(), allowTrailerWrite: true)
        t.equal(result.backup.count, 16)
        t.expect(result.backup.first { $0.sector == 5 }?.authFailed == true, "sector 5 must be flagged")
        t.expect(result.backup.first { $0.sector == 9 }?.authFailed == true, "sector 9 must be flagged")
        t.expect(result.backup.first { $0.sector == 3 }?.authFailed == false)
    },

    // MARK: Trailer

    test("first write installs the derived key in both slots and preserves the access bits") { t in
        let mock = try makeMock()
        let result = try makeService(mock).writeTag(record: row1Record(), allowTrailerWrite: true)
        let key = try derivedKey()
        t.expect(result.wroteTrailer)
        t.equal(mock.blocks[7].hexString, (key.bytes + [0xFF, 0x07, 0x80, 0x69] + key.bytes).hexString)
        t.equal(Array(mock.blocks[7][6...9]), [0xFF, 0x07, 0x80, 0x69],
                "access bits must be preserved verbatim, never authored")
        // Sector 2's trailer is deliberately left on the factory key (SPEC §5.1).
        t.expect(!writes(mock).contains { $0.block == 11 }, "block 11 must not be touched")
    },

    test("access bits are carried through even when they are non-standard") { t in
        let mock = try makeMock()
        // A card whose sector 1 was configured with different access bits: they must survive.
        mock.setBlock(7, to: [0, 0, 0, 0, 0, 0, 0x78, 0x77, 0x88, 0xC1, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
        _ = try makeService(mock).writeTag(record: row1Record(), allowTrailerWrite: true)
        t.equal(Array(mock.blocks[7][6...9]), [0x78, 0x77, 0x88, 0xC1],
                "read-modify-write must not substitute the transport configuration")
    },

    // SPEC OPEN QUESTION 4: the C# reader returns 16 zero bytes when a trailer read fails and never
    // checks SW, so the app would write all-zero access bits and lock the sector for good. Here an
    // all-zero access field is treated as a failed read.
    test("refuses to write a trailer whose access bits read back as zeros") { t in
        let mock = try makeMock()
        mock.setBlock(7, to: [UInt8](repeating: 0, count: 16))
        t.throwsError(TagError.unsafeTrailer(block: 7)) {
            _ = try makeService(mock).writeTag(record: row1Record(), allowTrailerWrite: true)
        }
        t.expect(!writes(mock).contains { $0.block == 7 }, "the trailer must not have been written")
    },

    test("rewriting an already-programmed tag leaves the trailer alone") { t in
        let mock = try makeMock(programmedWith: row1Record())
        let before = mock.blocks[7]
        let result = try makeService(mock).writeTag(
            record: SpoolRecord(materialId: "01001", colorRGB: "0000FF", filamentLength: .kg1),
            printerType: "K2")
        t.expect(result.wasAlreadyProgrammed)
        t.expect(!result.wroteTrailer, "the trailer write happens exactly once, on first programming")
        t.equal(mock.blocks[7], before)
        t.expect(!writes(mock).contains { $0.block == 7 }, "no FF D6 may target block 7")
        t.equal(mock.blocks[5].hexString, "451BBCE6FDE582AB501B41101C3741C0", "the record still changed")
    },

    // MARK: Write safety

    test("block 0 is never written") { t in
        let mock = try makeMock()
        _ = try makeService(mock).writeTag(record: row1Record(), printerType: "K2", allowTrailerWrite: true)
        t.expect(!writes(mock).contains { $0.block == 0 }, "the manufacturer block must never be a target")
        // And the layer below refuses it outright, so no future caller can slip one through.
        let card = MifareClassicCard(transport: mock)
        t.throwsError("writing block 0") {
            try card.writeBlock(0, data: [UInt8](repeating: 0, count: 16), allowTrailer: true)
        }
    },

    test("only blocks 4,5,6,7,8,9,10 are ever written") { t in
        let mock = try makeMock()
        _ = try makeService(mock).writeTag(record: row1Record(), printerType: "K2", allowTrailerWrite: true)
        t.equal(Set(writes(mock).map(\.block)), Set([4, 5, 6, 7, 8, 9, 10]))
    },

    test("a locked sector 2 does not abort the write, but is reported") { t in
        let mock = try makeMock()
        mock.unauthenticatableSectors = [2]
        let result = try makeService(mock).writeTag(record: row1Record(), printerType: "K2", allowTrailerWrite: true)
        t.expect(!result.wroteSector2, "the skip must be visible to the caller")
        t.equal(mock.blocks[4].hexString, readmeRow1Block4, "sector 1 must still be written")
        t.expect(!writes(mock).contains { $0.block == 8 })
    },

    test("an invalid printer type is rejected before anything is written") { t in
        let mock = try makeMock()
        t.throwsError(TagError.invalidPrinterType("Küche")) {
            _ = try makeService(mock).writeTag(record: row1Record(), printerType: "Küche", allowTrailerWrite: true)
        }
        t.equal(writes(mock).count, 0, "validation must precede the first write APDU")
    },
])
