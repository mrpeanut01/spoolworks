import Foundation
@testable import SpoolworksUI
import SpoolworksCore

// The async/@MainActor pump lives in UIStateTests.swift; these reuse it via `onMain` below.
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

@MainActor
private func makeInventory() -> (InventoryViewModel, InventoryStore, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-ui-\(UUID().uuidString)", isDirectory: true)
    let store = InventoryStore(directory: dir)
    return (InventoryViewModel(store: store, toasts: ToastCenter()), store, dir)
}

@MainActor
private func sampleSpool(_ serial: String = "000123", percent: Double = 100) -> Spool {
    Spool(identity: SpoolIdentity(vendorId: "0276", filamentId: "101001",
                                  colorHex: "C12E1F", serialNumber: serial),
          brand: "Creality", name: "Hyper PLA", materialType: "PLA",
          colorHex: "C12E1F", colorName: "Red",
          remainingPercent: percent, tagSource: .crealityFactory)
}

// MARK: - Inventory view model

let inventoryViewModelTests = TestSuite(name: "Inventory view model", cases: [

    test("adding a spool selects it and writes it straight to disk") { t in
        onMain {
            let (model, store, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let spool = sampleSpool()
            model.add(spool)

            t.equal(model.selectedID, spool.id, "selected")
            t.equal(model.inventory.active.count, 1, "in the list")
            // Persisted immediately: an inventory that loses the last spool logged because the
            // app was force-quit is worse than useless.
            let reloaded = (try? store.load()) ?? SpoolInventory()
            t.equal(reloaded.spools.count, 1, "already on disk")
        }
    },

    test("the detail rail follows the filter rather than showing a hidden spool") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let healthy = sampleSpool("000001", percent: 90)
            let low = sampleSpool("000002", percent: 10)
            model.add(healthy)
            model.add(low)
            model.selectedID = healthy.id

            model.filter = .low
            t.equal(model.selected?.id, low.id, "falls back to a row that is actually listed")

            model.filter = .all
            t.equal(model.selected?.id, healthy.id, "the explicit selection comes back")
        }
    },

    test("retiring clears the selection and keeps the record") { t in
        onMain {
            let (model, store, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let spool = sampleSpool()
            model.add(spool)
            model.retireTarget = spool
            model.confirmRetire(spool)

            t.expect(model.retireTarget == nil, "dialog dismissed")
            t.equal(model.inventory.active.count, 0, "gone from the list")
            let reloaded = (try? store.load()) ?? SpoolInventory()
            t.equal(reloaded.spools.count, 1, "history kept on disk")
        }
    },

    test("a corrupt file is reported instead of looking like a first run") { t in
        onMain {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("sw-ui-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let store = InventoryStore(directory: dir)
            try? Data("{ not json".utf8).write(to: store.fileURL)

            let model = InventoryViewModel(store: store, toasts: ToastCenter())
            model.load()
            t.expect(model.storageError != nil, "the screen can say why it is empty")
            t.expect(model.isEmpty, "and it is empty")
        }
    },

    test("a weigh-in converts grams to a percentage and records the delta") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let spool = sampleSpool(percent: 100)   // 1 kg net
            model.add(spool)

            t.expect(model.adjust(spool, toGrams: 640), "accepted")
            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.remainingPercent, 64, "640 g of 1000 g")
            t.equal(after.usage.first?.kind, .adjustment, "recorded as an adjustment")
            t.equal(after.usage.first?.deltaGrams, -360, "delta derived from the reading")
        }
    },

    // Weighing the spool *with* its core gives a figure larger than the spool can hold. Clamping
    // to 100% would silently discard what the user actually measured.
    test("a weigh-in larger than the spool is refused, not clamped") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let spool = sampleSpool(percent: 50)
            model.add(spool)

            t.expect(!model.adjust(spool, toGrams: 1250), "refused — that is gross weight")
            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.remainingPercent, 50, "unchanged")
            t.equal(after.usage.count, 0, "and nothing written to the history")

            t.expect(!model.adjust(spool, toGrams: -5), "a negative reading is refused too")
        }
    },

    test("a weigh-in of exactly zero is a spent spool, not an error") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let spool = sampleSpool(percent: 8)
            model.add(spool)
            t.expect(model.adjust(spool, toGrams: 0), "accepted")
            t.equal(model.inventory.spool(id: spool.id)?.remainingPercent, 0, "empty")
        }
    },

    test("a hand adjustment records the delta it caused") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let spool = sampleSpool(percent: 100)
            model.add(spool)
            model.adjust(spool, toPercent: 62)

            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.remainingPercent, 62, "figure moved")
            t.equal(after.usage.first?.kind, .adjustment, "recorded as an adjustment")
            t.equal(after.usage.first?.deltaGrams, -380, "delta derived, not asserted")
        }
    },
])

// MARK: - Intake

