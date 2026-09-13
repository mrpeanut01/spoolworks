import Foundation
@testable import SpoolworksUI
@testable import SpoolworksCore

// Attaching a tag to a spool that went into stock without one — from Inventory, from a read on
// Read / identify or Intake, and from the CFS. The thread through all of it: a Creality factory tag
// names a filament and a colour, not a spool, so its record being in stock already says nothing
// about which spool is on the reader.

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

// MARK: - Fixtures

@MainActor
private func makeInventory() -> (InventoryViewModel, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-attach-\(UUID().uuidString)", isDirectory: true)
    return (InventoryViewModel(store: InventoryStore(directory: dir), toasts: ToastCenter()), dir)
}

/// An Intake model over the bundled catalogue, so a tag's filament id resolves to a brand and name.
@MainActor
private func makeCatalogueIntake() async -> (IntakeViewModel, InventoryViewModel, () -> Void) {
    let catalogue = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-attach-cat-\(UUID().uuidString)", isDirectory: true)
    let materials = MaterialsViewModel(storage: MaterialStorage(directory: catalogue))
    await materials.load()
    let (inventory, dir) = makeInventory()
    let model = IntakeViewModel(monitor: ReaderMonitor(),
                                inventory: inventory,
                                materials: materials,
                                toasts: ToastCenter())
    return (model, inventory, {
        try? FileManager.default.removeItem(at: catalogue)
        try? FileManager.default.removeItem(at: dir)
    })
}

/// A factory Hyper PLA tag: serial `000001`, like every Creality spool of that filament and colour.
private func factoryRecord(serial: String = "000001") -> SpoolRecord? {
    try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F", filamentLength: .kg1,
                     serialNumber: serial)
}

/// A spool counted onto the shelf still sealed, so nothing about it came off a tag.
private func shelfSpool(colour: String = "C8301F") -> Spool {
    Spool(brand: "Creality", name: "Hyper PLA", materialType: "PLA",
          colorHex: colour, colorName: "Red",
          location: .shelf("Shelf"), remainingSource: "Counted onto the shelf, assumed full",
          tagSource: .untagged)
}

private func read(uid: [UInt8], record: SpoolRecord?) -> TagReadResult {
    TagReadResult(uid: uid,
                  derivedKey: MifareKey.default,
                  isProgrammed: false,
                  sector1Key: MifareKey.default,
                  sector1KeyType: .keyA,
                  decryptedSector1: [UInt8](repeating: 0, count: 48),
                  record: record,
                  recordError: nil,
                  sector2: nil,
                  printerType: nil)
}

private func slot(_ id: String, percent: String) -> CFSSlot {
    CFSSlot(materialId: id,
            remainLen: percent,
            filamentId: "101001",
            brand: "Creality",
            name: "Hyper PLA",
            materialType: "PLA",
            venderId: "0276",
            color: "#0C12E1F",
            filamentLen: "0165",
            serialNum: "000001",
            rfid: 2)
}

private func boxInfo(_ slots: [CFSSlot]) -> MaterialBoxInfo {
    MaterialBoxInfo(material: MaterialSection(state: "connect",
                                              info: [CFSBox(boxID: "T1",
                                                            state: "connect",
                                                            temperature: "27",
                                                            humidity: "39",
                                                            version: "1.1.2",
                                                            list: slots)]))
}

// MARK: - Attaching and pairing

