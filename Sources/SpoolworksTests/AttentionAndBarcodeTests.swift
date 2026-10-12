import Foundation
@testable import SpoolworksUI
@testable import SpoolworksCore

// What a spool still needs before it prints and designs correctly — the Inventory's warning
// triangles — and the two quicker ways of saying what a spool's colour is: the maker's own list,
// and the barcode on the box.

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

// MARK: - Barcodes

let boxBarcodeTests = TestSuite(name: "Box barcode", cases: [

    test("an EAN-13 and the UPC-A it contains are one code") { t in
        t.equal(BoxBarcode.normalise("6938936701934"), "06938936701934")
        // A UPC-A is an EAN-13 with its leading zero left off; Vision reports the thirteen digits.
        t.equal(BoxBarcode.normalise("697790574189"), BoxBarcode.normalise("0697790574189"))
        t.equal(BoxBarcode.display("00697790574189"), "697790574189")
        t.equal(BoxBarcode.display("06938936701934"), "6938936701934")
    },

    test("a misread digit is refused rather than looked up") { t in
        t.expect(BoxBarcode.normalise("6938936701935") == nil, "wrong check digit")
        t.expect(BoxBarcode.normalise("12345") == nil, "not a GTIN length")
        t.expect(BoxBarcode.normalise("LOT 2026-10") == nil)
        t.equal(BoxBarcode.normalise(" 6938936701934\n"), "06938936701934", "whitespace is not part of it")
    },

    test("the bundled table names a box's maker, line and colour") { t in
        let table = FilamentBarcodeCatalogue.shared
        t.expect(table.count > 5000, "the bundled table loaded (\(table.count))")
        guard let found = t.unwrap(table.filaments(for: "7340002118178").first) else { return }
        t.equal(found.brand, "3D Prima Basic")
        t.equal(found.line, "Recycle PLA")
        t.equal(found.colourName, "Black")
        t.equal(found.hex, "000000")
        t.equal(found.netWeightGrams, 1000)
        t.equal(found.product, "3D Prima Basic Recycle PLA")
        t.expect(table.filaments(for: "4006381333931").isEmpty, "a valid code for something else")
    },

    test("a box the user described is remembered, and wins") { t in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-barcode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LearnedBarcodesStore(directory: dir)
        t.expect(store.load().filaments.isEmpty, "no file is an empty answer, not an error")

        var learned = LearnedBarcodes()
        learned.learn(BarcodeFilament(brand: "Creality", line: "Hyper PLA", material: "PLA",
                                      colourName: "Red", hex: "#c12e1f", catalogueID: "01001"),
                      for: "6971636403135")
        learned.learn(BarcodeFilament(brand: "X", line: "Y", material: "", colourName: "", hex: "000000"),
                      for: "not a barcode")
        t.equal(learned.filaments.count, 1, "rubbish is not stored")
        try store.save(learned)

        let back = store.load().filament(for: "06971636403135")
        t.equal(back?.colourName, "Red")
        t.equal(back?.hex, "C12E1F")
        t.equal(back?.catalogueID, "01001")
        t.equal(back?.source, .learned)
    },
])

// MARK: - The maker's whole list

private func colour(_ brand: String, _ line: String, _ name: String, _ hex: String,
                    material: String = "", measured: Bool = false) -> BrandColour {
    BrandColour(brand: brand, line: line, material: material, name: name, hex: hex,
                source: measured ? .measured : .published)
}

private let lists = BrandColourCatalogue(colours: [
    colour("Creality", "Hyper PLA", "Red", "C32D30", material: "PLA"),
    colour("Creality", "Hyper PLA", "Skin", "E1C09D", material: "PLA"),
    colour("Creality", "Hyper PLA", "Skin", "E6CDB1", measured: true),
    colour("Creality", "Hyper PLA", "Black", "282C2C", material: "PLA"),
    colour("Creality", "Hyper PLA-CF", "Black", "101010", material: "PLA"),
    colour("Creality", "Hyper PETG", "Blue", "1A3A9A", material: "PETG"),
    colour("Overture", "Matte PLA", "Beige", "E7EFD7", material: "PLA"),
])

