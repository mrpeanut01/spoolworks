import Foundation
@testable import SpoolworksUI
@testable import SpoolworksCore

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
            model.adjust(spool, toPercent: 62, method: .weighed)

            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.remainingPercent, 62, "figure moved")
            t.equal(after.usage.first?.kind, .adjustment, "recorded as an adjustment")
            t.equal(after.usage.first?.deltaGrams, -380, "delta derived, not asserted")
        }
    },

    // `selected` follows the filter, so a bare `selectedID` naming a hidden spool showed some
    // other row. Opening a specific spool has to make it visible.
    test("revealing a spool the filter hides drops the filter so it is the one shown") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let healthy = sampleSpool("000001", percent: 90)
            let low = sampleSpool("000002", percent: 10)
            model.add(healthy)
            model.add(low)
            model.filter = .low

            model.reveal(healthy.id)
            t.equal(model.filter, .all, "the filter that hid it is dropped")
            t.equal(model.selected?.id, healthy.id, "and it is the one the rail shows")

            // A spool the filter already lists needs no such help, and the filter stands.
            model.filter = .low
            model.reveal(low.id)
            t.equal(model.filter, .low, "a listed spool leaves the filter alone")
            t.equal(model.selected?.id, low.id, "selected")
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
            t.equal(model.tagProgress, "0 of 2 written and verified",
                    "the stronger claim: a write is only believed after read-back")
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
            // Unplaced, not `Shelf`: that is a seeded place the user can rename or remove, and a
            // spool at a place the picker no longer offers renders blank. See D-011.
            t.equal(added.location, .unknown, "lands unplaced like every other way in")
        }
    },

    // Method B, and the defect that put phantom spools in the CFS list: the tags were written
    // with one payload and the spool was stored under whatever the form said at "Add to stock".
    test("a written spool is identified by what its tags hold, not by the form at confirm") { t in
        onMain {
            let (model, inventory, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let written = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                 filamentLength: .kg1, serialNumber: "424242") else { return }
            model.method = .manual
            model.brand = "Creality"
            model.name = "Hyper PLA"
            model.absorbWrite(uid: [1, 2, 3, 4], record: written)
            model.absorbWrite(uid: [9, 9, 9, 9], record: written)
            t.equal(model.tagsHandled, 2, "both tags written")
            t.expect(model.isIdentityLocked, "and the fields the tag encodes are locked")

            // The name is not on the tag, so it may still change.
            model.name = "Hyper PLA, the red one"
            t.expect(model.canConfirm, "a name edit is allowed")
            model.confirm()

            guard let added = t.unwrap(inventory.inventory.active.first, "spool") else { return }
            t.equal(added.identity, SpoolIdentity(record: written), "the identity is the tags'")
            t.equal(added.tagSource, .spoolworksWritten, "credited as written")
            t.equal(added.name, "Hyper PLA, the red one", "the edit that was allowed survived")
            t.equal(added.location, .unknown, "unplaced, like every other way in")
            t.equal(inventory.existing(for: written)?.id, added.id,
                    "so reading either tag later finds this spool rather than discovering another")
        }
    },

    test("a form that drifts from what was written cannot be confirmed until it is put back") { t in
        onMain {
            let (model, inventory, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let written = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                 filamentLength: .kg1, serialNumber: "424242") else { return }
            model.method = .manual
            model.brand = "Creality"
            model.absorbWrite(uid: [1, 2, 3, 4], record: written)
            model.absorbWrite(uid: [9, 9, 9, 9], record: written)

            // The colour panel and the camera sheet can both land a value around the view's lock.
            model.colorHex = "FFFFFF"
            guard let drift = t.unwrap(model.writtenDrift, "the drift is named") else { return }
            t.expect(drift.contains("C12E1F"), "and says what the tag holds: \(drift)")
            t.expect(!model.canConfirm, "which blocks the add")
            model.confirm()
            t.equal(inventory.inventory.active.count, 0, "nothing stored under the wrong identity")

            // An invalid value is drift too. It used to store `identity == nil` on a spool
            // marked `spoolworksWritten`, which no tag could ever match.
            model.colorHex = "not a colour"
            t.expect(!model.canConfirm, "an unencodable colour is a mismatch, not a nil identity")

            model.restoreWrittenValues()
            t.equal(model.colorHex, "C12E1F", "the tag's colour is back")
            t.equal(model.writtenDrift, nil, "the form agrees with the tags again")
            t.expect(model.canConfirm, "so it can be added")
        }
    },

    test("the first write fixes the form, and the second tag is drafted from the first") { t in
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
            model.colorHex = "E8A0B4"
            model.netWeightGrams = 1000
            // What landed differs from the form: the panel moved the colour after the reader
            // was armed, and the write went out with the draft as it stood.
            guard let written = try? SpoolRecord(materialId: "01001", colorRGB: "0087BE",
                                                 filamentLength: .g500, serialNumber: "424242") else { return }
            model.absorbWrite(uid: [1, 2, 3, 4], record: written)
            t.equal(model.colorHex, "0087BE", "the form takes the tag's colour")
            t.equal(model.netWeightGrams, 500, "and its size")
            t.equal(model.serial, "424242", "and its serial")
            t.equal(model.filamentId, "101001", "and its filament id")

            // A spool's two tags carry the same payload, so the second is drafted from the first
            // however the form has moved since.
            model.colorHex = "FFFFFF"
            model.loadDraft(into: tagModel)
            t.equal(tagModel.draft.colorHex, "0087BE", "the second tag repeats the first")
            t.equal(tagModel.draft.serialNumber, "424242", "same serial")
            t.equal(tagModel.draft.weight, .g500, "same length code")
        }
    },

    test("a second tag carrying a different payload is refused, not counted") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let first = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                               filamentLength: .kg1, serialNumber: "424242"),
                  let other = try? SpoolRecord(materialId: "01001", colorRGB: "0087BE",
                                               filamentLength: .kg1, serialNumber: "424242") else { return }
            model.method = .manual
            model.absorbWrite(uid: [1, 2, 3, 4], record: first)
            model.absorbWrite(uid: [9, 9, 9, 9], record: other)
            t.equal(model.tagsHandled, 1, "a tag that disagrees with the first does not fill the slot")
            t.expect(model.failure?.contains("different payload") == true, "and the screen says why")
            t.equal(model.writtenRecord, first, "the first tag stays the authority")
        }
    },

    // The reader's arming is driven from one value, so a field that feeds the written record
    // cannot be left off the list the view watches. The spool size was, and a tag auto-written
    // after the size changed carried the old length code.
    test("the arming key moves with every field the tag encodes, size included") { t in
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
            model.loadDraft(into: tagModel)
            t.equal(tagModel.draft.weight, .kg1, "armed for the default size")

            let before = model.armingKey
            model.netWeightGrams = 500
            t.expect(model.armingKey != before, "a size change re-arms")
            model.loadDraft(into: tagModel)
            t.equal(tagModel.draft.weight, .g500, "and the tag would now carry the new length code")

            let afterSize = model.armingKey
            model.serial = "424242"
            t.expect(model.armingKey != afterSize, "so does the serial")
            model.loadDraft(into: tagModel)
            t.equal(tagModel.draft.serialNumber, "424242", "carried through")

            let afterSerial = model.armingKey
            model.setTagsRequired(0)
            t.expect(model.armingKey != afterSerial,
                     "and the tag count, which decides whether anything is armed at all")
        }
    },

    // `reset()` picked the first catalogue brand whatever the method, and picking a brand runs
    // the catalogue pre-fill. Switching back from Method B with another brand chosen therefore
    // *changed* the brand, and Method A came up describing a filament nothing had read.
    test("switching back to Method A leaves no catalogue pre-fill behind") { t in
        onMain {
            let (model, _, cleanup) = await makeCatalogueIntake()
            defer { cleanup() }
            model.method = .manual
            let brands = model.catalogueBrands
            guard brands.count > 1 else {
                t.expect(false, "the bundled catalogue should have more than one brand")
                return
            }
            model.catalogueBrand = brands[1]
            t.expect(!model.brand.isEmpty, "Method B is pre-filled from the catalogue, as intended")

            model.method = .scan
            t.equal(model.brand, "", "brand")
            t.equal(model.name, "", "name")
            t.equal(model.materialType, "", "type")
            t.equal(model.materialID, "", "no catalogue material chosen")
            t.equal(model.filamentId, "", "no filament id")
            t.expect(model.decoded == nil, "and nothing claims to have been read")
        }
    },

    test("Method A does not invent a type for a filament id the catalogue does not know") { t in
        onMain {
            // `makeIntake()` uses the preview catalogue, which is empty: no id resolves.
            let (model, inventory, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "99999", colorRGB: "C12E1F",
                                                filamentLength: .kg1, serialNumber: "000777") else { return }
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.materialType, "", "nothing resolved, so nothing is claimed")
            model.confirm()

            guard let added = t.unwrap(inventory.inventory.active.first, "spool") else { return }
            // The same answer `logWrittenSpool` gives for the same case; the rail can correct it.
            t.equal(added.materialType, "", "left blank rather than guessed as PLA")
            t.equal(added.brand, "", "no brand invented either")
            t.equal(added.identity?.filamentId, "199999", "but the spool is still its tag's")
        }
    },

    test("with one tag required the toast says a tag was read, not both") { t in
        onMain {
            let (inventory, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let toasts = ToastCenter()
            let model = IntakeViewModel(monitor: ReaderMonitor(),
                                        inventory: inventory,
                                        materials: MaterialsViewModel.previewValue(),
                                        toasts: toasts)
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }
            model.setTagsRequired(1)
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.expect(model.allTagsHandled, "one of one is finished")
            guard let text = t.unwrap(toasts.current?.text, "toast") else { return }
            t.expect(text.hasPrefix("Tag read"), "worded for one tag: \(text)")
            t.expect(!text.contains("Both"), "and never claims two")
        }
    },

    // The name fallback ran only when there was no identity at all, so a spool this app tagged
    // for a filament the catalogue has since dropped cloned with no material and Method B sat
    // blocked on "Choose a material".
    test("a clone whose filament id the catalogue no longer knows finds its material by name") { t in
        onMain {
            let (model, _, cleanup) = await makeCatalogueIntake()
            defer { cleanup() }
            guard let row = model.materials(for: model.catalogueBrands.first ?? "").first else {
                t.expect(false, "the bundled catalogue should have a material")
                return
            }
            let source = Spool(identity: SpoolIdentity(vendorId: "0276", filamentId: "199999",
                                                       colorHex: "C12E1F", serialNumber: "000123"),
                               brand: row.brand, name: row.name, materialType: row.materialType,
                               colorHex: "C12E1F",
                               tagSource: .spoolworksWritten)
            model.clone(source)
            t.equal(model.selectedMaterial?.brand, row.brand, "matched by brand")
            t.equal(model.selectedMaterial?.name, row.name, "and by name")
            t.equal(model.writeBlocker, nil, "so the tags can be written")
        }
    },

    test("Open it on a duplicate shows that spool whatever the filter") { t in
        onMain {
            let (model, inventory, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1, serialNumber: "000123") else { return }
            let owner = inventory.spool(from: record)
            inventory.add(owner)
            inventory.add(sampleSpool("000002", percent: 5))
            inventory.filter = .low

            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.duplicate?.id, owner.id, "flagged as already in stock")
            model.openDuplicate()
            t.equal(inventory.selected?.id, owner.id,
                    "the duplicate itself is opened, not the first row the filter happens to list")
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


// MARK: - Logging a written spool

let writtenSpoolLoggingTests = TestSuite(name: "Logging a written spool", cases: [

    test("a verified write lands the spool in stock, unplaced") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else {
                t.record("could not build a record", file: #file, line: #line); return
            }

            let logged = model.logWrittenSpool(record: record,
                                               materialLabel: "Creality · Hyper PLA")
            guard let logged = t.unwrap(logged, "logged spool") else { return }
            t.equal(model.inventory.active.count, 1, "in stock")
            t.equal(logged.tagSource, .spoolworksWritten, "credited to this app, not the factory")
            // The tag says nothing about where the spool is; asserting a shelf would invent a fact.
            t.equal(logged.location, .unknown, "unplaced until something observes it")
            t.equal(logged.brand, "Creality", "brand split out of the material label")
            t.equal(logged.name, "Hyper PLA", "and the name")
            t.equal(logged.remainingPercent, 100, "a freshly tagged spool is full")
        }
    },

    // Replacing a damaged tag is not the acquisition of a new spool.
    test("re-tagging a spool already in stock updates it rather than duplicating") { t in
        onMain {
            let (model, _, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }

            model.add(model.spool(from: record, brand: "Creality", name: "Hyper PLA",
                                  location: .cfs(box: "T1", slot: "B")))
            model.logWrittenSpool(record: record, materialLabel: "Creality · Hyper PLA")

            t.equal(model.inventory.active.count, 1, "still one spool, not two")
            guard let after = t.unwrap(model.inventory.active.first, "spool") else { return }
            t.equal(after.location, .cfs(box: "T1", slot: "B"), "where it was is not forgotten")
            t.equal(after.tagSource, .spoolworksWritten, "but the tag source is updated")
            t.expect(after.usage.contains { $0.detail.contains("rewritten") },
                     "and the rewrite is on the record")
        }
    },


])