let tagAttachTests = TestSuite(name: "Attaching a tag to an untagged spool", cases: [

    // The reported bug: the attach was refused because a spool in the CFS already carried the
    // record, and a shelf of two identical spools could never both be tagged.
    test("a factory tag attaches even though a loaded spool carries the same record") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = factoryRecord() else { t.expect(false, "record"); return }
            let loaded = model.spool(from: record, brand: "Creality", name: "Hyper PLA",
                                     materialType: "PLA", location: .cfs(box: "T1", slot: "A"))
            model.add(loaded)
            let shelf = shelfSpool()
            model.add(shelf)

            model.attachTag(to: shelf)
            t.expect(model.attachTag(record: record, materialType: "PLA",
                                     source: .crealityFactory, readUIDs: [[1, 2, 3, 4]]),
                     "attached")
            t.equal(model.inventory.spool(id: shelf.id)?.identity, SpoolIdentity(record: record),
                    "the shelf spool carries the tag's identity")
            t.equal(model.inventory.spool(id: shelf.id)?.tagSource, .crealityFactory, "as a factory tag")
            t.equal(model.awaitingTagFor, nil, "the request is honoured")
            t.equal(model.inventory.spool(id: loaded.id)?.location, .cfs(box: "T1", slot: "A"),
                    "and the loaded twin is untouched")
        }
    },

    test("a tag with a serial of its own that belongs to another spool is still refused") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = factoryRecord(serial: "005150") else { t.expect(false, "record"); return }
            model.add(model.spool(from: record, tagSource: .spoolworksWritten))
            let shelf = shelfSpool()
            model.add(shelf)

            model.attachTag(to: shelf)
            t.expect(!model.attachTag(record: record, materialType: "PLA", readUIDs: [[1, 2, 3, 4]]),
                     "refused — that tag was written for one spool")
            t.equal(model.inventory.spool(id: shelf.id)?.identity, nil, "the shelf spool is unchanged")
            t.equal(model.awaitingTagFor, shelf.id, "and still waiting for the right tag")
            t.equal(model.pairing, nil, "with nothing paired")
        }
    },

    test("the first side waits for the second, which has to carry the same record") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = factoryRecord(),
                  let other = try? SpoolRecord(materialId: "01001", colorRGB: "FFFFFF",
                                               filamentLength: .kg1, serialNumber: "000001")
            else { t.expect(false, "records"); return }
            let shelf = shelfSpool()
            model.add(shelf)
            model.attachTag(to: shelf)
            model.attachTag(record: record, materialType: "PLA", source: .crealityFactory,
                            readUIDs: [[1, 2, 3, 4]])

            guard let pairing = t.unwrap(model.pairing, "a pairing is waiting") else { return }
            t.expect(!pairing.isComplete, "for the other side")
            t.equal(model.absorbPairedRead(uid: [1, 2, 3, 4], record: record), .sameTag,
                    "the same tag presented again is not the other side")

            if case .mismatch = model.absorbPairedRead(uid: [9, 9, 9, 9], record: other) {} else {
                t.expect(false, "a different record is refused")
            }
            t.expect(model.pairing?.isComplete == false, "and does not count")

            t.equal(model.absorbPairedRead(uid: [5, 6, 7, 8], record: record), .completed,
                    "the other side completes it")
            t.expect(model.pairing?.isComplete == true, "both sides seen")
            t.equal(model.inventory.spool(id: shelf.id)?.usage.first?.detail,
                    "Second tag read — both sides match", "and the log says so")
        }
    },

    test("both sides read up front finish at once, and a write does not wait for a read") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = factoryRecord(),
                  let written = factoryRecord(serial: "482913") else { t.expect(false, "records"); return }
            let both = shelfSpool()
            let blank = shelfSpool(colour: "C12E1F")
            model.add(both)
            model.add(blank)

            model.attachTag(to: both)
            model.attachTag(record: record, materialType: "PLA", source: .crealityFactory,
                            readUIDs: [[1, 2, 3, 4], [5, 6, 7, 8]])
            t.expect(model.pairing?.isComplete == true, "two reads complete the pair")
            t.equal(model.inventory.spool(id: both.id)?.usage.first?.detail,
                    "Both tags read and attached", "logged as both")

            model.attachTag(to: blank)
            model.attachTag(record: written, materialType: "PLA")
            t.equal(model.pairing, nil, "a write has its own second-side prompt")
            t.equal(model.inventory.spool(id: blank.id)?.usage.first?.detail,
                    "Tag written and verified", "and is logged as a write")
        }
    },

    test("cancelling, or retiring the spool, ends the pairing") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = factoryRecord() else { t.expect(false, "record"); return }
            let shelf = shelfSpool()
            model.add(shelf)

            model.attachTag(to: shelf)
            model.attachTag(record: record, materialType: "PLA", readUIDs: [[1, 2, 3, 4]])
            model.cancelTagRequest()
            t.equal(model.pairing, nil, "cancelled")

            model.attachTag(to: shelf)
            model.attachTag(record: record, materialType: "PLA", readUIDs: [[1, 2, 3, 4]])
            guard let spool = model.inventory.spool(id: shelf.id) else { return }
            model.confirmRetire(spool)
            t.equal(model.pairing, nil, "a pairing does not outlive its spool")
        }
    },

    test("a read tag is offered to the untagged spool it looks like") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            guard let record = factoryRecord() else { t.expect(false, "record"); return }
            let shelf = shelfSpool()
            model.add(shelf)
            t.equal(model.untaggedLookalikes(for: record, brand: "Creality", name: "Hyper PLA").map(\.id),
                    [shelf.id], "offered")
            t.equal(model.untaggedLookalikes(for: record, brand: "", name: "").count, 0,
                    "but not when the catalogue cannot say what the tag's filament is")
        }
    },
])

// MARK: - The CFS

