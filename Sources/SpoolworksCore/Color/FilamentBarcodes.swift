import Foundation
import os

// MARK: - The number under the bars

/// The barcode on a filament box, as the one number every form of it stands for.
///
/// A box carries a GTIN: thirteen digits under an EAN-13, twelve under a UPC-A. They are the same
/// numbering — a UPC-A is an EAN-13 with a leading zero left off — and a scanner reports whichever
/// it likes: Vision hands back a UPC-A as thirteen digits, a database lists it as twelve. So every
/// code is compared in its 14-digit form, and nothing here cares which symbology it arrived in.
public enum BoxBarcode {

    /// The GTIN-14 for `raw`, or nil when it is not a GTIN at all.
    ///
    /// The check digit is verified, not just counted. A camera reading bars off a curved, shiny
    /// box does occasionally produce a wrong digit, and a wrong digit that happens to be somebody
    /// else's product would fill the form with the wrong filament and look entirely plausible.
    public static func normalise(_ raw: String) -> String? {
        let digits = raw.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
            .map { Int($0.value) - 48 }
        // Anything else that is all digits — a lot number, a Code 128 serial — is not a GTIN.
        guard [8, 12, 13, 14].contains(digits.count), digits.allSatisfy({ (0...9).contains($0) }) else {
            return nil
        }
        let body = digits.dropLast()
        // Weights alternate 3, 1 from the digit beside the check digit, whatever the length.
        let total = body.reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset % 2 == 0 ? 3 : 1) }
        guard (10 - total % 10) % 10 == digits[digits.count - 1] else { return nil }
        let text = digits.map(String.init).joined()
        return String(repeating: "0", count: 14 - text.count) + text
    }

    /// The code as it is printed under the bars: thirteen digits, or twelve for a UPC-A.
    public static func display(_ gtin14: String) -> String {
        var text = Substring(gtin14)
        while text.count > 12, text.first == "0" { text = text.dropFirst() }
        return String(text)
    }
}

// MARK: - What a barcode says is in the box

/// The filament a box barcode identifies.
public struct BarcodeFilament: Hashable, Sendable, Codable {

    /// Where the answer came from.
    public enum Source: String, Sendable, Codable {
        /// The Open Filament Database.
        case published
        /// A box scanned here before, described by the user. See ``LearnedBarcodes``.
        case learned
    }

    public var brand: String
    /// The product line: `PolyTerra PLA`. For a learned entry, the spool's name.
    public var line: String
    /// The polymer.
    public var material: String
    /// The maker's name for the colour.
    public var colourName: String
    /// `RRGGBB`, uppercase.
    public var hex: String
    /// What a full spool holds, or nil where the source does not say.
    public var netWeightGrams: Int?
    /// The printer catalogue's id for it — known only for a learned entry, which was described
    /// against the catalogue in the first place.
    public var catalogueID: String?
    public var source: Source

    public init(brand: String, line: String, material: String, colourName: String, hex: String,
                netWeightGrams: Int? = nil, catalogueID: String? = nil, source: Source = .published) {
        self.brand = brand
        self.line = line
        self.material = material
        self.colourName = colourName
        self.hex = Spool.normaliseHex(hex)
        self.netWeightGrams = netWeightGrams
        self.catalogueID = catalogueID
        self.source = source
    }

    /// `"Polymaker PolyTerra PLA"`, without saying the maker twice.
    public var product: String {
        line.lowercased().hasPrefix(brand.lowercased()) ? line
            : [brand, line].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The colour as ``BrandColourCatalogue`` holds one, for naming the spool by it.
    public var colour: BrandColour {
        BrandColour(brand: brand, line: line, material: material, name: colourName, hex: hex,
                    source: .published)
    }
}

// MARK: - The bundled table

/// Box barcodes for the filaments the Open Filament Database lists one for.
///
/// Beside ``BrandColourCatalogue`` and from the same source: that one answers "what does this
/// maker call this colour", this one skips the question — the box already says, and a barcode is
/// read exactly or not at all.
public struct FilamentBarcodeCatalogue: Sendable {

    private let byCode: [String: [BarcodeFilament]]

    public var count: Int { byCode.count }
    public var isEmpty: Bool { byCode.isEmpty }

    public init(entries: [(code: String, filament: BarcodeFilament)]) {
        var index: [String: [BarcodeFilament]] = [:]
        for entry in entries {
            guard let key = BoxBarcode.normalise(entry.code) else { continue }
            if index[key]?.contains(entry.filament) != true {
                index[key, default: []].append(entry.filament)
            }
        }
        byCode = index
    }

