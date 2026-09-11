import Foundation

// SPEC-04 §3 — the two flows, which the Windows app splits across two confusingly-named
// dialogs (`UploadForm` titled "Upload" with a header reading "Update…", and `UpdateForm`
// titled "Update" reached from a menu item labelled "Download Database"):
//
//   Upload  — push the local material_database.json onto the printer, plus material_option.json
//             on the K1 family, then optionally reboot.
//   Update  — pull a database into the app, either from the printer or from Creality Cloud.
//
// Everything here is async, off the main actor, cancellable, and reports progress — all four of
// which the Windows app lacks (SPEC-04 §7: SSH runs synchronously on the UI thread, there is no
// CancellationToken anywhere, and progress is a static "Uploading..." label).

// MARK: - Printer model

/// Which family a printer profile belongs to. Drives the remote path, the default password, and
/// whether `material_option.json` is written.
///
/// There is **no detection** — SPEC-04 §4. The "type" is a display string the user picked from
/// a combo box, populated from local `material_database/<name>.json` filenames, which came from
/// Creality Cloud printer names ("K2 Plus", "K1 Max", "Hi Combo", …).
/// Classification is **shared with ``PrinterType``** — see
/// ``PrinterFamily/init(identifying:)``. The two used to disagree in three ways: this one
/// defaulted an unrecognised name to `.k2` (handing it K2's root password and `/mnt/UDISK`)
/// while `PrinterType.init(identifying:)` returned `nil`; this one stripped `creality` from
/// *anywhere* in the string with `range(of:)` rather than as the documented leading token; and
/// `PrinterType` has no `.i7`. Now there is one tokenizer, one alias table per family, and no
/// silent fallback.
public enum PrinterFamily: String, Equatable, CaseIterable, Sendable {
    case k1, k2, hi, i7

    /// The material-database family this printer family uses, or `nil` for `.i7`.
    ///
    /// `PrinterType` models the three families `db/` ships a catalogue for (`k1`/`k2`/`hi`).
    /// The i7 appears only in Android's password table (`MainActivity.java:1136`) and has no
    /// bundled catalogue, so it maps to nothing rather than being quietly filed under K2.
    public var printerType: PrinterType? {
        switch self {
        case .k1: return .k1
        case .k2: return .k2
        case .hi: return .hi
        case .i7: return nil
        }
    }

    /// The transport-layer family for a material-database family. Total in this direction.
    public init(_ printerType: PrinterType) {
        switch printerType {
        case .k1: self = .k1
        case .k2: self = .k2
        case .hi: self = .hi
        }
    }

    /// Tokens recognised for the i7, which ``PrinterType`` does not model.
    private static let i7Aliases: Set<String> = ["i7", "i7 pro", "i7pro"]

    /// Resolves a free-form printer name (a cloud printer name, a saved profile name, user
    /// input) to a family, or `nil` when it is not recognisably one of the four.
    ///
    /// Delegates the k1/k2/hi decision to ``PrinterType/init(identifying:)`` so there is
    /// exactly one anchored, token-based matcher in the codebase, and adds the i7 on top.
    /// There is intentionally **no** default-to-K2 fallback: an unknown name must not silently
    /// inherit K2's root password or its `/mnt/UDISK` paths.
    public init?(identifying rawName: String) {
        if let type = PrinterType(identifying: rawName) {
            self.init(type)
            return
        }
        let normalised = PrinterType.normalisedName(rawName)
        guard !normalised.isEmpty else { return nil }
        if PrinterFamily.i7Aliases.contains(normalised)
            || PrinterFamily.i7Aliases.contains(PrinterType.leadingToken(of: rawName)) {
            self = .i7
            return
        }
        return nil
    }

    /// Base directory on the printer. The *only* branch in the whole networking layer
    /// (SPEC-04 §2). Everything that is not K1 inherits the K2 path — including the Hi, which
    /// is assumed rather than verified (spec OPEN QUESTION #3).
    public var remoteBaseDirectory: String {
        switch self {
        case .k1: return "/usr/data/creality/userdata/box/"
        case .k2, .hi, .i7: return "/mnt/UDISK/creality/userdata/box/"
        }
    }

    /// The vendor factory default. See `VendorDefaultPassword` for provenance.
    public var defaultPassword: String {
        switch self {
        case .k1: return VendorDefaultPassword.k1
        case .k2: return VendorDefaultPassword.k2
        case .hi: return VendorDefaultPassword.hi
        case .i7: return VendorDefaultPassword.i7
        }
    }

