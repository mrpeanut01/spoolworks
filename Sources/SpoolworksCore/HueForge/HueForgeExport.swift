import Foundation
import CryptoKit

// MARK: - Where a TD came from

/// How far a transmission distance can be trusted.
///
/// Spoolworks knows a spool's colour and polymer and nothing about how much light it passes — a
/// tag does not carry it and the printer never asks. HueForge cannot use a filament without one.
/// So every exported TD has a provenance, and the screen shows it, because a guessed TD prints a
/// visibly wrong picture and looks exactly like a measured one in the file.
public enum HueForgeTDSource: Hashable, Sendable {
    /// Typed in here, or read from a HueForge file the user imported. Never overwritten.
    case user
    /// The same filament in one of HueForge's own libraries.
    case library(String)
    /// Taken from the nearest-coloured filaments of the same polymer. A starting point only.
    case estimated

    public var label: String {
        switch self {
        case .user: return "set by you"
        case .library: return "HueForge library"
        case .estimated: return "estimate"
        }
    }
}

// MARK: - What HueForge already knows

/// The TDs in HueForge's own libraries, for looking a spool's filament up in.
///
/// Read from the libraries HueForge ships and keeps (see ``HueForgeInstall``), so the numbers are
/// the vendor's or the HueForge team's own measurements rather than anything invented here.
public struct HueForgeTDReference: Sendable {

    private struct Entry: Sendable {
        let filament: HueForgeFilament
        let lab: LabColor?
        let brandKey: String
        let nameKey: String
        let typeKey: String
    }

    private let entries: [Entry]

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }

    public init(libraries: [HueForgeLibrary] = []) {
        entries = libraries.flatMap(\.filaments).map { f in
            Entry(filament: f,
                  lab: (try? RGB8(hex: f.colorHex)).map(LabColor.init),
                  brandKey: Self.key(f.brand),
                  nameKey: Self.key(f.name),
                  typeKey: Self.typeKey(f.type))
        }
    }

    /// Lower-case letters and digits only, so `Poly Lite`, `PolyLite` and `polylite` agree.
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    /// `PLA+` and `PLA` are different filaments but the same *kind* of light path, and vendors
    /// disagree about which of the two a given line is; for a TD lookup they are one polymer.
    static func typeKey(_ type: String) -> String {
        let k = key(type)
        return k.isEmpty ? "pla" : k
    }

    /// How close two colours must be, in ΔE, to count as the same colour of the same line.
    ///
    /// Tight — a fifth of ``Spool/lookalikeColourTolerance`` — because the consequence differs:
    /// that one decides whether to *ask* the user something, this one decides whether to hand
    /// HueForge a vendor's TD as if it were this filament's.
    static let sameColourTolerance: Double = 5

    /// How close a colour must be, in ΔE, to be worth estimating from.
    static let similarColourTolerance: Double = 12

    /// The TD for a filament, and where it came from.
    ///
    /// 1. The same line and polymer, with the same colour name or a colour within
    ///    ``sameColourTolerance`` — that *is* the filament, and its TD is the library's.
    /// 2. Otherwise the median of the nearest colours — of the same polymer where at least three
    ///    lie within ``similarColourTolerance``, of any polymer where they do not. Colour predicts
    ///    TD better than anything else on hand: black is ~0.3 mm in every line, white ~5.
    /// 3. With no reference at all, a curve through those same two anchors.
    public func transmissivity(brand: String, name: String, type: String,
                               colorHex: String) -> (value: Double, source: HueForgeTDSource) {
        let lab = (try? RGB8(hex: Spool.normaliseHex(colorHex))).map(LabColor.init)
        let brandKey = Self.key(brand), nameKey = Self.key(name), typeKey = Self.typeKey(type)

        let sameLine = entries.filter { $0.brandKey == brandKey && $0.typeKey == typeKey }
        func distance(_ e: Entry) -> Double? {
            guard let lab, let other = e.lab else { return nil }
            return lab.deltaE(to: other)
        }
        if let named = sameLine.first(where: { !nameKey.isEmpty && $0.nameKey == nameKey }) {
            return (named.filament.transmissivity, .library(Self.label(named.filament)))
        }
        if let near = sameLine.compactMap({ e in distance(e).map { (e, $0) } })
            .min(by: { $0.1 < $1.1 }), near.1 <= Self.sameColourTolerance {
            return (near.0.filament.transmissivity, .library(Self.label(near.0.filament)))
        }

        guard let lab else { return (Self.fallback(lightness: 50), .estimated) }
        // Colour first, polymer second. Black is ~0.3 mm in every polymer, so a near colour in
        // another polymer says more than a far colour in the same one — and the same-polymer
        // pool is thin outside PLA (15 ABS entries in 890), where "nearest" can be nowhere near.
        let ranked = entries.compactMap { e in e.lab.map { (e, lab.deltaE(to: $0)) } }
            .sorted { $0.1 < $1.1 }
        let close = ranked.filter { $0.0.typeKey == typeKey && $0.1 <= Self.similarColourTolerance }
        let chosen = (close.count >= 3 ? Array(close.prefix(5)) : Array(ranked.prefix(5)))
            .map(\.0.filament.transmissivity).sorted()
        guard !chosen.isEmpty else { return (Self.fallback(lightness: lab.l), .estimated) }
        return (chosen[chosen.count / 2], .estimated)
    }

    /// 0.4 mm at black, 6 mm at white, quadratic between — dark filament is opaque far sooner than
    /// its lightness alone suggests, which is what the medians of the shipped libraries show.
    static func fallback(lightness: Double) -> Double {
        let t = min(1, max(0, lightness / 100))
        return ((0.4 + 5.6 * t * t) * 10).rounded() / 10
    }

    private static func label(_ f: HueForgeFilament) -> String { "\(f.brand) \(f.name)" }
}

