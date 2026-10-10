import Foundation
import CryptoKit

// MARK: - One filament

/// One entry of a HueForge filament library.
///
/// The shape is taken from HueForge 0.9.4.3 itself rather than from documentation, because there is
/// none: all 20 vendor libraries it ships (890 entries) carry exactly these seven keys, and the
/// community-library template (`thehueforge/hueforge-community-library-example`) lists the same
/// seven as required.
///
/// Traps this type exists to get right:
/// - The key is `Transmissivity` although HueForge's own UI has called the value *Transmission
///   Distance* (TD) since before launch. The CSV column is `TD`. Same number, two names.
/// - `uuid` is lower-case as a key and is a **braced** GUID as a value: `{1800e8df-…}`.
/// - `Color` is `#rrggbb`, lower-case. Spoolworks holds `RRGGBB`; see ``init(brand:name:type:colorHex:transmissivity:owned:uuid:)``.
/// - Dual-colour and silk filaments carry `Tags`, `Secondary_Color`, `Secondary_Strength` and
///   `Secondary_Type`. Spoolworks does not model those, so they ride in ``additionalFields`` and
///   are written back verbatim — a library read here and re-saved loses nothing.
public struct HueForgeFilament: Hashable, Sendable, Codable {

    /// The product line, not the manufacturer: `PolyLite`, `BambuLab Basic`, `Creality Hyper`.
    public var brand: String
    /// `#rrggbb`.
    public var color: String
    /// The colour's name within the line: `White`, `Blue Gray`.
    public var name: String
    /// Whether it shows under *Owned* in HueForge's filament list.
    public var owned: Bool
    /// Transmission distance in millimetres.
    public var transmissivity: Double
    /// The polymer: `PLA`, `PLA+`, `PETG`, …
    public var type: String
    /// `{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}`. What HueForge's import matches on first.
    public var uuid: String
    /// Keys this struct does not model, preserved verbatim.
    public var additionalFields: [String: JSONValue]

    public init(brand: String,
                name: String,
                type: String,
                colorHex: String,
                transmissivity: Double,
                owned: Bool = true,
                uuid: String,
                additionalFields: [String: JSONValue] = [:]) {
        self.brand = brand
        self.name = name
        self.type = type
        self.color = Self.hueForgeColor(colorHex)
        self.transmissivity = transmissivity
        self.owned = owned
        self.uuid = uuid
        self.additionalFields = additionalFields
    }

    /// `RRGGBB`, upper-case, no `#` — the form the rest of Spoolworks holds a colour in.
    public var colorHex: String { Spool.normaliseHex(color) }

    /// `C12E1F` / `#c12e1f` / the tag's 7-character `0C12E1F` → `#c12e1f`.
    public static func hueForgeColor(_ raw: String) -> String {
        "#" + Spool.normaliseHex(raw).lowercased()
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case brand = "Brand"
        case color = "Color"
        case name = "Name"
        case owned = "Owned"
        case transmissivity = "Transmissivity"
        case type = "Type"
        case uuid
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        func raw(_ k: CodingKeys) throws -> JSONValue? {
            try c.decodeIfPresent(JSONValue.self, forKey: AnyCodingKey(stringValue: k.rawValue))
        }
        // Brand, name and TD are what make an entry usable; the rest have honest fallbacks. Read
        // leniently — a hand-edited library with `"Transmissivity": "1.5"` is still a library.
        guard let brand = try raw(.brand)?.stringValue,
              let name = try raw(.name)?.stringValue,
              let td = try raw(.transmissivity)?.doubleValue else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: c.codingPath,
                debugDescription: "a HueForge filament needs Brand, Name and Transmissivity"))
        }
        self.brand = brand
        self.name = name
        self.transmissivity = td
        self.color = Self.hueForgeColor(try raw(.color)?.stringValue ?? "000000")
        self.owned = try raw(.owned)?.boolValue ?? false
        self.type = try raw(.type)?.stringValue ?? "PLA"
        self.uuid = try raw(.uuid)?.stringValue ?? ""

        let modelled = Set(CodingKeys.allCases.map(\.rawValue))
        var extras: [String: JSONValue] = [:]
        for k in c.allKeys where !modelled.contains(k.stringValue) {
            extras[k.stringValue] = try c.decode(JSONValue.self, forKey: k)
        }
        additionalFields = extras
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.rawValue) }
        try c.encode(brand, forKey: key(.brand))
        try c.encode(color, forKey: key(.color))
        try c.encode(name, forKey: key(.name))
        try c.encode(owned, forKey: key(.owned))
        try c.encode(transmissivity, forKey: key(.transmissivity))
        try c.encode(type, forKey: key(.type))
        try c.encode(uuid, forKey: key(.uuid))
        let modelled = Set(CodingKeys.allCases.map(\.rawValue))
        for (k, v) in additionalFields where !modelled.contains(k) {
            try c.encode(v, forKey: AnyCodingKey(stringValue: k))
        }
    }
}