let intakeViewModelTests = TestSuite(name: "Intake view model", cases: [

    // 000001 is what Windows hard-codes, so every factory spool already carries it. Allocating it
    // to an app-written spool would collide with the entire Creality catalogue.
    test("an allocated serial is never the Windows default") { t in
        for _ in 0..<200 {
            let serial = IntakeViewModel.allocateSerial()
            t.equal(serial.count, 6, "fits the tag field")
            t.expect(serial != "000001", "not the hard-coded default")
            t.expect(serial.allSatisfy(\.isNumber), "digits only")
        }
    },

    test("switching method clears whatever the previous one had gathered") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: ToastCenter())
            model.brand = "Polymaker"
            model.colorHex = "E8A0B4"

            model.method = .manual
            t.equal(model.brand, "", "brand cleared")
            t.equal(model.colorHex, "C12E1F", "colour back to the default")
            t.equal(model.tagsHandled, 0, "tag progress cleared")
        }
    },

    test("the two-tag panel labels track method and progress") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: ToastCenter())

            t.equal(model.tagPanelLabel, "Step 2 · Read either tag", "scan reads")
            t.equal(model.formLabel, "Step 3 · Confirm", "scan confirms last")
            t.equal(model.tagProgress, "0 of 2 read", "progress")
            t.equal(model.tags.count, 2, "a spool carries two tags")

            model.method = .manual
            t.equal(model.tagPanelLabel, "Step 3 · Write both tags", "manual writes")
            t.equal(model.formLabel, "Step 2 · Describe the spool", "manual describes first")
            t.equal(model.tagProgress, "0 of 2 written", "progress")
        }
    },

    test("method A cannot add a spool it has not read; method B can add untagged") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: ToastCenter())

            t.expect(!model.canConfirm, "nothing read yet")

            model.method = .manual
            t.expect(!model.canConfirm, "an empty form is still not addable")
            model.brand = "Polymaker"
            t.expect(model.canConfirm, "a described spool can be added before it is tagged")
            t.equal(model.confirmTitle, "Add to stock (tags pending)", "and the button says so")
        }
    },

    // Method B writes a tag, and a tag stores a filament ID the printer looks up in its own
    // database. Brand and material as free text produce a tag the printer reads and ignores.
    test("Method B cannot write until a catalogue material is chosen") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: ToastCenter())
            model.method = .manual

            t.expect(!model.canWriteTags, "nothing chosen yet")
            guard let blocker = t.unwrap(model.writeBlocker, "blocker") else { return }
            // An empty catalogue and an unchosen material are different problems with different
            // fixes, and the message has to say which.
            t.expect(blocker.contains("catalogue") || blocker.contains("material"),
                     "and it names the problem: \(blocker)")
        }
    },

    test("scanning never asks for a catalogue material — the tag already carries one") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: ToastCenter())
            t.expect(model.isScan, "method A")
            t.expect(model.writeBlocker == nil, "no write blocker in scan mode")
        }
    },

    test("the tag draft is loaded from the intake form, not composed twice") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let monitor = ReaderMonitor()
            let toasts = ToastCenter()
            let settings = AppSettings(defaults: UserDefaults(suiteName: "sw-test-\(UUID())")!)
            let tagModel = TagViewModel(monitor: monitor, toasts: toasts, settings: settings)
            let model = IntakeViewModel(monitor: monitor,
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: toasts)
            model.method = .manual
            model.serial = "480880"
            model.netWeightGrams = 750
            model.colorHex = "E8A0B4"
            model.brand = "Polymaker"
            model.name = "PolyTerra PLA"

            model.loadDraft(into: tagModel)
            t.equal(tagModel.draft.serialNumber, "480880", "serial")
            t.equal(tagModel.draft.weight, .g750, "net weight becomes a length code")
            t.equal(tagModel.draft.colorHex, "E8A0B4", "colour")
            t.expect(tagModel.draft.materialLabel.contains("Polymaker"), "label carries the brand")
        }
    },

    test("a manually entered spool lands in stock as untagged") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: ToastCenter())
            model.method = .manual
            model.brand = "Prusament"
            model.name = "PETG"
            model.materialType = "PETG"
            model.colorHex = "232733"
            model.confirm()

            t.equal(inventory.inventory.active.count, 1, "added")
            guard let added = t.unwrap(inventory.inventory.active.first, "spool") else { return }
            t.equal(added.tagSource, .untagged, "no tags written, so not claimed as tagged")
            t.equal(added.brand, "Prusament", "description kept")
            t.equal(model.session.count, 1, "shown in the session list")
            t.equal(model.brand, "", "and the form is rearmed for the next spool")
        }
    },
])

// MARK: - CFS

let cfsViewModelTests = TestSuite(name: "CFS view model", cases: [

    test("with no printer configured the screen says what to do instead of polling") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let printers = PrinterViewModel.previewValue()
            let model = CFSViewModel(transport: UnimplementedPrinterTransport(),
                                     printers: printers,
                                     inventory: inventory)

            t.expect(!model.canPoll, "cannot poll")
            guard let reason = t.unwrap(model.blockedReason, "reason") else { return }
            t.expect(reason.contains("No printer is configured"), "and says why")
            t.equal(model.navBadge, "", "no badge rather than a misleading zero")
            t.equal(model.freshness, "not polled", "freshness is honest")
        }
    },

    test("the summary describes what was actually read") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let model = CFSViewModel(transport: UnimplementedPrinterTransport(),
                                     printers: PrinterViewModel.previewValue(),
                                     inventory: inventory)
            t.equal(model.slotSummary, "no reading yet", "before any poll")
            t.equal(model.note, "Poll the printer to read its CFS.", "and the note matches")
        }
    },
])