    /// Whether the printer's UI reads `material_option.json`.
    ///
    /// **Windows and Android disagree here and this is the resolution.** Windows writes it only
    /// on an *exact* `"k1"` name match (`UploadForm.cs:161`, `Equals(…, OrdinalIgnoreCase)`),
    /// so a `K1 Max` or `K1C` profile never gets one. Android writes it for any name
    /// *containing* `k1` (`Utils.java:478`), so those profiles do get one.
    ///
    /// We follow Android. Rationale: Windows' own *path* branch is a substring test, so a
    /// `K1 Max` profile is already treated as K1-family for the database upload and writes into
    /// `/usr/data/…`. Writing the database to the K1 location while withholding the companion
    /// index the K1 UI reads is internally inconsistent, and the exact-match test looks like an
    /// oversight rather than a decision — there is no comment or resource distinguishing K1 from
    /// K1 Max anywhere in the Windows tree. The failure modes are also asymmetric: writing the
    /// file to a printer that ignores it is inert, while withholding it from one that needs it
    /// leaves the brand/type picker empty. Spec OPEN QUESTION #4 remains open on real hardware;
    /// `UploadOptions.writeMaterialOption` lets a user override either way.
    public var writesMaterialOption: Bool { self == .k1 }
}

/// A printer profile: the user-visible name plus everything derived from it.
public struct PrinterModel: Equatable, Sendable {

    /// Exactly as shown in the UI, e.g. `"K1 Max"`. Also the local database filename stem.
    public let profileName: String
    public let family: PrinterFamily

    /// Fails when the name is not recognisably one of the four families.
    ///
    /// **This init is failable on purpose.** It used to default an unrecognised name to `.k2`,
    /// which meant an unknown or mistyped profile silently got K2's root password and wrote
    /// into K2's `/mnt/UDISK` paths — a guess dressed up as a fact, on a device where a wrong
    /// path means "silently do nothing" and a wrong password means "we tried the vendor default
    /// against an unknown machine". A caller that genuinely knows better uses
    /// ``init(profileName:family:)``.
    public init?(profileName: String) {
        guard let family = PrinterModel.family(forProfileName: profileName) else { return nil }
        self.profileName = profileName
        self.family = family
    }

    /// Overrides the derived family, for the case where the classifier does not know a model
    /// yet — including anything the failable init above rejects.
    public init(profileName: String, family: PrinterFamily) {
        self.profileName = profileName
        self.family = family
    }

    /// Classifies a cloud printer name, or returns `nil`.
    ///
    /// Both existing clients use **unanchored substring** tests in the order `hi`, `k1`, (`i7`),
    /// else K2 (Windows `UploadForm.cs:40-51`; Android `MainActivity.java:1131-1139`). The spec
    /// flags that as fragile: `hi` is tested first and matches anywhere, so any future model
    /// whose name happens to contain those two letters — "…High Flow", "Ender Hi-Speed" — silently
    /// picks up the Hi password, and `K1 Max` only works by luck.
    ///
    /// This is now a thin alias for ``PrinterFamily/init(identifying:)``, which is itself built
    /// on ``PrinterType/init(identifying:)`` — one anchored, token-based matcher for the whole
    /// codebase. Every real name in either client's catalogue (`{"K2","K1","HI","i7"}` plus
    /// cloud variants like `K1 Max`, `K1C`, `K2 Plus`, `Hi Combo`) still classifies the same
    /// way; `Ender 5` and `""` now return `nil` instead of `.k2`.
    public static func family(forProfileName name: String) -> PrinterFamily? {
        PrinterFamily(identifying: name)
    }

    /// `…/box/material_database.json` — the file both flows read and write (SPEC-04 §2).
    public var materialDatabasePath: String { family.remoteBaseDirectory + "material_database.json" }

    /// `…/box/material_option.json` — the K1 UI's brand/type picker source (SPEC-04 §10.5).
    public var materialOptionPath: String { family.remoteBaseDirectory + "material_option.json" }

    /// `…/box/material_box_info.json` — the CFS's live report of what is loaded. **Read only**:
    /// nothing in this app writes it, because it is the firmware's own state rather than a
    /// configuration file.
    public var materialBoxInfoPath: String { family.remoteBaseDirectory + "material_box_info.json" }