// MARK: - Stable ids

public extension HueForgeFilament {

    /// The uuid Spoolworks gives a filament, derived from what the filament *is*.
    ///
    /// Derived rather than random because HueForge's import matches on uuid first: exporting the
    /// same filament twice with two random ids would add it to the library twice, while the same
    /// id lets HueForge offer *Update Selected Entries* instead. That is the whole of what makes a
    /// second export a sync and not a duplicate.
    ///
    /// Keyed on brand line, polymer and colour — the same three things ``SpoolIdentity`` separates
    /// spools on — and **not** on the colour's name or the TD, so correcting either in Spoolworks
    /// updates the HueForge entry in place rather than orphaning it.
    ///
    /// SHA-256 folded into the RFC 4122 name-based layout (version 5, variant 1). Not a strict
    /// UUIDv5 — that is SHA-1 — but HueForge only requires the 8-4-4-4-12 shape, and its own
    /// shipped ids are not valid RFC versions either.
    static func stableUUID(brand: String, type: String, colorHex: String) -> String {
        let key = ["spoolworks", brand, type, Spool.normaliseHex(colorHex)]
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        func part(_ from: Int, _ length: Int) -> Substring {
            let start = hex.index(hex.startIndex, offsetBy: from)
            return hex[start..<hex.index(start, offsetBy: length)]
        }
        return "{\(part(0, 8))-\(part(8, 4))-\(part(12, 4))-\(part(16, 4))-\(part(20, 12))}"
    }
}

// MARK: - A library file

public enum HueForgeError: Error, Equatable, LocalizedError {
    case unreadable(String)
    case csvMissingHeaders([String])
    case notAHueForgeFolder(String)
    case insideApplicationBundle(String)
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case let .unreadable(why):
            return "That is not a HueForge filament file — \(why)."
        case let .csvMissingHeaders(missing):
            return "The CSV is missing the column\(missing.count == 1 ? "" : "s") "
                + missing.joined(separator: ", ") + ". HueForge's are Brand, Type, Color, Name, TD."
        case let .notAHueForgeFolder(path):
            return "\(path) has no Filaments folder in it, so it is not a HueForge folder."
        case let .insideApplicationBundle(path):
            return "\(path) is inside an application. Writing there would break the app's "
                + "signature; choose HueForge's data folder instead."
        case let .storage(why):
            return why
        }
    }
}

/// A HueForge filament library: `{ "Filaments": [ … ] }`.
///
/// One type for all four files HueForge keeps in this shape — `personal_library.json`, the vendor
/// libraries, community libraries, and what *Filaments ▸ Export* writes — and for its CSV, which
/// is the same rows under the headers `Brand, Type, Color, Name, TD` plus optional `Owned, Uuid`.
public struct HueForgeLibrary: Hashable, Sendable {

    public var filaments: [HueForgeFilament]

    public init(filaments: [HueForgeFilament] = []) {
        self.filaments = filaments
    }

    // MARK: JSON