// MARK: - Upload defaults

let uploadDefaultsTests = TestSuite(name: "Upload defaults", cases: [

    // The setting was inverted from "prevent" to "allow". A printer configured before the rename
    // must keep the behaviour its owner chose rather than silently flipping to the opposite.
    test("an existing prevent_ preference migrates to its inverse") { t in
        onMain {
            let suite = "sw-upload-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }

            // Someone who had deliberately allowed updates under the old spelling.
            defaults.set(false, forKey: "prevent_K2")
            t.expect(PrinterSettings.allowDatabaseUpdates(for: .k2, in: defaults),
                     "prevent=false becomes allow=true")

            defaults.removeObject(forKey: "prevent_K2")
            defaults.set(true, forKey: "prevent_K1")
            t.expect(!PrinterSettings.allowDatabaseUpdates(for: .k1, in: defaults),
                     "prevent=true becomes allow=false")
        }
    },

    // Blocking updates is the safe answer: leaving them on lets the printer's updater overwrite
    // the filaments you just pushed.
    test("updates are disallowed by default") { t in
        onMain {
            let suite = "sw-upload-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }
            t.expect(!PrinterSettings.allowDatabaseUpdates(for: .k2, in: defaults),
                     "off for a fresh printer")
        }
    },

    test("writing the new preference retires the old key") { t in
        onMain {
            let suite = "sw-upload-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }

            defaults.set(true, forKey: "prevent_K2")
            PrinterSettings.setAllowDatabaseUpdates(true, for: .k2, in: defaults)
            t.expect(defaults.object(forKey: "prevent_K2") == nil, "old key removed")
            t.expect(PrinterSettings.allowDatabaseUpdates(for: .k2, in: defaults),
                     "and the new one stands")
        }
    },

    // Reboot is only offered while updates are allowed, so blocking them must clear it — otherwise
    // a hidden "yes" springs back when they are re-enabled and the upload honours a choice the
    // user can no longer see.
    test("blocking updates clears the reboot preference") { t in
        onMain {
            let suite = "sw-upload-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }

            PrinterSettings.setAllowDatabaseUpdates(true, for: .k2, in: defaults)
            PrinterSettings.setRebootAfterUpload(true, for: .k2, in: defaults)
            t.expect(PrinterSettings.rebootAfterUpload(for: .k2, in: defaults), "reboot is on")

            // Derived, not stored: blocking updates reports reboot as off whatever is on disk.
            PrinterSettings.setAllowDatabaseUpdates(false, for: .k2, in: defaults)
            t.expect(!PrinterSettings.rebootAfterUpload(for: .k2, in: defaults),
                     "blocked updates means no reboot")

            // ...and the user's actual choice survives, rather than being reset.
            PrinterSettings.setAllowDatabaseUpdates(true, for: .k2, in: defaults)
            t.expect(PrinterSettings.rebootAfterUpload(for: .k2, in: defaults),
                     "re-allowing restores the choice they made")
        }
    },

    // A printer whose `allow` value arrived by migration never went through the setter, so an
    // invariant enforced only on write left the settings screen showing a disabled toggle
    // switched on — misstating what an upload would do.
    test("a migrated printer still reports reboot off while updates are blocked") { t in
        onMain {
            let suite = "sw-upload-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }

            // Exactly the on-disk shape of a printer configured before the rename.
            defaults.set(true, forKey: "prevent_K2")
            defaults.set(true, forKey: "reboot_K2")

            t.expect(!PrinterSettings.allowDatabaseUpdates(for: .k2, in: defaults),
                     "migrated to blocked")
            t.expect(!PrinterSettings.rebootAfterUpload(for: .k2, in: defaults),
                     "and reboot reports off without the setter ever running")
        }
    },
])


