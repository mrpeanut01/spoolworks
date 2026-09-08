import Foundation
@testable import SpoolworksUI
@testable import SpoolworksCore

// The material type a spool carries, and the labels the Tag column shows.
//
// Both exist because of the same defect: a spool written from the Write tag screen landed with an
// empty `materialType`, and there was no way to set one afterwards, so it read `—` in the table for
// ever. One end of the fix is that the type is now resolved at creation; the other is that it can be
// corrected. Both ends are pinned here.

private final class TypeCell<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

private func onMain(timeout: TimeInterval = 20, _ body: @escaping @MainActor () async -> Void) {
    let done = TypeCell(false)
    Task { @MainActor in
        await body()
        done.value = true
    }
    let deadline = Date().addingTimeInterval(timeout)
    while !done.value && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
    }
}

@MainActor
private func makeInventory() -> (InventoryViewModel, UserDefaults, String, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-type-\(UUID().uuidString)", isDirectory: true)
    let suite = "sw-type-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let model = InventoryViewModel(store: InventoryStore(directory: dir),
                                   toasts: ToastCenter(),
                                   defaults: defaults)
    return (model, defaults, suite, dir)
}

private func typedSpool(materialType: String) -> Spool {
    Spool(identity: SpoolIdentity(vendorId: "0276", filamentId: "101001",
                                  colorHex: "C12E1F", serialNumber: "000123"),
          brand: "Creality", name: "Hyper PLA", materialType: materialType,
          colorHex: "C12E1F", colorName: "Red",
          netWeightGrams: 1000,
          remainingPercent: 100,
          location: .unknown,
          tagSource: .spoolworksWritten)
}

let tagSourceLabelTests = TestSuite(name: "Tag source labels", cases: [

    test("the Tag column reads Creality, Custom and Untagged") { t in
        t.equal(TagSource.crealityFactory.description, "Creality", "factory tag")
        t.equal(TagSource.spoolworksWritten.description, "Custom", "a tag this app wrote")
        t.equal(TagSource.untagged.description, "Untagged · manual", "no tag")
    },

    test("the encoded form is untouched by the labels") { t in
        // The raw values are what `inventory.json` holds. Renaming a *case* to match a new label
        // would orphan every spool already recorded under the old one — a silent data loss that
        // would only show up as spools arriving with the wrong provenance after an upgrade.
        t.equal(TagSource.crealityFactory.rawValue, "crealityFactory", "factory raw value")
        t.equal(TagSource.spoolworksWritten.rawValue, "spoolworksWritten", "written raw value")
        t.equal(TagSource.untagged.rawValue, "untagged", "untagged raw value")

        for source in TagSource.allCases {
            t.equal(TagSource(rawValue: source.rawValue), source, "\(source.rawValue) round-trips")
        }
    },
])

