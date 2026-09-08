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
