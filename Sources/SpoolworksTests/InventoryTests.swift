import Foundation
@testable import SpoolworksCore

// MARK: - Fixtures

private func makeSpool(serial: String = "000001",
                       filamentId: String = "101001",
                       vendor: String = "0276",
                       colour: String = "C12E1F",
                       percent: Double = 100,
                       net: Int = 1000,
                       location: SpoolLocation = .unknown,
                       tagSource: TagSource = .crealityFactory,
                       identity: Bool = true) -> Spool {
    Spool(identity: identity ? SpoolIdentity(vendorId: vendor,
                                             filamentId: filamentId,
                                             colorHex: colour,
                                             serialNumber: serial) : nil,
          brand: "Creality",
          name: "Hyper PLA",
          materialType: "PLA",
          colorHex: colour,
          colorName: "Red",
          netWeightGrams: net,
          remainingPercent: percent,
          location: location,
          tagSource: tagSource)
}

private func slot(_ id: String,
                  serial: String,
                  percent: String,
                  filamentId: String = "101001",
                  vendor: String = "0276",
                  colour: String = "#0C12E1F",
                  rfid: Int = 2) -> CFSSlot {
    CFSSlot(materialId: id,
            remainLen: percent,
            filamentId: filamentId,
            brand: "Creality",
            name: "Hyper PLA",
            materialType: "PLA",
            venderId: vendor,
            color: colour,
            filamentLen: "0165",
            serialNum: serial,
            rfid: rfid)
}

private func boxInfo(_ slots: [CFSSlot], boxID: String = "T1") -> MaterialBoxInfo {
    MaterialBoxInfo(material: MaterialSection(state: "connect",
                                              info: [CFSBox(boxID: boxID,
                                                            state: "connect",
                                                            temperature: "27",
                                                            humidity: "39",
                                                            version: "1.1.2",
                                                            list: slots)]))
}

// MARK: - Spool

