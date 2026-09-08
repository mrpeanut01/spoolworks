import Foundation

// MARK: - Filament length

/// The `filamentLen` values the Creality apps recognise, in metres of 1.75 mm filament.
///
/// `Windows/CFS-RFID/Utils.cs:136-188` (`GetMaterialLength` / `GetMaterialWeight`) and
/// `Arduino/ESP32/Spool_ID/Spool_ID.ino:399+` carry the identical table. The field on the tag is
/// four ASCII digits and is *not* restricted to this set — an unknown value is legal on the wire
/// and the Windows app quietly reports it as "1 KG" (`Utils.cs:169`). So this enum is a lookup,
/// not a validator: `SpoolRecord.filamentLength` stays a `String`.
public enum FilamentLength: String, CaseIterable, Codable, Sendable {
    case kg1  = "0330"
    case g750 = "0247"
    case g600 = "0198"
    case g500 = "0165"
    case g250 = "0082"
    // -- beyond Creality's set ------------------------------------------------------------------
    //
    // The rest of a 100 g ladder, so the weight picker steps evenly instead of jumping
    // 250 → 500 → 600 → 750 → 1000. Sample and small spools live here too, which the five
    // documented values do not reach at all. The codes are
    // derived at the ratio the documented ones use — `floor(grams × 0.33)` metres, which
    // reproduces all five of them exactly — so the encoding is right even though Creality never
    // published these.
    //
    // **A Creality client reading one of these reports "1 KG."** `Utils.cs:169` defaults any
    // unrecognised length to 1 kg, so the printer, the Windows app and the Android app will all
    // call a 100 g spool a kilo. Spoolworks reads it correctly. See ``isCrealityStandard``, which
    // is what the write form uses to warn before this is committed to a tag.
    case g900 = "0297"
    case g800 = "0264"
    case g700 = "0231"
    case g400 = "0132"
    case g300 = "0099"
    case g200 = "0066"
    case g100 = "0033"

    /// Nominal spool weight in grams (`Utils.cs:172-188`).
    public var grams: Int {
        switch self {
        case .kg1:  return 1000
        case .g750: return 750
        case .g600: return 600
        case .g500: return 500
        case .g250: return 250
        case .g900: return 900
        case .g800: return 800
        case .g700: return 700
        case .g400: return 400
        case .g300: return 300
        case .g200: return 200
        case .g100: return 100
        }
    }

    /// Whether Creality's own software recognises this length code.
    ///
    /// The five documented values round-trip through the printer, the Windows app and the Android
    /// app. The rest are legal on the wire — the field is four free ASCII digits — but every
    /// Creality client falls back to "1 KG" for a code it does not know (`Utils.cs:169`), so a tag
    /// written with one is read correctly *here* and misreported everywhere else.
    public var isCrealityStandard: Bool {
        switch self {
        case .kg1, .g750, .g600, .g500, .g250: return true
        case .g900, .g800, .g700, .g400, .g300, .g200, .g100: return false
        }
    }

    /// The label the Windows UI shows for this length (`Utils.cs:136-170`).
    ///
    /// Derived rather than listed. The five Windows labels are exactly `1 KG` and `<n> G`, so a
    /// per-case switch was one more place to forget a weight — which is what happened the moment
    /// the ladder was filled in.
    public var label: String {
        grams >= 1000 && grams % 1000 == 0 ? "\(grams / 1000) KG" : "\(grams) G"
    }

    public static func forGrams(_ grams: Int) -> FilamentLength? {
        allCases.first { $0.grams == grams }
    }
}

// MARK: - Errors

/// Why a spool record was rejected.
///
/// Every case names the offending field, so a UI can highlight it without re-parsing.
public enum SpoolRecordError: Error, Equatable, CustomStringConvertible {
    /// The whole record was not 40 bytes (bare) or 48 bytes (padded to sector 1).
    case wrongRecordLength(actual: Int)
    /// A field was the wrong number of bytes.
    case wrongFieldWidth(field: SpoolRecord.Field, expected: Int, actual: Int)
    /// A byte in a field is outside that field's alphabet. `index` is relative to the field.
    case illegalByte(field: SpoolRecord.Field, byte: UInt8, index: Int, allowed: String)

    public var description: String {
        switch self {
        case let .wrongRecordLength(actual):
            return "spool record must be \(SpoolRecord.recordLength) or \(SpoolRecord.paddedLength) bytes, got \(actual)"
        case let .wrongFieldWidth(field, expected, actual):
            return "field \(field.rawValue) must be \(expected) characters, got \(actual)"
        case let .illegalByte(field, byte, index, allowed):
            let shown = (0x20...0x7E).contains(byte)
                ? "'\(Character(UnicodeScalar(byte)))'"
                : String(format: "0x%02X", byte)
            return "field \(field.rawValue) has \(shown) at index \(index); allowed: [\(allowed)]"
        }
    }
}