    /// Every filament listed under `code`. More than one only where the database files a product
    /// under two names for its line; they are the same box.
    public func filaments(for code: String) -> [BarcodeFilament] {
        guard let key = BoxBarcode.normalise(code) else { return [] }
        return byCode[key] ?? []
    }

    // MARK: Loading

    private struct Document: Decodable {
        struct Brand: Decodable {
            struct Line: Decodable {
                let name: String
                let material: String
                let codes: [Row]
            }
            let name: String
            let lines: [Line]
        }
        /// `[gtin, colour name, hex, net grams]`, as `Tools/build-filament-barcodes.py` writes it.
        struct Row: Decodable {
            let code: String
            let colour: String
            let hex: String
            let grams: Int

            init(from decoder: Decoder) throws {
                var row = try decoder.unkeyedContainer()
                code = try row.decode(String.self)
                colour = try row.decode(String.self)
                hex = try row.decode(String.self)
                grams = (try? row.decode(Int.self)) ?? 0
            }
        }
        let brands: [Brand]
    }

    public static func published(from data: Data) throws -> FilamentBarcodeCatalogue {
        let document = try JSONDecoder().decode(Document.self, from: data)
        return FilamentBarcodeCatalogue(entries: document.brands.flatMap { brand in
            brand.lines.flatMap { line in
                line.codes.map { row in
                    (code: row.code,
                     filament: BarcodeFilament(brand: brand.name, line: line.name,
                                               material: line.material, colourName: row.colour,
                                               hex: row.hex,
                                               netWeightGrams: row.grams > 0 ? row.grams : nil))
                }
            }
        })
    }

    /// The bundled table. Empty when it cannot be read — every box is then one the app has to be
    /// told about once, which is what it does for an unlisted box anyway.
    public static let shared: FilamentBarcodeCatalogue = {
        let log = Logger(subsystem: "com.obsidiang.spoolworks", category: "resources")
        guard let url = SpoolworksCoreResources.bundle?.url(forResource: "filament-barcodes",
                                                           withExtension: "json") else {
            log.error("filament-barcodes.json is not in the resource bundle; no box will be recognised until it has been scanned once")
            return FilamentBarcodeCatalogue(entries: [])
        }
        do {
            return try published(from: Data(contentsOf: url))
        } catch {
            log.error("filament-barcodes.json could not be read: \(String(describing: error), privacy: .public)")
            return FilamentBarcodeCatalogue(entries: [])
        }
    }()
}

// MARK: - Boxes the user has described

/// What the user said was in a box the bundled table did not know.
///
/// The table covers the makers the database has barcodes for, and Creality is barely one of them.
/// But a barcode means the same filament every time, so describing a box once is enough: the next
/// box of it is one scan. These win over the bundled table, because they are this user's answer
/// about this user's catalogue — they carry the catalogue id, which the table cannot.
public struct LearnedBarcodes: Codable, Hashable, Sendable {

    public private(set) var filaments: [String: BarcodeFilament]

    public init(filaments: [String: BarcodeFilament] = [:]) { self.filaments = filaments }

    public func filament(for code: String) -> BarcodeFilament? {
        BoxBarcode.normalise(code).flatMap { filaments[$0] }
    }

    public mutating func learn(_ filament: BarcodeFilament, for code: String) {
        guard let key = BoxBarcode.normalise(code) else { return }
        var learned = filament
        learned.source = .learned
        filaments[key] = learned
    }
}

/// `~/Library/Application Support/Spoolworks/barcodes.json`.
public struct LearnedBarcodesStore: Sendable {

    public let fileURL: URL

    public init(directory: URL, fileName: String = "barcodes.json") {
        fileURL = directory.appendingPathComponent(fileName)
    }

    /// Empty when the file is missing or unreadable, like ``LearnedColourNamesStore/load()``: a
    /// lost answer costs describing one box again.
    public func load() -> LearnedBarcodes {
        guard let data = try? Data(contentsOf: fileURL),
              let learned = try? JSONDecoder().decode(LearnedBarcodes.self, from: data) else {
            return LearnedBarcodes()
        }
        return learned
    }

    public func save(_ learned: LearnedBarcodes) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(learned).write(to: fileURL, options: .atomic)
    }
}
