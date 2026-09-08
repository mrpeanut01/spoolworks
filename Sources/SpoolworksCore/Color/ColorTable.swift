import Foundation

// The named-colour dataset, and the 8-bit sRGB value type the matcher works on.
//
// Source of truth is reference/colors.db (a ZIP holding the meodai
// color-names CSV, 31,861 rows). Tools/build-color-table.sh converts it to
// Resources/colors.bin at build-prep time; see SPEC-05 §1 and §8.1.
//
// The one invariant everything else depends on: entries are stored in original CSV row order.
// ColorMatcher.cs:87 breaks distance ties with a strict `<`, so the lowest row index wins.
// Any reordering here silently changes which name a tie resolves to.

/// A raw 8-bit sRGB triple.
///
/// Deliberately *device* sRGB code values, with no colour management attached: the C# app does
/// all its arithmetic on the integers straight out of the Win32 colour dialog (SPEC-05 §6), so
/// anything that hands a colour to this type must pin it to sRGB first — on macOS that means
/// `NSColor.usingColorSpace(.sRGB)` before reading components (SPEC-05 §8.4).
public struct RGB8: Equatable, Hashable, Sendable {
    public let r: UInt8
    public let g: UInt8
    public let b: UInt8

    public init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// Takes the low 24 bits of `packed`, i.e. `0x00RRGGBB`. Bits 24+ are ignored.
    public init(packed: UInt32) {
        self.r = UInt8((packed >> 16) & 0xFF)
        self.g = UInt8((packed >> 8) & 0xFF)
        self.b = UInt8(packed & 0xFF)
    }

    /// `0x00RRGGBB`.
    public var packed: UInt32 {
        (UInt32(r) << 16) | (UInt32(g) << 8) | UInt32(b)
    }

    /// Uppercase, no `#`, e.g. `"C12E1F"`. Matches `MainForm.cs:710`'s `.ToString("X6")`,
    /// which is the form written into the tag and shown in the Spoolman dialog.
    public var hexString: String {
        String(format: "%02X%02X%02X", r, g, b)
    }

    /// Lowercase with a leading `#`, e.g. `"#c12e1f"`. Matches the CSV's own column-1 form.
    public var cssHexString: String {
        String(format: "#%02x%02x%02x", r, g, b)
    }

    /// The 7-character tag colour field: a literal `'0'` nibble followed by `RRGGBB`.
    ///
    /// `MainForm.cs:450` is `string color = "0" + Color;` and the read path
    /// (`MainForm.cs:416`) starts at offset 18, skipping the nibble entirely. Its meaning in
    /// Creality's firmware is unknown — SPEC-05 §7 open question 1 — so we emit the same
    /// constant every known implementation emits and never try to interpret it.
    public var tagColorField: String {
        "0" + hexString
    }
}

/// Why a hex string could not be turned into an `RGB8`.
public enum ColorHexError: Error, Equatable {
    /// The string had no hex digits left after stripping `#` and whitespace.
    case empty
    /// A character outside `[0-9a-fA-F]` survived the strip.
    case invalidCharacter(String)
    /// Fewer than 6 significant digits — the C# path is length-agnostic, but a short string
    /// almost always means a truncated field rather than a colour the user meant.
    case tooShort(String, digits: Int)
    /// More than 7 digits: there is no defined encoding wider than the tag field.
    case tooLong(String, digits: Int)
    /// A 7-digit field whose leading nibble is not `'0'`. See `RGB8.init(hex:)`.
    case nonZeroLeadingNibble(String)
}

extension ColorHexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Colour hex string is empty."
        case let .invalidCharacter(input):
            return "Colour hex string \"\(input)\" contains a non-hexadecimal character."
        case let .tooShort(input, digits):
            return "Colour hex string \"\(input)\" has \(digits) digits; 6 (RRGGBB) are required."
        case let .tooLong(input, digits):
            return "Colour hex string \"\(input)\" has \(digits) digits; the widest defined form is the 7-character tag field."
        case let .nonZeroLeadingNibble(input):
            return "Tag colour field \"\(input)\" has a non-zero leading nibble. Its meaning is undefined, so the low 24 bits cannot be trusted as a colour."
        }
    }
}