let spoolModelTests = TestSuite(name: "Spool model", cases: [

    // The tag's colour field is seven characters — an unknown leading nibble plus RRGGBB — and the
    // CFS prefixes its own with '#'. A swatch fed the raw field renders the wrong colour, so
    // normalisation is asserted for every shape the two sources actually produce.
    test("colour hex is normalised from every source shape") { t in
        t.equal(Spool.normaliseHex("0C12E1F"), "C12E1F", "tag field, 7 chars")
        t.equal(Spool.normaliseHex("#0C12E1F"), "C12E1F", "CFS field, # + 7 chars")
        t.equal(Spool.normaliseHex("#C12E1F"), "C12E1F", "# + 6 chars")
        t.equal(Spool.normaliseHex("c12e1f"), "C12E1F", "lower case")
        t.equal(Spool.normaliseHex("  C12E1F "), "C12E1F", "surrounding space")
    },

    test("remaining percent is clamped on the way in") { t in
        var s = makeSpool(percent: 100)
        s.remainingPercent = 140
        t.equal(s.remainingPercent, 100, "above range")
        s.remainingPercent = -20
        t.equal(s.remainingPercent, 0, "below range")
    },

    test("grams are derived from net weight and percent") { t in
        let s = makeSpool(percent: 54, net: 1000)
        t.equal(s.remainingGrams, 540, "1 kg at 54%")
        t.equal(s.remainingGramsLabel, "≈ 540 g", "approximate when drawn from")

        let full = makeSpool(percent: 100, net: 750)
        t.equal(full.remainingGramsLabel, "750 g", "exact when untouched")
    },

    test("label combines brand, name and colour, and survives blanks") { t in
        t.equal(makeSpool().label, "Creality Hyper PLA · Red", "full")

        var noColour = makeSpool()
        noColour.colorName = ""
        t.equal(noColour.label, "Creality Hyper PLA", "no trailing separator when colour is unnamed")

        var empty = makeSpool()
        empty.brand = ""; empty.name = ""; empty.colorName = ""
        t.equal(empty.label, "Untitled spool", "never renders as an empty string")
    },

    // The design flags "2 low" across a fixture whose percentages are 12 and 33 plus eight higher
    // ones. A threshold of 20 or 25 would flag only one of them.
    test("low-stock threshold flags 12% and 33% but not 48%") { t in
        t.expect(makeSpool(percent: 12).isLow, "12% is low")
        t.expect(makeSpool(percent: 33).isLow, "33% is low")
        t.expect(!makeSpool(percent: 48).isLow, "48% is not low")
        t.equal(Spool.lowStockThresholdPercent, 35, "threshold")
    },

    // record(percent:) takes an absolute figure and derives the delta, because both real sources
    // report absolutes. If it took a delta the two could disagree.
    test("recording a new percent derives the signed delta") { t in
        var s = makeSpool(percent: 100, net: 1000)
        s.record(percent: 54, kind: .cfsPoll, detail: "CFS poll · T1A")
        t.equal(s.remainingPercent, 54, "new percent")
        t.equal(s.usage.count, 1, "one line appended")
        t.equal(s.usage[0].deltaGrams, -460, "delta in grams")
        t.equal(s.usage[0].amountLabel, "−460 g", "uses a real minus sign")

        s.record(percent: 60, kind: .adjustment, detail: "weigh-in")
        t.equal(s.usage[0].deltaGrams, 60, "a correction upward is positive")
        t.equal(s.usage.count, 2, "newest first")
    },

    test("a note records history without moving the figure") { t in
        var s = makeSpool(percent: 54)
        s.note(kind: .movement, detail: "Unloaded from T1A")
        t.equal(s.remainingPercent, 54, "unchanged")
        t.equal(s.usage[0].deltaGrams, 0, "zero delta")
    },

    test("untagged spools report em dashes rather than empty cells") { t in
        let s = makeSpool(tagSource: .untagged, identity: false)
        t.equal(s.serialLabel, "—", "serial")
        t.equal(s.filamentIdLabel, "—", "filament id")
        t.expect(s.isUntagged, "flagged untagged")
    },

    test("weight labels round to kilograms only when exact") { t in
        t.equal(Spool.weightLabel(1000), "1 kg")
        t.equal(Spool.weightLabel(750), "750 g")
        t.equal(Spool.weightLabel(250), "250 g")
    },
])

// MARK: - Identity

let spoolIdentityTests = TestSuite(name: "Spool identity", cases: [

    // A spool carries two tags with different UIDs and the same payload, and the CFS reports no
    // UID at all — so identity has to come from the payload.
    test("identity comes from vendor, filament, colour and serial") { t in
        let record = try SpoolRecord(materialId: "01001", colorRGB: "C12E1F", filamentLength: .kg1)
        let identity = SpoolIdentity(record: record)
        t.equal(identity.vendorId, record.vendorId, "vendor")
        t.equal(identity.filamentId, record.filamentId, "filament")
        t.equal(identity.serialNumber, record.serialNumber, "serial")
        t.equal(identity.colorHex, record.rgbHex, "colour, without the unknown leading nibble")
    },

    test("same serial under a different vendor is a different spool") { t in
        let a = SpoolIdentity(vendorId: "0276", filamentId: "101001",
                              colorHex: "C12E1F", serialNumber: "000001")
        let b = SpoolIdentity(vendorId: "0999", filamentId: "101001",
                              colorHex: "C12E1F", serialNumber: "000001")
        t.expect(a != b, "vendor participates in identity")
    },

    test("a tag read resolves to the inventory row it belongs to") { t in
        let record = try SpoolRecord(materialId: "01001", colorRGB: "C12E1F", filamentLength: .kg1)
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: record.serialNumber, filamentId: record.filamentId))
        t.expect(inventory.spool(matching: record) != nil, "matched")

        let other = try SpoolRecord(materialId: "02003", colorRGB: "8A8A88", filamentLength: .kg1)
        t.expect(inventory.spool(matching: other) == nil, "a different filament does not match")
    },

    test("a retired spool is not resurrected by presenting its tag") { t in
        var inventory = SpoolInventory()
        let spool = makeSpool()
        inventory.add(spool)
        inventory.retire(id: spool.id)
        t.expect(inventory.spool(identity: spool.identity!) == nil, "retired rows do not match")
    },
])

