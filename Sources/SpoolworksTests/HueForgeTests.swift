import Foundation
@testable import SpoolworksCore

// MARK: - Fixtures

/// Two entries copied from HueForge 0.9.4.3's shipped libraries, one with the optional keys a
/// dual-colour filament carries.
private let shippedLibraryJSON = """
{
    "Filaments": [
        {
            "Brand": "Creality Hyper",
            "Color": "#ffffff",
            "Name": "White",
            "Owned": false,
            "Transmissivity": 6.5,
            "Type": "PLA",
            "uuid": "{45625d51-718e-4c09-a937-f299d688cef6}"
        },
        {
            "Brand": "PolyLite",
            "Color": "#080a0d",
            "Name": "Black",
            "Owned": false,
            "Secondary_Color": "#101010",
            "Tags": ["Silk"],
            "Transmissivity": 0.3,
            "Type": "PLA",
            "uuid": "{4fdb74ec-692a-736b-12ae-878c5669237f}"
        }
    ]
}
"""

private func spool(brand: String = "Creality",
                   name: String = "Hyper PLA",
                   type: String = "PLA",
                   colour: String = "FFFFFF",
                   colourName: String = "White",
                   retired: Bool = false) -> Spool {
    Spool(brand: brand, name: name, materialType: type, colorHex: colour,
          colorName: colourName, isRetired: retired)
}

private func shippedLibrary() throws -> HueForgeLibrary {
    try HueForgeLibrary(json: Data(shippedLibraryJSON.utf8))
}