// MARK: - One row of the export

/// A filament as it will be sent to HueForge, plus what Spoolworks knows about why.
public struct HueForgeExportEntry: Identifiable, Hashable, Sendable {
    public var filament: HueForgeFilament
    public var tdSource: HueForgeTDSource
    /// The spools in stock that are this filament.
    public var spoolIDs: [UUID]
    /// False when the user has left this one out of the export.
    public var isIncluded: Bool

    public var id: String { filament.uuid }
}

/// What the user has decided about the export, which the inventory cannot say.
///
/// Both maps are keyed by ``HueForgeFilament/stableUUID(brand:type:colorHex:)``, so a decision
/// survives the spool it was made about being used up and replaced by another of the same
/// filament.
public struct HueForgePreferences: Codable, Hashable, Sendable {
    /// TDs the user typed or imported. These win over every lookup.
    public var transmissivity: [String: Double]
    /// Filaments left out of the export.
    public var excluded: Set<String>
    /// What was last handed to HueForge, by any route: uuid → ``HueForgeFilament/sentFingerprint``.
    ///
    /// Recorded rather than read back from HueForge's folder. That folder is inside another app's
    /// container, and looking in it makes macOS ask the user's permission — a question that should
    /// follow them choosing the folder, not appear because the Inventory was opened. `nil` in a
    /// file written before this was kept, and when nothing has ever been sent.
    public var sent: [String: String]?

    public init(transmissivity: [String: Double] = [:], excluded: Set<String> = [],
                sent: [String: String]? = nil) {
        self.transmissivity = transmissivity
        self.excluded = excluded
        self.sent = sent
    }
}

/// Whether HueForge has a filament as Spoolworks now describes it.
public enum HueForgeSyncState: Hashable, Sendable {
    /// Sent, and nothing about it has changed since.
    case current
    /// Sent, but its name, colour or TD has changed here since.
    case outdated
    /// Never sent.
    case notSent
    /// Left out of the export on purpose.
    case excluded
}

public extension HueForgeFilament {
    /// Everything HueForge is told about a filament, as one comparable string.
    ///
    /// Compared against ``HueForgePreferences/sent`` to tell a filament HueForge has from one it
    /// has an older description of — a colour renamed to its maker's name, a TD measured since.
    var sentFingerprint: String {
        [brand, type, color, name, HueForgeLibrary.number(transmissivity)].joined(separator: "|")
    }
}

// MARK: - Inventory → library

public enum HueForgeExporter {

    /// The HueForge *Brand* for a spool: the product line, which is Spoolworks' brand and name
    /// together with the polymer taken back off the end.
    ///
    /// Spoolworks follows the printer's catalogue — brand `Creality`, name `Hyper PLA`, type `PLA`.
    /// HueForge splits the same filament as Brand `Creality Hyper`, Type `PLA`, and matching that
    /// convention is what lets ``HueForgeTDReference`` find it.
    public static func brandLine(brand: String, name: String, type: String) -> String {
        var line = name.trimmingCharacters(in: .whitespaces)
        let polymer = type.trimmingCharacters(in: .whitespaces)
        if !polymer.isEmpty {
            if line.caseInsensitiveCompare(polymer) == .orderedSame {
                line = ""
            } else if line.lowercased().hasSuffix(" " + polymer.lowercased()) {
                line = String(line.dropLast(polymer.count + 1))
            }
        }
        let maker = brand.trimmingCharacters(in: .whitespaces)
        // A name that already leads with its maker ("Polymaker PolyLite") is not said twice.
        if !maker.isEmpty, line.lowercased().hasPrefix(maker.lowercased()) { return line }
        let joined = [maker, line].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? "Unbranded" : joined
    }