extension SpoolRecordError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - SpoolRecord

/// The 40-character ASCII record that lives in sector 1 of a Creality spool tag.
///
/// Layout (character offsets == byte offsets; the whole record is printable ASCII, with no packed
/// BCD, no binary integers and no endianness anywhere):
///
/// ```
/// 0        1  3  5      9  11        17       24     28       34      40
/// | month  |day|year| vendorId |batch| filamentId | color | len | serial | reserve |
/// |   A    |B1 | 24 |   0276   | A2  |   101001   |0FFFFFF|0165 | 000001 | 000000  |
/// ```
///
/// Field boundaries are firm: they are confirmed independently by the Android "manual tag data"
/// dialog, which is the only place all ten logical fields are parsed and length-validated
/// (`Android/.../MainActivity.java:917-926` and `:937-940`, widths 1,2,2,4,2,6,7,4,6,6 = 40).
/// The Windows writer concatenates the same widths (`MainForm.cs:445-455`) as does the Arduino
/// firmware (`Spool_ID.ino:386-395`). All three agree.
///
/// ## Deliberate deviation: this type is strict, the reference apps are not
///
/// The Windows app never validates a single field on read — it slices `Substring(12, 5)` and
/// `Substring(18, 6)` out of whatever came off the tag and trusts it (`MainForm.cs:401-422`).
/// Android checks lengths on write only. Here every field is validated for width *and* alphabet,
/// on construction and on decode, and out-of-range values are **rejected rather than truncated**.
/// Silently truncating a 7-digit serial to 6 would produce a tag that reads back as a different
/// spool; failing loudly is the safer half of that trade.
public struct SpoolRecord: Equatable, Hashable, CustomStringConvertible, Sendable {

    // MARK: Geometry

    /// The logical record: 40 ASCII characters.
    public static let recordLength = 40
    /// The record as stored: padded to 48 bytes = 3 × 16 = exactly sector 1's data area.
    public static let paddedLength = 48
    /// The pad byte is ASCII `'0'` (0x30), **not** NUL.
    ///
    /// This is easy to get wrong and it changes the ciphertext. Windows builds
    /// `reserve = "00000000000000"` — fourteen `'0'` characters where the logical `reserve` field
    /// is only six — so the record arrives at 48 characters already (`MainForm.cs:452`). Arduino
    /// makes the split explicit: `... + reserve + "00000000"` with `reserve = "000000"`
    /// (`Spool_ID.ino:395`). `FormatTag` writes 0x00 bytes, but that is erasure, not padding
    /// (`Utils.cs:283-314`). Confirmed against the golden ciphertexts: see `paddedPayload`.
    public static let padByte: UInt8 = 0x30

    /// `0276` — Creality (`MainActivity.java:745`, `Spool_ID.ino:389`, both comment it as such).
    /// Whether the printer accepts any other vendor id is unknown.
    public static let crealityVendorId = "0276"
    /// `A2`. Meaning undocumented in all three implementations; treated as an opaque constant.
    public static let defaultBatch = "A2"
    /// `000001` — the literal Windows always writes (`MainForm.cs:451`).
    public static let defaultSerialNumber = "000001"

    /// A serial for a spool this app is about to tag.
    ///
    /// Six digits, because that is the field's width, and **never** ``defaultSerialNumber``.
    /// `000001` is what the Windows app hard-codes, so every factory spool of a given material
    /// already carries it — the K2 Plus dump in `reference/` has all four slots reporting it. A
    /// tag written with that value is indistinguishable from the entire Creality catalogue, and
    /// two spools written back to back would be indistinguishable from each other.
    ///
    /// Random rather than sequential because there is nowhere to keep a counter that survives a
    /// reinstall. Six digits gives a ~1-in-900,000 collision per pair, which is far better than
    /// the certainty a constant provides.
    public static func randomSerialNumber() -> String {
        String(format: "%06d", Int.random(in: 100_000...999_999))
    }
    /// `000000` — the 6-character logical reserve field.
    public static let defaultReserve = "000000"

    // MARK: Alphabets

    /// The byte classes a field may contain.
    public enum Alphabet: String, Sendable {
        case digits = "0-9"
        case upperAlphanumeric = "0-9A-Z"
        /// Hex is accepted in either case on decode so a foreign tag is still readable; the
        /// builders in this file always emit uppercase, matching `ToString("X6")`
        /// (`MainForm.cs:698-712`) and Android's `.toUpperCase()` normalisation.
        case hex = "0-9A-Fa-f"

