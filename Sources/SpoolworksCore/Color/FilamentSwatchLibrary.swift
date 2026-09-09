import Foundation
import os

/// One manufacturer's colour, as measured.
public struct FilamentSwatch: Codable, Hashable, Sendable, Identifiable {

    public let manufacturer: String
    /// The maker's own name for it — "Galaxy Black", "Sakura Pink".
    public let name: String
    /// The material it was measured in. The same colour name often differs between PLA and PETG,
    /// which is why this is kept rather than collapsed away.
    public let type: String
    /// `RRGGBB`, uppercase.
    public let hex: String
    /// The basic-colour bucket: `BLK`, `WHT`, `GRY`, `RED`, `BLU`, `YLW`, and six more.
    public let parent: String

    public var id: String { "\(manufacturer)|\(name)|\(type)|\(hex)" }

    /// `"Galaxy Black · PETG"`.
    public var label: String { type.isEmpty ? name : "\(name) · \(type)" }

    private enum CodingKeys: String, CodingKey {
        case manufacturer, name, type, hex, parent
    }
}

/// The basic colours, as the dataset buckets them.
public enum BasicColor: String, CaseIterable, Sendable, Identifiable {
    case black = "BLK", white = "WHT", grey = "GRY", red = "RED"
    case blue = "BLU", yellow = "YLW", green = "GRN", orange = "RNG"
    case purple = "PPL", pink = "PNK", brown = "BRN", clear = "TRN"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .black: return "Black"
        case .white: return "White"
        case .grey: return "Grey"
        case .red: return "Red"
        case .blue: return "Blue"
        case .yellow: return "Yellow"
        case .green: return "Green"
        case .orange: return "Orange"
        case .purple: return "Purple"
        case .pink: return "Pink"
        case .brown: return "Brown"
        case .clear: return "Natural"
        }
    }

    /// The six the picker offers as one-click presets. The rest are reachable through a
    /// manufacturer's own list; putting all twelve on the front row would make the common ones
    /// harder to hit, not easier.
    public static let primary: [BasicColor] = [.black, .white, .grey, .red, .blue, .yellow]
}

/// Every filament colour the app knows about, indexed for picking.
///
/// ## Where the numbers come from
///
/// [filamentcolors.xyz](https://filamentcolors.xyz), MIT licensed, credited in `NOTICE`. Its hex
/// values are **colorimeter readings of physical printed swatches**, published alongside their LAB
/// values — not manufacturer marketing images, which are lit, retouched and colour-managed for a
/// web page rather than measured.
///
/// ## What that does and does not licence you to conclude
///
/// A measurement of *printed* filament is a shade off the raw spool, and further off whatever a
/// factory tag encodes. These are excellent for **choosing** a colour when tagging a third-party
/// spool. They are not a substitute for what a Creality tag actually says, and
/// ``SpoolIdentity`` keys on the tag's own value — so a spool tagged from this library and the
/// same spool's factory tag can legitimately disagree.
public struct FilamentSwatchLibrary: Sendable {

    public let swatches: [FilamentSwatch]
    /// Manufacturer names, sorted, as they appear in the data.
    public let manufacturers: [String]

    private let byManufacturer: [String: [FilamentSwatch]]

    public init(swatches: [FilamentSwatch]) {
        self.swatches = swatches
        var index: [String: [FilamentSwatch]] = [:]
        for swatch in swatches {
            index[swatch.manufacturer, default: []].append(swatch)
        }
        // Sorted by basic colour then name, so a maker's list reads as a colour wheel rather than
        // in whatever order the database happened to return.
        for (key, value) in index {
            index[key] = value.sorted {
                ($0.parent, $0.name, $0.type) < ($1.parent, $1.name, $1.type)
            }
        }
        self.byManufacturer = index
        self.manufacturers = index.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private struct Document: Decodable {
        let source: String
        let dbVersion: Int?
        let swatches: [FilamentSwatch]
    }

    /// Loads the bundled library. Returns an empty one rather than throwing: a missing colour list
    /// should cost the user a convenience, not the ability to write a tag.
    public static func bundled() -> FilamentSwatchLibrary {
        // Empty is the right outcome, but a silent one is not: `JSONDecoder` fails the whole
        // array on one bad element, so a single malformed record in a regenerated file would
        // empty all 2,258 swatches and the picker would simply show nothing, with no way for
        // anyone to learn why. The reason goes to the log.
        let log = Logger(subsystem: "com.obsidiang.spoolworks", category: "resources")
        guard let url = SpoolworksCoreResources.bundle?.url(forResource: "filament-swatches",
                                                            withExtension: "json") else {
            log.error("filament-swatches.json is not in the resource bundle; the swatch picker will be empty")
            return FilamentSwatchLibrary(swatches: [])
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: try Data(contentsOf: url))
            return FilamentSwatchLibrary(swatches: document.swatches)
        } catch {
            log.error("filament-swatches.json could not be read, so the swatch picker will be empty: \(String(describing: error), privacy: .public)")
            return FilamentSwatchLibrary(swatches: [])
        }
    }

    public func swatches(for manufacturer: String) -> [FilamentSwatch] {
        byManufacturer[manufacturer] ?? []
    }

    /// A manufacturer's colours in one basic-colour bucket.
    public func swatches(for manufacturer: String, basic: BasicColor) -> [FilamentSwatch] {
        swatches(for: manufacturer).filter { $0.parent == basic.rawValue }
    }

    /// The dataset's name for a manufacturer, matched loosely against a brand the app offers.
    ///
    /// The two vocabularies do not agree on case or spacing — the app says "eSun" where the data
    /// says "eSUN" — and an exact match would silently show an empty list for a brand that is
    /// plainly there.
    public func manufacturer(matching brand: String) -> String? {
        let needle = brand.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                   locale: nil)
            .replacingOccurrences(of: " ", with: "")
        guard !needle.isEmpty else { return nil }
        return manufacturers.first {
            $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .replacingOccurrences(of: " ", with: "") == needle
        }
    }

    public var isEmpty: Bool { swatches.isEmpty }
}