let spoolTypeEditingTests = TestSuite(name: "Spool type editing", cases: [

    test("a type can be corrected after the fact") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            // The state that actually occurred: written from the Write tag screen, no type.
            let spool = typedSpool(materialType: "")
            model.add(spool)
            t.equal(model.inventory.spool(id: spool.id)?.materialType, "", "starts blank")

            model.setMaterialType("PETG", for: spool)
            t.equal(model.inventory.spool(id: spool.id)?.materialType, "PETG", "and can be set")
        }
    },

    test("surrounding whitespace is trimmed, so a stray space is not a different type") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = typedSpool(materialType: "")
            model.add(spool)
            model.setMaterialType("  PLA-CF \n", for: spool)
            t.equal(model.inventory.spool(id: spool.id)?.materialType, "PLA-CF", "trimmed")
        }
    },

    test("the model still accepts an empty type, because unknown is a real state") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = typedSpool(materialType: "PLA")
            model.add(spool)
            model.setMaterialType("   ", for: spool)
            // Not reachable from the rail — the picker drops its `—` row once a type is chosen, so
            // the field is effectively mandatory from the first edit on. This is the model's own
            // contract: a spool whose type is genuinely unknown has to be representable, or the
            // ones already in stock like that could not be loaded back.
            t.equal(model.inventory.spool(id: spool.id)?.materialType, "",
                    "an unknown type stays representable at the model level")
        }
    },

    test("editing the type never touches the usage log") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = typedSpool(materialType: "")
            model.add(spool)
            let before = model.inventory.spool(id: spool.id)?.usage.count ?? -1

            model.setMaterialType("ABS", for: spool)

            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.usage.count, before, "no line added")
            // The usage log explains `remainingPercent` and every line in it carries a gram delta.
            // A metadata correction logging 0 g would be noise in the one place this app promises
            // is never noise — see `setMaterialType`.
            t.equal(after.remainingPercent, 100, "and the figure itself is untouched")
        }
    },

    test("re-committing the same type writes nothing") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            // The field commits on losing focus as well as on Return, so clicking through a row
            // re-commits whatever is already there. That must be a no-op.
            let spool = typedSpool(materialType: "PLA")
            model.add(spool)
            let before = model.inventory.spool(id: spool.id)
            model.setMaterialType("PLA", for: spool)
            t.equal(model.inventory.spool(id: spool.id), before, "the record is unchanged")
        }
    },

    test("a spool written for a known filament arrives with its type already set") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            guard let record = try? SpoolRecord(materialId: "01001",
                                                colorRGB: "C12E1F",
                                                filamentLength: .kg1,
                                                serialNumber: "000123") else {
                t.expect(false, "could not build a record")
                return
            }
            let logged = model.logWrittenSpool(record: record,
                                               materialLabel: "Creality · Hyper PLA",
                                               materialType: "PLA",
                                               enabled: true)
            t.equal(logged?.materialType, "PLA", "the type the caller resolved is carried through")
            t.equal(logged?.brand, "Creality", "and the label is still split into brand and name")
            t.equal(logged?.name, "Hyper PLA", "name")
        }
    },

    test("an unknown filament id logs no type rather than a plausible invention") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            guard let record = try? SpoolRecord(materialId: "99999",
                                                colorRGB: "C12E1F",
                                                filamentLength: .kg1,
                                                serialNumber: "000124") else {
                t.expect(false, "could not build a record")
                return
            }
            // The caller found nothing in the catalogue and passed "". Defaulting to PLA here would
            // put a type on screen that nothing supports, and the user would have no way to know it
            // was guessed rather than read.
            let logged = model.logWrittenSpool(record: record,
                                               materialLabel: "Someone Else · Filament",
                                               enabled: true)
            t.equal(logged?.materialType, "", "left blank, and correctable in the rail")
        }
    },
])

// MARK: - The name follows the material