// MARK: - Inventory

let spoolInventoryTests = TestSuite(name: "Spool inventory", cases: [

    test("summary drops clauses that would read zero") { t in
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: "000001", percent: 80))
        inventory.add(makeSpool(serial: "000002", percent: 90))
        t.equal(inventory.summary, "2 spools", "healthy inventory says only the count")

        inventory.add(makeSpool(serial: "000003", percent: 12))
        inventory.add(makeSpool(serial: "000004", tagSource: .untagged, identity: false))
        t.equal(inventory.summary, "4 spools · 1 low · 1 untagged", "clauses appear as they apply")
    },

    test("one spool is singular") { t in
        var inventory = SpoolInventory()
        inventory.add(makeSpool())
        t.equal(inventory.summary, "1 spool")
    },

    test("filters partition the inventory the way the segmented control does") { t in
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: "000001", percent: 80, location: .cfs(box: "T1", slot: "A")))
        inventory.add(makeSpool(serial: "000002", percent: 12, location: .shelf("Shelf · bin 1")))
        inventory.add(makeSpool(serial: "000003", percent: 90, location: .externalHolder))
        inventory.add(makeSpool(serial: "000004", tagSource: .untagged, identity: false))

        t.equal(inventory.filtered(by: .all).count, 4, "all")
        t.equal(inventory.filtered(by: .onPrinter).count, 2, "CFS slot and external holder")
        // `.shelf` — one button meaning "anywhere but the printer" — is gone. A location filter
        // now names exactly one place, and matches on the value the spool actually holds.
        t.equal(inventory.filtered(by: .at(.shelf("Shelf · bin 1"))).count, 1, "that one place")
        t.equal(inventory.filtered(by: .at(.unknown)).count, 1, "and Unplaced is a place like any other")
        t.equal(inventory.filtered(by: .at(.shelf("Shelf"))).count, 0,
                "a different name is a different place — no prefix or fuzzy matching")
        t.equal(inventory.filtered(by: .low).count, 1, "low")
        t.equal(inventory.filtered(by: .untagged).count, 1, "untagged")
    },

    // The Retire dialog promises the last reading "stays on the usage record".
    test("retiring keeps the spool and its history") { t in
        var inventory = SpoolInventory()
        var spool = makeSpool(percent: 49)
        spool.record(percent: 49, kind: .intake, detail: "Intake · tag read")
        inventory.add(spool)

        inventory.retire(id: spool.id)
        t.equal(inventory.active.count, 0, "gone from the active list")
        t.equal(inventory.spools.count, 1, "still in the file")

        guard let retired = t.unwrap(inventory.spool(id: spool.id), "retired spool") else { return }
        t.expect(retired.isRetired, "flagged")
        t.expect(retired.usage.contains { $0.kind == .retirement }, "retirement is on the record")
        t.expect(retired.usage.contains { $0.kind == .intake }, "earlier history survives")
    },

    test("retiring twice does not append a second line") { t in
        var inventory = SpoolInventory()
        let spool = makeSpool()
        inventory.add(spool)
        inventory.retire(id: spool.id)
        inventory.retire(id: spool.id)
        guard let retired = t.unwrap(inventory.spool(id: spool.id), "spool") else { return }
        t.equal(retired.usage.filter { $0.kind == .retirement }.count, 1, "one retirement line")
    },

    test("updating an unknown id is a no-op rather than an insert") { t in
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: "000001"))
        inventory.update(makeSpool(serial: "999999"))
        t.equal(inventory.spools.count, 1, "a stale selection cannot resurrect a deleted row")
    },
])

// MARK: - Reconciliation

