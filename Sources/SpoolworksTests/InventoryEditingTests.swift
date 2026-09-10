import Foundation
@testable import SpoolworksUI
@testable import SpoolworksCore

// Editing a spool's location and remaining figure on the Inventory screen: the place list, the
// cascade that keeps it from orphaning spools, and the rule that decides who wins when a hand
// edit and the CFS poll disagree. See `docs/DECISIONS.md` D-011.

// MARK: - Pump

// Same shape as the pumps in UIStateTests / SpoolManagementUITests: both are file-private, so each
// suite file carries its own rather than one being promoted to shared API for the tests' benefit.
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

private func makeSpool(serial: String = "000123",
                       percent: Double = 100,
                       location: SpoolLocation = .unknown) -> Spool {
    Spool(identity: SpoolIdentity(vendorId: "0276", filamentId: "101001",
                                  colorHex: "C12E1F", serialNumber: serial),
          brand: "Creality", name: "Hyper PLA", materialType: "PLA",
          colorHex: "C12E1F", colorName: "Red",
          netWeightGrams: 1000,
          remainingPercent: percent,
          location: location,
          tagSource: .crealityFactory)
}

private func slot(_ id: String, serial: String = "000123", percent: String = "70") -> CFSSlot {
    CFSSlot(materialId: id,
            remainLen: percent,
            filamentId: "101001",
            brand: "Creality",
            name: "Hyper PLA",
            materialType: "PLA",
            venderId: "0276",
            color: "#0C12E1F",
            filamentLen: "0165",
            serialNum: serial,
            rfid: 2)
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

@MainActor
private func makeModel() -> (InventoryViewModel, UserDefaults, String, URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("sw-places-\(UUID().uuidString)", isDirectory: true)
    let suite = "sw-places-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite) ?? .standard
    let model = InventoryViewModel(store: InventoryStore(directory: dir),
                                   toasts: ToastCenter(),
                                   defaults: defaults)
    return (model, defaults, suite, dir)
}

/// The invariant the place list must never break: every active spool is either somewhere the
/// printer put it, or at a place the picker still offers.
@MainActor
private func noOrphans(_ model: InventoryViewModel, _ t: TestContext) {
    for spool in model.inventory.active where !spool.location.isOnPrinter {
        guard let name = model.places.name(for: spool.location) else {
            t.expect(false, "\(spool.serialLabel) is at \(spool.location) with no place name")
            continue
        }
        t.expect(model.places.contains(name),
                 "\(spool.serialLabel) is at “\(name)”, which the picker no longer offers")
    }
}

// MARK: - The list itself

let spoolPlacesTests = TestSuite(name: "Spool places", cases: [

    // The tool owner asked for exactly these four, in this order.
    test("a first run is seeded with Unplaced and Shelf") { t in
        // `CFS` and `Ext…` were seeded once and retired: they duplicated the two locations the
        // printer owns, which "On printer" already covers. See `SpoolPlaces.retiredSeeds`.
        t.equal(SpoolPlaces().names, ["Unplaced", "Shelf"], "seeded list")
    },

    // `.unknown` is where `reconcile` puts a spool the printer has stopped reporting, and where a
    // freshly tagged spool lands. A list that could lose it would strand those spools in a state
    // no picker row expresses.
    test("Unplaced is always present, always first, and cannot be renamed or removed") { t in
        var places = SpoolPlaces(names: ["Shelf", "Bin"])
        t.equal(places.names.first, "Unplaced", "put back at the front")

        t.expect(places.remove("Unplaced").problem != nil, "removal refused")
        t.expect(places.rename("Unplaced", to: "Nowhere").problem != nil, "rename refused")
        t.expect(places.contains("Unplaced"), "still there")

        // ...and case does not get round it.
        t.expect(places.remove("unplaced").problem != nil, "refused however it is spelled")
    },

    test("names are trimmed and unique regardless of case") { t in
        var places = SpoolPlaces(names: ["Shelf"])
        t.equal(places.add("  Bin 3  ").name, "Bin 3", "trimmed on the way in")
        t.expect(places.add("SHELF").problem != nil, "a re-cased duplicate is refused")
        t.expect(places.add("   ").problem != nil, "a blank name is refused")
        t.expect(places.add(String(repeating: "x", count: 41)).problem != nil, "too long")
        t.equal(places.names, ["Unplaced", "Shelf", "Bin 3"], "nothing else changed")

        // Normalising in the initialiser as well, so a hand-edited defaults array is harmless.
        t.equal(SpoolPlaces(names: ["Shelf", "shelf", "", "  Shelf  "]).names,
                ["Unplaced", "Shelf"], "duplicates and blanks dropped on load")
    },

    // A rename that only changes capitalisation must not report a clash with itself.
    test("renaming an entry to a re-capitalisation of itself is allowed") { t in
        var places = SpoolPlaces(names: ["shelf"])
        t.equal(places.rename("shelf", to: "Shelf").name, "Shelf", "applied")
        t.equal(places.names, ["Unplaced", "Shelf"], "one entry, new spelling")
    },

    // This is the seam: nothing the user can pick produces a location the CFS poll owns.
    test("a place maps only to an asserted location, never to a printer-owned one") { t in
        let places = SpoolPlaces()
        t.equal(places.location(for: "Unplaced"), .unknown, "the reserved name")
        t.equal(places.location(for: "Shelf"), .shelf("Shelf"), "everything else is a shelf")
        // `CFS` is seeded because the tool owner asked for it, and it is an ordinary shelf name
        // with no special power — it does not, and must not, produce `.cfs(box:slot:)`.
        t.equal(places.location(for: "Anything"), .shelf("Anything"), "any name is a shelf")
        t.equal(places.location(for: "Ext…"), .shelf("Ext…"), "including one since retired")

        t.expect(places.name(for: .cfs(box: "T1", slot: "A")) == nil, "no row owns a CFS slot")
        t.expect(places.name(for: .externalHolder) == nil, "nor the external holder")
        t.equal(places.name(for: .unknown), "Unplaced", "and back the other way")
        t.equal(places.name(for: .shelf("Bin 3")), "Bin 3", "including a deleted place")
    },

    // The cascade primitive both renaming and removing are built on.
    test("reassigning a place moves its spools and logs why, without touching the figure") { t in
        var inventory = SpoolInventory()
        inventory.add(makeSpool(serial: "000001", percent: 64, location: .shelf("Bin 3")))
        inventory.add(makeSpool(serial: "000002", percent: 20, location: .shelf("bin 3")))
        inventory.add(makeSpool(serial: "000003", location: .cfs(box: "T1", slot: "A")))

        let moved = inventory.reassign(place: "Bin 3", to: .shelf("Shelf B"),
                                       detail: "Place renamed")
        t.equal(moved.count, 2, "both spellings of the same place moved")

        let first = inventory.active.first { $0.identity?.serialNumber == "000001" }
        t.equal(first?.location, .shelf("Shelf B"), "re-pointed")
        t.equal(first?.remainingPercent, 64, "the remaining figure is untouched")
        t.equal(first?.usage.first?.kind, .movement, "and the log says it moved")
        t.equal(first?.usage.first?.deltaGrams, 0, "a movement moves no filament")

        let loaded = inventory.active.first { $0.identity?.serialNumber == "000003" }
        t.equal(loaded?.location, .cfs(box: "T1", slot: "A"), "a loaded spool is not a shelf spool")
    },

    // A closed record should not grow new lines. `retire` already forces `.unknown`, so there is
    // nothing to move either.
    test("reassigning skips retired spools") { t in
        var inventory = SpoolInventory()
        let spool = makeSpool(location: .shelf("Bin 3"))
        inventory.add(spool)
        inventory.retire(id: spool.id)
        t.equal(inventory.reassign(place: "Bin 3", to: .unknown, detail: "gone").count, 0,
                "nothing moved")
    },
])

// MARK: - Editing from the screen

let inventoryEditingTests = TestSuite(name: "Inventory editing", cases: [

    // The invariant on `UsageEntry`: every change to `remainingPercent` appends a line explaining
    // it. The inline percentage edit is not allowed to be the exception.
    test("an inline percentage edit appends one adjustment entry") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(percent: 100)
            model.add(spool)

            t.expect(model.adjust(spool, toPercent: 62, method: .byHand), "accepted")
            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.remainingPercent, 62, "the figure moved")
            t.equal(after.usage.count, 1, "exactly one line")
            t.equal(after.usage.first?.kind, .adjustment, "an adjustment, as the model requires")
            t.equal(after.usage.first?.detail, "Set by hand", "worded for what was actually done")
            t.equal(after.usage.first?.deltaGrams, -380, "delta derived, not asserted")
            t.expect(after.remainingSource.hasPrefix("Set by hand"),
                     "and the source line says where the figure came from")
        }
    },

    // Two units, one path. A weigh-in and a percentage edit differ in wording only — if they ever
    // stop sharing `adjust(_:toPercent:method:)` this fails.
    test("the weigh-in and the percentage edit produce the same kind of entry") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let weighed = makeSpool(serial: "000001", percent: 100)
            let typed = makeSpool(serial: "000002", percent: 100)
            model.add(weighed)
            model.add(typed)

            t.expect(model.adjust(weighed, toGrams: 620), "grams accepted")
            t.expect(model.adjust(typed, toPercent: 62, method: .byHand), "percent accepted")

            let a = model.inventory.spool(id: weighed.id)
            let b = model.inventory.spool(id: typed.id)
            t.equal(a?.remainingPercent, b?.remainingPercent, "the same figure either way")
            t.equal(a?.usage.first?.kind, b?.usage.first?.kind, "the same kind of line")
            t.equal(a?.usage.first?.deltaGrams, b?.usage.first?.deltaGrams, "the same delta")
            t.equal(a?.usage.first?.detail, "Weighed in", "but the log says which was done")
            t.equal(b?.usage.first?.detail, "Set by hand", "for each")
        }
    },

    test("a percentage outside 0–100 is refused rather than clamped") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(percent: 40)
            model.add(spool)

            t.expect(!model.adjust(spool, toPercent: 130, method: .byHand), "over refused")
            t.expect(!model.adjust(spool, toPercent: -1, method: .byHand), "under refused")
            let after = model.inventory.spool(id: spool.id)
            t.equal(after?.remainingPercent, 40, "unchanged")
            t.equal(after?.usage.count, 0, "and nothing written to the history")
        }
    },

    // A "0 g" adjustment line explains nothing, so re-typing the figure already on record is
    // accepted and writes nothing. Anything that genuinely moves the number is still recorded.
    test("re-entering the figure already on record writes no line") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(percent: 40)
            model.add(spool)

            t.expect(model.adjust(spool, toPercent: 40, method: .byHand), "accepted, not an error")
            t.equal(model.inventory.spool(id: spool.id)?.usage.count, 0, "but nothing logged")

            t.expect(model.adjust(spool, toPercent: 39.6, method: .byHand), "a 4 g change is real")
            t.equal(model.inventory.spool(id: spool.id)?.usage.count, 1, "and is logged")
        }
    },

    // MARK: The place list, from the screen

    test("the picker offers the user's places, and the printer's position when it has one") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let shelved = makeSpool(serial: "000001", location: .shelf("Shelf"))
            let loaded = makeSpool(serial: "000002", location: .cfs(box: "T1", slot: "A"))
            model.add(shelved)
            model.add(loaded)

            let forShelved = model.locationOptions(for: shelved)
            t.expect(!forShelved.contains { $0.isPrinterOwned }, "no printer row for a shelf spool")
            t.equal(forShelved.count, model.places.names.count, "just the places")
            t.equal(model.locationOption(for: shelved), .place("Shelf"), "selected row")

            let forLoaded = model.locationOptions(for: loaded)
            t.equal(forLoaded.first, .printer("CFS T1 · A"), "the printer's position leads")
            t.equal(model.locationOption(for: loaded), .printer("CFS T1 · A"), "and is selected")
            // The label has to say where it came from: a user-created place called "CFS" would
            // otherwise be indistinguishable from a measured CFS slot.
            t.equal(forLoaded.first?.title, "CFS T1 · A · reported by the printer", "labelled")
        }
    },

    // The CFS conflict rule, half one: the picker cannot assert a printer-owned location at all.
    test("the printer's own row cannot be applied to a spool") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(location: .shelf("Shelf"))
            model.add(spool)

            model.setLocation(.printer("CFS T1 · A"), for: spool)
            t.equal(model.inventory.spool(id: spool.id)?.location, .shelf("Shelf"), "ignored")
            t.equal(model.inventory.spool(id: spool.id)?.usage.count, 0, "and not even logged")
        }
    },

    test("moving a loaded spool to a place ends the live reading and says so") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(location: .cfs(box: "T1", slot: "A"))
            model.add(spool)
            model.update({ var s = spool; s.remainingSource = "CFS remainLen · T1A"; return s }())

            model.setLocation(.place("Shelf"), for: spool)
            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.location, .shelf("Shelf"), "moved")
            // The same wording `reconcile` uses when the printer notices first — the rail should
            // not read differently depending on who spotted it.
            t.equal(after.remainingSource, "Last reading from CFS T1 · A", "no longer live")
            t.equal(after.usage.first?.kind, .movement, "logged")
        }
    },

    // The CFS conflict rule, half two: a manual move off the printer is provisional, and the poll
    // settles it — correctly in both directions.
    test("a poll that still reports the slot overrules the hand edit, in writing") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool()
            model.add(spool)
            model.reconcile(with: boxInfo([slot("A")]))
            t.equal(model.inventory.spool(id: spool.id)?.location, .cfs(box: "T1", slot: "A"),
                    "the poll loaded it")

            // The user says they took it out. They are wrong: it is still in the slot.
            model.setLocation(.place("Shelf"), for: spool)
            model.reconcile(with: boxInfo([slot("A")]))

            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.location, .cfs(box: "T1", slot: "A"), "measurement wins")
            t.equal(after.usage.first?.kind, .movement, "and it is not silent")
            t.equal(after.usage.first?.detail, "Loaded into T1A", "the poll says what it did")
        }
    },

    test("a poll that no longer reports the slot leaves the hand edit standing") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool()
            model.add(spool)
            model.reconcile(with: boxInfo([slot("A")]))

            // The user really did take it out and put it on a shelf.
            model.setLocation(.place("Shelf"), for: spool)
            // `addingUnknown` would otherwise invent a second spool from the empty box; there is
            // nothing to invent here, the box is empty.
            model.reconcile(with: boxInfo([]))

            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.location, .shelf("Shelf"),
                    "the unload pass only touches spools the printer still owns")
            t.equal(model.inventory.active.count, 1, "and no phantom spool appeared")
        }
    },

    // MARK: Editing the list

    test("renaming a place carries its spools with it") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(percent: 55, location: .shelf("Shelf"))
            model.add(spool)

            t.equal(model.renamePlace("Shelf", to: "Garage rack").name, "Garage rack", "applied")
            guard let after = t.unwrap(model.inventory.spool(id: spool.id), "spool") else { return }
            t.equal(after.location, .shelf("Garage rack"), "the spool came with it")
            t.equal(after.remainingPercent, 55, "the figure is not a location")
            t.equal(after.usage.first?.kind, .movement, "and the log explains the new label")
            noOrphans(model, t)
        }
    },

    // The headline requirement: removing a place must not leave spools referring to it.
    test("removing a place moves its spools to Unplaced rather than orphaning them") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            _ = model.addPlace("Garage")
            let a = makeSpool(serial: "000001", location: .shelf("Shelf"))
            let b = makeSpool(serial: "000002", location: .shelf("Shelf"))
            let elsewhere = makeSpool(serial: "000003", location: .shelf("Garage"))
            model.add(a)
            model.add(b)
            model.add(elsewhere)

            t.expect(model.spoolCount(atPlace: "Shelf") == 2, "the count the button shows")
            t.expect(model.removePlace("Shelf").isApplied, "removed")

            t.expect(!model.places.contains("Shelf"), "gone from the list")
            t.equal(model.inventory.spool(id: a.id)?.location, .unknown, "and its spools moved")
            t.equal(model.inventory.spool(id: b.id)?.location, .unknown, "both of them")
            t.equal(model.inventory.spool(id: elsewhere.id)?.location, .shelf("Garage"),
                    "another place is untouched")
            t.expect(model.inventory.spool(id: a.id)?.usage.first?.detail.contains("removed") == true,
                     "each says why it moved")
            noOrphans(model, t)
        }
    },

    // Removing a place a spool is *not* on must not write anything at all.
    test("removing an empty place touches no spool") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(location: .shelf("Shelf"))
            model.add(spool)
            _ = model.addPlace("Garage")
            t.expect(model.removePlace("Garage").isApplied, "removed")
            t.equal(model.inventory.spool(id: spool.id)?.usage.count, 0, "nothing logged")
            noOrphans(model, t)
        }
    },

    test("the list survives a relaunch, and an emptied list is not re-seeded") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            t.expect(model.addPlace("Garage rack").isApplied, "added")
            t.expect(model.removePlace("Shelf").isApplied, "removed")

            let reopened = InventoryViewModel(store: InventoryStore(directory: dir),
                                              toasts: ToastCenter(),
                                              defaults: defaults)
            t.equal(reopened.places.names, ["Unplaced", "Garage rack"], "exactly what was left")

            // Deleting everything is a choice, not a corruption — it must not spring back to the
            // seeded list. Only a *never written* key seeds.
            for name in ["Garage rack"] { reopened.removePlace(name) }
            let again = InventoryViewModel(store: InventoryStore(directory: dir),
                                           toasts: ToastCenter(),
                                           defaults: defaults)
            t.equal(again.places.names, ["Unplaced"], "honoured, not re-seeded")
        }
    },

    // A spool whose place predates the list — an inventory file written before this feature.
    // The picker must still show where it is rather than rendering blank.
    test("a spool at an unlisted place still gets a row of its own") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let spool = makeSpool(location: .shelf("Somewhere nobody configured"))
            model.add(spool)

            let options = model.locationOptions(for: spool)
            t.expect(options.contains(.place("Somewhere nobody configured")),
                     "offered so the picker is not blank")
            t.equal(model.locationOption(for: spool), .place("Somewhere nobody configured"),
                    "and it is the selection")
        }
    },

    // MARK: A tag request does not outlive its spool

    // `awaitingTagFor` survived retirement, so a tag read or written later — for some other
    // spool entirely — attached itself to a record that had been closed.
    test("retiring the spool a tag was being written for cancels the request") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            var shelf = makeSpool()
            shelf.identity = nil
            shelf.tagSource = .untagged
            model.add(shelf)
            model.attachTag(to: shelf)
            t.equal(model.awaitingTagFor, shelf.id, "waiting for a tag")

            model.confirmRetire(shelf)
            t.equal(model.awaitingTagFor, nil, "the request went with the spool")

            // A request raised against a stale copy of the retired spool — the rail can hold one
            // — is refused rather than reopening the record.
            guard let record = try? SpoolRecord(materialId: "01001", colorRGB: "C12E1F",
                                                filamentLength: .kg1, serialNumber: "005150") else {
                t.expect(false, "could not build a record"); return
            }
            model.attachTag(to: shelf)
            t.expect(!model.attachTag(record: record, materialType: "PLA"), "refused")
            t.equal(model.awaitingTagFor, nil, "and the stale request is dropped")
            t.equal(model.inventory.spool(id: shelf.id)?.identity, nil, "the retired spool is untouched")
            t.equal(model.inventory.active.count, 0, "and nothing was resurrected")
        }
    },
])