    public var defaultPassword: String { family.defaultPassword }
}

// MARK: - Options, progress, results

/// What `result.version` should say in the document we upload.
public enum VersionStamp: Equatable, Sendable {
    /// `9876543210` — "Prevent DB updates?" checked. ≈ year 2282, so the printer's own updater
    /// believes it is already ahead of anything Creality will ship (SPEC-04 §3.1 step 2).
    case preventUpdates
    /// "Prevent DB updates?" unchecked: read the printer's current version and stamp that, so
    /// the printer sees no change in version and leaves the database alone until Creality ships
    /// a newer one (Windows `UploadForm.cs:157-158`).
    case matchPrinter
    /// Leave the document's own version untouched. Used by the reset flow, where the point is to
    /// restore the factory database *and* let the printer resume updating it normally.
    case keepDocumentVersion
}

public struct UploadOptions: Equatable, Sendable {

    public var versionStamp: VersionStamp

    /// `nil` uses the family default. Set explicitly to override the Windows/Android divergence
    /// documented on `PrinterFamily.writesMaterialOption`.
    public var writeMaterialOption: Bool?

    /// Mirrors the Windows dialog's "Prevent DB updates?" checkbox, which defaults to `true`
    /// (`UploadForm.cs:97`). Its "Reboot printer?" checkbox has no counterpart: an upload never
    /// restarts the printer — see ``PrinterService/restartIfIdle(host:checkingWith:)``.
    public init(preventDatabaseUpdates: Bool = true,
                writeMaterialOption: Bool? = nil) {
        self.versionStamp = preventDatabaseUpdates ? .preventUpdates : .matchPrinter
        self.writeMaterialOption = writeMaterialOption
    }

    public init(versionStamp: VersionStamp,
                writeMaterialOption: Bool? = nil) {
        self.versionStamp = versionStamp
        self.writeMaterialOption = writeMaterialOption
    }

    /// True when the uploaded document will carry the `9876543210` sentinel.
    public var preventsDatabaseUpdates: Bool { versionStamp == .preventUpdates }
}

public struct PrinterProgress: Equatable, Sendable {
    public enum Stage: String, Equatable, Sendable {
        case preparing
        case readingPrinterVersion
        case uploadingDatabase
        case uploadingMaterialOption
        case downloadingDatabase
        case finished
    }
    public let stage: Stage
    /// 0…1. Coarse — the transport streams through one `ssh` process and gives no byte counts,
    /// so this is per-step rather than per-byte. Still infinitely better than the Windows app's
    /// static label.
    public let fractionCompleted: Double

    public init(stage: Stage, fractionCompleted: Double) {
        self.stage = stage
        self.fractionCompleted = fractionCompleted
    }
}

public typealias PrinterProgressHandler = @Sendable (PrinterProgress) -> Void

public struct UploadResult: Equatable, Sendable {
    /// The database bytes actually written to the printer, version stamp included. The Windows
    /// app rewrites its *local* file with the same stamp (`UploadForm.cs:153-158`), so callers
    /// should persist this rather than the bytes they passed in.
    public let uploadedDatabase: Data
    public let version: String
    public let wroteMaterialOption: Bool
}

/// The outcome of a version check against the printer (SPEC-04 §3.2).
public enum UpdateAvailability: Equatable, Sendable {
    case available(printerVersion: String, localVersion: String)
    case upToDate(version: String)
}

public enum PrinterServiceError: Error, Equatable, CustomStringConvertible {
    case databaseNotJSON
    case missingVersionField
    case unparsableVersion(String)
    case cloudUnavailable

    public var description: String {
        switch self {
        case .databaseNotJSON:    return "The material database is not valid JSON."
        case .missingVersionField: return "The material database has no result.version field."
        case .unparsableVersion(let value):
            return "The material database version \"\(value)\" is not a number."
        case .cloudUnavailable:
            return "This service was created without a Creality Cloud client."
        }
    }
}

// MARK: - Database document helpers

/// Reading and rewriting the bits of `material_database.json` the printer flows care about.
///
/// Deliberately operates on raw bytes rather than a typed model: the printer format has ~150
/// free-form `kvParam` keys per entry (SPEC-04 §10.3) and round-tripping it through a partial
/// Swift model would silently drop whatever we failed to model.
public enum MaterialDatabaseDocument {

