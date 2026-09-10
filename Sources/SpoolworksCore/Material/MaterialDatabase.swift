import Foundation

// MARK: - Errors

/// Every way the material-database layer can fail.
///
/// The Windows original has no error type at all: `MatDb.LoadFilaments`, `EditFilament`,
/// `RemoveFilament`, `GetVersion` and `SetVersion` are each wrapped in a bare `catch { }`
/// (`MatDb.cs:52,221,236,75,92`), so a malformed file yields a half-populated catalogue, a delete
/// of a non-existent id null-references into nothing, and the user is told none of it. Nothing in
/// this port fails silently.
public enum MaterialDatabaseError: Error, Equatable, Hashable, Sendable {
    /// `add` was called with an id already present. Windows has no such check in the model layer —
    /// only in the add dialog (`FilamentForm.cs:271`), so any other caller could duplicate an id.
    case duplicateID(String)
    /// `update`/`remove` named an id that is not in the catalogue.
    case notFound(String)
    /// A local database does not exist and no seed is available for this printer family.
    case seedUnavailable(PrinterType)
    /// The bytes are not a material database.
    case malformed(String)
    /// A filesystem operation failed.
    case storage(String)
    /// An operation that reads the current catalogue was called before ``MaterialDatabase/load()``.
    case notLoaded(PrinterType)
}

extension MaterialDatabaseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .duplicateID(id):
            return "A filament with id \(id) already exists. Duplicate IDs are not allowed."
        case let .notFound(id):
            return "No filament with id \(id) is in this database."
        case let .seedUnavailable(type):
            return "No bundled material database is available for \(type.displayName)."
        case let .malformed(detail):
            return "The material database could not be read: \(detail)"
        case let .storage(detail):
            return "The material database could not be stored: \(detail)"
        case let .notLoaded(type):
            return "The \(type.displayName) material database has not been loaded yet."
        }
    }
}

// MARK: - Wire envelope

/// One `result.list` element that could not be decoded, and why.
///
/// Never written back: a record we could not read is a record we cannot re-emit faithfully, and
/// guessing at it is exactly the failure mode this whole layer exists to avoid. It is reported so
/// the UI can say "94 of 98 filaments loaded; 4 were unreadable" instead of showing nothing.
public struct MaterialRecordFailure: Hashable, Sendable {
    /// Zero-based position in `result.list` as it appeared in the file.
    public let index: Int
    /// Human-readable reason, from the same formatter the envelope errors use.
    public let reason: String

    public init(index: Int, reason: String) {
        self.index = index
        self.reason = reason
    }
}

/// Decodes a `Filament` without ever throwing, so one bad element cannot abort the array.
///
/// This is the standard shape for element-wise tolerance: `UnkeyedDecodingContainer` only
/// advances past an element whose `decode` **succeeded**, so catching inside a loop over the
/// container would spin forever. Wrapping each element in a type whose own decode always
/// succeeds keeps the container advancing exactly once per element.
private struct LenientFilament: Decodable {
    let value: Filament?
    let failure: String?

    init(from decoder: Decoder) throws {
        do {
            value = try Filament(from: decoder)
            failure = nil
        } catch let error as DecodingError {
            value = nil
            failure = MaterialDatabase.describe(error)
        } catch {
            value = nil
            failure = error.localizedDescription
        }
    }
}

/// The on-disk / on-the-wire form: `{code, msg, reqId, result:{list, count, version}}`.
///
/// `code` and `msg` are never validated — the C# does not check them either (`MatDb.cs:29-49`) and
/// a future firmware may use them for something we do not want to hard-fail on. They are, however,
/// **preserved**: re-emitting the `0`/`"ok"` defaults over whatever the printer actually said
/// discards the only diagnostic the envelope carries.
///
/// Both this type and ``Result`` carry an `additionalFields` catch-all, for the same reason
/// ``Filament`` and ``MaterialBase`` do: `Codable` silently drops any key it does not model, so a
/// firmware that starts sending a new envelope-level or `result`-level key would have it stripped
/// on the next save — and that save is uploaded to the printer.
public struct MaterialDatabaseFile: Codable, Hashable, Sendable {
    public var code: Int
    public var msg: String
    /// `"0"` when this app wrote the file; a real printer sends e.g.
    /// `"cl602024082916552939795681"`. Always a String, never a number.
    ///
    /// Windows discards whatever it read and re-emits `"0"` on every save (`MatDb.cs:183`). This
    /// port preserves it — it is the only trace of where a file came from.
    public var reqId: String
    public var result: Result

