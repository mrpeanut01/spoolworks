import Foundation
@testable import SpoolworksUI
@testable import SpoolworksCore

// Naming a filament's colour the way its maker does: the colour difference, the maker's lists, the
// rule for when the nearest colour is the answer, and what the user's own answer does.

// MARK: - Fixtures

private func colour(_ brand: String, _ line: String, _ name: String, _ hex: String,
                    material: String = "", measured: Bool = false) -> BrandColour {
    BrandColour(brand: brand, line: line, material: material, name: name, hex: hex,
                source: measured ? .measured : .published)
}

/// A cut of the real lists, small enough to reason about.
private let fixture = BrandColourCatalogue(colours: [
    colour("Creality", "Hyper PLA", "Black", "282C2C", material: "PLA"),
    colour("Creality", "Hyper PLA", "Red", "C32D30", material: "PLA"),
    colour("Creality", "Hyper PLA", "Brown", "BC6C55", material: "PLA"),
    colour("Creality", "Hyper PLA", "Skin", "E1C09D", material: "PLA"),
    colour("Creality", "Hyper PLA", "Skin", "E6CDB1", measured: true),
    colour("Creality", "Hyper PLA", "Blue", "0081BF", material: "PLA"),
    colour("Creality", "Hyper PLA-CF", "Black", "101010", material: "PLA"),
    colour("Creality", "Hyper PETG", "Blue", "1A3A9A", material: "PETG"),
    colour("Creality", "HP ASA", "HP ASA", "0A0A0A", material: "ASA"),
    colour("Overture", "Matte PLA", "Beige", "E7EFD7", material: "PLA"),
    colour("Overture", "Matte PLA", "Light Green", "AFDEB9", material: "PLA"),
    colour("Polymaker", "PolyLite ABS", "Orange", "F68B1F", material: "ABS"),
    colour("eSUN 3D", "PLA+", "Fire Engine Red", "D6001C", material: "PLA"),
])

private func resolver(learned: LearnedColourNames = .init()) -> ColourNameResolver {
    ColourNameResolver(catalogue: fixture, learned: learned, generic: { "generic-\($0)" })
}

private final class Cell<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private func onMain(timeout: TimeInterval = 20, _ body: @escaping @MainActor () async -> Void) {
    let done = Cell(false)
    Task { @MainActor in
        await body()
        done.value = true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !done.value && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

// MARK: - Colour difference

let deltaE2000Tests = TestSuite(name: "Colour · CIEDE2000", cases: [

    test("agrees with the pairs published with the formula") { t in
        // Sharma, Wu & Dalal (2005), table 1: pairs 1, 7, 17 and 24.
        let pairs: [(LabColor, LabColor, Double)] = [
            (LabColor(l: 50, a: 2.6772, b: -79.7751), LabColor(l: 50, a: 0, b: -82.7485), 2.0425),
            (LabColor(l: 50, a: 0, b: 0), LabColor(l: 50, a: -1, b: 2), 2.3669),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 73, a: 25, b: -18), 27.1492),
            (LabColor(l: 50, a: 2.5, b: 0), LabColor(l: 50, a: 0, b: -2.5), 4.3065),
        ]
        for (first, second, expected) in pairs {
            t.expect(abs(first.deltaE2000(to: second) - expected) < 0.0001,
                     "expected \(expected), got \(first.deltaE2000(to: second))")
            t.expect(abs(second.deltaE2000(to: first) - expected) < 0.0001, "and symmetrically")
        }
        t.equal(LabColor(l: 40, a: 10, b: -5).deltaE2000(to: LabColor(l: 40, a: 10, b: -5)), 0)
    },
])

// MARK: - The maker's lists