    /// `9876543210` — Windows `Resources.resx:168-170` (`verPrevent`), Android
    /// `MainActivity.java:1609`. Both clients use the identical literal.
    public static let preventUpdatesVersion = "9876543210"

    /// Reads `result.version`.
    public static func version(in data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PrinterServiceError.databaseNotJSON
        }
        guard let result = root["result"] as? [String: Any] else {
            throw PrinterServiceError.missingVersionField
        }
        if let text = result["version"] as? String { return text }
        if let number = result["version"] as? NSNumber { return number.stringValue }
        throw PrinterServiceError.missingVersionField
    }

    /// Returns `data` with `result.version` replaced.
    ///
    /// Re-serialised as UTF-8 with sorted keys. UTF-8 fixes a real bug: the Windows app uses
    /// `Encoding.ASCII` on every path (`Utils.cs:524`, `Utils.cs:639`, `Utils.cs:674`,
    /// `MatDb.cs:89`, `MatDb.cs:186`), which turns every non-ASCII brand or colour name into
    /// `?`. Sorted keys make the output deterministic — the firmware parses JSON, so key order
    /// is not meaningful to it.
    public static func stamping(_ data: Data, version: String) throws -> Data {
        guard var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PrinterServiceError.databaseNotJSON
        }
        var result = (root["result"] as? [String: Any]) ?? [:]
        result["version"] = version
        // `result.count` must equal `list.length`; both clients maintain it by hand
        // (`MatDb.cs:179`, `Utils.cs:886`) and both can get it wrong. Fix it while we are here.
        if let list = result["list"] as? [Any] { result["count"] = list.count }
        root["result"] = result
        return try serialize(root)
    }

    /// Builds `material_option.json`: `{"<brand>": {"<meterialType>": "<name>\n<name>…"}}`.
    ///
    /// Windows `Utils.cs:694-728`, Android `Utils.java:487-515`. Note `meterialType` — the
    /// misspelling is in the firmware's own format and must be preserved (SPEC-04 §10.3).
    public static func materialOptionDocument(from database: Data) throws -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: database) as? [String: Any] else {
            throw PrinterServiceError.databaseNotJSON
        }
        let list = (root["result"] as? [String: Any])?["list"] as? [[String: Any]] ?? []

        var options: [String: [String: String]] = [:]
        for item in list {
            guard let base = item["base"] as? [String: Any],
                  let brand = base["brand"] as? String,
                  let type = base["meterialType"] as? String,
                  let name = base["name"] as? String
            else { continue }
            if let existing = options[brand]?[type] {
                options[brand, default: [:]][type] = existing + "\n" + name
            } else {
                options[brand, default: [:]][type] = name
            }
        }
        return try serialize(options)
    }

    private static func serialize(_ object: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys,
                                                        .withoutEscapingSlashes])
        } catch {
            throw PrinterServiceError.databaseNotJSON
        }
    }
}

// MARK: - Service

/// The two printer flows, driven through a `PrinterTransport`.
///
/// Nothing here knows about `ssh`; hand it a `MockPrinterTransport` and every path is testable
/// with no hardware, which is how the accompanying suite runs.
public struct PrinterService: Sendable {

    private let transport: PrinterTransport
    private let cloud: CrealityCloudAPI?

    public init(transport: PrinterTransport, cloud: CrealityCloudAPI? = nil) {
        self.transport = transport
        self.cloud = cloud
    }

    // MARK: Read (printer → PC)

    /// Reads the printer's live CFS state.
    ///
    /// Read-only and idempotent, which is why it has none of the ceremony `upload` needs: no
    /// version stamping, no staging file, no reboot. A decode failure is surfaced rather than
    /// swallowed — an unparseable document means the firmware's format has moved, and quietly
    /// reporting an empty CFS would be indistinguishable from a CFS that is genuinely empty.
    public func boxInfo(of model: PrinterModel) async throws -> MaterialBoxInfo {
        let data = try await transport.download(from: model.materialBoxInfoPath)
        return try MaterialBoxInfo.decode(from: data)
    }

    // MARK: Upload (PC → printer)