public extension RGB8 {
    /// Parses `"RRGGBB"`, `"#RRGGBB"`, or the 7-character tag field `"0RRGGBB"`.
    ///
    /// Case-insensitive; `#` is stripped from anywhere and surrounding whitespace is trimmed,
    /// matching `ColorMatcher.cs:74`'s `targetHex.Replace("#","")` +
    /// `Convert.ToInt32(…, 16)`.
    ///
    /// **The 7-digit guard is the one deliberate divergence from C#.** `Convert.ToInt32` is
    /// length-agnostic, so the C# code happily parses `"0C12E1F"` as `0xC12E1F` — correct only
    /// because the leading nibble is a hard-coded `'0'` on every write path in both the Windows
    /// and Android apps (SPEC-05 §4.2). Feed it a tag written by other software with, say,
    /// `"3C12E1F"` and it silently yields `0x3C12E1` — every channel shifted a nibble, a
    /// plausible-looking colour, and a wrong match with no diagnostic. Since the nibble's
    /// meaning is unknown (SPEC-05 §7 open question 1) we cannot interpret it, so we refuse it
    /// instead of guessing. Callers that genuinely want the low 24 bits of an arbitrary value
    /// can say so explicitly with `RGB8(packed:)`.
    init(hex: String) throws {
        let digits = hex
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")

        guard !digits.isEmpty else { throw ColorHexError.empty }
        guard digits.allSatisfy(\.isHexDigit) else {
            throw ColorHexError.invalidCharacter(hex)
        }
        guard digits.count >= 6 else {
            throw ColorHexError.tooShort(hex, digits: digits.count)
        }
        guard digits.count <= 7 else {
            throw ColorHexError.tooLong(hex, digits: digits.count)
        }
        if digits.count == 7 {
            guard digits.first == "0" else {
                throw ColorHexError.nonZeroLeadingNibble(hex)
            }
        }
        // Safe: 6 or 7 hex digits always fit in UInt32, and every character passed isHexDigit.
        guard let value = UInt32(digits, radix: 16) else {
            throw ColorHexError.invalidCharacter(hex)
        }
        self.init(packed: value)
    }
}

/// One row of the colour table.
public struct ColorEntry: Equatable, Sendable {
    /// 0-based index into the original CSV data rows. Load-bearing: it is the tie-break key.
    public let index: Int
    public let name: String
    public let rgb: RGB8

    public init(index: Int, name: String, rgb: RGB8) {
        self.index = index
        self.name = name
        self.rgb = rgb
    }

    /// The matched colour's own hex, in the CSV's lowercase `#rrggbb` form.
    public var hexString: String { rgb.cssHexString }
}

/// Why the generated colour resource could not be loaded.
///
/// The C# loader wraps the whole thing in `try { … } catch {}` (`ColorMatcher.cs:37,67`), so a
/// missing or corrupt dataset degrades to an empty list and *every* lookup silently returns
/// null — the user just sees a blank colour name and never learns why (SPEC-05 §7 open
/// question 4). We throw instead; the caller is free to fall back to the raw hex string, which
/// is the same user-visible outcome, but the failure is now diagnosable.
public enum ColorTableError: Error, Equatable {
    case resourceMissing(name: String)
    case unreadable(name: String, reason: String)
    case tooSmall(bytes: Int)
    case badMagic(found: String)
    case unsupportedVersion(UInt32)
    case sizeMismatch(expected: Int, actual: Int)
    case checksumMismatch(expected: UInt64, actual: UInt64)
    case corruptNameOffsets(index: Int)
    case invalidUTF8(index: Int)
}

extension ColorTableError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .resourceMissing(name):
            return "Colour table resource \"\(name)\" is missing from the bundle. Run Tools/build-color-table.sh."
        case let .unreadable(name, reason):
            return "Colour table resource \"\(name)\" could not be read: \(reason)"
        case let .tooSmall(bytes):
            return "Colour table is truncated: \(bytes) bytes is smaller than the \(ColorTable.headerSize)-byte header."
        case let .badMagic(found):
            return "Colour table has the wrong magic (found \"\(found)\", expected \"K2CT\"). The resource is not a colour table."
        case let .unsupportedVersion(version):
            return "Colour table format version \(version) is not supported by this build (expected \(ColorTable.formatVersion)). Re-run Tools/build-color-table.sh."
        case let .sizeMismatch(expected, actual):
            return "Colour table is truncated: header describes \(expected) bytes, file is \(actual)."
        case let .checksumMismatch(expected, actual):
            return String(format: "Colour table is corrupt: checksum 0x%016llX does not match the stored 0x%016llX.", actual, expected)
        case let .corruptNameOffsets(index):
            return "Colour table has a corrupt name offset at record \(index)."
        case let .invalidUTF8(index):
            return "Colour table record \(index) is not valid UTF-8."
        }
    }
}