// MARK: - The write form

let writeFormDefaultsTests = TestSuite(name: "Write form defaults", cases: [

    // Two spools tagged back to back must not collide — that is the whole point of randomising.
    test("consecutive drafts do not share a serial") { t in
        let a = SpoolDraft(), b = SpoolDraft()
        t.expect(a.serialNumber != b.serialNumber,
                 "two drafts, two serials (got \(a.serialNumber) twice)")
        t.expect(a.serialNumber != SpoolRecord.defaultSerialNumber, "and neither is 000001")
    },

    // A form that arrives claiming a material would put that material on the tag if a write
    // started before anyone looked at it. Blank cannot be written until a choice is made.
    test("a fresh form is blank and therefore not writable") { t in
        let draft = SpoolDraft()
        t.equal(draft.materialID, "", "no material chosen")
        t.expect(!draft.isValid, "so it cannot be written yet")
        t.expect(!draft.validationIssues.isEmpty, "and it says what is missing")
    },

    // The randomised serial must not make an untouched form look edited — both sides of the
    // comparison have to start from the same draft.
    test("a freshly built model does not report itself edited") { t in
        onMain {
            let monitor = ReaderMonitor()
            let suite = "sw-draft-\(UUID().uuidString)"
            guard let defaults = UserDefaults(suiteName: suite) else { return }
            defer { defaults.removePersistentDomain(forName: suite) }
            let model = TagViewModel(monitor: monitor,
                                     toasts: ToastCenter(),
                                     settings: AppSettings(defaults: defaults),
                                     defaults: defaults)
            t.expect(!model.draftIsEdited, "untouched")
            t.equal(model.draft.serialNumber, model.draftBaseline.serialNumber,
                    "including the random serial")
        }
    },
])