let makerColourListTests = TestSuite(name: "Maker's colour list", cases: [

    test("a known line lists its own colours, one per name, by name") { t in
        let found = lists.colours(brand: "Creality", name: "Hyper PLA", material: "PLA")
        t.equal(found.scope, .line)
        t.equal(found.colours.map(\.name), ["Black", "Red", "Skin"])
        t.expect(!found.colours.contains { $0.hex == "101010" }, "Hyper PLA-CF is another product")
    },

    test("where both sources list a colour, the measured one is the colour") { t in
        let skin = lists.colours(brand: "Creality", name: "Hyper PLA", material: "PLA")
            .colours.first { $0.name == "Skin" }
        t.equal(skin?.hex, "E6CDB1")
        t.equal(skin?.source, .measured)
    },

    test("an unlisted line offers the maker's whole range, saying which line each is") { t in
        let found = lists.colours(brand: "Creality", name: "CR-Silk", material: "PLA")
        t.equal(found.scope, .brand)
        t.equal(found.colours.filter { $0.name == "Black" }.count, 2, "one Black per line")
        t.expect(found.colours.contains { $0.line == "Hyper PETG" })
    },

    test("the maker is found in the name when the brand is Generic, and nobody's list otherwise") { t in
        t.equal(lists.colours(brand: "Generic", name: "Overture - Matte PLA", material: "PLA")
            .colours.map(\.name), ["Beige"])
        let unknown = lists.colours(brand: "Nobody", name: "PLA")
        t.expect(unknown.colours.isEmpty)
        t.equal(unknown.scope, .anywhere)
    },

    test("the bundled lists have Creality Hyper PLA's colours") { t in
        let found = BrandColourCatalogue.shared.colours(brand: "Creality", name: "Hyper PLA", material: "PLA")
        t.equal(found.scope, .line)
        t.expect(found.colours.count >= 8, "\(found.colours.count) colours")
        t.expect(found.colours.contains { $0.name == "Red" })
    },
])

// MARK: - HueForge: what has been sent

private func entry(_ name: String, td: Double = 1.5, included: Bool = true) -> HueForgeExportEntry {
    let uuid = HueForgeFilament.stableUUID(brand: "Creality Hyper", type: "PLA", colorHex: "C12E1F")
    return HueForgeExportEntry(
        filament: HueForgeFilament(brand: "Creality Hyper", name: name, type: "PLA",
                                   colorHex: "C12E1F", transmissivity: td, uuid: uuid),
        tdSource: .estimated, spoolIDs: [UUID()], isIncluded: included)
}

let hueForgeSyncStateTests = TestSuite(name: "HueForge · what has been sent", cases: [

    test("never sent, sent, and sent before it changed are three states") { t in
        let red = entry("Red")
        t.equal(HueForgeExporter.syncState(of: red, sent: nil), .notSent)
        t.equal(HueForgeExporter.syncState(of: red, sent: [:]), .notSent)

        let sent = HueForgeExporter.sentRecord(for: HueForgeExporter.library(from: [red]))
        t.equal(HueForgeExporter.syncState(of: red, sent: sent), .current)
        // Renamed to its maker's name, or its TD measured: same filament, older copy in HueForge.
        t.equal(HueForgeExporter.syncState(of: entry("Cherry Pie"), sent: sent), .outdated)
        t.equal(HueForgeExporter.syncState(of: entry("Red", td: 2.4), sent: sent), .outdated)
    },

    test("a filament left out on purpose is not reported as missing") { t in
        t.equal(HueForgeExporter.syncState(of: entry("Red", included: false), sent: nil), .excluded)
        let sent = HueForgeExporter.sentRecord(for: HueForgeExporter.library(from: [entry("Red", included: false)]))
        t.expect(sent.isEmpty, "and it is not in the record of what was sent")
    },

    test("a preferences file written before the record was kept still loads") { t in
        let old = Data(#"{"excluded":[],"transmissivity":{"{a}":1.2}}"#.utf8)
        let loaded = try JSONDecoder().decode(HueForgePreferences.self, from: old)
        t.equal(loaded.transmissivity["{a}"], 1.2)
        t.expect(loaded.sent == nil)
    },
])

// MARK: - The warnings

private final class FakeList: PrinterFilamentListReading, @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String>?
    private var _asked = 0

    /// `nil` is a printer that does not answer.
    init(ids: Set<String>?) { self.ids = ids }
    var asked: Int { lock.withLock { _asked } }
    func set(_ ids: Set<String>?) { lock.withLock { self.ids = ids } }

    func filamentIDs(host: String) async throws -> Set<String> {
        try lock.withLock {
            _asked += 1
            guard let ids else { throw CrealitySocketError.timedOut(seconds: 1) }
            return ids
        }
    }
}

private struct Attention {
    let inventory: InventoryViewModel
    let hueForge: HueForgeViewModel
    let model: SpoolAttentionModel
    let list: FakeList
    let cleanUp: () -> Void
}

