import Foundation
@testable import SpoolworksCore

// The real thing, pulled off a K2 Plus. Every other CFS test uses fixtures we wrote ourselves, so
// this one exists to catch the case where our idea of the format and the printer's have drifted.
private enum BoxFixture {
    static func data() -> Data? {
        guard let url = Bundle.module.url(forResource: "printer-k2plus-material_box_info",
                                          withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
}

let materialBoxInfoTests = TestSuite(name: "material_box_info decoding", cases: [

    test("the real K2 Plus dump decodes") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        let info = try MaterialBoxInfo.decode(from: data)

        t.equal(info.boxes.count, 1, "one CFS attached")
        t.equal(info.slotCount, 4, "four slots")
        t.equal(info.loadedSlotCount, 4, "all loaded")
        t.equal(info.material.state, "connect", "state")
        t.expect(info.material.isAutoRefillEnabled, "auto refill on")

        guard let box = t.unwrap(info.boxes.first, "box") else { return }
        t.equal(box.boxID, "T1", "id")
        t.equal(box.temperatureLabel, "27 °C", "temperature carries its unit")
        t.equal(box.humidityLabel, "39 %RH", "dry_and_humidity is mapped")
        t.equal(box.version, "1.1.2", "firmware")
        t.expect(box.isConnected, "connected")
    },

    test("a slot carries the whole tag record") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        let info = try MaterialBoxInfo.decode(from: data)
        guard let box = t.unwrap(info.boxes.first, "box"),
              let slot = t.unwrap(box.list.first, "T1A") else { return }

        t.equal(slot.materialId, "A", "slot letter")
        t.equal(slot.remainingPercent, 54, "remainLen is a percentage")
        t.equal(slot.filamentId, "101001", "filament id")
        t.equal(slot.venderId, "0276", "vendor")
        t.equal(slot.serialNum, "000001", "serial")
        t.equal(slot.rgbHex, "FFFFFF", "colour drops the '#' and the unknown nibble")
        // The design's decoded-field panel annotates "0165 → 1 kg". It is wrong: Utils.cs:172-188,
        // the ESP32 firmware and this dump all make 0165 a 500 g spool. 1 kg is 0330.
        t.equal(slot.netWeightGrams, 500, "0165 is 500 g, not 1 kg")
        t.equal(slot.temperatureLabel, "190–240 °C", "temperature range")
        t.expect(slot.hasTag, "rfid 2 means a tag was read")
        t.equal(slot.tagLabel, "RFID OK", "label")
        t.equal(slot.label(in: box), "T1A", "firmware slot label")
    },

    // same_material is a heterogeneous positional array on the wire, not an object:
    // ["101001", "0C12E1F", ["T1B","T1D"], "PLA"].
    test("same_material decodes from its positional array form") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        let info = try MaterialBoxInfo.decode(from: data)
        let groups = info.material.sameMaterial

        t.equal(groups.count, 3, "three groups")
        guard let partnered = t.unwrap(groups.first(where: \.isPartnered), "the auto-refill pair")
        else { return }
        t.equal(partnered.filamentId, "101001", "filament")
        t.equal(partnered.color, "0C12E1F", "colour")
        t.equal(partnered.slots, ["T1B", "T1D"], "slots")
        t.equal(partnered.materialType, "PLA", "type")
        t.equal(partnered.label, "101001 · 0C12E1F", "display label")
        t.equal(partnered.slotsLabel, "T1B, T1D", "slot list")

        t.equal(groups.filter { !$0.isPartnered }.count, 2, "a group of one is not a pairing")
    },

    test("same_material round-trips through encoding") { t in
        let group = SameMaterialGroup(filamentId: "101001", color: "0C12E1F",
                                      slots: ["T1B", "T1D"], materialType: "PLA")
        let data = try JSONEncoder().encode(group)
        guard let json = t.unwrap((try? JSONSerialization.jsonObject(with: data)) as? [Any], "array")
        else { return }
        t.equal(json.count, 4, "still a positional array of four")
        let decoded = try JSONDecoder().decode(SameMaterialGroup.self, from: data)
        t.equal(decoded, group, "round-trips")
    },

