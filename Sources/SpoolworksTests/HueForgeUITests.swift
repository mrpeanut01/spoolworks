import Foundation
@testable import SpoolworksUI
@testable import SpoolworksCore

// The HueForge window's model: that the list follows the inventory, that a typed TD survives a
// relaunch, and that every way out writes what the list shows.

// Same pump as InventoryEditingTests; file-private there, so carried here too.
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

private func spool(colour: String, name: String) -> Spool {
    Spool(brand: "Creality", name: "Hyper PLA", materialType: "PLA",
          colorHex: colour, colorName: name)
}

@MainActor
private func makeModels() -> (InventoryViewModel, HueForgeViewModel, URL, UserDefaults, String) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-hueforge-\(UUID().uuidString)", isDirectory: true)
    let suite = "sw-hueforge-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let toasts = ToastCenter()
    let inventory = InventoryViewModel(store: InventoryStore(directory: dir), toasts: toasts,
                                       defaults: defaults)
    let model = HueForgeViewModel(inventory: inventory,
                                  store: HueForgePreferencesStore(directory: dir),
                                  toasts: toasts, defaults: defaults)
    return (inventory, model, dir, defaults, suite)
}

let hueForgeViewModelTests = TestSuite(name: "HueForge · window", cases: [

    test("the list follows the inventory as spools are added") { t in
        onMain {
            let (inventory, model, dir, defaults, suite) = makeModels()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            t.expect(model.entries.isEmpty)
            inventory.add(spool(colour: "FFFFFF", name: "White"))
            inventory.add(spool(colour: "FFFFFF", name: "White"))
            inventory.add(spool(colour: "C12E1F", name: "Red"))
            t.equal(model.entries.map(\.filament.name), ["Red", "White"])
            t.equal(model.summary, "2 filaments from 3 spools")
        }
    },

    test("a typed TD is kept across a relaunch, rubbish is refused, and Reset forgets it") { t in
        onMain {
            let (inventory, model, dir, defaults, suite) = makeModels()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            inventory.add(spool(colour: "FFFFFF", name: "White"))
            let id = model.entries[0].id
            t.equal(model.entries[0].tdSource, .estimated)

            t.expect(!model.setTransmissivity("thick", for: id))
            t.expect(!model.setTransmissivity("0", for: id))
            t.expect(model.problem != nil, "a refused value says why")
            t.expect(model.setTransmissivity("5,8", for: id), "a decimal comma is a decimal")
            t.equal(model.entries[0].filament.transmissivity, 5.8)
            t.equal(model.entries[0].tdSource, .user)
            t.expect(model.problem == nil)

            let relaunched = HueForgeViewModel(inventory: inventory,
                                               store: HueForgePreferencesStore(directory: dir),
                                               toasts: ToastCenter(), defaults: defaults)
            t.equal(relaunched.entries[0].filament.transmissivity, 5.8)

            model.clearTransmissivity(for: id)
            t.equal(model.entries[0].tdSource, .estimated)
        }
    },

    test("export writes the included filaments in the format the file name asks for") { t in
        onMain {
            let (inventory, model, dir, defaults, suite) = makeModels()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            inventory.add(spool(colour: "FFFFFF", name: "White"))
            inventory.add(spool(colour: "C12E1F", name: "Red"))
            model.setIncluded(false, for: model.entries.first { $0.filament.name == "Red" }!.id)

            let json = dir.appendingPathComponent("out.json"), csv = dir.appendingPathComponent("out.csv")
            model.export(to: json)
            model.export(to: csv)
            t.equal((try? HueForgeLibrary(contentsOf: json))?.filaments.map(\.name), ["White"])
            t.equal((try? HueForgeLibrary(contentsOf: csv))?.filaments.map(\.name), ["White"])
            t.expect((try? String(contentsOf: csv, encoding: .utf8))?.hasPrefix("Brand,Type,Color,Name,TD") == true)
        }
    },

    test("choosing a sync folder syncs to it, remembers it, and a wrong folder is refused") { t in
        onMain {
            let (inventory, model, dir, defaults, suite) = makeModels()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            inventory.add(spool(colour: "FFFFFF", name: "White"))

            model.chooseSyncFolder(dir)
            t.expect(model.syncFolder == nil, "a folder with no Filaments in it is not adopted")
            t.expect(model.problem != nil)

            let hueForge = dir.appendingPathComponent("HueForge")
            try? FileManager.default.createDirectory(at: hueForge.appendingPathComponent("Filaments"),
                                                     withIntermediateDirectories: true)
            model.chooseSyncFolder(hueForge)
            t.equal(model.syncFolder?.path, hueForge.path)
            t.expect(model.problem == nil)
            let file = hueForge.appendingPathComponent("Filaments/Vendor Libraries/Spoolworks.json")
            t.equal((try? HueForgeLibrary(contentsOf: file))?.filaments.count, 1)

            // A second spool, then Sync now: the file is replaced, not appended to.
            inventory.add(spool(colour: "C12E1F", name: "Red"))
            model.syncNow()
            t.equal((try? HueForgeLibrary(contentsOf: file))?.filaments.count, 2)
        }
    },

    test("TDs imported from a HueForge file replace the estimates") { t in
        onMain {
            let (inventory, model, dir, defaults, suite) = makeModels()
            defer { try? FileManager.default.removeItem(at: dir); defaults.removePersistentDomain(forName: suite) }
            inventory.add(spool(colour: "FFFFFF", name: "White"))
            let file = dir.appendingPathComponent("personal_library_export.csv")
            try? Data("Brand,Type,Color,Name,TD\nCreality Hyper,PLA,#ffffff,White,6.9\n".utf8).write(to: file)
            model.importTransmissivities(from: file)
            t.equal(model.entries[0].filament.transmissivity, 6.9)
            t.equal(model.entries[0].tdSource, .user)
        }
    },
])