        func allows(_ byte: UInt8) -> Bool {
            let isDigit = (0x30...0x39).contains(byte)
            switch self {
            case .digits: return isDigit
            case .upperAlphanumeric: return isDigit || (0x41...0x5A).contains(byte)
            case .hex: return isDigit || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
            }
        }
    }

    // MARK: Fields

    /// The ten logical fields, with the offsets and widths every implementation agrees on.
    public enum Field: String, CaseIterable, Codable, Sendable {
        case month, day, year, vendorId, batch, filamentId, color, filamentLength, serialNumber, reserve

        public var offset: Int {
            switch self {
            case .month: return 0
            case .day: return 1
            case .year: return 3
            case .vendorId: return 5
            case .batch: return 9
            case .filamentId: return 11
            case .color: return 17
            case .filamentLength: return 24
            case .serialNumber: return 28
            case .reserve: return 34
            }
        }

        public var width: Int {
            switch self {
            case .month: return 1
            case .day, .year, .batch: return 2
            case .vendorId, .filamentLength: return 4
            case .filamentId, .serialNumber, .reserve: return 6
            case .color: return 7
            }
        }

        public var alphabet: Alphabet {
            switch self {
            // `day = "B1"` and `batch = "A2"` are demonstrably not decimal, and `month` is "A"
            // in three of the four known samples and "9" in the fourth — so these three take
            // the widest alphabet the corpus supports. See the date discussion below.
            case .month, .day, .batch, .reserve: return .upperAlphanumeric
            case .year, .vendorId, .filamentId, .filamentLength, .serialNumber: return .digits
            case .color: return .hex
            }
        }
    }

    // MARK: Stored fields

    /// `month` + `day` + `year`, 5 characters. **The semantics are unknown** — see `RecordDate`.
    public let date: RecordDate
    /// 4 digits. `0276` is Creality.
    public let vendorId: String
    /// 2 characters. Opaque; always `A2` in the known corpus.
    public let batch: String
    /// 6 digits: a leading class digit (always `'1'` in every implementation) plus the 5-digit
    /// `base.id` from `material_database.json`.
    public let filamentId: String
    /// 7 characters: an unknown leading nibble plus `RRGGBB`.
    ///
    /// The leading nibble is written as `'0'` by all three implementations
    /// (`MainForm.cs:450`, `MainActivity.java`, `Spool_ID.ino:391`: `"0" + materialColor`) and
    /// discarded on read (`MainForm.cs:416` reads offset 18 for 6 characters). All four
    /// `docs/tn_data.json` samples also start with `0`. **Its meaning is not known** — an alpha
    /// channel, a colour-space selector and a multi-colour flag are all consistent with the
    /// evidence, which is to say none of them are supported by it. This type therefore emits
    /// `'0'` when it builds a colour, and preserves whatever it read when it decodes one.
    public let color: String
    /// 4 digits, metres of 1.75 mm filament. See `FilamentLength` for the known values.
    public let filamentLength: String
    /// 6 digits. Windows hard-codes `000001`; Android substitutes a Spoolman id; Arduino
    /// randomises it (`Spool_ID.ino:393`). All three stay within 6 digits.
    public let serialNumber: String
    /// 6 characters. Always `000000`; purpose undocumented.
    public let reserve: String

    // MARK: - The date group

    /// The 5-character date group at offsets 0..4.
    ///
    /// **The encoding is not derivable from any implementation in this repository.** Every one of
    /// them hard-codes the literal `"AB124"` (`MainForm.cs:453`, `MainActivity.java:754`,
    /// `Spool_ID.ino:395`); there is no date formatting anywhere near the tag codec. The known
    /// corpus is two values, `AB124` and `9A224` (README tag table, `docs/tn_data.json`).
    /// `year` is plainly a 2-digit year, but `day` cannot be plain hex — `B1` = 177 and
    /// `A2` = 162 are both out of range for a day of month. The 1/2/2 *boundaries* are firm
    /// (Android parses and length-validates them individually); the *semantics* are not.
    /// Treated here as three opaque strings.
    public struct RecordDate: Equatable, Hashable, Codable, Sendable, CustomStringConvertible {
        public var month: String
        public var day: String
        public var year: String

        public init(month: String, day: String, year: String) {
            self.month = month; self.day = day; self.year = year
        }

        /// `AB124` — the literal every reference implementation writes.
        public static let creality = RecordDate(month: "A", day: "B1", year: "24")

        public var encoded: String { month + day + year }
        public var description: String { encoded }
    }