let cfsLookalikeTests = TestSuite(name: "CFS slots like an untagged spool", cases: [

    test("a slot like an untagged shelf spool waits for an answer instead of becoming a second spool") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            model.add(shelfSpool())

            model.reconcile(with: boxInfo([slot("C", percent: "100")]))
            t.equal(model.pendingLookalikes.map(\.label), ["T1C"], "asked about")
            t.equal(model.inventory.active.count, 1, "and nothing added")
        }
    },

    test("yes puts the shelf spool in the slot, with the printer's reading, without scanning") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let shelf = shelfSpool()
            model.add(shelf)
            let info = boxInfo([slot("C", percent: "80")])
            model.reconcile(with: info)
            guard let held = t.unwrap(model.pendingLookalikes.first, "held") else { return }

            model.confirmLookalike(held, as: shelf.id)
            guard let spool = t.unwrap(model.inventory.spool(id: shelf.id), "still there") else { return }
            t.equal(spool.location, .cfs(box: "T1", slot: "C"), "loaded into its slot now, not in 30 s")
            t.equal(spool.remainingPercent, 80, "with the CFS's figure")
            t.equal(spool.identity, held.identity, "carrying the slot's identity")
            t.equal(spool.tagSource, .crealityFactory, "read by the printer")
            t.equal(model.pendingLookalikes.count, 0, "answered")
            t.equal(model.inventory.active.count, 1, "one record")

            model.reconcile(with: info)
            t.equal(model.pendingLookalikes.count, 0, "and the next poll does not ask again")
            t.equal(model.inventory.active.count, 1, "or discover a second")
        }
    },

    test("no discovers it as a spool of its own, and is not asked again") { t in
        onMain {
            let (model, dir) = makeInventory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let shelf = shelfSpool()
            model.add(shelf)
            let info = boxInfo([slot("C", percent: "100")])
            model.reconcile(with: info)
            guard let held = t.unwrap(model.pendingLookalikes.first, "held") else { return }

            model.declineLookalike(held)
            t.equal(model.inventory.active.count, 2, "a second spool")
            t.equal(model.inventory.spool(id: shelf.id)?.location, .shelf("Shelf"),
                    "and the shelf spool stays where it is")

            model.reconcile(with: info)
            t.equal(model.pendingLookalikes.count, 0, "not asked again")
            t.equal(model.inventory.active.count, 2, "and not discovered twice")
        }
    },
])

// MARK: - Intake

let intakeTwinTests = TestSuite(name: "Intake of a tag already in stock", cases: [

    test("a factory tag already in stock can be added as another spool") { t in
        onMain {
            let (model, inventory, cleanup) = await makeCatalogueIntake()
            defer { cleanup() }
            guard let record = factoryRecord() else { t.expect(false, "record"); return }
            let loaded = inventory.spool(from: record, location: .cfs(box: "T1", slot: "A"))
            inventory.add(loaded)

            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.duplicate?.id, loaded.id, "reads the same as the loaded spool")
            t.expect(model.duplicateIsAmbiguous, "which a factory tag cannot tell apart")
            t.expect(!model.canConfirm, "so nothing is added without asking")

            model.addAnotherLikeDuplicate()
            t.expect(model.canConfirm, "continuing as a new spool is allowed")
            model.confirm()
            t.equal(inventory.inventory.active.count, 2, "two spools")
            t.equal(Set(inventory.inventory.active.compactMap(\.identity)).count, 1,
                    "sharing one tag record, as factory twins do")
        }
    },

    test("a tag with a serial of its own offers no twin") { t in
        onMain {
            let (model, inventory, cleanup) = await makeCatalogueIntake()
            defer { cleanup() }
            guard let record = factoryRecord(serial: "005150") else { t.expect(false, "record"); return }
            inventory.add(inventory.spool(from: record, tagSource: .spoolworksWritten))

            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.expect(!model.duplicateIsAmbiguous, "that tag is that spool")
            model.addAnotherLikeDuplicate()
            t.expect(!model.canConfirm, "and a copy is still refused")
        }
    },

    test("a tag like an untagged spool in stock is offered to it, twin or not") { t in
        onMain {
            let (model, inventory, cleanup) = await makeCatalogueIntake()
            defer { cleanup() }
            guard let record = factoryRecord() else { t.expect(false, "record"); return }
            inventory.add(inventory.spool(from: record, location: .cfs(box: "T1", slot: "A")))
            let shelf = shelfSpool()
            inventory.add(shelf)

            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            t.equal(model.lookalike?.id, shelf.id, "the untagged spool is offered")

            t.expect(model.attachToLookalike(), "attached")
            t.equal(inventory.inventory.spool(id: shelf.id)?.identity, SpoolIdentity(record: record),
                    "to the shelf spool")
            t.equal(inventory.inventory.active.count, 2, "without a third record")
            t.expect(inventory.pairing?.isComplete == false, "waiting for the other side")
            t.equal(model.decoded, nil, "and Intake is ready for the next spool")
        }
    },

    test("declining the offer lets the tag be added as a new spool") { t in
        onMain {
            let (model, inventory, cleanup) = await makeCatalogueIntake()
            defer { cleanup() }
            guard let record = factoryRecord() else { t.expect(false, "record"); return }
            inventory.add(inventory.spool(from: record, location: .cfs(box: "T1", slot: "A")))
            inventory.add(shelfSpool())

            model.absorb(read(uid: [1, 2, 3, 4], record: record))
            model.dismissLookalike()
            t.equal(model.lookalike, nil, "the offer is gone")
            t.expect(model.canConfirm, "and the twin can be added")

            model.absorb(read(uid: [5, 6, 7, 8], record: record))
            t.equal(model.lookalike, nil, "the second side does not bring the offer back")
        }
    },
])