    /// One entry per distinct filament in stock.
    ///
    /// HueForge's library is a list of *filaments*; the inventory is a list of *spools*. Three
    /// spools of Hyper PLA White are one row here. Retired spools are left out: HueForge's
    /// *Owned* means "I can print with this", and a retired spool is exactly the one you cannot.
    public static func entries(for inventory: SpoolInventory,
                               preferences: HueForgePreferences = .init(),
                               reference: HueForgeTDReference = .init()) -> [HueForgeExportEntry] {
        var order: [String] = []
        var byID: [String: HueForgeExportEntry] = [:]

        for spool in inventory.active {
            let type = spool.materialType.trimmingCharacters(in: .whitespaces)
            let polymer = type.isEmpty ? "PLA" : type
            let brand = brandLine(brand: spool.brand, name: spool.name, type: polymer)
            let uuid = HueForgeFilament.stableUUID(brand: brand, type: polymer,
                                                   colorHex: spool.colorHex)
            if byID[uuid] != nil {
                byID[uuid]?.spoolIDs.append(spool.id)
                continue
            }
            let name = spool.colorName.isEmpty ? "#\(spool.colorHex)" : spool.colorName
            let td: Double
            let source: HueForgeTDSource
            if let own = preferences.transmissivity[uuid] {
                (td, source) = (own, .user)
            } else {
                (td, source) = reference.transmissivity(brand: brand, name: name, type: polymer,
                                                        colorHex: spool.colorHex)
            }
            order.append(uuid)
            byID[uuid] = HueForgeExportEntry(
                filament: HueForgeFilament(brand: brand, name: name, type: polymer,
                                           colorHex: spool.colorHex, transmissivity: td,
                                           owned: true, uuid: uuid),
                tdSource: source,
                spoolIDs: [spool.id],
                isIncluded: !preferences.excluded.contains(uuid))
        }
        return order.compactMap { byID[$0] }.sorted {
            ($0.filament.brand, $0.filament.name) < ($1.filament.brand, $1.filament.name)
        }
    }

    /// The library to hand HueForge: the included entries, in order.
    public static func library(from entries: [HueForgeExportEntry]) -> HueForgeLibrary {
        HueForgeLibrary(filaments: entries.filter(\.isIncluded).map(\.filament))
    }

    /// What to record in ``HueForgePreferences/sent`` after handing `library` to HueForge.
    ///
    /// The whole record is replaced, not merged: Sync overwrites the file wholesale, so a filament
    /// that was in the last one and is not in this one is no longer in HueForge's copy either.
    public static func sentRecord(for library: HueForgeLibrary) -> [String: String] {
        Dictionary(library.filaments.map { ($0.uuid, $0.sentFingerprint) },
                   uniquingKeysWith: { _, latest in latest })
    }

    /// Whether HueForge has `entry` as it stands.
    public static func syncState(of entry: HueForgeExportEntry,
                                 sent: [String: String]?) -> HueForgeSyncState {
        guard entry.isIncluded else { return .excluded }
        guard let fingerprint = sent?[entry.filament.uuid] else { return .notSent }
        return fingerprint == entry.filament.sentFingerprint ? .current : .outdated
    }

    /// The TDs a HueForge file can supply for these entries.
    ///
    /// This is the half of the sync that runs towards Spoolworks: measure a filament with a TD-1
    /// in HueForge, export, read it here, and the measured value replaces the estimate. Matched on
    /// uuid first — a file that began as a Spoolworks export carries ours — then on line, polymer
    /// and colour name.
    public static func transmissivities(in library: HueForgeLibrary,
                                        for entries: [HueForgeExportEntry]) -> [String: Double] {
        var found: [String: Double] = [:]
        let key = HueForgeTDReference.key
        for entry in entries {
            let mine = entry.filament
            let match = library.filaments.first { !$0.uuid.isEmpty && $0.uuid.lowercased() == mine.uuid }
                ?? library.filaments.first {
                    key($0.brand) == key(mine.brand) && key($0.name) == key(mine.name)
                        && HueForgeTDReference.typeKey($0.type) == HueForgeTDReference.typeKey(mine.type)
                }
            if let match, match.transmissivity > 0 { found[mine.uuid] = match.transmissivity }
        }
        return found
    }
}

