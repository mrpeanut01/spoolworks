import Foundation
@testable import SpoolworksCore

// Tests for the material/filament database layer (SPEC/02-material-db.md).
//
// Three things are being pinned here:
//   1. the wire format — real records lifted from `db/k2.json` and `db/k1.json` must decode, and a
//      decode/encode cycle must not lose a byte the printer cares about;
//   2. the four defects the Windows original ships with (no duplicate check on add, edit appends
//      instead of replacing, mutate-while-enumerating swallowed by an empty catch, and save
//      early-returning on an empty list) — each has a test that fails if the fix regresses;
//   3. that nothing fails silently: every error path throws something specific.

// MARK: - Helpers

private enum Fixture {
    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw MaterialDatabaseError.storage("fixture \(name).json is missing from the test bundle")
        }
        return try Data(contentsOf: url)
    }

    static func file(_ name: String) throws -> MaterialDatabaseFile {
        try MaterialDatabase.decode(try data(name))
    }
}

/// A throwaway Application Support directory, so tests never touch the real one.
private final class TempStorage {
    let root: URL
    let storage: MaterialStorage

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("k2-matdb-tests-\(UUID().uuidString)", isDirectory: true)
        // Deliberately NOT created: the database layer is expected to create it on demand.
        storage = MaterialStorage(directory: root.appendingPathComponent("material_database", isDirectory: true))
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

/// Wraps one record in the standard envelope, for the hand-written edge cases.
private func envelope(_ record: String, version: String = "1758907369") -> Data {
    Data("""
    {"code":0,"msg":"ok","reqId":"0","result":{"list":[\(record)],"count":1,"version":"\(version)"}}
    """.utf8)
}

private let minimalBase = """
{"id":"01001","brand":"Creality","name":"Hyper PLA","meterialType":"PLA","colors":["#ffffff"],
 "density":1.24,"diameter":"1.75","costPerMeter":0,"weightPerMeter":0,"rank":10000,
 "minTemp":190,"maxTemp":240,"isSoluble":false,"isSupport":false,
 "shrinkageRate":0,"softeningTemp":0,"dryingTemp":0,"dryingTime":0}
"""

private func record(base: String = minimalBase, kvParam: String = "{}") -> String {
    """
    {"engineVersion":"3.0.0","printerIntName":"F008","nozzleDiameter":["0.4"],
     "kvParam":\(kvParam),"base":\(base)}
    """
}

private func sampleFilament(id: String, name: String = "Test PLA", brand: String = "Generic") -> Filament {
    Filament(printerIntName: PrinterType.k2.printerIntName,
             kvParam: ["filament_type": "PLA", "filament_vendor": brand],
             base: MaterialBase(id: id, brand: brand, name: name, materialType: "PLA"))
}

/// A database backed by a temp directory and an in-memory seed holding `ids`.
private func makeDatabase(_ temp: TempStorage, ids: [String],
                          version: String = "1758907369") throws -> MaterialDatabase {
    let file = MaterialDatabaseFile(list: ids.map { sampleFilament(id: $0) }, version: version)
    let seed = StaticMaterialSeed([.k2: try MaterialDatabase.encode(file)])
    let db = MaterialDatabase(printerType: .k2, storage: temp.storage, seed: seed)
    try db.load()
    return db
}

/// A database over a catalogue written straight to disk, backed by the **bundled** seed — so
/// `topUpFromSeed` has the real shipped k2.json to top up from, not a stand-in.
private func makeBundleSeededDatabase(_ temp: TempStorage, ids: [String],
                                      version: String) throws -> MaterialDatabase {
    let file = MaterialDatabaseFile(list: ids.map { sampleFilament(id: $0) }, version: version)
    try temp.storage.createDirectoryIfNeeded()
    try MaterialDatabase.encode(file).write(to: temp.storage.url(for: .k2), options: .atomic)
    let db = MaterialDatabase(printerType: .k2, storage: temp.storage, seed: BundledMaterialSeed())
    try db.load()
    return db
}

// MARK: - Suite

let materialDatabaseTests = TestSuite(name: "Material database", cases: [

    // MARK: - Printer type

    // Windows uses three disagreeing mechanisms (a hard-coded array, the DB file name, and
    // unanchored `Contains` tests with "hi" checked first). This port uses one anchored scheme.
    test("printer type resolves canonical tokens") { t in
        t.equal(PrinterType(identifying: "k2"), .k2)
        t.equal(PrinterType(identifying: "K1"), .k1)
        t.equal(PrinterType(identifying: "HI"), .hi)
        t.equal(PrinterType(identifying: "  K2  "), .k2)
    },

    test("printer type resolves cloud printer names, file names and model codes") { t in
        t.equal(PrinterType(identifying: "K2 Plus"), .k2)
        t.equal(PrinterType(identifying: "K1 Max"), .k1)
        t.equal(PrinterType(identifying: "CR-K1 Max"), .k1)
        t.equal(PrinterType(identifying: "Creality Hi"), .hi)
        t.equal(PrinterType(identifying: "Hi Combo"), .hi)
        t.equal(PrinterType(identifying: "k2.json"), .k2)
        t.equal(PrinterType(identifying: "F008"), .k2)
        t.equal(PrinterType(identifying: "F018"), .hi)
    },

    // The Windows landmine: `name.ToLower().Contains("hi")` is tested FIRST and unanchored, so any
    // name containing the letters "hi" is classified as a Hi — and everything unrecognised silently
    // becomes a K2. Both are refused here.
    test("printer type refuses unanchored matches and has no silent fallback") { t in
        t.equal(PrinterType(identifying: "Ender Chi"), nil, "Windows would call this a Hi")
        t.equal(PrinterType(identifying: "Chiron"), nil, "contains 'hi'")
        t.equal(PrinterType(identifying: "Ender 3 V3"), nil, "Windows would silently call this a K2")
        t.equal(PrinterType(identifying: ""), nil)
        t.equal(PrinterType(identifying: "   "), nil)
    },

    test("printer type metadata matches the shipped databases") { t in
        t.equal(PrinterType.k1.printerIntName, "CR-K1 Max")
        t.equal(PrinterType.k2.printerIntName, "F008")
        t.equal(PrinterType.hi.printerIntName, "F018")
        // Always lower-case on disk — the case-sensitivity hazard `MatDb.cs` walked into.
        for type in PrinterType.allCases {
            t.equal(type.databaseFileName, type.databaseFileName.lowercased(), "file name casing")
            t.expect(!type.displayName.isEmpty, "display name for \(type.rawValue)")
        }
        // `material_option.json` is a K1-only side-car (Utils.SaveMatOption).
        t.equal(PrinterType.k1.usesMaterialOptionSidecar, true)
        t.equal(PrinterType.k2.usesMaterialOptionSidecar, false)
        t.equal(PrinterType.hi.usesMaterialOptionSidecar, false)
    },

    // MARK: - Decoding real records

    test("decodes a real k2 subset") { t in
        let file = try Fixture.file("material-k2-subset")
        t.equal(file.code, 0)
        t.equal(file.msg, "ok")
        t.equal(file.reqId, "0")
        t.equal(file.result.version, "1758907369")
        t.equal(file.result.count, 3)
        t.equal(file.result.list.count, 3)
        t.equal(file.result.list.map(\.id), ["01001", "00001", "E1001"], "file order preserved")
        t.equal(file.result.list.map(\.vendor), ["Creality", "Generic", "eSUN"])
        t.equal(file.result.list.map(\.printerIntName), ["F008", "F008", "F008"])
        t.equal(file.result.list[0].nozzleDiameter, ["0.4"])
        t.equal(file.result.list[0].engineVersion, "3.0.0")
    },

    // The wire key is misspelled and must stay misspelled or the printer rejects the file; the
    // Swift property is not.
    test("the misspelled meterialType key decodes and re-encodes") { t in
        let file = try Fixture.file("material-k2-subset")
        guard let first = t.unwrap(file.result.list.first) else { return }
        t.equal(first.materialType, "PLA")
        t.equal(first.base.materialType, "PLA")

        let data = try MaterialDatabase.encode(file)
        let text = String(decoding: data, as: UTF8.self)
        t.expect(text.contains("\"meterialType\""), "wire spelling must survive the round trip")
        t.expect(!text.contains("\"materialType\""), "the corrected spelling must never be written")
    },

    test("diameter is a string and density is a number") { t in
        let file = try Fixture.file("material-k2-subset")
        guard let first = t.unwrap(file.result.list.first) else { return }
        t.equal(first.base.diameter, "1.75")
        t.equal(first.base.density, 1.24)

        // …and both are re-emitted in the wire form the printer sends.
        let text = String(decoding: try MaterialDatabase.encode(file), as: UTF8.self)
        t.expect(text.contains("\"diameter\" : \"1.75\""), "diameter must stay quoted")
        t.expect(text.contains("\"density\" : 1.24"), "density must stay unquoted")
    },

    // Defensive: a source that quotes the density or unquotes the diameter still lands in the
    // right property rather than failing the whole catalogue.
    test("string/number confusion in diameter and density is tolerated on decode") { t in
        let swapped = """
        {"id":"01001","brand":"Creality","name":"Hyper PLA","meterialType":"PLA","colors":["#ffffff"],
         "density":"1.24","diameter":1.75,"costPerMeter":0,"weightPerMeter":0,"rank":10000,
         "minTemp":"190","maxTemp":240,"isSoluble":"0","isSupport":false,
         "shrinkageRate":0,"softeningTemp":0,"dryingTemp":0,"dryingTime":0}
        """
        let file = try MaterialDatabase.decode(envelope(record(base: swapped)))
        guard let base = t.unwrap(file.result.list.first?.base) else { return }
        t.equal(base.density, 1.24)
        t.equal(base.diameter, "1.75")
        t.equal(base.minTemp, 190)
        t.equal(base.isSoluble, false)
    },

    test("ids are never coerced to integers") { t in
        let file = try Fixture.file("material-k2-subset")
        t.equal(file.result.list[1].id, "00001", "leading zeros survive")
        t.equal(file.result.list[2].id, "E1001", "non-numeric ids load (the add form would reject this)")
    },

    // 90/91/92/93/100 keys observed across the shipped files: never a fixed struct.
    test("kvParam key sets vary per record and stay a dictionary") { t in
        let file = try Fixture.file("material-k2-subset")
        t.equal(file.result.list.map(\.kvParam.count), [9, 12, 15], "heterogeneous key counts")

        let outlier = try Fixture.file("material-k1-outlier")
        guard let extra = t.unwrap(outlier.result.list.first) else { return }
        t.equal(extra.printerIntName, "CR-K1 Max")
        // The 10 keys only `k1.json` id 01002 carries.
        for key in ["customized_plate_temp", "filament_long_retractions_when_cut",
                    "idle_temperature", "pellet_flow_coefficient", "filament_stamping_distance"] {
            t.expect(extra.kvParam[key] != nil, "outlier key \(key) is missing")
        }
    },

    test("kvParam values keep their string spelling, including the nil sentinel") { t in
        let file = try Fixture.file("material-k2-subset")
        guard let kv = t.unwrap(file.result.list.first?.kvParam) else { return }
        t.equal(kv["filament_retraction_speed"], "nil", "the literal 'nil' means unset — not Swift nil")
        t.equal(kv["filament_shrink"], "100%")
        t.equal(kv["filament_density"], "1.24", "a logically numeric value is still a string")
        t.equal(kv["nozzle_temperature"], "220")
        t.equal(kv["filament_notes"], "\"\"", "an escaped empty string, not an empty value")
        t.equal(kv["filament_end_gcode"], ";filament end gcode \n", "embedded newline survives")
    },

    // Codable drops any key it does not model; the C# cannot lose data because it keeps the raw
    // blob. The catch-alls are what buy back that guarantee.
    test("round trip preserves unmodelled fields") { t in
        let original = try Fixture.data("material-extra-fields")
        let file = try MaterialDatabase.decode(original)
        guard let entry = t.unwrap(file.result.list.first) else { return }

        t.equal(entry.additionalFields["futureEntryField"], .string("keep me"))
        t.equal(entry.additionalFields["futureEntryObject"],
                .object(["nested": .array([.int(1), .double(2.5), .bool(true), .null, .string("x")])]))
        t.equal(entry.base.additionalFields["createTime"], .int(1746005657))
        t.equal(entry.base.additionalFields["status"], .int(1))
        t.equal(entry.base.additionalFields["userInfo"],
                .object(["uid": .string("abc"), "nickName": .string("someone")]))

        // A printer's reqId survives; Windows replaces it with "0" on the first local save.
        t.equal(file.reqId, "cl602024082916552939795681")
        t.equal(entry.nozzleDiameter, ["0.4", "0.6"])

        // Re-encode, re-decode, compare against the untouched original key by key.
        let reencoded = try MaterialDatabase.encode(file)
        let a = try JSONSerialization.jsonObject(with: original) as? NSDictionary
        let b = try JSONSerialization.jsonObject(with: reencoded) as? NSDictionary
        guard let a, let b else { t.expect(false, "could not re-parse for comparison"); return }
        t.expect(a.isEqual(to: b as! [AnyHashable: Any]), "round trip lost or altered a key")

        // …and the value graph is stable across a second cycle.
        t.equal(try MaterialDatabase.decode(reencoded), file)
    },

    test("an empty catalogue is a valid database") { t in
        let data = Data(#"{"code":0,"msg":"ok","reqId":"0","result":{"list":[],"count":0,"version":"0"}}"#.utf8)
        let file = try MaterialDatabase.decode(data)
        t.equal(file.result.list.count, 0)
        t.equal(file.result.count, 0)
        t.equal(file.result.version, MaterialVersion.unknown)
    },

    // MARK: - Malformed input

    test("truncated JSON reports a decoding failure rather than a half-filled catalogue") { t in
        let data = try Fixture.data("material-malformed")
        t.throwsError("decoding a truncated file") {
            _ = try MaterialDatabase.decode(data)
        }
        // …and it does not leave a partially populated database behind (MatDb.cs:52 does).
        let temp = TempStorage()
        try temp.storage.createDirectoryIfNeeded()
        try data.write(to: temp.storage.url(for: .k2))
        let db = MaterialDatabase(printerType: .k2, storage: temp.storage, seed: StaticMaterialSeed([:]))
        t.throwsError("loading a truncated file") { try db.load() }
        t.equal(db.filaments.count, 0)
        t.equal(db.isLoaded, false)
    },

    // CHANGED EXPECTATION. A missing identity field used to throw out of `decode` and take the
    // whole envelope with it. The record is still rejected — that has not changed, and it still
    // names the missing key — but the rejection is now scoped to the one record and reported in
    // `result.recordFailures`, so 97 good records still load. See IntegrityFixTests for the
    // survives-a-bad-record cases.
    test("a record missing a required identity field is rejected") { t in
        let noID = """
        {"brand":"Creality","name":"Hyper PLA","meterialType":"PLA","density":1.24,"diameter":"1.75"}
        """
        let file = try MaterialDatabase.decode(envelope(record(base: noID)))
        t.equal(file.result.list.count, 0, "the bad record must not be in the catalogue")
        guard let failure = t.unwrap(file.recordFailures.first, "record failure") else { return }
        t.equal(failure.index, 0)
        t.expect(failure.reason.contains("id"), "the message should name the missing key: \(failure.reason)")
    },

    // CHANGED EXPECTATION, same reason: reported per record rather than fatal for the file.
    // `kvParam`'s strictness itself is unchanged and deliberate — every one of the 12 082 values
    // in the shipped databases is a JSON string, so a number there means the file is not what we
    // think it is, and coercing it would lose the distinction between "190" and 190 on the way
    // back out to the printer.
    test("a non-string kvParam value is reported, not coerced") { t in
        let file = try MaterialDatabase.decode(envelope(record(kvParam: #"{"nozzle_temperature":220}"#)))
        t.equal(file.result.list.count, 0, "the record is still refused, not coerced")
        t.equal(file.recordFailures.count, 1)
        t.expect(file.recordFailures.first?.reason.contains("kvParam") == true,
                 "the message should name kvParam: \(file.recordFailures.first?.reason ?? "")")
    },

    test("an envelope with no result is rejected") { t in
        t.throwsError("decoding an envelope with no result") {
            _ = try MaterialDatabase.decode(Data(#"{"code":0,"msg":"ok","reqId":"0"}"#.utf8))
        }
        t.throwsError("decoding something that is not JSON at all") {
            _ = try MaterialDatabase.decode(Data("not json".utf8))
        }
    },

    // MARK: - Storage location and seeding

    test("storage resolves under Application Support") { t in
        let storage = try MaterialStorage.applicationSupport()
        let path = storage.directory.path
        t.expect(path.contains("Application Support/CFS-RFID/material_database"),
                 "unexpected storage path: \(path)")
        t.equal(storage.url(for: .k2).lastPathComponent, "k2.json")
        t.equal(storage.url(for: .k1).lastPathComponent, "k1.json")
        t.equal(storage.url(for: .hi).lastPathComponent, "hi.json")
    },

    test("first run seeds from the bundled catalogue and creates the directory") { t in
        let temp = TempStorage()
        t.equal(FileManager.default.fileExists(atPath: temp.storage.directory.path), false)

        let db = try makeDatabase(temp, ids: ["00001", "01001"])
        t.equal(FileManager.default.fileExists(atPath: temp.storage.directory.path), true,
                "the directory must be created on demand")
        t.equal(temp.storage.exists(.k2), true)
        t.equal(db.filaments.map(\.id), ["00001", "01001"])
        t.equal(db.isLoaded, true)
        t.equal(temp.storage.installedTypes(), [.k2])
    },

    test("an existing local database is never overwritten by the seed") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001"])
        try db.add(sampleFilament(id: "09999"))
        try db.save()

        let reopened = MaterialDatabase(printerType: .k2, storage: temp.storage,
                                        seed: StaticMaterialSeed([.k2: try MaterialDatabase.encode(
                                            MaterialDatabaseFile(list: [sampleFilament(id: "00001")]))]))
        try reopened.load()
        t.equal(reopened.filaments.map(\.id), ["00001", "09999"], "the seed must not clobber local edits")
    },

    test("a missing seed for a missing database is reported") { t in
        let temp = TempStorage()
        let db = MaterialDatabase(printerType: .hi, storage: temp.storage, seed: StaticMaterialSeed([:]))
        t.throwsError(MaterialDatabaseError.seedUnavailable(.hi)) { try db.load() }
    },

    // Pins the real shipped data, through the same path the app uses on first run.
    //
    // `k2` is the July-2026 K2 Plus capture; `k1` and `hi` are still the September-2025 ones,
    // which is why the versions are asserted per family rather than as one constant.
    test("the bundled seed loads the shipped databases") { t in
        let seed = BundledMaterialSeed()
        let expected: [PrinterType: (count: Int, version: String)] = [
            .k2: (96, "1784284303"),
            .k1: (46, "1758907369"),
            .hi: (21, "1758907369"),
        ]
        for (type, (count, version)) in expected {
            let file = try MaterialDatabase.decode(try seed.seedData(for: type))
            t.equal(file.result.list.count, count, "\(type.rawValue) record count")
            t.equal(file.result.count, count, "\(type.rawValue) declared count")
            t.equal(file.result.version, version, "\(type.rawValue) version")
            t.expect(file.result.list.allSatisfy { $0.printerIntName == type.printerIntName },
                     "\(type.rawValue) printerIntName")
            t.equal(Set(file.result.list.map(\.id)).count, count, "\(type.rawValue) ids are unique")
        }
    },

    // The reason the K2 seed was refreshed: the shipped catalogue is where an app-written tag's
    // filament ID comes from, and the 2025 capture had three Polymaker records and two eSUN ones.
    // A brand the picker cannot offer is a spool this app cannot tag.
    test("the K2 seed carries the third-party brands") { t in
        let file = try MaterialDatabase.decode(try BundledMaterialSeed().seedData(for: .k2))
        let byBrand = Dictionary(grouping: file.result.list, by: \.vendor).mapValues(\.count)
        t.equal(byBrand["Polymaker"], 13, "Polymaker")
        t.equal(byBrand["eSUN"], 18, "eSUN")
        // The ids these brands use are exactly the ones the write form used to refuse: a letter
        // followed by four digits. See `SpoolDraft.validationIssues`.
        let lettered = file.result.list.filter { $0.id.first?.isLetter == true }
        t.equal(lettered.count, 31, "P- and E-prefixed ids")
        t.expect(lettered.allSatisfy { $0.id.utf8.count == 5 }, "still five bytes wide")
    },

    // The capture also held two records the printer had synced from the user's own slicer
    // profiles — a second and third `00004`, carrying a `userMaterial` path into that machine's
    // filesystem. A duplicate id makes `filament(id:)` ambiguous, so they are not shipped.
    test("the K2 seed carries no user-authored records") { t in
        let file = try MaterialDatabase.decode(try BundledMaterialSeed().seedData(for: .k2))
        t.expect(file.result.list.allSatisfy { $0.additionalFields["userMaterial"] == nil },
                 "no userMaterial records")
        t.equal(file.result.list.filter { $0.id == "00004" }.count, 1, "one Generic ABS")
    },

    // MARK: - Seed top-up

    // `seedFromBundle` runs only when there is no local file, so a refreshed bundled catalogue
    // reached first-run installs and nobody else. This is how an existing install gets the new
    // records - offered, and additive.
    test("a newer bundled seed offers the records the local catalogue lacks") { t in
        let temp = TempStorage()
        let db = try makeBundleSeededDatabase(temp, ids: ["00001"], version: "1700000000")
        t.equal(db.pendingSeedAdditions().count, 95, "95 of the 96 bundled records are new")

        let added = try db.topUpFromSeed()
        t.equal(added.count, 95, "and all 95 are added")
        t.equal(db.filaments.count, 96, "alongside the one already there")
        t.equal(db.version, "1784284303", "stamped to the seed's version")
        t.equal(db.pendingSeedAdditions(), [], "so the offer is gone")
        t.expect(db.contains(id: "P1003"), "Polymaker Panchroma PLA Matte is in")
    },

    // The catalogue on disk is the user's. A record they have edited keeps their edit, and a
    // catalogue that has moved past the seed - a printer download - is not touched at all.
    test("a top-up never overwrites a record the catalogue already has") { t in
        let temp = TempStorage()
        let db = try makeBundleSeededDatabase(temp, ids: ["00001"], version: "1700000000")
        guard var mine = t.unwrap(db.filament(id: "00001"), "seeded record") else { return }
        mine.base.name = "Mine, hand-tuned"
        mine.base.minTemp = 205
        try db.update(mine)

        _ = try db.topUpFromSeed()
        t.equal(db.filament(id: "00001")?.name, "Mine, hand-tuned", "the edit survives")
        t.equal(db.filament(id: "00001")?.base.minTemp, 205, "temperatures included")
    },

    test("a catalogue newer than the seed is left alone") { t in
        let temp = TempStorage()
        let db = try makeBundleSeededDatabase(temp, ids: ["00001"], version: "1800000000")
        t.equal(db.pendingSeedAdditions(), [], "nothing offered")
        t.equal(try db.topUpFromSeed(), [], "and nothing added")
        t.equal(db.filaments.count, 1, "the catalogue is untouched")
        t.equal(db.version, "1800000000", "version included")
    },

    test("a top-up before a load is refused rather than writing a catalogue from nothing") { t in
        let temp = TempStorage()
        let db = MaterialDatabase(printerType: .k2, storage: temp.storage,
                                  seed: BundledMaterialSeed())
        t.throwsError(MaterialDatabaseError.notLoaded(.k2)) { _ = try db.topUpFromSeed() }
        t.equal(db.pendingSeedAdditions(), [], "and nothing is offered either")
    },

    // MARK: - Vendor catalogue

    // The captured catalogue covers Creality, Generic, eSUN and Polymaker's engineering line. The
    // brands people actually buy elsewhere are not in it, and their records cannot be captured
    // from anywhere - they are assembled from each maker's published profile by
    // `Tools/build-vendor-catalogue.py`.
    test("the bundled vendor catalogue carries the five Tier 1 brands") { t in
        let seed = BundledMaterialSeed()
        guard let data = try seed.vendorCatalogueData(for: .k2) else {
            t.record("no vendor catalogue is bundled for k2", file: #file, line: #line); return
        }
        let file = try MaterialDatabase.decode(data)
        t.equal(file.result.list.count, 113, "record count")
        t.equal(file.result.count, 113, "declared count")
        let byBrand = Dictionary(grouping: file.result.list, by: \.vendor).mapValues(\.count)
        t.equal(byBrand["Bambu Lab"], 41, "Bambu Lab")
        t.equal(byBrand["Elegoo"], 30, "Elegoo")
        t.equal(byBrand["Polymaker"], 24, "Polymaker's consumer line")
        t.equal(byBrand["Overture"], 11, "Overture")
        t.equal(byBrand["SUNLU"], 7, "SUNLU")
        t.equal(Set(file.result.list.map(\.id)).count, 113, "ids are unique")
    },

    // Two catalogues that share an id would make `filament(id:)` answer differently depending on
    // which was added first, and the printer would resolve whichever it holds.
    test("no vendor id collides with the captured catalogue") { t in
        let seed = BundledMaterialSeed()
        guard let data = try seed.vendorCatalogueData(for: .k2) else { return }
        let vendor = try MaterialDatabase.decode(data)
        let captured = try MaterialDatabase.decode(try seed.seedData(for: .k2))
        let capturedIDs = Set(captured.result.list.map(\.id))
        let overlap = vendor.result.list.map(\.id).filter { capturedIDs.contains($0) }
        t.equal(overlap, [], "ids must not collide")
        // Every id is five ASCII alphanumerics, or no tag can carry it. This is the rule three
        // separate validators were getting wrong before.
        t.expect(vendor.result.list.allSatisfy {
            $0.id.utf8.count == 5 && $0.id.allSatisfy { c in c.isASCII && (c.isUppercase || c.isNumber) }
        }, "every id is five capitals-and-digits bytes")
    },

    // The rule the generator exists to enforce: a filament profile mixes what belongs to the
    // plastic with what belongs to the printer, and only the first half travels. Vendor G-code
    // drives hardware a Creality machine does not have - and Bambu's is a bare comment where
    // Creality's sets the nozzle temperature, so taking it would have replaced working
    // temperature control with nothing.
    test("vendor records keep Creality's machine settings and the vendor's material ones") { t in
        let seed = BundledMaterialSeed()
        guard let data = try seed.vendorCatalogueData(for: .k2) else { return }
        let vendor = try MaterialDatabase.decode(data)
        let captured = try MaterialDatabase.decode(try seed.seedData(for: .k2))
        guard let genericPLA = captured.result.list.first(where: { $0.id == "00001" }) else {
            t.record("Generic PLA is missing from the capture", file: #file, line: #line); return
        }
        guard let bambuBasic = vendor.result.list.first(where: { $0.name == "Bambu PLA Basic" }) else {
            t.record("Bambu PLA Basic is missing", file: #file, line: #line); return
        }
        for machineKey in ["filament_start_gcode", "filament_end_gcode", "pressure_advance",
                           "filament_retraction_length", "filament_z_hop"] {
            t.equal(bambuBasic.kvParam[machineKey], genericPLA.kvParam[machineKey],
                    "\(machineKey) belongs to the printer")
        }
        // ...and the material half is Bambu's own, not Creality's.
        t.equal(bambuBasic.base.density, 1.26, "Bambu's published density")
        t.equal(bambuBasic.kvParam["filament_vendor"], "Bambu Lab", "vendor is derived, not copied")
        t.expect(bambuBasic.base.rank < 4530, "sorts below every captured record")
    },

    test("adding the vendor catalogue is additive and leaves the version alone") { t in
        let temp = TempStorage()
        let db = try makeBundleSeededDatabase(temp, ids: ["00001"], version: "1700000000")
        let added = try db.addVendorCatalogue()
        t.equal(added.count, 113, "all 113 land")
        t.equal(db.filaments.count, 114, "alongside the one already there")
        t.equal(db.version, "1700000000",
                "the version describes the captured edition and must not move")
        t.equal(db.pendingVendorAdditions(), [], "so the offer is gone")
        t.expect(db.contains(id: "B1002"), "Bambu PLA Basic is in")
    },

    test("a second add of the vendor catalogue changes nothing") { t in
        let temp = TempStorage()
        let db = try makeBundleSeededDatabase(temp, ids: ["00001"], version: "1700000000")
        _ = try db.addVendorCatalogue()
        guard var mine = t.unwrap(db.filament(id: "B1002"), "Bambu PLA Basic") else { return }
        mine.base.name = "Mine, hand-tuned"
        try db.update(mine)
        t.equal(try db.addVendorCatalogue(), [], "nothing to add")
        t.equal(db.filament(id: "B1002")?.name, "Mine, hand-tuned", "and the edit survives")
    },

    // MARK: - CRUD

    test("lookup by id, trimmed") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001", "01001", "E1001"])
        t.equal(db.filament(id: "01001")?.name, "Test PLA")
        t.equal(db.filament(id: "  01001 ")?.id, "01001", "lookup trims, as MatDb.cs does")
        t.equal(db.filament(id: "E1001")?.id, "E1001")
        t.equal(db.filament(id: "nope"), nil)
        t.equal(db.contains(id: "00001"), true)
    },

    // FIX (Windows defect a): MatDb.AddFilament appends unconditionally; uniqueness lives only in
    // the add dialog, so any other caller can duplicate an id.
    test("add rejects a duplicate id") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001", "01001"])
        t.throwsError(MaterialDatabaseError.duplicateID("01001")) {
            try db.add(sampleFilament(id: "01001", name: "Impostor"))
        }
        t.throwsError(MaterialDatabaseError.duplicateID("01001")) {
            try db.add(sampleFilament(id: " 01001 "))
        }
        t.equal(db.filaments.count, 2, "a rejected add must not mutate the catalogue")
        t.equal(db.filament(id: "01001")?.name, "Test PLA")

        try db.add(sampleFilament(id: "29001", name: "New PLA"))
        t.equal(db.filaments.map(\.id), ["00001", "01001", "29001"], "a new id appends")
        t.throwsError("adding an empty id") { try db.add(sampleFilament(id: "  ")) }
    },

    // FIX (Windows defect b): MatDb.EditFilament removes then appends, so the edited record moves
    // to the end of the file on every save.
    test("edit replaces in place and keeps file order") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001", "01001", "E1001"])
        guard var edited = t.unwrap(db.filament(id: "01001")) else { return }
        edited.name = "Hyper PLA (edited)"
        edited.vendor = "Creality"
        try db.update(edited)

        t.equal(db.filaments.map(\.id), ["00001", "01001", "E1001"], "order must not churn")
        t.equal(db.filaments[1].name, "Hyper PLA (edited)")
        t.equal(db.filaments[1].vendor, "Creality")
        t.equal(db.filaments.count, 3, "edit must not append a second copy")

        // The edit survives a save/load cycle in the same position.
        try db.save()
        let reopened = MaterialDatabase(printerType: .k2, storage: temp.storage, seed: StaticMaterialSeed([:]))
        try reopened.load()
        t.equal(reopened.filaments.map(\.id), ["00001", "01001", "E1001"])
        t.equal(reopened.filaments[1].name, "Hyper PLA (edited)")
    },

    // FIX (Windows defect c): edit and remove mutate the list while enumerating it — an
    // InvalidOperationException swallowed by an empty catch — and remove of an unknown id
    // null-references into the same catch, so failure looks exactly like success.
    test("edit and remove of an unknown id are reported, not swallowed") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001", "01001"])
        t.throwsError(MaterialDatabaseError.notFound("77777")) {
            try db.update(sampleFilament(id: "77777"))
        }
        t.throwsError(MaterialDatabaseError.notFound("77777")) {
            try db.remove(id: "77777")
        }
        t.equal(db.filaments.count, 2, "a failed operation must not mutate the catalogue")
    },

    test("remove takes exactly one record and leaves the rest intact") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001", "01001", "E1001", "P1001"])
        try db.remove(id: "01001")
        t.equal(db.filaments.map(\.id), ["00001", "E1001", "P1001"])
        try db.remove(id: " P1001 ")
        t.equal(db.filaments.map(\.id), ["00001", "E1001"], "remove trims its argument")
    },

    test("upsert adds a new id and replaces an existing one") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001"])
        try db.upsert(sampleFilament(id: "01001", name: "Fresh"))
        try db.upsert(sampleFilament(id: "00001", name: "Replaced"))
        t.equal(db.filaments.map(\.id), ["00001", "01001"])
        t.equal(db.filament(id: "00001")?.name, "Replaced")
    },

    // FIX (Windows defect d): MatDb.SaveFilaments early-returns on an empty list, so deleting the
    // last filament silently fails to persist and is undone by the next load.
    test("deleting the last filament persists") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001"])
        try db.remove(id: "00001")
        t.equal(db.filaments.count, 0)
        try db.save()

        let reopened = MaterialDatabase(printerType: .k2, storage: temp.storage, seed: StaticMaterialSeed([:]))
        try reopened.load()
        t.equal(reopened.filaments.count, 0, "the deletion must survive a reload")

        let onDisk = try MaterialDatabase.decode(try Data(contentsOf: temp.storage.url(for: .k2)))
        t.equal(onDisk.result.count, 0, "count must be rewritten to 0")
        t.equal(onDisk.result.list.count, 0)
    },

    test("save recomputes count and preserves reqId") { t in
        let temp = TempStorage()
        let seed = StaticMaterialSeed([.k2: try Fixture.data("material-extra-fields")])
        let db = MaterialDatabase(printerType: .k2, storage: temp.storage, seed: seed)
        try db.load()
        try db.add(sampleFilament(id: "00001"))
        try db.save()

        let onDisk = try MaterialDatabase.decode(try Data(contentsOf: temp.storage.url(for: .k2)))
        t.equal(onDisk.result.count, 2, "count is recomputed from the list")
        t.equal(onDisk.reqId, "cl602024082916552939795681", "Windows would have replaced this with 0")
        t.equal(onDisk.result.list[0].base.additionalFields["createTime"], .int(1746005657),
                "unmodelled fields survive a save")
    },

    // MARK: - Versioning

    test("version comparison is numeric, not lexicographic") { t in
        t.equal(MaterialVersion.isNewer("1758907369", than: "1746005657"), true)
        t.equal(MaterialVersion.isNewer("1746005657", than: "1758907369"), false)
        t.equal(MaterialVersion.isNewer("1758907369", than: "1758907369"), false, "strictly newer")
        // Lexicographically "999999999" > "1758907369"; numerically it is not.
        t.equal(MaterialVersion.isNewer("1758907369", than: "999999999"), true)
        t.equal(MaterialVersion.isNewer("42", than: MaterialVersion.unknown), true)
        // The prevent-update sentinel must beat any real epoch.
        t.equal(MaterialVersion.isNewer(MaterialVersion.preventUpdateSentinel, than: "1758907369"), true)
        t.equal(MaterialVersion.preventUpdateSentinel, "9876543210")
    },

    test("a non-numeric version is detectable rather than silently zero") { t in
        t.equal(MaterialVersion.number("1758907369"), 1_758_907_369)
        t.equal(MaterialVersion.number(" 1758907369 "), 1_758_907_369, "trims")
        t.equal(MaterialVersion.number("v2"), nil)
        t.equal(MaterialVersion.number(""), nil)
        // isNewer still has to answer, and treats nonsense as 0 — as the C# treats a missing file.
        t.equal(MaterialVersion.isNewer("v2", than: "1"), false)
        t.equal(MaterialVersion.isNewer("1", than: "v2"), true)
    },

    test("version is a string on the wire and epoch seconds in value") { t in
        let stamped = MaterialVersion.now(Date(timeIntervalSince1970: 1_758_907_369))
        t.equal(stamped, "1758907369")

        let file = MaterialDatabaseFile(list: [sampleFilament(id: "00001")], version: stamped)
        let text = String(decoding: try MaterialDatabase.encode(file), as: UTF8.self)
        t.expect(text.contains("\"version\" : \"1758907369\""), "version must stay quoted")
    },

    test("local CRUD preserves the version, and an update moves it deliberately") { t in
        let temp = TempStorage()
        let db = try makeDatabase(temp, ids: ["00001", "01001"], version: "1746005657")
        t.equal(db.version, "1746005657")

        try db.add(sampleFilament(id: "29001"))
        try db.remove(id: "00001")
        try db.save()
        var onDisk = try MaterialDatabase.decode(try Data(contentsOf: temp.storage.url(for: .k2)))
        t.equal(onDisk.result.version, "1746005657", "local edits must not bump the version")

        t.equal(db.isOutdated(comparedTo: "1758907369"), true)
        t.equal(db.isOutdated(comparedTo: "1700000000"), false)

        db.setVersion("1758907369")
        try db.save()
        onDisk = try MaterialDatabase.decode(try Data(contentsOf: temp.storage.url(for: .k2)))
        t.equal(onDisk.result.version, "1758907369")
        t.equal(db.isOutdated(comparedTo: "1758907369"), false)

        db.stampVersionNow(Date(timeIntervalSince1970: 1_800_000_000))
        t.equal(db.version, "1800000000")
    },

    // MARK: - Model conveniences

    test("filament identity fields are views onto base, not a cache") { t in
        var filament = sampleFilament(id: "00001", name: "Generic PLA", brand: "Generic")
        filament.name = "Renamed"
        filament.vendor = "eSUN"
        filament.materialType = "PETG"
        filament.id = "E1001"
        // The C# keeps four cached strings alongside the raw blob and lets them drift
        // (UpdateForm.cs:156). Here there is nothing to drift.
        t.equal(filament.base.name, "Renamed")
        t.equal(filament.base.brand, "eSUN")
        t.equal(filament.base.materialType, "PETG")
        t.equal(filament.base.id, "E1001")

        filament.syncDerivedKVParams()
        t.equal(filament.kvParam["filament_vendor"], "eSUN")
        t.equal(filament.kvParam["filament_type"], "PETG")
    },
])