    /// Envelope-level keys this struct does not model, preserved verbatim.
    public var additionalFields: [String: JSONValue]

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case code, msg, reqId, result
    }

    public struct Result: Codable, Hashable, Sendable {
        /// The records that decoded. See ``recordFailures`` for the ones that did not.
        public var list: [Filament]
        /// Recomputed from `list.count` on every save, so it is authoritative afterwards even if
        /// the source file disagreed.
        public var count: Int
        /// Unix epoch seconds **as a String**. See ``MaterialVersion``.
        public var version: String

        /// `result`-level keys this struct does not model, preserved verbatim.
        public var additionalFields: [String: JSONValue]

        /// Elements of `result.list` that failed to decode, in file order.
        ///
        /// Not part of the wire format and never encoded. See ``MaterialRecordFailure``.
        public var recordFailures: [MaterialRecordFailure]

        public enum CodingKeys: String, CodingKey, CaseIterable {
            case list, count, version
        }

        public init(list: [Filament], count: Int? = nil, version: String = MaterialVersion.unknown,
                    additionalFields: [String: JSONValue] = [:],
                    recordFailures: [MaterialRecordFailure] = []) {
            self.list = list
            self.count = count ?? list.count
            self.version = version
            self.additionalFields = additionalFields
            self.recordFailures = recordFailures
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: AnyCodingKey.self)
            func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.rawValue) }

            // Element-wise, so one odd record from a printer cannot take the whole catalogue
            // down. Decoding `list` as a single `[Filament]` meant a lone bad element — a
            // `colors` that is a bare string, a numeric `kvParam` value, a `base` with no `id` —
            // aborted the array and the user's entire catalogue refused to load.
            let elements = try c.decodeIfPresent([LenientFilament].self, forKey: key(.list)) ?? []
            list = elements.compactMap(\.value)
            recordFailures = elements.enumerated().compactMap { index, element in
                element.failure.map { MaterialRecordFailure(index: index, reason: $0) }
            }

            // `count` is the file's own claim and is preserved as read; `save()` recomputes it.
            // Both are read as leniently as the records are: an unquoted version or a quoted
            // count from a firmware this app has not met must not refuse the whole catalogue
            // when every record in it is fine.
            count = try c.decodeIfPresent(JSONValue.self, forKey: key(.count))?.intValue ?? list.count
            version = try c.decodeIfPresent(JSONValue.self, forKey: key(.version))?.stringValue
                ?? MaterialVersion.unknown

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
            try c.encode(list, forKey: key(.list))
            try c.encode(count, forKey: key(.count))
            try c.encode(version, forKey: key(.version))
            let modelled = Set(CodingKeys.allCases.map(\.rawValue))
            for (k, v) in additionalFields where !modelled.contains(k) {
                try c.encode(v, forKey: AnyCodingKey(stringValue: k))
            }
        }
    }

    public init(list: [Filament] = [], version: String = MaterialVersion.unknown,
                reqId: String = "0", code: Int = 0, msg: String = "ok",
                additionalFields: [String: JSONValue] = [:]) {
        self.code = code
        self.msg = msg
        self.reqId = reqId
        self.result = Result(list: list, version: version)
        self.additionalFields = additionalFields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        func key(_ k: CodingKeys) -> AnyCodingKey { AnyCodingKey(stringValue: k.rawValue) }
        code = try c.decodeIfPresent(Int.self, forKey: key(.code)) ?? 0
        msg = try c.decodeIfPresent(String.self, forKey: key(.msg)) ?? "ok"
        reqId = try c.decodeIfPresent(String.self, forKey: key(.reqId)) ?? "0"
        result = try c.decode(Result.self, forKey: key(.result))

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
        try c.encode(code, forKey: key(.code))
        try c.encode(msg, forKey: key(.msg))
        try c.encode(reqId, forKey: key(.reqId))
        try c.encode(result, forKey: key(.result))
        let modelled = Set(CodingKeys.allCases.map(\.rawValue))
        for (k, v) in additionalFields where !modelled.contains(k) {
            try c.encode(v, forKey: AnyCodingKey(stringValue: k))
        }
    }

    /// Every record that failed to decode, in file order. Empty for a clean file.
    public var recordFailures: [MaterialRecordFailure] { result.recordFailures }
}

// MARK: - Versioning

/// `result.version` handling.
///
/// The value is a **string** holding unix epoch seconds (`"1758907369"` = 2025-09-26). It must be
/// compared numerically: `UpdateForm.cs:112` does `long.Parse(new) > long.Parse(current)`, and a
/// non-numeric value there throws into a generic "Error checking version". It must also stay a
/// *string* on the wire — the printer writes it quoted and a numeric encode changes the format.
public enum MaterialVersion {
    /// What Windows reports for a missing or unreadable file (`MatDb.cs:66,75`).
    public static let unknown = "0"