// MARK: - HueForge on disk

/// Where HueForge keeps its filament libraries, and the one file in there Spoolworks owns.
///
/// ## Why sync writes its own file and never the personal library
///
/// `personal_library.json` is HueForge's working copy: it rewrites the file as the user edits, and
/// holds it in memory while running. Anything Spoolworks wrote there would either be overwritten
/// or overwrite a TD the user had just measured. A separate library file in *Vendor Libraries* is
/// the same thing HueForge's own *Import ▸ Vendor Libraries* produces — it copies the file into
/// that folder — so Spoolworks replaces ``syncFileName`` wholesale and touches nothing else.
public enum HueForgeInstall {

    public static let syncFileName = "Spoolworks.json"
    public static let libraryFolders = ["Vendor Libraries", "Community Libraries"]

    /// HueForge's own data folder on macOS — where *Sync* should be pointed.
    ///
    /// HueForge is sandboxed, so the `~/Documents/HueForge` its messages talk about is really
    /// inside its container. Confirmed against a running 0.9.4.3: its working directory and its
    /// logs are both under this path, and the `HueForge` folder in the real `~/Documents` is empty.
    ///
    /// Spoolworks never opens this on its own initiative. macOS guards one app's container from
    /// another and asks the user the first time; that question should follow the user choosing the
    /// folder, not appear because a window was opened.
    public static func dataFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(
            "Library/Containers/com.thehueforge.hueforge/Data/Documents/HueForge", isDirectory: true)
    }

    /// Where the libraries HueForge *ships* can be read without asking anyone: inside the
    /// application. Enough for vendor TDs; the user's own measurements are in ``dataFolder(home:)``.
    public static func bundledFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [URL] {
        [URL(fileURLWithPath: "/Applications/HueForge.app/Contents"),
         home.appendingPathComponent("Applications/HueForge.app/Contents")]
    }

    /// The `Filaments` folder for whatever the user pointed at — the HueForge folder, or the
    /// `Filaments` folder itself.
    public static func filamentsFolder(in chosen: URL,
                                       fileManager: FileManager = .default) -> URL? {
        func isDirectory(_ url: URL) -> Bool {
            var flag: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &flag) && flag.boolValue
        }
        let nested = chosen.appendingPathComponent("Filaments", isDirectory: true)
        if isDirectory(nested) { return nested }
        let looksLikeFilaments = chosen.lastPathComponent == "Filaments"
            || libraryFolders.contains { isDirectory(chosen.appendingPathComponent($0)) }
        return looksLikeFilaments && isDirectory(chosen) ? chosen : nil
    }

    /// Every library readable under a `Filaments` folder, for ``HueForgeTDReference``.
    ///
    /// Spoolworks' own sync file is skipped: reading it back would turn last time's estimates into
    /// this time's "HueForge library" values.
    public static func libraries(inFilamentsFolder folder: URL,
                                 fileManager: FileManager = .default) -> [HueForgeLibrary] {
        var files = [folder.appendingPathComponent("personal_library.json")]
        for sub in libraryFolders {
            let urls = (try? fileManager.contentsOfDirectory(
                at: folder.appendingPathComponent(sub), includingPropertiesForKeys: nil)) ?? []
            files += urls.filter {
                $0.pathExtension.lowercased() == "json" && $0.lastPathComponent != syncFileName
            }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return files.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? HueForgeLibrary(json: $0) }
        }
    }

    /// The reference built from the first candidate folder that has any libraries in it.
    public static func reference(candidates: [URL] = bundledFolders(),
                                 fileManager: FileManager = .default) -> HueForgeTDReference {
        for candidate in candidates {
            guard let folder = filamentsFolder(in: candidate, fileManager: fileManager) else { continue }
            let found = libraries(inFilamentsFolder: folder, fileManager: fileManager)
            if found.contains(where: { !$0.filaments.isEmpty }) {
                return HueForgeTDReference(libraries: found)
            }
        }
        return HueForgeTDReference()
    }

    /// Writes the library into a HueForge folder as ``syncFileName`` and returns where it went.
    @discardableResult
    public static func sync(_ library: HueForgeLibrary,
                            toHueForgeFolder chosen: URL,
                            fileManager: FileManager = .default) throws -> URL {
        // An application bundle is sealed by its signature; a file added inside one makes macOS
        // treat the app as damaged. The shipped libraries are readable there, never writable.
        guard !chosen.standardizedFileURL.pathComponents.contains(where: { $0.hasSuffix(".app") }) else {
            throw HueForgeError.insideApplicationBundle(chosen.path)
        }
        guard let filaments = filamentsFolder(in: chosen, fileManager: fileManager) else {
            throw HueForgeError.notAHueForgeFolder(chosen.path)
        }
        let folder = filaments.appendingPathComponent(libraryFolders[0], isDirectory: true)
        let target = folder.appendingPathComponent(syncFileName)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try library.jsonData().write(to: target, options: .atomic)
        } catch {
            throw HueForgeError.storage("Could not write \(target.path) — \(error.localizedDescription)")
        }
        return target
    }
}