/// The 31,861-entry named-colour table, in original CSV row order.
///
/// Immutable after loading, so it is safe to share; `ColorTable.shared()` hands out one
/// process-wide instance rather than re-parsing per dialog the way `SmDialog.cs:58` does.
public final class ColorTable: @unchecked Sendable {
    public static let resourceName = "colors"
    public static let resourceExtension = "bin"
    public static let formatVersion: UInt32 = 1
    /// magic + version + count + namesLength + checksum.
    static let headerSize = 24

    /// Packed `0x00RRGGBB`, one per record, in CSV row order. Contiguous so the match loop is
    /// a straight scan.
    private let packed: [UInt32]
    /// `count + 1` byte offsets into `nameBytes`; record `i` spans `[offsets[i], offsets[i+1])`.
    private let offsets: [UInt32]
    private let nameBytes: [UInt8]
    /// Lazily built on first name lookup — most sessions only ever go rgb → name.
    private lazy var nameIndex: [String: Int] = {
        var map: [String: Int] = [:]
        map.reserveCapacity(packed.count)
        for i in 0..<packed.count {
            // First row wins, mirroring the matcher's tie-break. Names are in fact unique
            // across all 31,861 rows, so this only matters if the dataset is ever rebuilt.
            let key = name(at: i).lowercased()
            if map[key] == nil { map[key] = i }
        }
        return map
    }()
    private let nameIndexLock = NSLock()

    // MARK: - Loading

    private static let bundled: Result<ColorTable, Error> = Result {
        // Deliberately NOT `Bundle.module`: it traps when the bundle is missing, making
        // `ColorTableError.resourceMissing` unreachable, and it falls back to an absolute build
        // path baked in at compile time. See SpoolworksCoreResources.
        guard let bundle = SpoolworksCoreResources.bundle else {
            throw ColorTableError.resourceMissing(name: SpoolworksCoreResources.searchedDescription)
        }
        return try ColorTable(bundle: bundle)
    }

    /// The process-wide table, parsed once. Throws the original load error on every call.
    public static func shared() throws -> ColorTable {
        try bundled.get()
    }

    /// The bundle the generated resource ships in, or nil if it is absent.
    public static var resourceBundle: Bundle? { SpoolworksCoreResources.bundle }