    /// `Resources.verPrevent` — stamped into the local DB before upload when the user asks the
    /// printer not to replace it with a cloud update (`UploadForm.cs:151-154`). An artificially huge
    /// epoch so no real cloud version ever exceeds it.
    public static let preventUpdateSentinel = "9876543210"

    /// Current time as epoch seconds. The only place Windows generates a version is the cloud
    /// assembly path (`Utils.cs:887`), which falls back to exactly this.
    public static func now(_ date: Date = Date()) -> String {
        String(Int64(date.timeIntervalSince1970))
    }

    /// Parses a version for comparison. `nil` when it is not an integer — the caller decides what
    /// that means rather than silently treating it as 0.
    public static func number(_ version: String) -> Int64? {
        Int64(version.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// True when `candidate` is strictly newer than `current`. An unparseable version counts as 0,
    /// matching the C# behaviour of treating a missing file as `"0"`, but ``number(_:)`` is exposed
    /// so a caller that wants to distinguish "old" from "nonsense" can.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        (number(candidate) ?? 0) > (number(current) ?? 0)
    }
}

// MARK: - Seeding

/// Supplies a starting catalogue for a printer family that has no local database yet.
public protocol MaterialSeedProviding: Sendable {
    /// Returns the seed bytes, or throws ``MaterialDatabaseError/seedUnavailable(_:)``.
    func seedData(for printerType: PrinterType) throws -> Data

    /// The third-party catalogue for this family, or `nil` where there is none.
    ///
    /// Kept separate from the seed rather than folded into it, because the two are not equally
    /// trustworthy and the difference is worth preserving. A seed record was captured from a
    /// printer: its profile is the printer's own and its id already resolves there. A vendor
    /// record was assembled from the filament maker's published profile: the numbers are theirs,
    /// but the **id is ours**, so a tag written against one is ignored until the catalogue has
    /// been uploaded to the printer. Merging them would lose that distinction permanently.
    func vendorCatalogueData(for printerType: PrinterType) throws -> Data?
}

public extension MaterialSeedProviding {
    /// Most providers have no third-party catalogue; the bundled one does.
    func vendorCatalogueData(for printerType: PrinterType) throws -> Data? { nil }
}

/// Reads the seed from the app bundle (`k1.json` / `k2.json` / `hi.json`).
///
/// **New behaviour — Windows has nothing equivalent.** There, `material_database/` starts empty,
/// `CheckDBfile` is a bare `File.Exists` (`Utils.cs:338-346`), and if it returns false the app
/// shows "Add a printer to get started" and expects the user either to download a profile from
/// Creality Cloud or to hand-drop one of the `db/*.json` files next to the exe. Seeding from a
/// bundled copy removes a first-run dead end that has no macOS equivalent (the .app bundle is
/// signed and read-only, so "drop a file next to the binary" is not a thing a user can do).
public struct BundledMaterialSeed: MaterialSeedProviding {
    public init() {}

    public func seedData(for printerType: PrinterType) throws -> Data {
        guard let url = Self.seedURL(for: printerType) else {
            throw MaterialDatabaseError.seedUnavailable(printerType)
        }
        do { return try Data(contentsOf: url) }
        catch { throw MaterialDatabaseError.storage("reading seed \(url.lastPathComponent): \(error.localizedDescription)") }
    }

    /// Bundle first, then the repository's `db/` directory.
    ///
    /// Seeds ship inside the app's resource bundle; `make-app.sh` copies `db/*.json` into it and
    /// refuses to build a bundle that is missing them.
    ///
    /// There is deliberately NO source-tree fallback. An earlier version resolved `#filePath` to
    /// find `db/` in the repository, which baked the developer's absolute source path into every
    /// shipped binary. On the build machine that path exists, so the app silently read resources
    /// out of the source tree and looked healthy; anywhere else it was simply absent. A shipped
    /// app must resolve resources only from its own bundle.
    static func seedURL(for printerType: PrinterType) -> URL? {
        SpoolworksCoreResources.url(forResource: printerType.rawValue, withExtension: "json")
    }