// MARK: - Intake auto-read

@MainActor
private func makeIntake() -> (IntakeViewModel, InventoryViewModel, URL) {
    let (inventory, _, dir) = makeInventory()
    let model = IntakeViewModel(monitor: ReaderMonitor(),
                                inventory: inventory,
                                materials: MaterialsViewModel.previewValue(),
                                toasts: ToastCenter())
    return (model, inventory, dir)
}

/// An intake model over the bundled catalogue, for the cases that need real brands and ids. The
/// preview catalogue `makeIntake()` uses is empty, which is what every other case wants.
@MainActor
private func makeCatalogueIntake() async -> (IntakeViewModel, InventoryViewModel, () -> Void) {
    let catalogue = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-cat-\(UUID().uuidString)", isDirectory: true)
    let materials = MaterialsViewModel(storage: MaterialStorage(directory: catalogue))
    await materials.load()
    let (inventory, _, dir) = makeInventory()
    let model = IntakeViewModel(monitor: ReaderMonitor(),
                                inventory: inventory,
                                materials: materials,
                                toasts: ToastCenter())
    return (model, inventory, {
        try? FileManager.default.removeItem(at: catalogue)
        try? FileManager.default.removeItem(at: dir)
    })
}

private func read(uid: [UInt8], record: SpoolRecord?) -> TagReadResult {
    TagReadResult(uid: uid,
                  derivedKey: MifareKey.default,
                  isProgrammed: record != nil,
                  sector1Key: MifareKey.default,
                  sector1KeyType: .keyA,
                  decryptedSector1: [UInt8](repeating: 0, count: 48),
                  record: record,
                  recordError: nil,
                  sector2: nil,
                  printerType: nil)
}