let brandColourCatalogueTests = TestSuite(name: "Colour · maker's lists", cases: [

    test("a maker is found in the name when the brand is Generic") { t in
        t.equal(fixture.brand(for: "Generic", name: "Overture - Matte PLA"), "Overture")
        t.equal(fixture.brand(for: "creality"), "Creality")
        t.equal(fixture.brand(for: "eSUN", name: "PLA+"), "eSUN 3D", "the sources' two spellings are one maker")
        t.equal(fixture.brand(for: "Generic", name: "Generic PETG - Multicolor"), nil)
    },

    test("the spool's own line is searched first, and a near-namesake line is not it") { t in
        let found = fixture.matches(brand: "Creality", name: "Hyper PLA", material: "PLA", hex: "000000")
        t.equal(found.first?.colour.line, "Hyper PLA")
        t.equal(found.first?.scope, .line)
        t.expect(!found.contains { $0.scope == .line && $0.colour.line == "Hyper PLA-CF" },
                 "Hyper PLA-CF contains the words but is a different product")
        t.expect(found.contains { $0.scope == .brand && $0.colour.name == "Blue" && $0.colour.line == "Hyper PETG" } == false,
                 "a name the line already offers is not repeated from another line")
    },

    test("a line the printer names differently still meets the maker's") { t in
        let found = fixture.matches(brand: "Generic", name: "Polymaker ABS", material: "ABS", hex: "FF9300")
        t.equal(found.first?.colour.label, "Orange · PolyLite ABS")
        t.equal(found.first?.scope, .line)
    },

    test("one name is offered once, at its nearest reading") { t in
        let skins = fixture.matches(brand: "Creality", name: "Hyper PLA", hex: "E7CEB5")
            .filter { $0.colour.name == "Skin" }
        t.equal(skins.count, 1)
        t.equal(skins.first?.colour.source, .measured, "the measured swatch is the nearer of the two")
    },

    test("a product listed as its own colour is not offered as a colour name") { t in
        t.expect(!fixture.matches(brand: "Creality", name: "CR-TPU", hex: "000000")
            .contains { $0.colour.name == "HP ASA" })
    },

    test("an unknown maker gets lookalikes from anyone, marked as such") { t in
        let found = fixture.matches(brand: "Generic", name: "Mystery", hex: "D6001C")
        t.equal(found.first?.scope, .anywhere)
        t.equal(found.first?.colour.brand, "eSUN 3D")
    },

    test("the bundled lists load, and know Creality's own names") { t in
        let shared = BrandColourCatalogue.shared
        t.expect(shared.count > 10_000, "both sources should be present, got \(shared.count)")
        t.equal(shared.matches(brand: "Creality", name: "Hyper PLA", material: "PLA", hex: "E7CEB5")
            .first?.colour.name, "Skin")
    },
])

// MARK: - Deciding

let colourNameResolverTests = TestSuite(name: "Colour · naming", cases: [

    test("a clear match in the line is the maker's name") { t in
        let red = resolver().resolve(brand: "Creality", name: "Hyper PLA", material: "PLA", hex: "C12E1F")
        t.equal(red.name, "Red")
        t.equal(red.source, .brand)
        // A tag's nominal black is ΔE 11 from the measured one and still unmistakably it.
        t.equal(resolver().resolve(brand: "Creality", name: "Hyper PLA", material: "PLA", hex: "000000").name, "Black")
    },

    test("two candidates too close to call leave a description and the choices") { t in
        let pastel = resolver().resolve(brand: "Generic", name: "Overture - Matte PLA", hex: "D9F6D5")
        t.equal(pastel.source, .generic)
        t.equal(pastel.name, "generic-D9F6D5")
        t.equal(Set(pastel.suggestions.prefix(2).map(\.colour.name)), ["Beige", "Light Green"])
    },

    test("a line that lists nothing near the colour does not borrow a neighbour's name") { t in
        // The factory Blue tag: navy, where the line's Blue is cyan. Nothing in the line is near,
        // and the line is known, so it is the user's call — with the line's colours to pick from.
        let navy = resolver().resolve(brand: "Creality", name: "Hyper PLA", material: "PLA", hex: "0A2989")
        t.equal(navy.source, .generic)
        t.expect(navy.suggestions.contains { $0.colour.name == "Blue" }, "the line's own Blue is offered")
    },

    test("a maker's wider range names a line the lists do not have") { t in
        let tpu = resolver().resolve(brand: "Creality", name: "CR-TPU", material: "TPU", hex: "282C2C")
        t.equal(tpu.name, "Black")
        t.equal(tpu.source, .brand)
    },

    test("lookalikes from other makers never name a spool") { t in
        t.equal(resolver().resolve(brand: "Generic", name: "Mystery", hex: "D6001C").source, .generic)
    },

    test("what the user said wins, by filament and exact colour") { t in
        var learned = LearnedColourNames()
        let key = LearnedColourNames.key(filamentId: "01001", brand: "Creality", name: "Hyper PLA", hex: "#0A2989")
        t.equal(key, "01001|0A2989")
        learned.learn("Blue", forKey: key)
        let told = resolver(learned: learned).resolve(brand: "Creality", name: "Hyper PLA",
                                                      filamentId: "01001", hex: "0A2989")
        t.equal(told.name, "Blue")
        t.equal(told.source, .learned)
        t.equal(resolver(learned: learned).resolve(brand: "Creality", name: "Hyper PLA",
                                                   filamentId: "01001", hex: "0A2A89").source, .generic,
                "another hex is another colour")
        learned.learn("  ", forKey: key)
        t.equal(learned.name(forKey: key), nil, "an empty name forgets")
        t.equal(LearnedColourNames.key(filamentId: "", brand: "Generic", name: "Overture - Matte PLA", hex: "d9f6d5"),
                "generic|overturemattepla|D9F6D5")
    },

    test("the decisive rule needs a lead, not just a short distance") { t in
        func match(_ name: String, _ d: Double, _ scope: BrandColourCatalogue.Scope = .line) -> BrandColourCatalogue.Match {
            .init(colour: colour("B", "L", name, "000000"), deltaE: d, scope: scope)
        }
        t.expect(ColourNameResolver.isDecisive([match("a", 1.5), match("b", 1.8)]), "exact within the line")
        t.expect(!ColourNameResolver.isDecisive([match("a", 1.5, .brand), match("b", 1.8, .brand)]),
                 "but not across a whole range")
        t.expect(ColourNameResolver.isDecisive([match("a", 4.5), match("b", 9.4)]))
        t.expect(!ColourNameResolver.isDecisive([match("a", 7.0), match("b", 7.4)]))
        t.expect(!ColourNameResolver.isDecisive([match("a", 16), match("b", 60)]), "too far is too far")
        t.expect(ColourNameResolver.isDecisive([match("a", 11)]), "the only candidate, and near enough")
        t.expect(!ColourNameResolver.isDecisive([match("a", 0, .anywhere)]))
        t.expect(!ColourNameResolver.isDecisive([]))
    },
])