let intakeNameTests = TestSuite(name: "Intake name generation", cases: [

    test("changing the material changes the name, even after it was edited by hand") { t in
        onMain {
            let toasts = ToastCenter()
            let catalogue = FileManager.default.temporaryDirectory
                .appendingPathComponent("sw-cat-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: catalogue) }
            let materials = MaterialsViewModel(storage: MaterialStorage(directory: catalogue))
            await materials.load()
            guard materials.rows.count > 1 else {
                t.expect(false, "the bundled catalogue should have more than one filament")
                return
            }
            let (inventory, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: materials,
                                        toasts: toasts)
            model.method = .manual

            // Two filaments from one brand, so switching between them is a pure material change.
            let brand = materials.rows.map(\.brand).first { candidate in
                materials.rows.filter { $0.brand == candidate }.count > 1
            }
            guard let brand, case let choices = materials.rows.filter({ $0.brand == brand }),
                  choices.count > 1 else {
                t.expect(false, "no brand with two filaments to switch between")
                return
            }
            model.catalogueBrand = brand

            model.materialID = choices[0].id
            t.equal(model.name, choices[0].name, "the name comes from the material")

            // The behaviour that was wrong: a hand-typed name used to survive the switch, leaving
            // the form describing a filament it was no longer going to write.
            model.name = "My own label"
            model.materialID = choices[1].id
            t.equal(model.name, choices[1].name, "and a hand-edited one is replaced, not kept")
            t.equal(model.filamentId, "1" + choices[1].id, "the id moved with it")
            t.equal(model.brand, choices[1].brand, "and so did the brand")
        }
    },

    test("brand and name compose the inventory label, so neither has to carry the other") { t in
        // The reason the name is just the material and not "Brand - Material": `Spool.label`
        // already joins them. Storing the brand inside the name too would render it twice, and
        // `brand` is not decoration — the swatch library matches a manufacturer on it and the CFS
        // reconcile writes it from the slot.
        let spool = Spool(identity: nil,
                          brand: "Creality", name: "Hyper PLA", materialType: "PLA",
                          colorHex: "C12E1F", colorName: "Cherry Pie",
                          netWeightGrams: 1000, remainingPercent: 100,
                          location: .unknown, tagSource: .crealityFactory)
        t.equal(spool.label, "Creality Hyper PLA · Cherry Pie",
                "brand and material read as one name already")
    },
])

// MARK: - Draggable column and rail widths

@MainActor
private func makeLayout() -> (InventoryLayout, UserDefaults, String) {
    let suite = "sw-layout-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    return (InventoryLayout(defaults: defaults), defaults, suite)
}

let inventoryLayoutTests = TestSuite(name: "Inventory layout", cases: [

    test("a drag is clamped to each column's own floor and ceiling") { t in
        onMain {
            let (layout, defaults, suite) = makeLayout()
            defer { defaults.removePersistentDomain(forName: suite) }
            for column in InventoryLayout.Column.allCases {
                layout.setWidth(-500, for: column)
                t.equal(layout.width(column), column.minimum, "\(column) floor")
                layout.setWidth(9_999, for: column)
                t.equal(layout.width(column), column.maximum, "\(column) ceiling")
                layout.setWidth(column.defaultWidth, for: column)
                t.equal(layout.width(column), column.defaultWidth, "\(column) accepts a real value")
            }
        }
    },

    test("the rail cannot be dragged out of existence, in either direction") { t in
        onMain {
            let (layout, defaults, suite) = makeLayout()
            defer { defaults.removePersistentDomain(forName: suite) }
            layout.setRailWidth(0)
            t.equal(layout.railWidth, InventoryLayout.railMinimum, "the rail keeps a floor")
            layout.setRailWidth(5_000)
            t.equal(layout.railWidth, InventoryLayout.railMaximum,
                    "and a ceiling, so the table cannot be squeezed away either")
        }
    },

    test("widths survive a relaunch") { t in
        onMain {
            let (layout, defaults, suite) = makeLayout()
            defer { defaults.removePersistentDomain(forName: suite) }
            layout.setWidth(140, for: .location)
            layout.setRailWidth(520)

            let reopened = InventoryLayout(defaults: defaults)
            t.equal(reopened.width(.location), 140, "the column came back")
            t.equal(reopened.railWidth, 520, "and so did the rail")
        }
    },

    test("a stored width outside the limits is clamped on the way in, not trusted") { t in
        onMain {
            let (_, defaults, suite) = makeLayout()
            defer { defaults.removePersistentDomain(forName: suite) }
            // A hand-edited plist, or one written by a version with different limits. Trusting it
            // would open the app with a column wider than the window and no way to see the table.
            defaults.set(99_999.0, forKey: "SpoolworksInventoryColumn_tag")
            defaults.set(-1.0, forKey: "SpoolworksInventoryRailWidth")

            let layout = InventoryLayout(defaults: defaults)
            t.equal(layout.width(.tag), InventoryLayout.Column.tag.maximum, "column clamped on load")
            t.equal(layout.railWidth, InventoryLayout.railMinimum, "rail clamped on load")
        }
    },

    test("a non-finite width is replaced rather than clamped") { t in
        // `NaN` compares false against everything, so `min`/`max` pass it straight through into a
        // frame and the table stops laying out for the rest of the session.
        t.equal(InventoryLayout.clamp(.nan, min: 10, max: 100), 10, "NaN falls back to the floor")
        t.equal(InventoryLayout.clamp(.infinity, min: 10, max: 100), 10, "and so does infinity")
        t.equal(InventoryLayout.clamp(50, min: 10, max: 100), 50, "a real value is untouched")
    },

    test("reset puts everything back and forgets it") { t in
        onMain {
            let (layout, defaults, suite) = makeLayout()
            defer { defaults.removePersistentDomain(forName: suite) }
            layout.setWidth(200, for: .serial)
            layout.setRailWidth(600)
            layout.reset()

            t.equal(layout.width(.serial), InventoryLayout.Column.serial.defaultWidth, "column")
            t.equal(layout.railWidth, InventoryLayout.railDefault, "rail")
            t.expect(defaults.object(forKey: "SpoolworksInventoryColumn_serial") == nil,
                     "and the stored value is gone, not merely overwritten")
        }
    },
])

// MARK: - Where the screens land after a write

let intakeReturnsToScanTests = TestSuite(name: "Intake returns to Method A", cases: [

    test("adding a spool from Method B leaves the screen on Method A") { t in
        onMain {
            let catalogue = FileManager.default.temporaryDirectory
                .appendingPathComponent("sw-cat-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: catalogue) }
            let materials = MaterialsViewModel(storage: MaterialStorage(directory: catalogue))
            await materials.load()
            let (inventory, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: materials,
                                        toasts: ToastCenter())
            model.method = .manual
            model.name = "A third-party spool"

            t.expect(model.canConfirm, "the form is confirmable")
            model.confirm()

            // Method B is the detour taken because a spool has no tag. The next spool probably has
            // one, and leaving the screen on B also leaves the reader armed to write rather than
            // to read.
            t.equal(model.method, .scan, "back on Method A")
            t.equal(model.name, "", "and the form is cleared, not merely switched")
            t.equal(model.tagsHandled, 0, "with the tag slots reset")
        }
    },

    test("confirming from Method A still clears the form") { t in
        onMain {
            let catalogue = FileManager.default.temporaryDirectory
                .appendingPathComponent("sw-cat-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: catalogue) }
            let materials = MaterialsViewModel(storage: MaterialStorage(directory: catalogue))
            await materials.load()
            let (inventory, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: materials,
                                        toasts: ToastCenter())
            // Already on Method A, so setting the method again changes nothing — this is the case
            // that would break if the reset were left to `method`'s `didSet` alone.
            model.method = .manual
            model.method = .scan
            model.name = "typed by hand"
            model.confirm()
            t.equal(model.method, .scan, "still Method A")
        }
    },
])

// MARK: - Weights, in one hundred gram steps

let weightLadderTests = TestSuite(name: "Weight ladder", cases: [

    test("every hundred grams from 100 to 1000 has a code") { t in
        for grams in stride(from: 100, through: 1000, by: 100) {
            guard let length = t.unwrap(FilamentLength.forGrams(grams), "\(grams) g") else { continue }
            t.equal(length.grams, grams, "\(grams) g round-trips")
            // The codes are not published for the new rungs; they are derived at the ratio the
            // documented ones use, and that derivation has to keep reproducing the published ones.
            t.equal(length.rawValue, String(format: "%04d", Int(Double(grams) * 0.33)),
                    "\(grams) g derives its own code")
            t.equal(FilamentLength(rawValue: length.rawValue)?.grams, grams, "and decodes back")
        }
    },

    test("only Creality's own five are flagged as standard") { t in
        let standard = Set(FilamentLength.allCases.filter(\.isCrealityStandard).map(\.grams))
        t.equal(standard, [1000, 750, 600, 500, 250],
                "the added rungs stay flagged, because every Creality client reads them as 1 KG")
    },

    test("the label is derived, so a new rung cannot be forgotten") { t in
        t.equal(FilamentLength.kg1.label, "1 KG", "the Windows form for a kilo")
        t.equal(FilamentLength.g750.label, "750 G", "and for grams")
        t.equal(FilamentLength.g300.label, "300 G", "including one Windows never had")
        for length in FilamentLength.allCases {
            t.expect(!length.label.isEmpty, "\(length.grams) g has a label")
        }
    },
])

let remainingOptionTests = TestSuite(name: "Remaining options", cases: [

    test("a 1 kg spool steps in hundreds, fullest first, in both units") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = typedSpool(materialType: "PLA")
            let options = model.remainingOptions(for: spool)
            t.equal(options.map(\.grams), [1000, 900, 800, 700, 600, 500, 400, 300, 200, 100, 0],
                    "eleven rungs, fullest first")
            t.equal(options.first?.label, "1000 g · 100%", "full")
            t.equal(options.last?.label, "0 g · 0%", "empty")
            t.expect(options.contains { $0.label == "100 g · 10%" },
                     "and the rung the request named")
        }
    },

    test("a spool whose net weight is not a multiple of 100 can still say full") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            var spool = typedSpool(materialType: "PLA")
            spool.netWeightGrams = 750
            let options = model.remainingOptions(for: spool)
            t.equal(options.first?.grams, 750, "its own weight is the top rung")
            t.equal(options.first?.label, "750 g · 100%", "and reads as full")
            t.equal(options.dropFirst().first?.grams, 700, "then the ladder resumes")
            t.equal(options.last?.grams, 0, "down to empty")
        }
    },

    test("a spool with no net weight offers nothing rather than dividing by zero") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            var spool = typedSpool(materialType: "PLA")
            spool.netWeightGrams = 0
            t.equal(model.remainingOptions(for: spool).count, 0, "no rungs")
        }
    },

    test("every rung is accepted, so the picker can never offer a refused value") { t in
        onMain {
            let (model, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = typedSpool(materialType: "PLA")
            model.add(spool)
            for option in model.remainingOptions(for: spool) {
                // Re-applying the figure already on record is a no-op by design, so start each
                // rung from a different one.
                _ = model.adjust(spool, toGrams: option.grams == 0 ? 100 : 0)
                t.expect(model.adjust(spool, toGrams: option.grams),
                         "\(option.label) is accepted")
            }
        }
    },
])