    /// Reads a library, tolerating the lower-case `filaments` key HueForge's own filament *sets*
    /// (`.fss`) use, and skipping entries it cannot make sense of rather than refusing the file.
    public init(json data: Data) throws {
        let root: [String: JSONValue]
        do {
            root = try JSONDecoder().decode([String: JSONValue].self, from: data)
        } catch {
            throw HueForgeError.unreadable("it is not a JSON object")
        }
        guard case let .array(items)? = root["Filaments"] ?? root["filaments"] else {
            throw HueForgeError.unreadable("it has no \"Filaments\" list")
        }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        filaments = items.compactMap { item in
            guard let raw = try? encoder.encode(item) else { return nil }
            return try? decoder.decode(HueForgeFilament.self, from: raw)
        }
    }

    /// The library as HueForge writes it: sorted keys, LF line endings.
    ///
    /// LF matters for a community source — the manifest's `sha256` is taken over LF-normalised
    /// content, so a file written any other way fails HueForge's integrity check.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(["Filaments": filaments])
        data.append(0x0A)
        return data
    }

    // MARK: CSV

    public static let csvRequiredHeaders = ["Brand", "Type", "Color", "Name", "TD"]
    public static let csvOptionalHeaders = ["Owned", "Uuid"]

    public func csvString() -> String {
        var lines = [(Self.csvRequiredHeaders + Self.csvOptionalHeaders).joined(separator: ",")]
        for f in filaments {
            lines.append([f.brand, f.type, f.color, f.name, Self.number(f.transmissivity),
                          f.owned ? "true" : "false", f.uuid]
                .map(Self.csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Reads HueForge's CSV. Headers are matched case-insensitively and in any order; columns it
    /// does not name are ignored, which is also what HueForge does with them.
    public init(csv text: String) throws {
        // Excel and Numbers both lead a UTF-8 CSV with a byte-order mark, which would otherwise
        // become part of the first header's name.
        var rows = Self.csvRows(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
        guard !rows.isEmpty else { throw HueForgeError.unreadable("it is empty") }
        let header = rows.removeFirst().map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        func column(_ name: String) -> Int? { header.firstIndex(of: name.lowercased()) }
        let missing = Self.csvRequiredHeaders.filter { column($0) == nil }
        guard missing.isEmpty else { throw HueForgeError.csvMissingHeaders(missing) }

        filaments = rows.compactMap { row in
            func value(_ name: String) -> String? {
                guard let i = column(name), i < row.count else { return nil }
                return row[i].trimmingCharacters(in: .whitespaces)
            }
            guard let brand = value("Brand"), let name = value("Name"),
                  let td = value("TD").flatMap(Double.init) else { return nil }
            return HueForgeFilament(
                brand: brand,
                name: name,
                type: value("Type") ?? "PLA",
                colorHex: value("Color") ?? "000000",
                transmissivity: td,
                owned: JSONValue.string(value("Owned") ?? "").boolValue ?? false,
                uuid: value("Uuid") ?? "")
        }
    }

    /// Reads either format, going by the file's extension and falling back to its first character.
    public init(contentsOf url: URL) throws {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw HueForgeError.unreadable(error.localizedDescription)
        }
        let looksLikeJSON = data.first { !$0.isASCIIWhitespace } == UInt8(ascii: "{")
        if url.pathExtension.lowercased() == "csv" || !looksLikeJSON {
            try self.init(csv: String(decoding: data, as: UTF8.self))
        } else {
            try self.init(json: data)
        }
    }

    /// `5`, `0.3`, `12.5` — never `5.0`, and never the binary tail of a `Double`.
    public static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(rounded)
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// RFC 4180: quoted fields, doubled quotes, and newlines inside quotes.
    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var chars = text.makeIterator()
        var pending = chars.next()
        func endRow() {
            row.append(field)
            field = ""
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []
        }
        while let ch = pending {
            pending = chars.next()
            if quoted {
                if ch == "\"" {
                    if pending == "\"" { field.append("\""); pending = chars.next() }
                    else { quoted = false }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" {
                quoted = true
            } else if ch == "," {
                row.append(field)
                field = ""
            } else if ch.isNewline {
                // "\r\n" is one Character in Swift, so this is one row end, not two.
                endRow()
            } else {
                field.append(ch)
            }
        }
        endRow()
        return rows
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}