// MARK: - In the inventory

@MainActor
private func makeInventory() -> (InventoryViewModel, URL, UserDefaults, String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-colours-\(UUID().uuidString)", isDirectory: true)
    let suite = "sw-colours-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    return (InventoryViewModel(store: InventoryStore(directory: dir), toasts: ToastCenter(),
                               defaults: defaults, colours: fixture), dir, defaults, suite)
}

private func stock(_ hex: String, name: String, serial: String) -> Spool {
    Spool(identity: SpoolIdentity(vendorId: "0276", filamentId: "01001", colorHex: hex, serialNumber: serial),
          brand: "Creality", name: "Hyper PLA", materialType: "PLA", colorHex: hex, colorName: name)
}

let inventoryColourNameTests = TestSuite(name: "Colour · in the inventory", cases: [

    test("a spool built from a tag takes its maker's name") { t in
        onMain {
            let (model, dir, defaults, suite) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            var spool = Spool(brand: "Creality", name: "Hyper PLA", materialType: "PLA", colorHex: "C12E1F")
            model.applyColourName(to: &spool)
            t.equal(spool.colorName, "Red")
            t.equal(spool.colorNameSource, .brand)
            t.equal(spool.label, "Creality Hyper PLA · Red")
        }
    },

    test("existing spools are offered a rename, and nothing changes until it is taken") { t in
        onMain {
            let (model, dir, defaults, suite) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            let red = stock("C12E1F", name: "Cherry Pie", serial: "000001")
            let black = stock("000000", name: "Black", serial: "000002")
            let navy = stock("0A2989", name: "Naval Adventures", serial: "000003")
            [red, black, navy].forEach(model.add)

            t.equal(model.renameProposals.map(\.name), ["Red"],
                    "Black already is its maker's name, and navy is not the lists' to decide")
            t.equal(model.inventory.spool(id: red.id)?.colorName, "Cherry Pie")
            t.equal(model.colourNameSource(for: black), .brand)
            t.equal(model.colourNameSource(for: navy), .generic)

            model.applyRenames([red.id])
            t.equal(model.inventory.spool(id: red.id)?.colorName, "Red")
            t.expect(model.renameProposals.isEmpty)
        }
    },

    test("one answer names every spool of that filament and colour, and is remembered") { t in
        onMain {
            let (model, dir, defaults, suite) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            let first = stock("0A2989", name: "Naval Adventures", serial: "000001")
            let second = stock("0A2989", name: "Naval Adventures", serial: "000002")
            let other = stock("C12E1F", name: "Cherry Pie", serial: "000003")
            [first, second, other].forEach(model.add)

            model.setColourName("Blue", for: first)
            t.equal(model.inventory.spool(id: first.id)?.colorName, "Blue")
            t.equal(model.inventory.spool(id: second.id)?.colorName, "Blue")
            t.equal(model.inventory.spool(id: second.id)?.colorNameSource, .learned)
            t.equal(model.inventory.spool(id: other.id)?.colorName, "Cherry Pie")

            // A later spool of the same filament and colour, after a relaunch.
            let relaunched = InventoryViewModel(store: InventoryStore(directory: dir), toasts: ToastCenter(),
                                                defaults: defaults, colours: fixture)
            var third = stock("0A2989", name: "", serial: "000004")
            relaunched.applyColourName(to: &third)
            t.equal(third.colorName, "Blue")

            // Clearing the name forgets the answer.
            model.setColourName("", for: first)
            t.equal(model.inventory.spool(id: first.id)?.colorNameSource, .generic)
        }
    },

    test("an inventory saved before name sources existed still loads") { t in
        let old = #"{"spools":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","brand":"Creality","name":"Hyper PLA","materialType":"PLA","colorHex":"C12E1F","colorName":"Cherry Pie","netWeightGrams":1000,"remainingPercent":80,"location":{"unknown":{}},"remainingSource":"","tagSource":"untagged","intakeDate":"2026-01-01T00:00:00Z","usage":[],"isRetired":false}]}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let inventory = try decoder.decode(SpoolInventory.self, from: Data(old.utf8))
        t.equal(inventory.spools.first?.colorName, "Cherry Pie")
        t.equal(inventory.spools.first?.colorNameSource, nil)
    },
])