    // MARK: - Initialisers

    /// Builds a record from already-formatted field values, validating every one.
    ///
    /// - Throws: `SpoolRecordError` naming the first field that is the wrong width or contains a
    ///   byte outside its alphabet.
    public init(date: RecordDate = .creality,
                vendorId: String = SpoolRecord.crealityVendorId,
                batch: String = SpoolRecord.defaultBatch,
                filamentId: String,
                color: String,
                filamentLength: String,
                serialNumber: String = SpoolRecord.defaultSerialNumber,
                reserve: String = SpoolRecord.defaultReserve) throws {
        self.date = date
        self.vendorId = vendorId
        self.batch = batch
        self.filamentId = filamentId
        self.color = color
        self.filamentLength = filamentLength
        self.serialNumber = serialNumber
        self.reserve = reserve
        try Self.validate(self)
    }

    /// The ergonomic form: the three values the Windows UI actually collects.
    ///
    /// Mirrors `WriteSpoolData(MaterialID, Color, Length)` (`MainForm.cs:445-455`) — it prefixes
    /// the material id with `'1'` and the colour with the unknown `'0'` nibble, and uppercases
    /// the hex so the bytes match what `ToString("X6")` produces.
    ///
    /// - Parameters:
    ///   - materialId: exactly 5 digits — `base.id` from `material_database.json`, which the
    ///     Windows app validates the same way (`FilamentForm.cs:251,256`).
    ///   - colorRGB: exactly 6 hex digits, `RRGGBB`, alpha already stripped.
    public init(materialId: String,
                colorRGB: String,
                filamentLength: FilamentLength,
                serialNumber: String = SpoolRecord.defaultSerialNumber,
                date: RecordDate = .creality,
                vendorId: String = SpoolRecord.crealityVendorId,
                batch: String = SpoolRecord.defaultBatch,
                reserve: String = SpoolRecord.defaultReserve) throws {
        // Check the components before concatenating, so the error blames the right thing rather
        // than reporting a 4-character filamentId when the caller passed a 3-character id.
        guard materialId.utf8.count == 5 else {
            throw SpoolRecordError.wrongFieldWidth(field: .filamentId, expected: 6,
                                                   actual: materialId.utf8.count + 1)
        }
        guard colorRGB.utf8.count == 6 else {
            throw SpoolRecordError.wrongFieldWidth(field: .color, expected: 7,
                                                   actual: colorRGB.utf8.count + 1)
        }
        try self.init(date: date,
                      vendorId: vendorId,
                      batch: batch,
                      filamentId: "1" + materialId,
                      color: "0" + colorRGB.uppercased(),
                      filamentLength: filamentLength.rawValue,
                      serialNumber: serialNumber,
                      reserve: reserve)
    }

    // MARK: - Decoding

    /// Parses a record from bytes, validating field widths and alphabets.
    ///
    /// Accepts either the bare 40-byte record or the 48-byte padded form that comes off sector 1;
    /// in the padded case the trailing 8 bytes are ignored rather than required to be `'0'`,
    /// because they carry no information and a foreign writer may well put something else there.
    public init(validating bytes: [UInt8]) throws {
        guard bytes.count == Self.recordLength || bytes.count == Self.paddedLength else {
            throw SpoolRecordError.wrongRecordLength(actual: bytes.count)
        }
        func slice(_ field: Field) -> String {
            String(decoding: bytes[field.offset..<(field.offset + field.width)], as: UTF8.self)
        }
        // Any non-ASCII byte survives this as a replacement character or a multi-byte scalar, and
        // is caught by the width or alphabet check in `validate`.
        try self.init(date: RecordDate(month: slice(.month), day: slice(.day), year: slice(.year)),
                      vendorId: slice(.vendorId),
                      batch: slice(.batch),
                      filamentId: slice(.filamentId),
                      color: slice(.color),
                      filamentLength: slice(.filamentLength),
                      serialNumber: slice(.serialNumber),
                      reserve: slice(.reserve))
    }

    /// Parses a record from a string. See `init(validating: [UInt8])`.
    public init(validating string: String) throws {
        try self.init(validating: Array(string.utf8))
    }

    /// Non-throwing decode. Returns nil for anything `init(validating:)` would reject.
    public init?(decoding string: String) {
        guard let parsed = try? SpoolRecord(validating: string) else { return nil }
        self = parsed
    }

    /// Non-throwing decode. Returns nil for anything `init(validating:)` would reject.
    public init?(decoding bytes: [UInt8]) {
        guard let parsed = try? SpoolRecord(validating: bytes) else { return nil }
        self = parsed
    }

    // MARK: - Encoding

