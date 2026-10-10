import Foundation
import os

// MARK: - One maker's colour

/// A colour as its maker sells it: whose it is, which product line, and what they call it.
public struct BrandColour: Hashable, Sendable, Identifiable {

    /// Where the hex came from, which is how far it can be trusted as a *colour*.
    public enum Source: String, Sendable {
        /// The maker's published value (Open Filament Database). Right for the name, nominal as a
        /// colour — a marketing hex, not a reading.
        case published
        /// A colorimeter reading of a printed swatch (filamentcolors.xyz). What a camera sees.
        case measured
    }

    public let brand: String
    /// The product line: `Hyper PLA`, `PolyLite PETG`, `Matte PLA`.
    public let line: String
    /// The polymer, where the source records one separately from the line.
    public let material: String
    /// The maker's own name for the colour: `Skin`, `Galaxy Black`.
    public let name: String
    /// `RRGGBB`, uppercase.
    public let hex: String
    public let source: Source

    public var id: String { "\(brand)|\(line)|\(name)|\(hex)|\(source.rawValue)" }

    /// `"Skin · Hyper PLA"`.
    public var label: String { line.isEmpty ? name : "\(name) · \(line)" }
}

// MARK: - The catalogue

/// Every maker's colours, indexed by maker, for answering "what does *this brand* call this?".
///
/// ## Why this exists beside ``ColorMatcher``
///
/// ``ColorMatcher`` names a colour by the nearest of 31,861 generic names, which is the right
/// answer to "what colour is this" and the wrong answer to "what is this filament called". A
/// factory Creality Hyper PLA Red (`C12E1F`) came out as "Cherry Pie" and Skin (`E7CEB5`) as
/// "Malibu Dune" — both good descriptions, neither on any box. A filament's colour name belongs to
/// its maker, so the search has to start inside the maker's own list.
///
/// ## Two sources, deliberately both
///
/// The Open Filament Database supplies breadth and the makers' own names (156 brands); its hexes
/// are published values. filamentcolors.xyz supplies colorimeter readings of printed swatches (150
/// brands, 67 in common). A tag's hex resembles the first, a camera reading the second, and
/// neither set covers the other's gaps — so every lookup searches both and keeps the nearer.
public struct BrandColourCatalogue: Sendable {

    private struct Entry: Sendable {
        let colour: BrandColour
        let lab: LabColor
        let lineTokens: Set<String>
        let nameKey: String
    }

    private let byBrand: [String: [Entry]]
    /// Brand key → the name to show for it.
    private let brandNames: [String: String]
    /// Brand names as token lists, longest first, for finding a maker inside free text.
    private let brandTokens: [(key: String, tokens: [String])]