let intakeAutoReadTests = TestSuite(name: "Intake auto-read", cases: [

    // The user presses nothing: a tag landing on the reader fills the next empty slot.
    test("a tag fills the first slot without anyone pressing Read") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }

            t.equal(model.tagsHandled, 0, "nothing read yet")
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.tagsHandled, 1, "one slot filled")
            t.equal(model.filamentId, record.filamentId, "and the form took the payload")
            t.equal(model.tagProgress, "1 of 2 read", "progress")
        }
    },

    // A spool's two tags carry the SAME payload and different UIDs — so the UID is the key.
    // Presenting one tag twice must not tick off the second.
    test("the same tag presented twice does not fill both slots") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }

            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.tagsHandled, 1, "still one")
        }
    },

    test("the spool's second tag — same payload, different UID — fills the second slot") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }

            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            model.absorb(read(uid: [9, 9, 9, 9], record: record))
            t.equal(model.tagsHandled, 2, "both slots")
            t.equal(model.tagProgress, "2 of 2 read", "progress")
        }
    },

    // A second spool presented before the first is confirmed would otherwise build one record out
    // of two different spools' tags.
    test("a different spool is refused rather than filling the empty slot") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let first = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                               filamentLength: .kg1),
                  let other = try? SpoolRecord(materialId: "02003", colorRGB: "8A8A88",
                                               filamentLength: .kg1) else { return }

            model.absorb(read(uid: [1, 2, 3, 4], record: first))
            model.absorb(read(uid: [5, 6, 7, 8], record: other))

            t.equal(model.tagsHandled, 1, "the second slot stays empty")
            t.expect(model.mismatch != nil, "and the screen says why")
            t.equal(model.filamentId, first.filamentId, "the form still holds the first spool")
        }
    },

    // Method B's slots are for writing blank tags, and a write must stay behind its confirmation.
    test("a tag arriving in Method B fills nothing") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }
            model.method = .manual
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.tagsHandled, 0, "writing is never automatic")
        }
    },

    test("a blank tag says what to do instead of filling a slot") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            model.absorb(read(uid: [1, 2, 3, 4], record: nil))
            t.equal(model.tagsHandled, 0, "nothing filled")
            t.expect(model.failure?.contains("Method B") == true, "and points at Method B")
        }
    },

    test("starting over forgets the tags already seen") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            model.reset()
            t.equal(model.tagsHandled, 0, "cleared")

            // The very same tag must be readable again after a reset.
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.tagsHandled, 1, "and it counts again")
        }
    },

    // Tag A absorbed, tag B refused as a different spool, Discard — B is still on the reader,
    // and the next read of it has to count even though it is a UID the model has just seen. The
    // view used to key absorption on that UID, so an equal value after the reset never fired.
    test("a tag refused as a mismatch counts once the intake it clashed with is discarded") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let first = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                               filamentLength: .kg1),
                  let other = try? SpoolRecord(materialId: "02003", colorRGB: "8A8A88",
                                               filamentLength: .kg1) else { return }
            model.absorb(read(uid: [1, 2, 3, 4], record: first))
            model.absorb(read(uid: [5, 6, 7, 8], record: other))
            t.expect(model.mismatch != nil, "refused while the first spool is in progress")

            model.reset()
            model.absorb(read(uid: [5, 6, 7, 8], record: other))
            t.equal(model.tagsHandled, 1, "the same read, presented again, fills the first slot")
            t.equal(model.mismatch, nil, "no clash left")
            t.equal(model.filamentId, other.filamentId, "and the form holds the second spool")
        }
    },
])