// MARK: - An edited net weight survives Method A

let intakeNetWeightTests = TestSuite(name: "Intake net weight", cases: [

    test("a net weight corrected after reading a tag is what gets added to stock") { t in
        onMain {
            let catalogue = FileManager.default.temporaryDirectory
                .appendingPathComponent("sw-cat-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: catalogue) }
            let materials = MaterialsViewModel(storage: MaterialStorage(directory: catalogue))
            await materials.load()
            let (inventory, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }

            // A tag that says 1 kg, on a spool the user can see is a 250 g sample. The tag's length
            // code is nominal — and every Creality client reports an unrecognised code as 1 KG —
            // so the figure on the form has to win.
            guard let record = try? SpoolRecord(materialId: "01001",
                                                colorRGB: "C12E1F",
                                                filamentLength: .kg1,
                                                serialNumber: "000321") else {
                t.expect(false, "could not build a record")
                return
            }
            let spool = inventory.spool(from: record,
                                        brand: "Creality",
                                        name: "Hyper PLA",
                                        materialType: "PLA",
                                        netWeightGrams: 250,
                                        tagSource: .crealityFactory,
                                        detail: "Intake · tag read")
            t.equal(spool.netWeightGrams, 250, "the corrected figure, not the tag's 1000")
            t.equal(record.weightGrams, 1000, "and the tag itself is unchanged")
        }
    },

    test("without a correction the tag's own weight is still used") { t in
        onMain {
            let (inventory, defaults, suite, dir) = makeInventory()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            guard let record = try? SpoolRecord(materialId: "01001",
                                                colorRGB: "C12E1F",
                                                filamentLength: .g500,
                                                serialNumber: "000322") else {
                t.expect(false, "could not build a record")
                return
            }
            let spool = inventory.spool(from: record, tagSource: .crealityFactory)
            t.equal(spool.netWeightGrams, 500, "the tag decides when nothing overrides it")
        }
    },
])