    public var count: Int { byBrand.values.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { byBrand.isEmpty }
    /// Display names of every maker, sorted.
    public var brands: [String] {
        brandNames.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    public init(colours: [BrandColour]) {
        var index: [String: [Entry]] = [:]
        var names: [String: String] = [:]
        for colour in colours {
            guard let rgb = try? RGB8(hex: colour.hex) else { continue }
            let key = Self.brandKey(colour.brand)
            guard !key.isEmpty else { continue }
            // A single-colour product is listed with the product as its "colour" — `HP ASA` in
            // line `HP ASA`, `CR-Wood` in `PLA CR-Wood`. That is not a colour name, and offered as
            // one it reads as nonsense ("Hyper PLA · HP ASA").
            let nameWords = Set(Self.tokens(colour.name))
            let lineWords = Set(Self.tokens(colour.line))
            if nameWords == lineWords
                || nameWords == lineWords.subtracting(Self.tokens(colour.material)) { continue }
            // Published names win the display slot: "eSUN" over a second source's "eSUN 3D".
            if names[key] == nil || colour.source == .published { names[key] = colour.brand }
            index[key, default: []].append(Entry(
                colour: colour,
                lab: LabColor(rgb),
                lineTokens: Self.lineTokens(colour.line, material: colour.material, brandKey: key),
                nameKey: Self.tokens(colour.name).joined()))
        }
        byBrand = index
        brandNames = names
        brandTokens = names.map { (key: $0.key, tokens: Self.tokens($0.value)) }
            .filter { !$0.tokens.isEmpty }
            .sorted { $0.tokens.joined().count > $1.tokens.joined().count }
    }

    // MARK: Vocabulary

    /// Lower-case words. `PLA+` keeps its plus as a word, because `PLA` and `PLA+` are different
    /// lines with different colour lists.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "+", with: " plus ")
            .folding(options: .diacriticInsensitive, locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Makers the two sources — and the printer's catalogue — spell differently.
    private static let brandAliases = [
        "esun3d": "esun", "bambu": "bambulab", "bambulabs": "bambulab",
        "prusa": "prusament", "prusaresearch": "prusament", "amolen": "amolen", "molen": "amolen",
    ]

    static func brandKey(_ brand: String) -> String {
        let key = tokens(brand).joined()
        return brandAliases[key] ?? key
    }

    /// Words that say nothing about which line a filament is.
    private static let noise: Set<String> = ["generic", "filament", "filaments", "1", "75mm", "175mm"]

    /// A line as a set of words, with the maker's own name taken out and the polymer put in.
    ///
    /// Both halves matter. The printer's catalogue says `Polymaker ABS` where the maker says
    /// `PolyLite ABS`, and one source files a line as `Matte` with polymer `PLA` where another
    /// calls the whole thing `Matte PLA`; as word sets they meet.
    static func lineTokens(_ line: String, material: String, brandKey: String) -> Set<String> {
        var words = tokens(line) + tokens(material)
        words.removeAll { noise.contains($0) || brandKey == (brandAliases[$0] ?? $0) }
        return Set(words)
    }

    // MARK: Finding the maker

    /// The catalogue's maker for a spool, looking in its name when its brand is not one.
    ///
    /// The printer's catalogue files most third-party filament under brand `Generic` with the maker
    /// in the name — `Generic` / `Overture - Matte PLA` — so the brand field alone finds nothing
    /// for exactly the spools that most need it.
    public func brand(for brand: String, name: String = "") -> String? {
        let direct = Self.brandKey(brand)
        if let found = brandNames[direct] { return found }

        let words = Self.tokens(brand + " " + name).map { Self.brandAliases[$0] ?? $0 }
        for candidate in brandTokens {
            // Short names are too easy to find by accident inside a product name.
            guard candidate.key.count >= 4 else { continue }
            let needle = candidate.tokens
            guard needle.count <= words.count else { continue }
            let joinedHit = words.contains(candidate.key)
            let sequenceHit = (0...(words.count - needle.count)).contains {
                Array(words[$0..<($0 + needle.count)]) == needle
            }
            if joinedHit || sequenceHit { return brandNames[candidate.key] }
        }
        return nil
    }

    // MARK: Matching

    /// How wide the search had to go to find a candidate.
    public enum Scope: Int, Sendable, Comparable {
        /// The spool's own product line.
        case line
        /// Another line from the same maker.
        case brand
        /// Any maker — only when the spool's maker is unknown.
        case anywhere

        public static func < (lhs: Scope, rhs: Scope) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Match: Hashable, Sendable, Identifiable {
        public let colour: BrandColour
        /// CIEDE2000 to the colour asked about.
        public let deltaE: Double
        public let scope: Scope
        public var id: String { colour.id }
    }

    /// The maker's colours nearest to `hex`, nearest first, one per distinct name — up to `limit`
    /// from the spool's own line, then up to `limit` more from the rest of the maker's range.
    ///
    /// Both groups are always returned, because a line that simply does not list the colour would
    /// otherwise crowd out the answer: Hyper PLA has fifteen colours and none is the navy a
    /// factory Blue tag carries, while Hyper PETG's Blue is right there.
    ///
    /// The spool's own line is searched first and reported as ``Scope/line``; the rest of the
    /// maker's range follows as ``Scope/brand``. With no recognisable maker the whole catalogue is
    /// searched instead, which is a list of lookalikes rather than of names for this filament —
    /// callers must not auto-name from ``Scope/anywhere``.
    public func matches(brand: String, name: String = "", material: String = "",
                        hex: String, limit: Int = 5) -> [Match] {
        guard let rgb = try? RGB8(hex: Spool.normaliseHex(hex)) else { return [] }
        let lab = LabColor(rgb)

        guard let maker = self.brand(for: brand, name: name) else {
            return nearest(in: byBrand.values.joined(), to: lab, scope: .anywhere,
                           distinctBy: { "\($0.colour.brand)|\($0.nameKey)" }, limit: limit)
        }
        let key = Self.brandKey(maker)
        let pool = byBrand[key] ?? []
        let wanted = Self.lineTokens(name, material: material, brandKey: key)

        // The line is the entries whose words equal the spool's; failing that, the ones that
        // contain them all — `ABS` is found inside `PolyLite ABS`. An exact line is preferred
        // because `Hyper PLA` is also contained in `Hyper PLA-CF`, which is a different product
        // with different colours.
        var inLine: [Entry] = []
        if !wanted.isEmpty {
            inLine = pool.filter { $0.lineTokens == wanted }
            if inLine.isEmpty { inLine = pool.filter { wanted.isSubset(of: $0.lineTokens) } }
        }
        let lineMatches = nearest(in: inLine, to: lab, scope: .line,
                                  distinctBy: \.nameKey, limit: limit)
        let taken = Set(lineMatches.map { Self.tokens($0.colour.name).joined() })
        let brandMatches = nearest(in: pool.filter { !taken.contains($0.nameKey) }, to: lab,
                                   scope: .brand, distinctBy: \.nameKey, limit: limit)
        return lineMatches + brandMatches
    }

    private func nearest<S: Sequence>(in entries: S, to lab: LabColor, scope: Scope,
                                      distinctBy key: (Entry) -> String,
                                      limit: Int) -> [Match] where S.Element == Entry {
        var best: [String: Match] = [:]
        for entry in entries {
            let distance = lab.deltaE2000(to: entry.lab)
            let k = key(entry)
            if let held = best[k], held.deltaE <= distance { continue }
            best[k] = Match(colour: entry.colour, deltaE: distance, scope: scope)
        }
        // Ties broken by name so the order is the same on every run.
        return Array(best.values.sorted { ($0.deltaE, $0.colour.name) < ($1.deltaE, $1.colour.name) }
            .prefix(limit))
    }

    // MARK: Loading

    private struct PublishedDocument: Decodable {
        struct Brand: Decodable {
            struct Line: Decodable {
                let name: String
                let material: String
                let colours: [[String]]
            }
            let name: String
            let lines: [Line]
        }
        let brands: [Brand]
    }

    /// The published colours in `brand-colours.json`, as written by `Tools/build-brand-colours.py`.
    public static func published(from data: Data) throws -> [BrandColour] {
        try JSONDecoder().decode(PublishedDocument.self, from: data).brands.flatMap { brand in
            brand.lines.flatMap { line in
                line.colours.compactMap { pair -> BrandColour? in
                    guard pair.count == 2 else { return nil }
                    return BrandColour(brand: brand.name, line: line.name, material: line.material,
                                       name: pair[0], hex: pair[1], source: .published)
                }
            }
        }
    }

    /// Both bundled sources. Loaded once; about 17,000 colours and a few milliseconds.
    ///
    /// Degrades to whatever could be read, like ``FilamentSwatchLibrary/bundled()``: a missing
    /// list costs brand names, and every caller already falls back to a generic one.
    public static let shared: BrandColourCatalogue = {
        var colours = FilamentSwatchLibrary.bundled().swatches.map {
            BrandColour(brand: $0.manufacturer, line: $0.type, material: "", name: $0.name,
                        hex: $0.hex, source: .measured)
        }
        let log = Logger(subsystem: "com.obsidiang.spoolworks", category: "resources")
        if let url = SpoolworksCoreResources.bundle?.url(forResource: "brand-colours",
                                                        withExtension: "json") {
            do {
                colours += try published(from: Data(contentsOf: url))
            } catch {
                log.error("brand-colours.json could not be read, so fewer colours will be named by their maker: \(String(describing: error), privacy: .public)")
            }
        } else {
            log.error("brand-colours.json is not in the resource bundle; fewer colours will be named by their maker")
        }
        return BrandColourCatalogue(colours: colours)
    }()
}

// MARK: - Naming a colour

/// Where a spool's colour name came from.
///
/// Stored with the name because the two kinds are not interchangeable: a maker's name is a fact
/// about the filament, a generic one is a description of a colour, and a screen that shows both the
/// same way invites reading "Cherry Pie" off a box that says "Red".
public enum ColourNameSource: String, Codable, Sendable {
    /// The user said so, here or for an earlier spool of the same filament and colour.
    case learned
    /// The maker's name, matched without doubt.
    case brand
    /// The nearest generic colour name. A description, not a product name.
    case generic
}

/// What the user has told the app a colour is called.
///
/// Keyed on the filament and the exact hex, so the answer given for one spool is the answer for
/// every later spool carrying the same tag payload. This is the only thing that can name a factory
/// colour reliably: a tag's hex is a *code*. Creality's Hyper PLA Blue tag says `0A2989`, navy,
/// where the filament measures `0081BF` — no colour distance connects those, but the pair
/// (filament `01001`, `0A2989`) always means the same spool colour.
public struct LearnedColourNames: Codable, Hashable, Sendable {

    public private(set) var names: [String: String]

    public init(names: [String: String] = [:]) { self.names = names }

    /// `01001|0A2989` when the spool has a filament id; otherwise maker, line and hex.
    public static func key(filamentId: String, brand: String, name: String, hex: String) -> String {
        let colour = Spool.normaliseHex(hex)
        let id = filamentId.trimmingCharacters(in: .whitespaces)
        if !id.isEmpty { return "\(id)|\(colour)" }
        return "\(BrandColourCatalogue.brandKey(brand))|\(BrandColourCatalogue.tokens(name).joined())|\(colour)"
    }

    public func name(forKey key: String) -> String? { names[key] }

    /// An empty name forgets the entry.
    public mutating func learn(_ name: String, forKey key: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[key] = trimmed.isEmpty ? nil : trimmed
    }
}

/// `~/Library/Application Support/Spoolworks/colour-names.json`.
public struct LearnedColourNamesStore: Sendable {

    public let fileURL: URL

    public init(directory: URL, fileName: String = "colour-names.json") {
        fileURL = directory.appendingPathComponent(fileName)
    }

    /// Empty when the file is missing or unreadable: a lost answer is asked for again, which is a
    /// nuisance, where refusing to name anything until the file is repaired would be a fault.
    public func load() -> LearnedColourNames {
        guard let data = try? Data(contentsOf: fileURL),
              let names = try? JSONDecoder().decode(LearnedColourNames.self, from: data) else {
            return LearnedColourNames()
        }
        return names
    }

    public func save(_ names: LearnedColourNames) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(names).write(to: fileURL, options: .atomic)
    }
}

/// Names a spool's colour: what the user said, else the maker's name, else a description.
public struct ColourNameResolver: Sendable {

    public struct Resolution: Hashable, Sendable {
        public let name: String
        public let source: ColourNameSource
        /// The maker's nearest colours, for offering when ``source`` is `.generic` — or for
        /// correcting a name that was matched wrongly.
        public let suggestions: [BrandColourCatalogue.Match]
    }

    public var catalogue: BrandColourCatalogue
    public var learned: LearnedColourNames
    /// The generic fallback; a closure so the 636 KB table stays the caller's to load.
    public var generic: @Sendable (String) -> String

    public init(catalogue: BrandColourCatalogue,
                learned: LearnedColourNames = .init(),
                generic: @escaping @Sendable (String) -> String) {
        self.catalogue = catalogue
        self.learned = learned
        self.generic = generic
    }

    /// Beyond this the nearest colour is a different colour, however far the runner-up is.
    public static let farthestAcceptable: Double = 15
    /// Within this the colour *is* the maker's, whatever else is near it.
    public static let effectivelyExact: Double = 2

    /// Whether the nearest candidate is the answer rather than merely the first of several.
    ///
    /// There is no distance that means "match". A factory tag says `000000` for a black that
    /// measures `282C2C` — ΔE 11, and unmistakably the same filament — while two pastel greens
    /// from one matte range sit 0.4 apart and are different products. What separates those cases
    /// is not how near the winner is but how far ahead of the next *differently named* colour it
    /// is, so that is the test: clearly ahead in both absolute and relative terms.
    public static func isDecisive(_ matches: [BrandColourCatalogue.Match]) -> Bool {
        guard let best = matches.first, best.scope != .anywhere else { return false }
        // "Exact" only means something inside the spool's own line. Across a maker's whole range
        // there is always some white within 2 of any white.
        if best.scope == .line, best.deltaE <= effectivelyExact { return true }
        guard best.deltaE <= farthestAcceptable else { return false }
        guard let next = matches.dropFirst().first else { return true }
        return next.deltaE >= best.deltaE + 4 && next.deltaE >= best.deltaE * 1.5
    }

    public func resolve(brand: String, name: String, material: String = "",
                        filamentId: String = "", hex: String) -> Resolution {
        let colour = Spool.normaliseHex(hex)
        let suggestions = catalogue.matches(brand: brand, name: name, material: material,
                                            hex: colour, limit: 6)
        let key = LearnedColourNames.key(filamentId: filamentId, brand: brand, name: name, hex: colour)
        if let told = learned.name(forKey: key) {
            return Resolution(name: told, source: .learned, suggestions: suggestions)
        }
        // The spool's own line decides if it can. The maker's wider range decides only when the
        // line is not in the catalogue at all: a line that is listed and has nothing near this
        // colour is a reason to ask, not to borrow a neighbour's name.
        let line = suggestions.filter { $0.scope == .line }
        if Self.isDecisive(line), let best = line.first {
            return Resolution(name: best.colour.name, source: .brand, suggestions: suggestions)
        }
        let wider = suggestions.filter { $0.scope == .brand }
        if line.isEmpty, Self.isDecisive(wider), let best = wider.first {
            return Resolution(name: best.colour.name, source: .brand, suggestions: suggestions)
        }
        return Resolution(name: generic(colour), source: .generic, suggestions: suggestions)
    }
}