// MARK: - The filter row follows the place list

let inventoryFilterOptionTests = TestSuite(name: "Inventory filter options", cases: [

    test("there is a filter button for every configured location") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            let titles = model.filterOptions.map(\.title)
            t.equal(titles, ["All", "On printer", "Unplaced", "Shelf", "Low", "Untagged"],
                    "states, then every place, then the conditions")

            _ = model.addPlace("Dry box")
            t.expect(model.filterOptions.map(\.title).contains("Dry box"),
                     "a place added is immediately filterable")
        }
    },

    test("a renamed place takes its filter button with it") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            _ = model.renamePlace("Shelf", to: "Cabinet")
            let titles = model.filterOptions.map(\.title)
            t.expect(titles.contains("Cabinet"), "the new name is offered")
            t.expect(!titles.contains("Shelf"), "and the old one is not")
        }
    },

    test("filtering by a place that is then renamed falls back to All") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            model.add(makeSpool(location: .shelf("Shelf")))
            model.filter = .at(.shelf("Shelf"))
            t.equal(model.rows.count, 1, "the filter finds it")

            // Without the fallback the table would go empty with a button still lit, which reads
            // as every spool having vanished rather than as a filter naming nothing.
            _ = model.renamePlace("Shelf", to: "Cabinet")
            t.equal(model.filter, .all, "the selection falls back")
            t.equal(model.rows.count, 1, "and the spool is still listed")
        }
    },

    test("filtering by a place that is then removed falls back to All") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            _ = model.addPlace("Garage")
            model.filter = .at(.shelf("Garage"))
            _ = model.removePlace("Garage")
            t.equal(model.filter, .all, "the selection falls back")
        }
    },

    test("a non-place filter is left alone when the list changes") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            model.filter = .low
            _ = model.removePlace("Garage")
            t.equal(model.filter, .low, "Low is not a place and survives")
        }
    },
])