    test("the external holder is reported as detached on this dump") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        let info = try MaterialBoxInfo.decode(from: data)
        guard let rack = t.unwrap(info.rackMaterial, "rackMaterial") else { return }
        t.expect(!rack.attach, "nothing mounted")
        t.equal(rack.rgbHex, "C12E1F", "colour still normalises")
        // This firmware omits venderId/serialNum on the holder entirely.
        t.expect(rack.identity == nil, "no identity without a serial")
    },

    // An empty slot blanks most of its keys. A strict decoder would throw on the whole document
    // because one slot of four has no spool in it.
    test("an empty slot decodes rather than failing the document") { t in
        let json = """
        {"Material": {"state": "connect", "info": [
          {"boxID": "T2", "state": "connect", "list": [
            {"materialId": "A"},
            {"materialId": "B", "filamentId": "", "remainLen": ""}
          ]}
        ]}}
        """
        let info = try MaterialBoxInfo.decode(from: Data(json.utf8))
        t.equal(info.slotCount, 2, "both slots present")
        t.equal(info.loadedSlotCount, 0, "neither is loaded")
        t.expect(info.boxes[0].list[0].identity == nil, "no identity")
        t.equal(info.boxes[0].list[0].tagLabel, "No tag", "reported as untagged")
        t.equal(info.boxes[0].list[0].netWeightGrams, 1000, "falls back to 1 kg like GetMaterialWeight")
    },

    test("a document with no CFS at all is valid") { t in
        let info = try MaterialBoxInfo.decode(from: Data("{}".utf8))
        t.expect(info.hasNoCFS, "no boxes")
        t.equal(info.slotCount, 0, "no slots")
        t.expect(info.rackMaterial == nil, "no holder")
    },

    test("a box with no boxID is rejected — it could not be matched to anything") { t in
        let json = #"{"Material": {"info": [{"state": "connect", "list": []}]}}"#
        t.throwsError("decoding a nameless box") {
            _ = try MaterialBoxInfo.decode(from: Data(json.utf8))
        }
    },
])

// MARK: - The ambiguity the real hardware creates

let cfsIdentityAmbiguityTests = TestSuite(name: "CFS identity ambiguity", cases: [

    // The K2 Plus dump has all four slots reporting serialNum 000001, because Windows hard-codes
    // it. Keying on serial + filament alone — which is what the design says — would collapse four
    // spools into one row.
    test("the real dump's four slots share one serial") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        let info = try MaterialBoxInfo.decode(from: data)
        let serials = Set(info.boxes.flatMap { $0.list.map(\.serialNum) })
        t.equal(serials, ["000001"], "serial carries no information here")
        t.expect(info.boxes[0].list.allSatisfy { $0.identity?.hasGenericSerial == true },
                 "flagged as generic")
    },

    test("colour separates three of the four, and reconciliation separates the fourth") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        let info = try MaterialBoxInfo.decode(from: data)

        let identities = Set(info.boxes.flatMap { $0.list.compactMap(\.identity) })
        t.equal(identities.count, 3, "T1B and T1D are the same red, so colour cannot split them")

        var inventory = SpoolInventory()
        inventory.reconcile(with: info)
        t.equal(inventory.active.count, 4, "but four slots still produce four distinct spools")

        let locations = Set(inventory.active.map(\.location))
        t.equal(locations.count, 4, "each bound to its own slot")
    },

    // Without slot-stable binding, T1B and T1D would swap on every poll and each would be credited
    // with the other's consumption.
    test("the red pair stays bound to its own slot across polls") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        var inventory = SpoolInventory()
        inventory.reconcile(with: try MaterialBoxInfo.decode(from: data))

        func spool(at slot: String) -> Spool? {
            t.unwrap(inventory.active.first { $0.location == .cfs(box: "T1", slot: slot) },
                     "spool in T1\(slot)")
        }
        guard let b0 = spool(at: "B"), let d0 = spool(at: "D") else { return }
        let bID = b0.id, dID = d0.id
        t.expect(bID != dID, "two distinct records for the two red spools")

        // Poll again with B drawn down and D untouched.
        var second = try MaterialBoxInfo.decode(from: data)
        second.material.info[0].list[1].remainLen = "30"
        inventory.reconcile(with: second)

        guard let b1 = spool(at: "B"), let d1 = spool(at: "D") else { return }
        t.equal(b1.id, bID, "B is still the same record")
        t.equal(d1.id, dID, "D is still the same record")
        t.equal(b1.remainingPercent, 30, "the draw landed on B")
        t.equal(d1.remainingPercent, 52, "and not on D")
    },

    test("polling the same snapshot twice changes nothing") { t in
        guard let data = t.unwrap(BoxFixture.data(), "fixture") else { return }
        let info = try MaterialBoxInfo.decode(from: data)
        var inventory = SpoolInventory()
        inventory.reconcile(with: info)
        let before = inventory.active.map { ($0.id, $0.usage.count, $0.remainingPercent) }

        let report = inventory.reconcile(with: info)
        t.expect(report.isEmpty, "no change reported")
        let after = inventory.active.map { ($0.id, $0.usage.count, $0.remainingPercent) }
        t.equal(before.map(\.0), after.map(\.0), "same records")
        t.equal(before.map(\.1), after.map(\.1), "no usage lines appended")
        t.equal(before.map(\.2), after.map(\.2), "no figures moved")
    },
])