let inventoryReconcileTests = TestSuite(name: "Inventory reconciliation", cases: [

    test("a loaded slot updates the matching spool's location and remaining") { t in
        var inventory = SpoolInventory()
        let spool = makeSpool(serial: "000001", percent: 100)
        inventory.add(spool)

        let report = inventory.reconcile(with: boxInfo([slot("A", serial: "000001", percent: "54")]))

        guard let updated = t.unwrap(inventory.spool(id: spool.id), "spool") else { return }
        t.equal(updated.remainingPercent, 54, "took the CFS figure")
        t.equal(updated.location, .cfs(box: "T1", slot: "A"), "located in the slot")
        t.equal(report.updated.count, 1, "reported as updated")
        t.equal(report.discovered.count, 0, "nothing discovered")
    },

    // A 30 s poll would otherwise write 2,880 identical usage lines a day.
    test("an unchanged poll appends no usage line") { t in
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: "000001", percent: 54))
        let info = boxInfo([slot("A", serial: "000001", percent: "54")])

        inventory.reconcile(with: info)
        let afterFirst = inventory.active[0].usage.count
        let report = inventory.reconcile(with: info)

        t.equal(inventory.active[0].usage.count, afterFirst, "no new line")
        t.expect(report.isEmpty, "reported as no change")
    },

    test("a slot the inventory has never seen is discovered, not ignored") { t in
        var inventory = SpoolInventory()
        let report = inventory.reconcile(with: boxInfo([slot("B", serial: "000099", percent: "77")]))

        t.equal(report.discovered.count, 1, "one discovery")
        t.equal(inventory.active.count, 1, "added to stock")
        let found = inventory.active[0]
        t.equal(found.remainingPercent, 77, "with its measured figure")
        t.equal(found.location, .cfs(box: "T1", slot: "B"), "and its slot")
        t.equal(found.colorHex, "C12E1F", "colour normalised from the CFS '#0C12E1F' form")
        t.equal(found.tagSource, .crealityFactory, "an RFID-read slot is a factory tag")
        t.expect(found.usage.contains { $0.detail.contains("T1B") }, "says where it came from")
    },

    test("discovery can be refused") { t in
        var inventory = SpoolInventory()
        let report = inventory.reconcile(with: boxInfo([slot("B", serial: "000099", percent: "77")]),
                                         addingUnknown: false)
        t.expect(report.discovered.isEmpty, "nothing discovered")
        t.equal(inventory.active.count, 0, "inventory untouched")
    },

    test("a spool that leaves its slot loses its location but keeps its figure") { t in
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: "000001", percent: 100))
        inventory.reconcile(with: boxInfo([slot("A", serial: "000001", percent: "54")]))

        // Poll again with the slot now empty.
        let report = inventory.reconcile(with: boxInfo([]))

        let spool = inventory.active[0]
        t.equal(report.unloaded.count, 1, "reported as unloaded")
        t.equal(spool.location, .unknown, "no longer on the printer")
        t.equal(spool.remainingPercent, 54, "last measured figure stands")
        t.expect(spool.remainingSource.contains("Last reading"), "and the source says so")
        t.expect(spool.usage.contains { $0.detail.contains("Unloaded from") }, "move is on the record")
    },

    // A spool the user put on a shelf must not be dragged to .unknown by a poll that never
    // mentioned it.
    test("a shelved spool is untouched by a poll") { t in
        var inventory = SpoolInventory()
        var shelved = makeSpool(serial: "000002", percent: 90, location: .shelf("Shelf · bin 3"))
        shelved.remainingSource = "Manual record"
        inventory.add(shelved)

        let report = inventory.reconcile(with: boxInfo([slot("A", serial: "000001", percent: "54")]))

        guard let after = t.unwrap(inventory.spool(id: shelved.id), "shelved spool") else { return }
        t.equal(after.location, .shelf("Shelf · bin 3"), "still on its shelf")
        t.equal(after.usage.count, 0, "no history written")
        t.expect(!report.unloaded.contains(shelved.id), "not reported as unloaded")
    },

    test("a slot with no serial cannot be matched and is skipped") { t in
        var inventory = SpoolInventory()
        let anonymous = slot("C", serial: "", percent: "50")
        let report = inventory.reconcile(with: boxInfo([anonymous]))
        t.expect(report.isEmpty, "nothing to do")
        t.equal(inventory.active.count, 0, "no phantom row")
    },

    test("an unoccupied slot is not treated as a spool") { t in
        var inventory = SpoolInventory()
        let empty = CFSSlot(materialId: "D")
        let report = inventory.reconcile(with: boxInfo([empty]))
        t.expect(report.isEmpty, "no change")
        t.equal(inventory.active.count, 0, "no row for an empty slot")
    },

    test("the external holder locates its spool but reports no measurement") { t in
        var inventory = SpoolInventory()
        // Colour is part of identity, so the inventory row has to be the same green the
        // holder reports, not the fixture's default red.
        let spool = makeSpool(serial: "000004", colour: "3E9E4A", percent: 78)
        inventory.add(spool)

        var info = boxInfo([])
        let rackJSON = """
        {"attach": true, "selected": false, "rfid": 2, "editStatus": 1,
         "filamentId": "101001", "color": "#03E9E4A", "brand": "Creality", "name": "Ender PLA",
         "materialType": "PLA", "minTemp": 190, "maxTemp": 240,
         "venderId": "0276", "serialNum": "000004"}
        """
        info.rackMaterial = try JSONDecoder().decode(RackMaterial.self, from: Data(rackJSON.utf8))

        inventory.reconcile(with: info)
        guard let after = t.unwrap(inventory.spool(id: spool.id), "spool") else { return }
        t.equal(after.location, .externalHolder, "mounted on the holder")
        t.equal(after.remainingPercent, 78, "the holder has no sensor, so the figure is untouched")
        t.expect(after.remainingSource.contains("no sensor"), "and the source admits it")
    },

    test("twin spools keep their own places: one in a slot, one on the holder") { t in
        // T1B and T1D in the K2 dump share vendor, filament, colour and serial — a real pairing,
        // which is why the firmware groups them as auto-refill partners. Put one such pair in a
        // slot and on the holder and poll twice: each must stay where it is. The holder match
        // used to take the first spool of that identity, which was the slot's own, and move it;
        // the real holder spool was then "unloaded", and the next poll reversed both.
        var inventory = SpoolInventory()
        let onHolder = makeSpool(serial: "000004", colour: "3E9E4A", percent: 78,
                                 location: .externalHolder)
        let inSlot = makeSpool(serial: "000004", colour: "3E9E4A", percent: 60,
                               location: .cfs(box: "T1", slot: "B"))
        // Newest first, so the slot spool is the first identity match in the list.
        inventory.add(onHolder)
        inventory.add(inSlot)

        var info = boxInfo([slot("B", serial: "000004", percent: "60", colour: "#03E9E4A")])
        let rackJSON = """
        {"attach": true, "selected": false, "rfid": 2, "editStatus": 1,
         "filamentId": "101001", "color": "#03E9E4A", "brand": "Creality", "name": "Ender PLA",
         "materialType": "PLA", "minTemp": 190, "maxTemp": 240,
         "venderId": "0276", "serialNum": "000004"}
        """
        info.rackMaterial = try JSONDecoder().decode(RackMaterial.self, from: Data(rackJSON.utf8))

        for poll in 1...2 {
            let report = inventory.reconcile(with: info)
            t.expect(report.unloaded.isEmpty, "poll \(poll): nothing was unloaded")
            t.expect(report.updated.isEmpty, "poll \(poll): nothing moved")
            guard let slotSpool = t.unwrap(inventory.spool(id: inSlot.id), "slot spool"),
                  let holderSpool = t.unwrap(inventory.spool(id: onHolder.id), "holder spool")
            else { return }
            t.equal(slotSpool.location, .cfs(box: "T1", slot: "B"), "poll \(poll): the slot keeps its spool")
            t.equal(holderSpool.location, .externalHolder, "poll \(poll): the holder keeps its spool")
            t.equal(slotSpool.usage.count, 0, "poll \(poll): no movement written for the slot spool")
            t.equal(holderSpool.usage.count, 0, "poll \(poll): no movement written for the holder spool")
        }
    },

    test("a retired spool is not reclaimed by a poll that still lists its slot") { t in
        var inventory = SpoolInventory()
        let spool = makeSpool(serial: "000001")
        inventory.add(spool)
        inventory.retire(id: spool.id)

        let report = inventory.reconcile(with: boxInfo([slot("A", serial: "000001", percent: "54")]))
        t.equal(report.discovered.count, 1, "it comes back as a new, separate record")
        guard let retired = t.unwrap(inventory.spool(id: spool.id), "the retired row") else { return }
        t.expect(retired.isRetired, "the retired row stays retired")
    },
])