    /// The exact 40-character on-tag record.
    ///
    /// Byte-for-byte what `MainForm.cs:453` concatenates, minus the 8 filler characters that
    /// `paddedPayload` adds.
    public var encoded: String {
        date.encoded + vendorId + batch + filamentId + color + filamentLength + serialNumber + reserve
    }

    /// `encoded` as ASCII bytes — 40 of them, always.
    public var encodedBytes: [UInt8] { Array(encoded.utf8) }

    /// The 48 bytes to hand to `CrealityCrypto.encryptPayload`: the record plus 8 ASCII `'0'`.
    ///
    /// The padding is ASCII `'0'`, not NUL — see `padByte`. Verified against the reference
    /// ciphertexts: for the standard record the final 16 bytes are `"0100000000000000"` (the
    /// trailing `'1'` of `serialNumber = "000001"` lands at offset 33), which encrypts to
    /// `FAC8F07509292DF943D4CDF64CBA06A1`. Padding with NUL instead would produce a completely
    /// different block 6 and an unreadable tag.
    public var paddedPayload: [UInt8] {
        var out = encodedBytes
        out.append(contentsOf: [UInt8](repeating: Self.padByte, count: Self.paddedLength - Self.recordLength))
        return out
    }

    public var description: String { encoded }

    // MARK: - Derived accessors

    /// The 5-digit `base.id` from `material_database.json` — `filamentId` without its class digit.
    public var materialId: String { String(filamentId.dropFirst()) }

    /// The leading class digit of `filamentId`. `'1'` in every known implementation; meaning
    /// undocumented.
    public var filamentClass: Character { filamentId.first ?? "1" }

    /// The unknown leading nibble of `color`, preserved from whatever was decoded.
    public var colorPrefix: Character { color.first ?? "0" }

    /// The `RRGGBB` part of `color` — what the Windows app reads back (`MainForm.cs:416`).
    public var rgbHex: String { String(color.dropFirst()) }

    /// The recognised length, if `filamentLength` is one of the five documented values.
    public var knownLength: FilamentLength? { FilamentLength(rawValue: filamentLength) }

    /// Nominal spool weight. Falls back to 1000 g for an unrecognised length, matching
    /// `GetMaterialWeight`'s default (`Utils.cs:169`).
    public var weightGrams: Int { knownLength?.grams ?? 1000 }

    /// The value of one field, for field-targeted UI and for validation.
    public func value(of field: Field) -> String {
        switch field {
        case .month: return date.month
        case .day: return date.day
        case .year: return date.year
        case .vendorId: return vendorId
        case .batch: return batch
        case .filamentId: return filamentId
        case .color: return color
        case .filamentLength: return filamentLength
        case .serialNumber: return serialNumber
        case .reserve: return reserve
        }
    }

    // MARK: - Validation

    private static func validate(_ record: SpoolRecord) throws {
        for field in Field.allCases {
            let value = record.value(of: field)
            let bytes = Array(value.utf8)
            guard bytes.count == field.width else {
                throw SpoolRecordError.wrongFieldWidth(field: field, expected: field.width,
                                                       actual: bytes.count)
            }
            for (index, byte) in bytes.enumerated() where !field.alphabet.allows(byte) {
                throw SpoolRecordError.illegalByte(field: field, byte: byte, index: index,
                                                   allowed: field.alphabet.rawValue)
            }
        }
    }
}

// MARK: - Codable

/// Decoding goes through the validating initialiser, so a record that came from JSON is subject
/// to exactly the same rules as one that came off a tag.
extension SpoolRecord: Codable {
    private enum CodingKeys: String, CodingKey {
        case date, vendorId, batch, filamentId, color, filamentLength, serialNumber, reserve
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(date: c.decode(RecordDate.self, forKey: .date),
                      vendorId: c.decode(String.self, forKey: .vendorId),
                      batch: c.decode(String.self, forKey: .batch),
                      filamentId: c.decode(String.self, forKey: .filamentId),
                      color: c.decode(String.self, forKey: .color),
                      filamentLength: c.decode(String.self, forKey: .filamentLength),
                      serialNumber: c.decode(String.self, forKey: .serialNumber),
                      reserve: c.decode(String.self, forKey: .reserve))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(date, forKey: .date)
        try c.encode(vendorId, forKey: .vendorId)
        try c.encode(batch, forKey: .batch)
        try c.encode(filamentId, forKey: .filamentId)
        try c.encode(color, forKey: .color)
        try c.encode(filamentLength, forKey: .filamentLength)
        try c.encode(serialNumber, forKey: .serialNumber)
        try c.encode(reserve, forKey: .reserve)
    }
}