// MARK: - Where a spool goes when it leaves the printer

let unloadDestinationTests = TestSuite(name: "Unload destination", cases: [

    test("unplaced by default, which is the honest answer before anyone has said otherwise") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            t.equal(model.places.unloadDestination, SpoolPlaces.unplaced, "default")
        }
    },

    test("a spool the printer stops reporting goes where the user chose") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            model.setUnloadDestination("Shelf")
            model.add(makeSpool(serial: "000123", location: .cfs(box: "T1", slot: "A")))

            // The slot is reported, then it is not.
            _ = model.reconcile(with: boxInfo([slot("T1A", serial: "000123")]))
            _ = model.reconcile(with: boxInfo([]))

            guard let after = t.unwrap(model.inventory.active.first, "the spool") else { return }
            t.equal(after.location, .shelf("Shelf"), "back on the shelf, not Unplaced")
            t.expect(after.usage.contains { $0.detail.hasPrefix("Unloaded from") },
                     "and its history still says which slot it came off")
        }
    },

    test("renaming the chosen place carries the choice with it") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            model.setUnloadDestination("Shelf")
            _ = model.renamePlace("Shelf", to: "Cabinet")
            // Stored as a name, so without carrying it this would silently revert to Unplaced the
            // next time a spool came off the printer.
            t.equal(model.places.unloadDestination, "Cabinet", "followed the rename")
        }
    },

    test("removing the chosen place sends spools back to Unplaced, not to nothing") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            _ = model.addPlace("Garage")
            model.setUnloadDestination("Garage")
            _ = model.removePlace("Garage")
            t.equal(model.places.unloadDestination, SpoolPlaces.unplaced, "fell back")
        }
    },

    test("a destination naming a place that does not exist is refused, and cannot be loaded") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            t.expect(!model.setUnloadDestination("Nowhere").isApplied, "refused")
            t.equal(model.places.unloadDestination, SpoolPlaces.unplaced, "and unchanged")

            // A hand-edited plist is the other way in, and the initialiser has to close it too —
            // spools sent to a place the picker has never heard of would be unreachable by filter
            // and unexplainable in the rail.
            let hostile = SpoolPlaces(names: ["Unplaced", "Shelf"], unloadDestination: "Nowhere")
            t.equal(hostile.unloadDestination, SpoolPlaces.unplaced, "normalised on the way in")
        }
    },

    test("the choice survives a relaunch") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            _ = model.addPlace("Garage")
            model.setUnloadDestination("Garage")
            t.equal(SpoolPlacesStore.load(from: defaults).unloadDestination, "Garage", "persisted")
        }
    },
])