    /// Location of the generated resource inside `bundle`. Exposed so callers (and tests) can
    /// read the raw blob without going through a full parse.
    public static func resourceURL(in bundle: Bundle) throws -> URL {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension) else {
            throw ColorTableError.resourceMissing(name: "\(resourceName).\(resourceExtension)")
        }
        return url
    }

    /// Location of the generated resource in the SpoolworksCore bundle.
    public static func resourceURL() throws -> URL {
        guard let bundle = resourceBundle else {
            throw ColorTableError.resourceMissing(name: SpoolworksCoreResources.searchedDescription)
        }
        return try resourceURL(in: bundle)
    }

    /// Loads the generated resource from `bundle`.
    public convenience init(bundle: Bundle) throws {
        let url = try Self.resourceURL(in: bundle)
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ColorTableError.unreadable(name: url.lastPathComponent,
                                             reason: error.localizedDescription)
        }
        try self.init(blob: data)
    }

    /// Parses a colour-table blob. See `Tools/build-color-table.sh` for the layout.
    public init(blob: Data) throws {
        let bytes = [UInt8](blob)
        guard bytes.count >= Self.headerSize else {
            throw ColorTableError.tooSmall(bytes: bytes.count)
        }

        let magic = String(decoding: bytes[0..<4], as: UTF8.self)
        guard magic == "K2CT" else { throw ColorTableError.badMagic(found: magic) }

        let version = Self.readUInt32(bytes, 4)
        guard version == Self.formatVersion else {
            throw ColorTableError.unsupportedVersion(version)
        }

        let count = Int(Self.readUInt32(bytes, 8))
        let namesLength = Int(Self.readUInt32(bytes, 12))
        let storedHash = Self.readUInt64(bytes, 16)

        // Overflow-safe because count and namesLength are UInt32 widened to Int (64-bit).
        let rgbBytes = count * 4
        let offsetBytes = (count + 1) * 4
        let expectedSize = Self.headerSize + rgbBytes + offsetBytes + namesLength
        guard bytes.count == expectedSize else {
            throw ColorTableError.sizeMismatch(expected: expectedSize, actual: bytes.count)
        }

        let actualHash = Self.fnv1a64(bytes, from: Self.headerSize)
        guard actualHash == storedHash else {
            throw ColorTableError.checksumMismatch(expected: storedHash, actual: actualHash)
        }

        var packed = [UInt32]()
        packed.reserveCapacity(count)
        for i in 0..<count {
            packed.append(Self.readUInt32(bytes, Self.headerSize + i * 4))
        }

        let offsetsBase = Self.headerSize + rgbBytes
        var offsets = [UInt32]()
        offsets.reserveCapacity(count + 1)
        for i in 0...count {
            offsets.append(Self.readUInt32(bytes, offsetsBase + i * 4))
        }

        // Validate once at load so `name(at:)` can slice without bounds checks or optionals.
        var previous: UInt32 = 0
        for i in 0...count {
            let offset = offsets[i]
            guard offset >= previous, offset <= UInt32(namesLength) else {
                throw ColorTableError.corruptNameOffsets(index: min(i, max(count - 1, 0)))
            }
            previous = offset
        }
        guard offsets[count] == UInt32(namesLength) else {
            throw ColorTableError.corruptNameOffsets(index: max(count - 1, 0))
        }

        let namesBase = offsetsBase + offsetBytes
        self.packed = packed
        self.offsets = offsets
        self.nameBytes = Array(bytes[namesBase..<(namesBase + namesLength)])

        // The names blob is UTF-8 (739 rows are non-ASCII). Validate the whole blob up front
        // rather than per lookup — a Latin-1 or truncated rebuild is caught at load, not when
        // some unlucky user happens to match "5-Masted Preußen".
        guard String(bytes: self.nameBytes, encoding: .utf8) != nil else {
            throw ColorTableError.invalidUTF8(index: 0)
        }
    }

    // MARK: - Access

    public var count: Int { packed.count }

    /// The packed colours, in CSV row order, for a caller that wants to run its own scan.
    public var packedColors: [UInt32] { packed }

    public func rgb(at index: Int) -> RGB8 {
        RGB8(packed: packed[index])
    }

    public func name(at index: Int) -> String {
        let start = Int(offsets[index])
        let end = Int(offsets[index + 1])
        return String(decoding: nameBytes[start..<end], as: UTF8.self)
    }

    public func entry(at index: Int) -> ColorEntry {
        ColorEntry(index: index, name: name(at: index), rgb: rgb(at: index))
    }

    /// Exact name lookup, case-insensitive and whitespace-trimmed.
    ///
    /// The C# app has no such lookup — matching is one-way there — but the tag stores only a
    /// hex value, so going the other way is useful when a name arrives from Spoolman.
    public func index(forName name: String) -> Int? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        nameIndexLock.lock()
        defer { nameIndexLock.unlock() }
        return nameIndex[key]
    }

    public func entry(forName name: String) -> ColorEntry? {
        index(forName: name).map { entry(at: $0) }
    }

    /// name → `"#rrggbb"`, or nil if the name is not in the dataset.
    public func hex(forName name: String) -> String? {
        entry(forName: name)?.hexString
    }

    // MARK: - Blob primitives

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func readUInt64(_ bytes: [UInt8], _ offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in (0..<8).reversed() {
            value = (value << 8) | UInt64(bytes[offset + i])
        }
        return value
    }

    /// FNV-1a 64, matching the generator. Corruption detection only, not a security hash.
    static func fnv1a64(_ bytes: [UInt8], from start: Int) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        bytes.withUnsafeBufferPointer { buffer in
            for i in start..<buffer.count {
                hash = (hash ^ UInt64(buffer[i])) &* 0x0000_0100_0000_01B3
            }
        }
        return hash
    }
}