// MARK: - Persistence

let inventoryStoreTests = TestSuite(name: "Inventory persistence", cases: [

    test("a missing file is first run, not an error") { t in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-inv-\(UUID().uuidString)", isDirectory: true)
        let store = InventoryStore(directory: dir)
        let loaded = try store.load()
        t.equal(loaded.spools.count, 0, "empty inventory")
    },

    test("a percentage outside 0…100 in the file is clamped on load, not trusted") { t in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-inv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InventoryStore(directory: dir)
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: "000009", percent: 100))
        try store.save(inventory)

        // Property observers do not run during decode, so a hand-edited or corrupt figure used
        // to arrive verbatim and trap in `Int(...)` the first time the row rendered.
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        t.expect(text.contains("\"remainingPercent\" : 100"), "fixture assumption about the file's layout")
        try text.replacingOccurrences(of: "\"remainingPercent\" : 100", with: "\"remainingPercent\" : 1e300")
            .write(to: store.fileURL, atomically: true, encoding: .utf8)

        let loaded = try store.load()
        guard let spool = t.unwrap(loaded.spools.first, "the spool") else { return }
        t.equal(spool.remainingPercent, 100, "clamped on the way in")
        t.equal(spool.remainingLabel, "100%", "and renders without trapping")
        t.equal(spool.remainingGrams, 1000)
    },

    test("a usage figure that does not fit an Int renders blank rather than trapping") { t in
        let entry = UsageEntry(kind: .adjustment, detail: "corrupt", deltaGrams: 1e300)
        t.equal(entry.amountLabel, "—")
        t.equal(UsageEntry(kind: .adjustment, detail: "", deltaGrams: -38).amountLabel, "−38 g",
                "an ordinary figure is unchanged")
    },

    test("a saved inventory round-trips with its history intact") { t in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-inv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = InventoryStore(directory: dir)

        var inventory = SpoolInventory()
        var spool = makeSpool(serial: "000001", percent: 100, location: .cfs(box: "T1", slot: "A"))
        spool.record(percent: 54, kind: .cfsPoll, detail: "CFS poll · T1A")
        inventory.add(spool)
        inventory.add(makeSpool(serial: "000002", location: .shelf("Shelf · bin 2"),
                                tagSource: .untagged, identity: false))

        try store.save(inventory)
        let loaded = try store.load()

        t.equal(loaded.spools.count, 2, "both spools")
        guard let first = t.unwrap(loaded.spool(id: spool.id), "first spool") else { return }
        t.equal(first.remainingPercent, 54, "figure")
        t.equal(first.location, .cfs(box: "T1", slot: "A"), "location enum round-trips")
        t.equal(first.usage.count, 1, "history")
        t.equal(first.usage[0].deltaGrams, -460, "delta")
        t.equal(loaded.spools[0].location, .shelf("Shelf · bin 2"), "associated-value case round-trips")
    },

    // Starting empty on a corrupt file looks exactly like "the app lost all my spools".
    test("a corrupt file is reported rather than silently starting empty") { t in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-inv-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = InventoryStore(directory: dir)
        try Data("{ not json".utf8).write(to: store.fileURL)

        t.throwsError("loading a corrupt inventory") { _ = try store.load() }
    },

    test("saving creates the directory it needs") { t in
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sw-inv-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("nested", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        let store = InventoryStore(directory: dir)
        try store.save(SpoolInventory(spools: [makeSpool()]))
        t.expect(store.exists(), "file written")
    },
])