// MARK: - Retiring the two places that were seeded by mistake

let retiredSeedTests = TestSuite(name: "Retired seeded places", cases: [

    test("CFS and Ext… are dropped, and only once") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            // A list as an installed copy already has it.
            _ = model.addPlace("CFS")
            _ = model.addPlace("Ext…")
            t.expect(model.places.contains("CFS"), "present to begin with")

            model.retireSeededPlaces()
            t.expect(!model.places.contains("CFS"), "CFS gone — On printer already says this")
            t.expect(!model.places.contains("Ext…"), "and Ext…")
            t.expect(model.places.contains("Shelf"), "while a real place is untouched")

            // Adding one back must stick: a cleanup that ran every launch would be the app
            // arguing with the user.
            _ = model.addPlace("CFS")
            model.retireSeededPlaces()
            t.expect(model.places.contains("CFS"), "put back by hand, and left alone")
        }
    },

    test("a place with spools on it is kept, because the user has made it theirs") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            _ = model.addPlace("CFS")
            model.add(makeSpool(location: .shelf("CFS")))

            model.retireSeededPlaces()
            t.expect(model.places.contains("CFS"), "kept")
            t.equal(model.inventory.active.first?.location, .shelf("CFS"),
                    "and the spool did not move — a cleanup must not cascade")
            noOrphans(model, t)
        }
    },

    test("a place chosen as the unload destination is kept, because that is a setting") { t in
        onMain {
            let (model, defaults, suite, dir) = makeModel()
            defer {
                try? FileManager.default.removeItem(at: dir)
                defaults.removePersistentDomain(forName: suite)
            }
            _ = model.addPlace("Ext…")
            model.setUnloadDestination("Ext…")
            model.retireSeededPlaces()
            t.expect(model.places.contains("Ext…"), "kept")
            t.equal(model.places.unloadDestination, "Ext…", "and still the destination")
        }
    },

    test("a fresh install seeds only Unplaced and Shelf") { t in
        t.equal(SpoolPlaces().names, ["Unplaced", "Shelf"],
                "the two that duplicated On printer are not seeded any more")
    },
])