/// `printers` empty is an install with no printer configured. Factory ids are the Creality `0…`
/// range, as in the bundled catalogue.
@MainActor
private func makeAttention(onPrinter: Set<String>? = ["01001"],
                           printers: [SpoolAttentionModel.Printer] = [.init(family: .k2, host: "192.168.10.19",
                                                                            name: "K2 Plus")],
                           hueForgeInstalled: Bool = false) -> Attention {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-attention-\(UUID().uuidString)", isDirectory: true)
    let suite = "sw-attention-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let toasts = ToastCenter()
    let inventory = InventoryViewModel(store: InventoryStore(directory: dir), toasts: toasts,
                                       defaults: defaults, colours: lists)
    let hueForge = HueForgeViewModel(inventory: inventory,
                                     store: HueForgePreferencesStore(directory: dir),
                                     toasts: toasts, defaults: defaults,
                                     isInstalled: hueForgeInstalled)
    let list = FakeList(ids: onPrinter)
    let model = SpoolAttentionModel(
        inventory: inventory, hueForge: hueForge, filamentList: list,
        printers: { printers },
        isFactoryFilament: { id, _ in id.hasPrefix("0") },
        filamentID: { spool in
            let id = spool.identity?.filamentId ?? ""
            return id.count == 6 ? String(id.dropFirst()) : id
        },
        filamentLabel: { $0 == "P1003" ? "Polymaker Panchroma PLA Matte" : nil })
    return Attention(inventory: inventory, hueForge: hueForge, model: model, list: list, cleanUp: {
        try? FileManager.default.removeItem(at: dir)
        defaults.removePersistentDomain(forName: suite)
    })
}

/// A spool whose colour carries its maker's name, so only the question under test is open.
private func tagged(_ filamentId: String, brand: String = "Creality", name: String = "Hyper PLA",
                    source: ColourNameSource = .brand) -> Spool {
    Spool(identity: SpoolIdentity(vendorId: "0276", filamentId: filamentId, colorHex: "C32D30",
                                  serialNumber: "123456"),
          brand: brand, name: name, materialType: "PLA", colorHex: "C32D30", colorName: "Red",
          colorNameSource: source, tagSource: .spoolworksWritten)
}