    /// Pushes `database` onto the printer. SPEC-04 §3.1, "Normal upload path".
    ///
    /// Order of operations matches the Windows app: stamp the version, upload the database, then
    /// write `material_option.json` on the K1 family. Unlike both upstream clients it **never
    /// restarts the printer**: a restart takes a print in progress down with it, so it is a separate
    /// step the app asks about, through ``restartIfIdle(host:checkingWith:)``. The printer uses the
    /// new database once it has restarted (SPEC-04 §1.5).
    @discardableResult
    public func upload(database: Data,
                       to model: PrinterModel,
                       options: UploadOptions = UploadOptions(),
                       progress: PrinterProgressHandler? = nil) async throws -> UploadResult {

        progress?(PrinterProgress(stage: .preparing, fractionCompleted: 0))
        try Task.checkCancellation()

        let version: String
        switch options.versionStamp {
        case .preventUpdates:
            version = MaterialDatabaseDocument.preventUpdatesVersion
        case .matchPrinter:
            // Windows reads the printer's own version and stamps the local file with it
            // (`UploadForm.cs:157-158`). Its `GetPrinterVersion` swallows every exception and
            // returns the string "0" (`Utils.cs:678-681`), so an unreachable printer silently
            // stamps the database version as 0. We propagate the error instead.
            progress?(PrinterProgress(stage: .readingPrinterVersion, fractionCompleted: 0.1))
            version = try await printerDatabaseVersion(of: model)
        case .keepDocumentVersion:
            version = try MaterialDatabaseDocument.version(in: database)
        }

        let stamped = try MaterialDatabaseDocument.stamping(database, version: version)

        try Task.checkCancellation()
        progress?(PrinterProgress(stage: .uploadingDatabase, fractionCompleted: 0.3))
        try await transport.upload(data: stamped, to: model.materialDatabasePath)

        let shouldWriteOption = options.writeMaterialOption ?? model.family.writesMaterialOption
        if shouldWriteOption {
            try Task.checkCancellation()
            progress?(PrinterProgress(stage: .uploadingMaterialOption, fractionCompleted: 0.6))
            let optionDocument = try MaterialDatabaseDocument.materialOptionDocument(from: stamped)
            try await transport.upload(data: optionDocument, to: model.materialOptionPath)
        }

        progress?(PrinterProgress(stage: .finished, fractionCompleted: 1))
        return UploadResult(uploadedDatabase: stamped,
                            version: version,
                            wroteMaterialOption: shouldWriteOption)
    }

    /// Reset flow (SPEC-04 §3.1, "Reset path"): push a factory database.
    ///
    /// The Windows app reboots unconditionally here (`UploadForm.cs:111`, `Utils.cs:470`). This
    /// does not restart the printer at all, for the same reason
    /// ``upload(database:to:options:progress:)`` does not.
    ///
    /// Takes the cloud-built database as a parameter rather than building it here: converting a
    /// profile zip into the printer format is the database layer's job, not the transport's.
    ///
    /// The factory database keeps its own version: Windows uploads the cloud JSON verbatim in
    /// this mode and never touches `result.version` (`Utils.cs:454-455`). Stamping the
    /// prevent-updates sentinel here would defeat the point of a reset, which is to hand the
    /// printer back a database it is free to keep updating.
    @discardableResult
    public func reset(to model: PrinterModel,
                      withCloudDatabase database: Data,
                      progress: PrinterProgressHandler? = nil) async throws -> UploadResult {
        try await upload(database: database,
                         to: model,
                         options: UploadOptions(versionStamp: .keepDocumentVersion,
                                                writeMaterialOption: model.family.writesMaterialOption),
                         progress: progress)
    }

    // MARK: Restart