// MARK: - One reader, one path

let intakeReaderContentionTests = TestSuite(name: "Intake reader contention", cases: [

    // The manual button used to open a second card session while TagViewModel was auto-reading —
    // two models contending for one reader, which is how a read wedges mid-scan. And absorb()
    // began with `guard !busy`, so the read it was called from silently discarded its own result.
    test("absorbing works while the model reports itself busy") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1) else { return }

            model.setBusy(true)
            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.tagsHandled, 1, "the result is not discarded")
        }
    },
])


// MARK: - Intake slot states

let intakeSlotStateTests = TestSuite(name: "Intake slot states", cases: [

    // The row used to derive "ready"/"waiting" from a single boolean, with no state for work in
    // progress and none for verified — so it flickered between two words and never confirmed a
    // tag had actually been written.
    test("only the next undone slot is ready; the other waits") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            model.method = .manual
            t.equal(model.tags[0].state, .ready, "the first is next")
            t.equal(model.tags[1].state, .waiting, "the second waits its turn")
        }
    },

    test("the reader's activity shows on the slot in flight, and only that one") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            model.method = .manual
            model.activityLabel = "Writing tag…"

            t.equal(model.tags[0].state, .working("Writing tag…"), "the one being worked on")
            t.expect(model.tags[0].state.isWorking, "and it reports itself busy, for the spinner")
            t.equal(model.tags[1].state, .waiting, "the other is untouched")
        }
    },

    test("a verified write marks a slot done and the next becomes ready") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            model.method = .manual

            model.absorbWrite(uid: [1, 2, 3, 4])
            t.equal(model.tags[0].state, .done, "first verified")
            t.equal(model.tags[1].state, .ready, "second is now next")
            t.equal(model.tagSummary, "1 of 2 written and verified", "and the count says so")

            model.absorbWrite(uid: [9, 9, 9, 9])
            t.equal(model.tags[1].state, .done, "both verified")
            t.equal(model.tagSummary, "2 of 2 written and verified", "count")
        }
    },

    // A spool tagged on one side only fails to read half the time it is loaded. Writing the same
    // blank tag twice must not claim both sides are done.
    test("writing the same tag twice does not claim both slots") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            model.method = .manual
            model.absorbWrite(uid: [1, 2, 3, 4])
            model.absorbWrite(uid: [1, 2, 3, 4])
            t.equal(model.tagsHandled, 1, "still one side done")
            t.equal(model.tags[1].state, .ready, "the second is still outstanding")
        }
    },

    // Arming has to stop once both are done, or a third tag laid down while tidying up gets
    // written.
    test("arming drops once both tags are written") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            model.method = .manual
            model.catalogueBrand = model.catalogueBrands.first ?? ""
            model.absorbWrite(uid: [1, 2, 3, 4])
            model.absorbWrite(uid: [9, 9, 9, 9])
            t.expect(!model.isArmedToWrite, "no longer armed")
        }
    },

    test("scanning never arms a write") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            t.expect(model.isScan, "method A")
            t.expect(!model.isArmedToWrite, "reading is not writing")
            model.absorbWrite(uid: [1, 2, 3, 4])
            t.equal(model.tagsHandled, 0, "and a write outcome is ignored here")
        }
    },

    // "Write now" on the second row with the first row's tag still on the reader rewrites that
    // tag. The confirmation sheet used to tick the second slot off by index regardless; a write
    // now counts only through the UID, so the same tag stays one side.
    test("rewriting the first tag from the second slot does not claim both sides") { t in
        onMain {
            let (model, _, dir) = makeIntake()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1, serialNumber: "424242") else { return }
            model.method = .manual
            model.absorbWrite(uid: [1, 2, 3, 4], record: record)
            t.equal(model.tags[1].state, .ready, "the second slot is next")

            // The second slot's write lands on the same physical tag.
            model.absorbWrite(uid: [1, 2, 3, 4], record: record)
            t.equal(model.tagsHandled, 1, "still one side")
            t.equal(model.tags[1].state, .ready, "the second is still outstanding")
            t.equal(model.tagSummary, "1 of 2 written and verified", "and the summary says so")
            t.expect(!model.allTagsHandled, "nothing claims the spool is done")
        }
    },
])