let spoolAttentionTests = TestSuite(name: "Spool attention", cases: [

    test("a filament the printer does not list is marked, naming the printer and the filament") { t in
        onMain {
            let a = makeAttention(onPrinter: ["01001"])
            defer { a.cleanUp() }
            let vendor = tagged("1P1003", brand: "Polymaker", name: "Panchroma PLA Matte")
            let factory = tagged("101001")
            a.inventory.add(vendor)
            a.inventory.add(factory)
            t.expect(a.model.issues(for: vendor).isEmpty, "nothing is claimed before the printer is asked")

            a.model.refreshListings()
            await a.model.settle()
            t.equal(a.model.issues(for: vendor),
                    [.notOnPrinter(printer: "K2 Plus", filament: "Polymaker Panchroma PLA Matte",
                                   filamentID: "P1003")])
            t.equal(a.model.issues(for: vendor).first?.title,
                    "K2 Plus does not list Polymaker Panchroma PLA Matte yet")
            t.expect(a.model.issues(for: factory).isEmpty)
            t.equal(a.model.family(missing: vendor), .k2)
        }
    },

    test("a factory filament is never marked, even when the printer's reply leaves it out") { t in
        onMain {
            let a = makeAttention(onPrinter: [])
            defer { a.cleanUp() }
            let factory = tagged("101001")
            a.inventory.add(factory)
            a.model.refreshListings()
            await a.model.settle()
            t.expect(a.model.issues(for: factory).isEmpty)
        }
    },

    test("a printer that does not answer, or no printer at all, raises nothing") { t in
        onMain {
            let silent = makeAttention(onPrinter: nil)
            defer { silent.cleanUp() }
            let vendor = tagged("1P1003")
            silent.inventory.add(vendor)
            silent.model.refreshListings()
            await silent.model.settle()
            t.expect(silent.model.issues(for: vendor).isEmpty, "could not ask is not does not list")

            let none = makeAttention(printers: [])
            defer { none.cleanUp() }
            none.inventory.add(vendor)
            none.model.refreshListings()
            await none.model.settle()
            t.expect(none.model.issues(for: vendor).isEmpty)
            t.equal(none.list.asked, 0)
        }
    },

    test("adding the filament to the printer clears its mark without asking again") { t in
        onMain {
            let a = makeAttention(onPrinter: [])
            defer { a.cleanUp() }
            let vendor = tagged("1P1003")
            a.inventory.add(vendor)
            a.model.refreshListings()
            await a.model.settle()
            t.equal(a.model.issues(for: vendor).map(\.id), ["printer"])

            a.model.noteAdded(filamentID: "P1003", family: .k2)
            t.expect(a.model.issues(for: vendor).isEmpty)
            t.equal(a.list.asked, 1)
        }
    },

    test("the printer's list is trusted for a while, and re-read when forced") { t in
        onMain {
            let a = makeAttention(onPrinter: [])
            defer { a.cleanUp() }
            a.model.refreshListings()
            await a.model.settle()
            a.model.refreshListings()
            await a.model.settle()
            t.equal(a.list.asked, 1, "opening the Inventory again does not ask the printer again")
            a.model.refreshListings(force: true)
            await a.model.settle()
            t.equal(a.list.asked, 2)
        }
    },

    test("a colour named only by description is marked until it has a maker's name") { t in
        onMain {
            let a = makeAttention()
            defer { a.cleanUp() }
            // FA00FA is nowhere near any Hyper PLA colour, so the lists cannot name it.
            var spool = Spool(brand: "Creality", name: "Hyper PLA", materialType: "PLA", colorHex: "FA00FA")
            a.inventory.applyColourName(to: &spool)
            a.inventory.add(spool)
            t.equal(a.model.issues(for: spool), [.colourUnmatched(maker: "Creality")])
            t.equal(a.model.issues(for: spool).first?.title,
                    "Colour is not matched to Creality's own colours")

            a.inventory.setColourName("Magenta", for: spool)
            t.expect(a.model.issues(for: spool).isEmpty, "the user's answer settles it")
        }
    },

    test("the faults are counted, and the missing filaments listed once each, for fixing in bulk") { t in
        onMain {
            let a = makeAttention(onPrinter: [])
            defer { a.cleanUp() }
            a.inventory.add(tagged("1P1003"))
            a.inventory.add(tagged("1P1003"))
            a.inventory.add(tagged("1A1002", brand: "Anycubic", name: "Anycubic PLA", source: .generic))
            a.inventory.add(tagged("101001"))
            t.expect(a.model.missingFilaments == nil, "nothing to add before the printer is asked")
            a.model.refreshListings()
            await a.model.settle()

            t.equal(a.model.count("printer"), 3)
            t.equal(a.model.count("colour"), 1)
            t.equal(a.model.count("hueforge"), 0)
            t.equal(a.model.missingFilaments?.ids, ["A1002", "P1003"])
            t.equal(a.model.missingFilaments?.printerName, "K2 Plus")
        }
    },

    test("unmatched colours are one question per filament and colour, answered together") { t in
        onMain {
            let a = makeAttention()
            defer { a.cleanUp() }
            @MainActor func add(_ hex: String) -> Spool {
                var spool = Spool(brand: "Creality", name: "Hyper PLA", materialType: "PLA", colorHex: hex)
                a.inventory.applyColourName(to: &spool)
                a.inventory.add(spool)
                return spool
            }
            let first = add("FA00FA"), second = add("FA00FA"), other = add("00FA00")
            let groups = a.inventory.unmatchedColours()
            t.equal(groups.map(\.spoolCount).sorted(), [1, 2])
            guard let pair = groups.first(where: { $0.spoolCount == 2 }) else { return }
            t.expect(pair.options.contains { $0.name == "Red" }, "the maker's colours are offered")

            // Only the pair is answered; the other row is left alone.
            a.inventory.applyColourNames([pair.id: " Magenta "], to: groups)
            let stock = a.inventory.inventory
            t.equal(stock.spool(id: first.id)?.colorName, "Magenta")
            t.equal(stock.spool(id: second.id)?.colorName, "Magenta")
            t.equal(stock.spool(id: first.id)?.colorNameSource, .learned)
            t.equal(stock.spool(id: other.id)?.colorNameSource, .generic)
            t.equal(a.model.count("colour"), 1, "and the marks follow")
            t.equal(a.inventory.unmatchedColours().count, 1)
        }
    },

    test("HueForge is only mentioned on a Mac that uses it") { t in
        onMain {
            let without = makeAttention(hueForgeInstalled: false)
            defer { without.cleanUp() }
            let spool = tagged("101001")
            without.inventory.add(spool)
            t.expect(without.model.issues(for: spool).isEmpty)

            let with = makeAttention(hueForgeInstalled: true)
            defer { with.cleanUp() }
            with.inventory.add(spool)
            t.equal(with.model.issues(for: spool), [.notInHueForge(outdated: false)])
            t.equal(with.model.issues(for: spool).first?.title, "Not synced with HueForge")
        }
    },

    test("sending the library clears the mark; changing the filament afterwards brings it back") { t in
        onMain {
            let a = makeAttention(hueForgeInstalled: true)
            defer { a.cleanUp() }
            let spool = tagged("101001")
            a.inventory.add(spool)
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("sw-attention-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: out) }

            a.hueForge.export(to: out)
            t.expect(a.model.issues(for: spool).isEmpty, "exported, so HueForge can have it")

            guard let id = a.hueForge.entries.first?.id else { return t.expect(false, "no entry") }
            a.hueForge.setTransmissivity("3.3", for: id)
            t.equal(a.model.issues(for: spool), [.notInHueForge(outdated: true)])

            a.hueForge.setIncluded(false, for: id)
            t.expect(a.model.issues(for: spool).isEmpty, "left out on purpose is not a fault")
        }
    },
])

// MARK: - Intake: the colour menu and the box

@MainActor
private func makeIntake() async -> (IntakeViewModel, InventoryViewModel, () -> Void) {
    let catalogue = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-cat-\(UUID().uuidString)", isDirectory: true)
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-intake-\(UUID().uuidString)", isDirectory: true)
    let materials = MaterialsViewModel(storage: MaterialStorage(directory: catalogue))
    await materials.load()
    let inventory = InventoryViewModel(store: InventoryStore(directory: dir), toasts: ToastCenter())
    let model = IntakeViewModel(monitor: ReaderMonitor(), inventory: inventory,
                                materials: materials, toasts: ToastCenter())
    return (model, inventory, {
        try? FileManager.default.removeItem(at: catalogue)
        try? FileManager.default.removeItem(at: dir)
    })
}

let intakeMakerColourTests = TestSuite(name: "Intake · maker's colours and box barcode", cases: [

    test("choosing a brand and material offers that maker's colours") { t in
        onMain {
            let (model, _, cleanUp) = await makeIntake()
            defer { cleanUp() }
            model.method = .manual
            model.catalogueBrand = "Creality"
            model.materialID = "01001"
            t.equal(model.name, "Hyper PLA")
            let listed = model.makerColours
            t.equal(listed.scope, .line)
            t.expect(listed.colours.contains { $0.name == "Red" }, "Hyper PLA comes in Red")
            t.expect(model.chosenMakerColour == nil, "nothing is chosen until the user chooses")
        }
    },

    test("the chosen colour sets the code, and its name goes on the spool") { t in
        onMain {
            let (model, inventory, cleanUp) = await makeIntake()
            defer { cleanUp() }
            model.method = .manual
            model.catalogueBrand = "Creality"
            model.materialID = "01001"
            guard let red = model.makerColours.colours.first(where: { $0.name == "Red" }) else {
                return t.expect(false, "no Red in the list")
            }
            model.chooseMakerColour(red)
            t.equal(model.colorHex, red.hex)
            t.equal(model.chosenMakerColour?.id, red.id)

            model.setTagsRequired(0)
            model.confirm()
            let spool = inventory.inventory.active.first
            t.equal(spool?.colorName, "Red")
            t.equal(spool?.colorHex, red.hex)
            t.expect(spool?.colorNameSource != .generic, "a maker's colour is not a description")
        }
    },

    test("a colour typed over, or a change of material, is no longer the maker's colour") { t in
        onMain {
            let (model, _, cleanUp) = await makeIntake()
            defer { cleanUp() }
            model.method = .manual
            model.catalogueBrand = "Creality"
            model.materialID = "01001"
            guard let red = model.makerColours.colours.first(where: { $0.name == "Red" }) else { return }
            model.chooseMakerColour(red)
            model.colorHex = "123456"
            t.expect(model.chosenMakerColour == nil)

            model.chooseMakerColour(red)
            model.materialID = "00001"
            t.expect(model.pickedColour == nil, "Hyper PLA's Red is not Generic PLA's")
            t.equal(model.colorHex, red.hex, "the colour itself is a fact about the spool and stays")
        }
    },

    test("a listed box fills in the maker's entry, the colour and the size") { t in
        onMain {
            let (model, _, cleanUp) = await makeIntake()
            defer { cleanUp() }
            model.method = .manual
            // eSUN PLA-Matte, Milky White, 1 kg — and the catalogue has eSUN's own PLA-Matte.
            guard let found = t.unwrap(model.barcodeFilament(for: "6922572201811")) else { return }
            model.applyBarcode(code: "6922572201811", filament: found)
            t.equal(model.materialID, "E1003")
            t.equal(model.brand, "eSUN")
            t.equal(model.name, "eSUN PLA-Matte")
            t.equal(model.colorHex, "FBFBF9")
            t.equal(model.pickedColour?.name, "Milky White")
            t.equal(model.netWeightGrams, 1000)
            t.expect(model.canWriteTags, "a scanned box is ready to tag")
        }
    },

    test("a sub-brand's box finds the entry its parent's catalogue files it under") { t in
        onMain {
            let (model, _, cleanUp) = await makeIntake()
            defer { cleanUp() }
            model.method = .manual
            let panchroma = BarcodeFilament(brand: "Panchroma", line: "Matte PLA", material: "PLA",
                                            colourName: "Charcoal Black", hex: "2F2E30")
            t.equal(model.catalogueRow(for: panchroma)?.id, "P1003")
            // A box that says only `PETG` is not the maker's PETG-ESD.
            let plain = BarcodeFilament(brand: "Polymaker", line: "PETG", material: "PETG",
                                        colourName: "Black", hex: "000000")
            t.equal(model.catalogueRow(for: plain)?.id, "00003", "the printer's generic PETG")
        }
    },

    test("a maker the catalogue has nothing from is tagged as the generic polymer, under its own name") { t in
        onMain {
            let (model, inventory, cleanUp) = await makeIntake()
            defer { cleanUp() }
            model.method = .manual
            guard let found = t.unwrap(model.barcodeFilament(for: "8720629064369")) else { return }
            model.applyBarcode(code: "8720629064369", filament: found)
            t.equal(model.materialID, "00001")
            t.equal(model.brand, "FormFutura")
            t.equal(model.name, "EasyFil ePLA")
            t.expect(model.barcodeNote?.contains("Generic PLA") == true, "the form says what it will be tagged as")

            model.setTagsRequired(0)
            model.confirm()
            t.equal(inventory.inventory.active.first?.label, "FormFutura EasyFil ePLA · Matt White")
        }
    },

    test("an unlisted box is remembered once the spool is described") { t in
        onMain {
            let (model, inventory, cleanUp) = await makeIntake()
            defer { cleanUp() }
            // A valid GTIN that no filament list has.
            let code = "4006381333931"
            model.method = .manual
            t.expect(model.barcodeFilament(for: code) == nil)
            model.applyBarcode(code: code, filament: nil)
            t.expect(model.barcodeNote?.contains("not listed") == true)

            model.catalogueBrand = "Creality"
            model.materialID = "01001"
            guard let red = model.makerColours.colours.first(where: { $0.name == "Red" }) else { return }
            model.chooseMakerColour(red)
            model.netWeightGrams = 500
            model.setTagsRequired(0)
            model.confirm()
            t.expect(model.scannedBarcode == nil, "the next spool starts without a barcode")

            // The next box of it: a new model, as after a relaunch.
            let again = IntakeViewModel(monitor: ReaderMonitor(), inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(), toasts: ToastCenter())
            let known = again.barcodeFilament(for: code)
            t.equal(known?.source, .learned)
            t.equal(known?.colourName, "Red")
            t.equal(known?.catalogueID, "01001")
            t.equal(known?.netWeightGrams, 500)
        }
    },

    test("a barcode fills nothing in once a tag is written, or in Method A") { t in
        onMain {
            let (model, _, cleanUp) = await makeIntake()
            defer { cleanUp() }
            let box = BarcodeFilament(brand: "eSUN 3D", line: "PLA-Matte", material: "PLA",
                                      colourName: "Milky White", hex: "FBFBF9")
            model.method = .scan
            model.applyBarcode(code: "6922572201811", filament: box)
            t.expect(model.scannedBarcode == nil, "the tag is the authority in Method A")

            model.method = .manual
            model.catalogueBrand = "Creality"
            model.materialID = "01001"
            model.absorbWrite(uid: [1, 2, 3, 4])
            t.expect(model.isIdentityLocked)
            model.applyBarcode(code: "6922572201811", filament: box)
            t.equal(model.materialID, "01001")
            model.chooseMakerColour(box.colour)
            t.expect(model.pickedColour == nil, "nor does the colour menu")
        }
    },
])