    /// Restarts the printer, if it is idle when asked immediately beforehand.
    ///
    /// The only way the `reboot` command (SPEC-04 §1.5) leaves this package. `reboot` in a root
    /// shell takes the printer down at once, print and all, so `activityReader` is asked what the
    /// printer is doing first, and anything but ``PrinterActivity/idle`` refuses:
    /// ``RestartRefusal/printing(paused:)``, ``RestartRefusal/busy``, or
    /// ``RestartRefusal/unconfirmed(_:)`` when the answer cannot be had. There is no override
    /// (docs/DECISIONS.md D-006).
    ///
    /// `reboot` always tears the connection down mid-command, so a transport-level "connection
    /// closed" immediately afterwards is success, not failure. The Windows app only survives
    /// this by accident, via a 5 s `CommandTimeout` (SPEC-04 §11.5).
    ///
    /// Only the *teardown message* is treated as success. This used to also accept any
    /// `remoteCommandFailed(255, …)` whatever the message, and 255 is ssh's catch-all for
    /// everything it does itself — a refused password, a rejected host key, a failed
    /// negotiation. Those all reported a restart for a printer that never restarted, which then
    /// read back as "the upload took effect" when it had not.
    public func restartIfIdle(host: String, checkingWith activityReader: PrinterActivityReading) async throws {
        let activity: PrinterActivity
        do {
            activity = try await activityReader.activity(host: host)
        } catch {
            throw RestartRefusal.unconfirmed(error.localizedDescription)
        }
        switch activity {
        case .idle:
            break
        case let .printing(paused):
            throw RestartRefusal.printing(paused: paused)
        case .busy:
            throw RestartRefusal.busy
        }

        try Task.checkCancellation()
        do {
            try await transport.run(command: PrinterCommand.reboot)
        } catch let error as PrinterTransportError {
            switch error {
            case .remoteCommandFailed(_, let message)
                where PrinterService.indicatesConnectionTornDown(message):
                return
            case .connectionFailed(let detail) where PrinterService.indicatesConnectionTornDown(detail):
                return
            default:
                throw error
            }
        }
    }

    static func indicatesConnectionTornDown(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("closed by remote host")
            || lower.contains("connection reset")
            || lower.contains("broken pipe")
    }

    // MARK: Update (printer → PC)

    /// Downloads `material_database.json` from the printer (SPEC-04 §3.2, "On — the printer itself").
    public func downloadDatabaseFromPrinter(_ model: PrinterModel,
                                            progress: PrinterProgressHandler? = nil) async throws -> Data {
        progress?(PrinterProgress(stage: .downloadingDatabase, fractionCompleted: 0.1))
        try Task.checkCancellation()
        let data = try await transport.download(from: model.materialDatabasePath)
        progress?(PrinterProgress(stage: .finished, fractionCompleted: 1))
        return data
    }

    /// The printer's current `result.version`.
    public func printerDatabaseVersion(of model: PrinterModel) async throws -> String {
        let data = try await transport.download(from: model.materialDatabasePath)
        return try MaterialDatabaseDocument.version(in: data)
    }

    /// Compares the printer's version against the local one, numerically
    /// (`long.Parse(newVersion) > long.Parse(currentVersion)` — `UpdateForm.cs:112`).
    public func checkForUpdate(on model: PrinterModel,
                               localVersion: String) async throws -> UpdateAvailability {
        let printerVersion = try await printerDatabaseVersion(of: model)
        guard let remote = Int64(printerVersion) else {
            throw PrinterServiceError.unparsableVersion(printerVersion)
        }
        guard let local = Int64(localVersion) else {
            throw PrinterServiceError.unparsableVersion(localVersion)
        }
        return remote > local
            ? .available(printerVersion: printerVersion, localVersion: localVersion)
            : .upToDate(version: printerVersion)
    }

    // MARK: Update (cloud → PC)

    /// Fetches the profile bundle for a model from Creality Cloud (SPEC-04 §5.2 steps 1-3).
    ///
    /// Returns the raw zip. Unpacking it and joining it against `materialList` to produce the
    /// printer format (§5.2 step 4, `ProcessMaterials`) belongs to the database layer.
    public func downloadProfileZipFromCloud(for model: PrinterModel,
                                            nozzle: String = CrealityCloudRequest.defaultNozzle) async throws -> Data {
        guard let cloud else { throw PrinterServiceError.cloudUnavailable }
        return try await cloud.profileZip(forPrinterNamed: model.profileName, nozzle: nozzle)
    }

    /// The cloud catalogue of printer models. There is no LAN discovery anywhere in either
    /// existing client (SPEC-04 §6); this is the only "find printers" there is.
    public func cloudPrinterModels(nozzle: String = CrealityCloudRequest.defaultNozzle) async throws -> [CloudPrinter] {
        guard let cloud else { throw PrinterServiceError.cloudUnavailable }
        return try await cloud.printerList(nozzle: nozzle)
    }
}

/// `Error.localizedDescription` — which is what every UI surface shows — reads `errorDescription`,
/// not `description`. Without this the CFS strip and the upload sheets showed "The operation
/// couldn't be completed. (SpoolworksCore.PrinterServiceError error 3.)" in place of the sentence the case
/// was written to say.
extension PrinterServiceError: LocalizedError {
    public var errorDescription: String? { description }
}