// MARK: - Community source

/// A HueForge *community source*: a folder to push to a Git host, which HueForge then subscribes
/// to by its manifest URL (*Filaments ▸ Manage Community Sources*) and re-downloads on its own.
///
/// The layout and the manifest's fields are those of `thehueforge/hueforge-community-library-example`
/// and its `generate_manifest.py`. This is the only route by which HueForge *pulls* — every other
/// one needs the user to import a file — so it is the closest thing HueForge has to a live sync.
public enum HueForgeCommunitySource {

    public struct Manifest: Codable, Hashable, Sendable {
        public struct Library: Codable, Hashable, Sendable {
            public var name: String
            public var filename: String
            public var category: String
            public var url: String
            public var sha256: String
            public var filament_count: Int
        }
        public var source_name: String
        public var libraries: [Library]
    }

    public static func manifest(for library: HueForgeLibrary,
                                sourceName: String,
                                baseURL: String,
                                fileName: String = HueForgeInstall.syncFileName) throws -> Manifest {
        let data = try library.jsonData()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var base = baseURL.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        return Manifest(source_name: sourceName, libraries: [
            .init(name: (fileName as NSString).deletingPathExtension,
                  filename: fileName,
                  category: "community",
                  url: "\(base)/\(fileName)",
                  sha256: digest,
                  filament_count: library.filaments.count),
        ])
    }

    /// Writes `libraries/Spoolworks.json` and `manifest.json` into `folder`.
    ///
    /// `baseURL` is the raw URL the `libraries` folder will be served from, e.g.
    /// `https://raw.githubusercontent.com/<user>/<repo>/main/libraries`.
    @discardableResult
    public static func write(_ library: HueForgeLibrary,
                             to folder: URL,
                             sourceName: String,
                             baseURL: String,
                             fileManager: FileManager = .default) throws -> URL {
        let libraries = folder.appendingPathComponent("libraries", isDirectory: true)
        let manifestURL = folder.appendingPathComponent("manifest.json")
        do {
            try fileManager.createDirectory(at: libraries, withIntermediateDirectories: true)
            try library.jsonData().write(
                to: libraries.appendingPathComponent(HueForgeInstall.syncFileName), options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            var data = try encoder.encode(
                manifest(for: library, sourceName: sourceName, baseURL: baseURL))
            data.append(0x0A)
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            throw HueForgeError.storage(
                "Could not write the source to \(folder.path) — \(error.localizedDescription)")
        }
        return manifestURL
    }
}

// MARK: - Persistence

/// `~/Library/Application Support/Spoolworks/hueforge.json` — the TDs and exclusions.
///
/// Beside `inventory.json` rather than inside it: these are keyed by filament, not by spool, and a
/// TD someone measured should outlive the spool it was measured on.
public struct HueForgePreferencesStore: Sendable {

    public let fileURL: URL

    public init(directory: URL, fileName: String = "hueforge.json") {
        fileURL = directory.appendingPathComponent(fileName)
    }

    /// A missing file is the first run; one that will not decode is an error worth reporting,
    /// because starting empty would silently discard every TD the user had entered.
    public func load() throws -> HueForgePreferences {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        do {
            return try JSONDecoder().decode(HueForgePreferences.self, from: Data(contentsOf: fileURL))
        } catch {
            throw HueForgeError.storage("Could not read \(fileURL.lastPathComponent) — \(error.localizedDescription)")
        }
    }

    public func save(_ preferences: HueForgePreferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try encoder.encode(preferences).write(to: fileURL, options: .atomic)
        } catch {
            throw HueForgeError.storage("Could not save \(fileURL.lastPathComponent) — \(error.localizedDescription)")
        }
    }
}