private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("spoolworks-hueforge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - The file formats

let hueForgeLibraryTests = TestSuite(name: "HueForge · library files", cases: [

    test("a shipped library decodes, and keys it does not model survive a round trip") { t in
        let library = try shippedLibrary()
        t.equal(library.filaments.count, 2)
        t.equal(library.filaments[0].brand, "Creality Hyper")
        t.equal(library.filaments[0].transmissivity, 6.5)
        t.equal(library.filaments[1].colorHex, "080A0D")

        let again = try HueForgeLibrary(json: try library.jsonData())
        t.equal(again, library)
        t.equal(again.filaments[1].additionalFields["Tags"], .array([.string("Silk")]))
        t.equal(again.filaments[1].additionalFields["Secondary_Color"], .string("#101010"))
    },

    test("JSON is written the way HueForge writes it") { t in
        let filament = HueForgeFilament(brand: "Creality Hyper", name: "Red", type: "PLA",
                                        colorHex: "0C12E1F", transmissivity: 3,
                                        uuid: "{00000000-0000-5000-8000-000000000000}")
        let text = String(decoding: try HueForgeLibrary(filaments: [filament]).jsonData(), as: UTF8.self)
        t.expect(text.contains("\"Filaments\""), "top-level key")
        t.expect(text.contains("\"Color\" : \"#c12e1f\""), "colour is #rrggbb, lower-case: \(text)")
        t.expect(text.contains("\"Transmissivity\" : 3,"), "a whole TD is not written as 3.0: \(text)")
        t.expect(text.contains("\"Owned\" : true"), "owned")
        t.expect(!text.contains("\r"), "LF only — a community manifest hashes LF content")
        t.expect(text.hasSuffix("}\n"), "ends with a newline")
    },

    test("the lower-case key of a filament set is accepted, and a broken entry costs only itself") { t in
        let json = #"{"filaments":[{"Brand":"A","Name":"B","Transmissivity":"1.5"},{"Brand":"no TD"}]}"#
        let library = try HueForgeLibrary(json: Data(json.utf8))
        t.equal(library.filaments.count, 1)
        t.equal(library.filaments[0].transmissivity, 1.5, "a quoted TD still reads")
        t.equal(library.filaments[0].type, "PLA")
    },

    test("something that is not a library says so") { t in
        t.throwsError(HueForgeError.unreadable("it has no \"Filaments\" list")) {
            _ = try HueForgeLibrary(json: Data(#"{"result":{}}"#.utf8))
        }
        t.throwsError(HueForgeError.unreadable("it is not a JSON object")) {
            _ = try HueForgeLibrary(json: Data("[]".utf8))
        }
    },

    test("CSV carries HueForge's headers and survives awkward names") { t in
        let filament = HueForgeFilament(brand: "Acme, Inc.", name: "5\" Blue", type: "PETG",
                                        colorHex: "1A5FB4", transmissivity: 12.5,
                                        uuid: "{3f2a9c1e-7b4d-4e8a-9c02-5d6e1f8a2b37}")
        let csv = HueForgeLibrary(filaments: [filament]).csvString()
        t.equal(csv.split(separator: "\n").first.map(String.init), "Brand,Type,Color,Name,TD,Owned,Uuid")
        t.expect(csv.contains("\"Acme, Inc.\",PETG,#1a5fb4,\"5\"\" Blue\",12.5,true,"), csv)
        t.equal(try HueForgeLibrary(csv: csv).filaments, [filament])
    },

    test("CSV reads columns in any order, ignores extras, and tolerates CRLF and a BOM") { t in
        let csv = "\u{FEFF}td,Notes,name,BRAND,Color,Type\r\n0.3,opaque,Black,PolyLite,#080a0d,PLA\r\n,,,,,\r\n"
        let library = try HueForgeLibrary(csv: csv)
        t.equal(library.filaments.count, 1)
        t.equal(library.filaments[0].brand, "PolyLite")
        t.equal(library.filaments[0].transmissivity, 0.3)
        t.equal(library.filaments[0].owned, false)
    },

    test("CSV without HueForge's columns names the ones missing") { t in
        t.throwsError(HueForgeError.csvMissingHeaders(["Type", "TD"])) {
            _ = try HueForgeLibrary(csv: "Brand,Name,Color\nA,B,#000000\n")
        }
    },
])

// MARK: - Inventory → library

let hueForgeExportTests = TestSuite(name: "HueForge · export", cases: [

    test("a stable id has HueForge's shape and depends only on the filament") { t in
        let id = HueForgeFilament.stableUUID(brand: "Creality Hyper", type: "PLA", colorHex: "C12E1F")
        t.expect(id.range(of: #"^\{[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\}$"#,
                          options: .regularExpression) != nil, id)
        t.equal(HueForgeFilament.stableUUID(brand: " creality hyper", type: "pla", colorHex: "#0c12e1f"), id,
                "case, spacing and the tag's leading nibble do not change it")
        t.expect(HueForgeFilament.stableUUID(brand: "Creality Hyper", type: "PLA", colorHex: "FFFFFF") != id,
                 "another colour is another filament")
        t.expect(HueForgeFilament.stableUUID(brand: "Creality Hyper", type: "PETG", colorHex: "C12E1F") != id,
                 "another polymer is another filament")
    },

    test("the brand is the product line, with the polymer taken back off") { t in
        t.equal(HueForgeExporter.brandLine(brand: "Creality", name: "Hyper PLA", type: "PLA"), "Creality Hyper")
        t.equal(HueForgeExporter.brandLine(brand: "Generic", name: "PLA", type: "PLA"), "Generic")
        t.equal(HueForgeExporter.brandLine(brand: "Creality", name: "CR-PLA", type: "PLA"), "Creality CR-PLA")
        t.equal(HueForgeExporter.brandLine(brand: "Polymaker", name: "Polymaker PolyLite PLA", type: "PLA"),
                "Polymaker PolyLite")
        t.equal(HueForgeExporter.brandLine(brand: "", name: "", type: "PLA"), "Unbranded")
    },

    test("spools of one filament are one entry, and a retired spool is not owned") { t in
        let inventory = SpoolInventory(spools: [
            spool(), spool(),
            spool(colour: "C12E1F", colourName: "Red"),
            spool(colour: "000000", colourName: "Black", retired: true),
        ])
        let entries = HueForgeExporter.entries(for: inventory)
        t.equal(entries.map(\.filament.name), ["Red", "White"])
        t.equal(entries.first { $0.filament.name == "White" }?.spoolIDs.count, 2)
        t.expect(entries.allSatisfy { $0.filament.owned && $0.filament.brand == "Creality Hyper" })
        t.equal(entries[0].filament.uuid,
                HueForgeFilament.stableUUID(brand: "Creality Hyper", type: "PLA", colorHex: "C12E1F"))
    },

    test("a spool with no colour name or polymer still makes a usable entry") { t in
        let entries = HueForgeExporter.entries(for: SpoolInventory(spools: [
            spool(type: "", colour: "1A5FB4", colourName: ""),
        ]))
        t.equal(entries.first?.filament.name, "#1A5FB4")
        t.equal(entries.first?.filament.type, "PLA")
    },

    test("an excluded filament stays in the list and out of the file") { t in
        let inventory = SpoolInventory(spools: [spool(), spool(colour: "C12E1F", colourName: "Red")])
        let red = HueForgeFilament.stableUUID(brand: "Creality Hyper", type: "PLA", colorHex: "C12E1F")
        let entries = HueForgeExporter.entries(for: inventory,
                                               preferences: .init(excluded: [red]))
        t.equal(entries.count, 2)
        t.equal(HueForgeExporter.library(from: entries).filaments.map(\.name), ["White"])
    },
])

// MARK: - Transmission distance

let hueForgeTransmissivityTests = TestSuite(name: "HueForge · transmission distance", cases: [

    test("the same filament in HueForge's library supplies the TD") { t in
        let reference = HueForgeTDReference(libraries: [try shippedLibrary()])
        let entries = HueForgeExporter.entries(for: SpoolInventory(spools: [spool()]),
                                               reference: reference)
        t.equal(entries.first?.filament.transmissivity, 6.5)
        t.equal(entries.first?.tdSource, .library("Creality Hyper White"))
    },

    test("a scanned colour a shade off the library's is still that filament") { t in
        let reference = HueForgeTDReference(libraries: [try shippedLibrary()])
        let found = reference.transmissivity(brand: "creality hyper", name: "Ivory", type: "PLA+",
                                             colorHex: "FAFAF7")
        t.equal(found.value, 6.5)
        t.equal(found.source, .library("Creality Hyper White"))
    },

    test("an unknown filament is estimated from the nearest colours, and says so") { t in
        let reference = HueForgeTDReference(libraries: [try shippedLibrary()])
        let dark = reference.transmissivity(brand: "Acme", name: "Charcoal", type: "PLA", colorHex: "101010")
        t.equal(dark.source, .estimated)
        let none = HueForgeTDReference().transmissivity(brand: "Acme", name: "Snow", type: "PLA",
                                                        colorHex: "FFFFFF")
        t.equal(none.source, .estimated)
        t.equal(none.value, 6.0, "with no reference, white lands on the curve's white")
        t.equal(HueForgeTDReference.fallback(lightness: 0), 0.4)
    },

    test("a TD the user set beats the library's") { t in
        let reference = HueForgeTDReference(libraries: [try shippedLibrary()])
        let id = HueForgeFilament.stableUUID(brand: "Creality Hyper", type: "PLA", colorHex: "FFFFFF")
        let entries = HueForgeExporter.entries(for: SpoolInventory(spools: [spool()]),
                                               preferences: .init(transmissivity: [id: 7.2]),
                                               reference: reference)
        t.equal(entries.first?.filament.transmissivity, 7.2)
        t.equal(entries.first?.tdSource, .user)
    },

    test("TDs come back from a HueForge file by id, then by name") { t in
        let entries = HueForgeExporter.entries(for: SpoolInventory(spools: [
            spool(), spool(colour: "C12E1F", colourName: "Red"),
        ]))
        let white = entries.first { $0.filament.name == "White" }!.filament
        let red = entries.first { $0.filament.name == "Red" }!.filament
        var measured = white
        measured.transmissivity = 5.8
        measured.name = "Renamed in HueForge"
        let file = HueForgeLibrary(filaments: [
            measured,
            HueForgeFilament(brand: "creality HYPER", name: "red", type: "PLA", colorHex: "AA0000",
                             transmissivity: 2.9, uuid: "{someone-elses}"),
            HueForgeFilament(brand: "Other", name: "Green", type: "PLA", colorHex: "00FF00",
                             transmissivity: 4, uuid: ""),
        ])
        t.equal(HueForgeExporter.transmissivities(in: file, for: entries),
                [white.uuid: 5.8, red.uuid: 2.9])
    },

    test("preferences persist, and a missing file is an empty start") { t in
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = HueForgePreferencesStore(directory: folder)
        t.equal(try store.load(), HueForgePreferences())
        let saved = HueForgePreferences(transmissivity: ["{a}": 1.2], excluded: ["{b}"])
        try store.save(saved)
        t.equal(try store.load(), saved)
    },
])

// MARK: - HueForge on disk

let hueForgeInstallTests = TestSuite(name: "HueForge · sync and community source", cases: [

    test("sync writes one file into Vendor Libraries and leaves the personal library alone") { t in
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let filaments = root.appendingPathComponent("Filaments")
        try FileManager.default.createDirectory(at: filaments, withIntermediateDirectories: true)
        let personal = filaments.appendingPathComponent("personal_library.json")
        try Data(shippedLibraryJSON.utf8).write(to: personal)

        let library = HueForgeExporter.library(
            from: HueForgeExporter.entries(for: SpoolInventory(spools: [spool()])))
        let written = try HueForgeInstall.sync(library, toHueForgeFolder: root)
        t.equal(written.path, filaments.appendingPathComponent("Vendor Libraries/Spoolworks.json").path)
        t.equal(try HueForgeLibrary(contentsOf: written), library)
        t.equal(try Data(contentsOf: personal), Data(shippedLibraryJSON.utf8))

        // Pointing at the Filaments folder itself lands in the same place.
        t.equal(try HueForgeInstall.sync(library, toHueForgeFolder: filaments).path, written.path)
    },

    test("the reference reads HueForge's libraries but never Spoolworks' own sync file") { t in
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let vendor = root.appendingPathComponent("Filaments/Vendor Libraries")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        try Data(shippedLibraryJSON.utf8).write(to: vendor.appendingPathComponent("Creality.json"))
        try Data(shippedLibraryJSON.utf8).write(to: vendor.appendingPathComponent("Spoolworks.json"))
        try Data("not json".utf8).write(to: vendor.appendingPathComponent("Broken.json"))
        t.equal(HueForgeInstall.reference(candidates: [root]).count, 2)
        t.expect(HueForgeInstall.reference(candidates: [root.appendingPathComponent("missing")]).isEmpty)
    },

    test("sync refuses a folder that is not HueForge's, and anything inside an application") { t in
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        t.throwsError(HueForgeError.notAHueForgeFolder(root.path)) {
            try HueForgeInstall.sync(HueForgeLibrary(), toHueForgeFolder: root)
        }
        let bundle = root.appendingPathComponent("HueForge.app/Contents")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Filaments"),
                                                withIntermediateDirectories: true)
        t.throwsError(HueForgeError.insideApplicationBundle(bundle.path)) {
            try HueForgeInstall.sync(HueForgeLibrary(), toHueForgeFolder: bundle)
        }
        t.expect(!FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent("Filaments/Vendor Libraries").path))
    },

    test("a community source has the template's layout and a hash of the file it points at") { t in
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let library = try shippedLibrary()
        let manifestURL = try HueForgeCommunitySource.write(
            library, to: root, sourceName: "Shed inventory",
            baseURL: "https://raw.githubusercontent.com/me/filaments/main/libraries/")

        let manifest = try JSONDecoder().decode(HueForgeCommunitySource.Manifest.self,
                                                from: Data(contentsOf: manifestURL))
        t.equal(manifest.source_name, "Shed inventory")
        guard let entry = t.unwrap(manifest.libraries.first, "manifest entry") else { return }
        t.equal(entry.name, "Spoolworks")
        t.equal(entry.filename, "Spoolworks.json")
        t.equal(entry.category, "community")
        t.equal(entry.url, "https://raw.githubusercontent.com/me/filaments/main/libraries/Spoolworks.json")
        t.equal(entry.filament_count, 2)

        // Checked against the system's own SHA-256 rather than the code under test.
        let file = root.appendingPathComponent("libraries/Spoolworks.json")
        let shasum = Process()
        shasum.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        shasum.arguments = ["-a", "256", file.path]
        let pipe = Pipe()
        shasum.standardOutput = pipe
        try shasum.run()
        shasum.waitUntilExit()
        let expected = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: " ").first.map(String.init)
        t.equal(entry.sha256, expected ?? "")
    },
])