    /// `vendor-k2.json` and friends — the assembled third-party catalogue, absent for families
    /// that have none. Built by `Tools/build-vendor-catalogue.py`; see that file for what is
    /// taken from a vendor profile and, more importantly, what is not.
    public func vendorCatalogueData(for printerType: PrinterType) throws -> Data? {
        guard let url = SpoolworksCoreResources.url(forResource: "vendor-\(printerType.rawValue)",
                                                    withExtension: "json") else { return nil }
        do { return try Data(contentsOf: url) }
        catch { throw MaterialDatabaseError.storage("reading \(url.lastPathComponent): \(error.localizedDescription)") }
    }
}

/// An in-memory seed, for tests and for callers that fetch a catalogue themselves.
public struct StaticMaterialSeed: MaterialSeedProviding {
    private let payloads: [PrinterType: Data]
    public init(_ payloads: [PrinterType: Data]) { self.payloads = payloads }
    public func seedData(for printerType: PrinterType) throws -> Data {
        guard let data = payloads[printerType] else {
            throw MaterialDatabaseError.seedUnavailable(printerType)
        }
        return data
    }
}

// MARK: - Storage location

/// Where databases live on disk.
///
/// Windows uses `AppDomain.CurrentDomain.BaseDirectory + "\\material_database\\"` — the directory
/// containing the .exe — in eleven places. That is wrong on macOS twice over: an .app bundle is
/// signed (writing inside it breaks the signature) and may sit on a read-only volume. The
/// equivalent user-writable location is Application Support; `~/Library/Caches` would be wrong
/// because the catalogue holds user-authored filaments that must survive cache eviction.
public struct MaterialStorage: Hashable, Sendable {
    /// The directory holding `<type>.json`.
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/CFS-RFID/material_database`.
    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> MaterialStorage {
        do {
            let base = try fileManager.url(for: .applicationSupportDirectory,
                                           in: .userDomainMask,
                                           appropriateFor: nil,
                                           create: false)
            return MaterialStorage(directory: base
                .appendingPathComponent("CFS-RFID", isDirectory: true)
                .appendingPathComponent("material_database", isDirectory: true))
        } catch {
            throw MaterialDatabaseError.storage("locating Application Support: \(error.localizedDescription)")
        }
    }

    /// The file for a family. Always lower-case (`k2.json`), so the same name resolves on a
    /// case-sensitive APFS volume as on a case-insensitive one — the hazard `MatDb.cs` walked into
    /// by lower-casing the type but listing the directory with its on-disk casing.
    public func url(for printerType: PrinterType) -> URL {
        directory.appendingPathComponent(printerType.databaseFileName)
    }

    public func exists(_ printerType: PrinterType, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: url(for: printerType).path)
    }

    /// Creates the directory if it is missing. Windows does the same, lazily, in `SetDBfile`
    /// (`Utils.cs:369-380`).
    public func createDirectoryIfNeeded(fileManager: FileManager = .default) throws {
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MaterialDatabaseError.storage("creating \(directory.path): \(error.localizedDescription)")
        }
    }

    /// Families that already have a local file, in a stable order. Replaces
    /// `Utils.GetPrinterTypes()`'s directory listing (`Utils.cs:398-418`), but resolves each name
    /// through ``PrinterType`` instead of handing raw file names to the rest of the app.
    public func installedTypes(fileManager: FileManager = .default) -> [PrinterType] {
        PrinterType.allCases.filter { exists($0, fileManager: fileManager) }
    }
}

// MARK: - MaterialDatabase

/// The material catalogue for one printer family: load, save, CRUD and versioning.
///
/// Mirrors `Windows/CFS-RFID/MatDb.cs` plus the `Utils.*Material` pass-throughs, with the four
/// documented defects fixed (each marked `FIX (Windows defect …)` at its site). Like the C#, CRUD
/// is in-memory and nothing reaches disk until ``save()``; unlike the C#, the state is per-instance
/// rather than a static `List<Filament>`.
///
/// Not thread-safe — confine an instance to one actor/queue, as the UI layer does.
public final class MaterialDatabase {
    public let printerType: PrinterType
    public let storage: MaterialStorage
    public let seed: MaterialSeedProviding
    private let fileManager: FileManager

    /// The catalogue, in file order.
    public private(set) var filaments: [Filament] = []
    /// `result.version`. Preserved across local CRUD — see ``save()``.
    public private(set) var version: String = MaterialVersion.unknown
    /// `reqId` as read from the file, preserved on save.
    public private(set) var reqId: String = "0"
    /// `code` as read from the file, preserved on save. Never interpreted.
    public private(set) var code: Int = 0
    /// `msg` as read from the file, preserved on save. Never interpreted.
    public private(set) var msg: String = "ok"
    /// Envelope-level keys we do not model, preserved on save.
    public private(set) var envelopeFields: [String: JSONValue] = [:]
    /// `result`-level keys we do not model, preserved on save.
    public private(set) var resultFields: [String: JSONValue] = [:]
    /// Records in the loaded file that could not be decoded. Empty for a clean file.
    ///
    /// Non-empty means the catalogue is **incomplete**: those records are not in ``filaments``
    /// and a ``save()`` would drop them from the file. A UI should say so before saving.
    public private(set) var recordFailures: [MaterialRecordFailure] = []
    /// True once ``load()`` has run.
    public private(set) var isLoaded = false

    /// True when the in-memory catalogue differs from what is on disk.
    ///
    /// FIX — the write itself was already atomic, but a *failed* write left the mutation sitting
    /// in ``filaments`` with nothing to mark it unsaved and nothing to undo it, so the UI went on
    /// showing a filament the disk did not have (and, after a delete, hiding one it did). Every
    /// mutating operation now sets this; ``save()`` clears it on success and rolls the whole
    /// in-memory state back to the last persisted snapshot on failure.
    public private(set) var hasUnsavedChanges = false

    /// The state last known to be on disk, for the rollback in ``save()``.
    private var persistedState: MaterialDatabaseFile?

    public init(printerType: PrinterType,
                storage: MaterialStorage,
                seed: MaterialSeedProviding = BundledMaterialSeed(),
                fileManager: FileManager = .default) {
        self.printerType = printerType
        self.storage = storage
        self.seed = seed
        self.fileManager = fileManager
    }

    /// The file this instance reads and writes.
    public var fileURL: URL { storage.url(for: printerType) }

    // MARK: Codec

    /// Decoder/encoder pair used for every read and write.
    ///
    /// `.sortedKeys` reproduces the alphabetical `kvParam` order of the shipped files (a
    /// `[String: String]` has no order of its own) and makes output byte-stable, which matters for
    /// diffing a local DB against a printer's. `.prettyPrinted` matches the C#'s
    /// `Formatting.Indented`; note the shipped `db/*.json` use 2-space indent *without* a space
    /// after the colon, so they were not produced by the C# writer either — byte-parity with them
    /// is not achievable through `JSONEncoder` and is not attempted.
    ///
    /// `withoutEscapingSlashes` keeps G-code paths readable. Files are written as UTF-8; the C#
    /// uses `Encoding.ASCII` (`MatDb.cs:23,89`), which turns any byte > 0x7F into `?` — a silent
    /// corruption this port deliberately does not reproduce.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decodes an envelope, reporting *why* on failure instead of swallowing it.
    public static func decode(_ data: Data) throws -> MaterialDatabaseFile {
        do {
            return try JSONDecoder().decode(MaterialDatabaseFile.self, from: data)
        } catch let error as DecodingError {
            throw MaterialDatabaseError.malformed(describe(error))
        } catch {
            throw MaterialDatabaseError.malformed(error.localizedDescription)
        }
    }

    public static func encode(_ file: MaterialDatabaseFile) throws -> Data {
        do { return try makeEncoder().encode(file) }
        catch { throw MaterialDatabaseError.malformed("encoding failed: \(error)") }
    }

    /// Renders a `DecodingError` as one readable line. Shared with the per-record decoder above.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map(\.stringValue).joined(separator: ".")
        }
        switch error {
        case let .keyNotFound(key, context):
            return "missing key '\(key.stringValue)' at \(path(context).isEmpty ? "<root>" : path(context))"
        case let .typeMismatch(type, context):
            return "expected \(type) at \(path(context)): \(context.debugDescription)"
        case let .valueNotFound(type, context):
            return "missing value of type \(type) at \(path(context))"
        case let .dataCorrupted(context):
            return context.debugDescription
        @unknown default:
            return String(describing: error)
        }
    }

    // MARK: Load / save

    /// Loads the local file, seeding it from the bundled catalogue on first run.
    ///
    /// Replaces `MatDB.LoadFilaments` (`MatDb.cs:15-53`) — which resets the list, wraps everything
    /// in `catch { }` and therefore leaves a *partially* filled catalogue behind when a file is
    /// malformed. Here a malformed file throws and the in-memory state is left untouched.
    @discardableResult
    public func load() throws -> [Filament] {
        if !storage.exists(printerType, fileManager: fileManager) {
            try seedFromBundle()
        }
        let data: Data
        do { data = try Data(contentsOf: fileURL) }
        catch { throw MaterialDatabaseError.storage("reading \(fileURL.path): \(error.localizedDescription)") }

        adopt(try Self.decode(data))
        // Everything in memory came straight off the disk, so this is the rollback baseline and
        // there is nothing unsaved.
        markPersisted()
        return filaments
    }

    /// Writes the local file from the bundled seed. Called by ``load()``; exposed for a
    /// "reset to factory catalogue" action.
    public func seedFromBundle() throws {
        let data = try seed.seedData(for: printerType)
        // Validate before writing: a corrupt seed should surface here, not on the next load.
        _ = try Self.decode(data)
        try storage.createDirectoryIfNeeded(fileManager: fileManager)
        do { try data.write(to: fileURL, options: .atomic) }
        catch { throw MaterialDatabaseError.storage("writing \(fileURL.path): \(error.localizedDescription)") }
    }

    /// Persists the current catalogue.
    ///
    /// FIX (Windows defect d) — `MatDB.SaveFilaments` early-returns when the list is null or empty
    /// (`MatDb.cs:161-164`), so **deleting the last filament silently fails to persist**: the file
    /// keeps its old contents and the deletion is undone by the next load. There is no reading of
    /// that as intentional — a zero-record file is perfectly valid (see the empty-envelope fixture)
    /// — so an empty catalogue is written like any other.
    ///
    /// The version is written unchanged, which matches Windows: `SaveFilaments` writes whatever the
    /// caller passes and every caller passes the version last read from the file
    /// (`MainForm.cs:751,778,806`). Local add/edit/delete therefore preserves the version; only an
    /// update from the cloud or a printer moves it, via ``setVersion(_:)``.
    /// FIX — a failed write used to leave memory and disk disagreeing. The write is atomic, so
    /// on throw the file still holds the previous contents; the in-memory catalogue is therefore
    /// rewound to match it and ``hasUnsavedChanges`` is left set, rather than the caller being
    /// shown a mutation that never landed. See ``hasUnsavedChanges``.
    public func save() throws {
        let file = snapshot()
        do {
            try storage.createDirectoryIfNeeded(fileManager: fileManager)
            let data = try Self.encode(file)
            do { try data.write(to: fileURL, options: .atomic) }
            catch {
                throw MaterialDatabaseError.storage(
                    "writing \(fileURL.path): \(error.localizedDescription)")
            }
        } catch {
            rollBackToPersistedState()
            throw error
        }
        // The records that would not decode were never in `list`, so the file just written no
        // longer holds them: the catalogue is complete again, in memory and on disk. Until this
        // point they stay in the snapshot, so a failed save rolls back to a state that still
        // admits the disk is incomplete rather than one that silently claims it is clean.
        recordFailures = []
        persistedState = snapshot()
        hasUnsavedChanges = false
    }

    /// Restores the in-memory state to the last snapshot known to be on disk.
    ///
    /// With no baseline — nothing has ever been loaded or saved through this instance — there is
    /// nothing on disk to agree with, so the in-memory state is left alone and
    /// ``hasUnsavedChanges`` stays set.
    private func rollBackToPersistedState() {
        guard let persistedState else { return }
        applyState(persistedState)
        hasUnsavedChanges = true
    }

    /// Records the current state as the on-disk baseline and clears the dirty flag.
    private func markPersisted() {
        persistedState = snapshot()
        hasUnsavedChanges = false
    }

    /// The current state as a wire envelope. `count` is recomputed from the list, as the C# does
    /// (`MatDb.cs:179`). `code`, `msg`, `reqId` and every unmodelled envelope/`result` key are
    /// carried straight through from whatever was read.
    public func snapshot() -> MaterialDatabaseFile {
        var file = MaterialDatabaseFile(list: filaments, version: version, reqId: reqId,
                                        code: code, msg: msg, additionalFields: envelopeFields)
        file.result.count = filaments.count
        file.result.additionalFields = resultFields
        file.result.recordFailures = recordFailures
        return file
    }

    /// Replaces the whole catalogue — the cloud/printer merge path's landing point.
    ///
    /// Marks the database dirty: adopting a cloud or printer document changes what is in memory
    /// without touching the disk, so it is by definition unsaved. ``load()`` clears the flag
    /// afterwards, because there the document *is* the disk.
    public func adopt(_ file: MaterialDatabaseFile) {
        applyState(file)
        isLoaded = true
        hasUnsavedChanges = true
    }

    /// The shared body of ``adopt(_:)`` and the rollback. Pure state assignment, no flags.
    private func applyState(_ file: MaterialDatabaseFile) {
        filaments = file.result.list.map(Self.trimIdentity)
        version = file.result.version
        reqId = file.reqId
        code = file.code
        msg = file.msg
        envelopeFields = file.additionalFields
        resultFields = file.result.additionalFields
        recordFailures = file.result.recordFailures
    }

    /// `MatDb.cs:41-44` trims id/name/brand/type on load and matches on the trimmed id. Doing it
    /// once, here, means every later comparison can be a plain `==`.
    private static func trimIdentity(_ filament: Filament) -> Filament {
        var copy = filament
        copy.base.id = filament.base.id.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.base.name = filament.base.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.base.brand = filament.base.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.base.materialType = filament.base.materialType.trimmingCharacters(in: .whitespacesAndNewlines)
        return copy
    }

    // MARK: CRUD

    /// Looks a filament up by id. Replaces `MatDB.GetFilamentById` (`MatDb.cs:95-107`).
    public func filament(id: String) -> Filament? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return filaments.first { $0.base.id == key }
    }

    public func contains(id: String) -> Bool { filament(id: id) != nil }

    /// Appends a filament.
    ///
    /// FIX (Windows defect a) — `MatDB.AddFilament` appends unconditionally with no duplicate check
    /// (`MatDb.cs:204`); uniqueness lives only in the add dialog (`FilamentForm.cs:271`), so any
    /// other caller — the cloud merge, a future script, a second window — can produce two records
    /// with the same id, after which lookup returns whichever comes first and edit/remove touch
    /// only one of them. The check belongs in the model, so it is here.
    ///
    /// Note the C# also re-syncs `base` from its four cached fields at this point
    /// (`MatDb.cs:198-201`); there is nothing to re-sync here because ``Filament`` has no cache.
    public func add(_ filament: Filament) throws {
        let record = Self.trimIdentity(filament)
        guard !record.base.id.isEmpty else {
            throw MaterialDatabaseError.malformed("filament id must not be empty")
        }
        guard !contains(id: record.base.id) else {
            throw MaterialDatabaseError.duplicateID(record.base.id)
        }
        filaments.append(record)
        hasUnsavedChanges = true
    }

    /// Replaces an existing filament, matched on trimmed id, **in place**.
    ///
    /// FIX (Windows defects b and c) — `MatDB.EditFilament` (`MatDb.cs:209-223`) does
    /// `foreach (item in mdb) { if (match) { mdb.Remove(item); mdb.Add(filament); } }`. Two bugs:
    ///  (b) remove-then-append moves the edited record to the **end**, so the on-disk order churns
    ///      on every save and the UI's sort is disturbed for no reason;
    ///  (c) it mutates the collection it is enumerating, which throws `InvalidOperationException`
    ///      on the next `MoveNext()` — swallowed by the enclosing `catch { }` (`MatDb.cs:221`). It
    ///      only appears to work because the swap has already happened when the throw lands; a
    ///      second matching id would never be reached, and the caller is told nothing.
    /// Replacing at the found index is both order-preserving and free of the enumeration hazard,
    /// and an unknown id is now reported rather than being a no-op.
    public func update(_ filament: Filament) throws {
        let record = Self.trimIdentity(filament)
        guard let index = filaments.firstIndex(where: { $0.base.id == record.base.id }) else {
            throw MaterialDatabaseError.notFound(record.base.id)
        }
        filaments[index] = record
        hasUnsavedChanges = true
    }

    /// Adds the filament, or replaces it if its id is already present. This is the cloud/printer
    /// merge semantic (`UpdateForm.cs:153-170`), spelled out as one operation.
    public func upsert(_ filament: Filament) throws {
        if contains(id: filament.base.id) {
            try update(filament)
        } else {
            try add(filament)
        }
    }

    /// Removes a filament by id.
    ///
    /// FIX (Windows defect c, again) — `MatDB.RemoveFilament` (`MatDb.cs:225-238`) has the same
    /// mutate-while-enumerating pattern under the same empty `catch`. On top of that,
    /// `Utils.RemoveMaterial` (`Utils.cs:47-50`) resolves the id through `GetFilamentById`, which
    /// returns `null` when not found, then dereferences it — a NullReferenceException swallowed
    /// into silence, so "delete a filament that isn't there" looks exactly like success.
    /// Here an unknown id throws ``MaterialDatabaseError/notFound(_:)``.
    public func remove(id: String) throws {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = filaments.firstIndex(where: { $0.base.id == key }) else {
            throw MaterialDatabaseError.notFound(key)
        }
        filaments.remove(at: index)
        hasUnsavedChanges = true
    }

    // MARK: Versioning

    /// Sets `result.version` in memory. Persisted by the next ``save()``.
    ///
    /// Windows has a separate `MatDB.SetVersion` that re-parses and rewrites the whole file
    /// (`MatDb.cs:78-93`); folding it into the normal save path removes a read-modify-write race
    /// against the in-memory catalogue.
    public func setVersion(_ newVersion: String) {
        version = newVersion
        hasUnsavedChanges = true
    }

    /// Stamps the version to now, for a catalogue this app assembled itself (`Utils.cs:887`).
    public func stampVersionNow(_ date: Date = Date()) {
        version = MaterialVersion.now(date)
        hasUnsavedChanges = true
    }

    /// True when `remoteVersion` is strictly newer than the loaded one — the `UpdateForm.cs:112`
    /// comparison, with the parse failure surfaced instead of thrown into a generic message.
    public func isOutdated(comparedTo remoteVersion: String) -> Bool {
        MaterialVersion.isNewer(remoteVersion, than: version)
    }

    // MARK: Seed top-up

    /// The ids a **newer** bundled seed holds that this catalogue does not, in seed order.
    ///
    /// Read-only, and deliberately separate from ``topUpFromSeed()``: the catalogue on disk is the
    /// user's, so a refreshed seed is *offered* rather than merged behind their back. A printer
    /// download, a hand-edited file and a deleted factory record are all legitimate states that an
    /// automatic merge would quietly undo.
    ///
    /// Empty when the seed is not newer than the local version, so the offer disappears once
    /// ``topUpFromSeed()`` has stamped it — and never reappears for a catalogue that has since
    /// moved past the seed, such as one downloaded from a printer.
    public func pendingSeedAdditions() -> [String] {
        guard isLoaded, let file = try? Self.decode(try seed.seedData(for: printerType)),
              isOutdated(comparedTo: file.result.version)
        else { return [] }
        return file.result.list.map(\.base.id).filter { !contains(id: $0) }
    }

    /// Adds the catalogue records that a newer bundled seed has and this one does not, then
    /// stamps the seed's version and saves.
    ///
    /// ``seedFromBundle()`` only ever runs when there is no local file, so before this existed a
    /// refreshed seed reached first-run installs and nobody else: an app that had been opened once
    /// kept its original catalogue for good. That is not abstract staleness — the catalogue is
    /// where an app-written tag's filament ID comes from, so a brand missing from it is a spool
    /// this app cannot tag, and the user's only route to the new records was to delete the file.
    ///
    /// **Additive only, and deliberately so.** A record already present is left exactly as it is,
    /// whether the user wrote it or edited a factory one — a top-up that silently reverted
    /// hand-tuned temperatures would be a worse bug than the staleness it fixes. Use
    /// ``seedFromBundle()`` for a destructive "reset to the factory catalogue", and the
    /// printer/cloud merge (which upserts) where the remote copy is meant to win.
    ///
    /// The third-party records this catalogue does not have, in catalogue order.
    ///
    /// Unlike ``pendingSeedAdditions()`` this is not version-gated. The vendor catalogue is not a
    /// newer edition of the local one — it is a different set of filaments — so "do I already have
    /// these ids" is the only question that means anything.
    public func pendingVendorAdditions() -> [String] {
        guard isLoaded,
              let data = (try? seed.vendorCatalogueData(for: printerType)) ?? nil,
              let file = try? Self.decode(data)
        else { return [] }
        return file.result.list.map(\.base.id).filter { !contains(id: $0) }
    }

    /// Adds the third-party catalogue's records, skipping any id already present, and saves.
    ///
    /// The version is deliberately **not** stamped. `result.version` describes the captured
    /// catalogue's edition and is what the printer compares against on update; moving it because
    /// records were added locally would tell the printer this catalogue is newer than it is.
    ///
    /// - Returns: the ids added. Empty when every one was already present.
    @discardableResult
    public func addVendorCatalogue() throws -> [String] {
        guard isLoaded else { throw MaterialDatabaseError.notLoaded(printerType) }
        guard let data = try seed.vendorCatalogueData(for: printerType) else { return [] }
        let file = try Self.decode(data)

        var added: [String] = []
        for filament in file.result.list where !contains(id: filament.base.id) {
            try add(filament)
            added.append(filament.base.id)
        }
        guard !added.isEmpty else { return [] }
        try save()
        return added
    }

    /// - Returns: the ids added, in seed order. Empty when there was nothing to do.
    @discardableResult
    public func topUpFromSeed() throws -> [String] {
        guard isLoaded else { throw MaterialDatabaseError.notLoaded(printerType) }
        let file: MaterialDatabaseFile
        do { file = try Self.decode(try seed.seedData(for: printerType)) }
        catch let error as MaterialDatabaseError { throw error }
        catch { throw MaterialDatabaseError.malformed(error.localizedDescription) }

        guard isOutdated(comparedTo: file.result.version) else { return [] }

        var added: [String] = []
        for filament in file.result.list where !contains(id: filament.base.id) {
            try add(filament)
            added.append(filament.base.id)
        }
        // The version moves even when every record was already present: the local catalogue is
        // then a superset of this seed, and leaving it behind would re-offer a top-up with
        // nothing in it on every load.
        setVersion(file.result.version)
        try save()
        return added
    }
}
