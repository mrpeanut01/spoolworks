import Foundation
@testable import SpoolworksCore

/// Validates the material-database layer against a database pulled off a real printer.
///
/// Source: a Creality K2 Plus (`K2Plus-E1DB`, Linux 5.4.61 armv7l) at
/// `/mnt/UDISK/creality/userdata/box/material_database.json` — 478,873 bytes, 98 records,
/// retrieved read-only over SSH.
///
/// This matters because every other material test uses fixtures we trimmed ourselves. Real
/// firmware ships fields the extracted spec never saw: it documented 18 `base` keys and this
/// database has 20. The loss-free round-trip is only genuinely proven here.
private enum RealFixture {
    static func data() -> Data? {
        guard let url = Bundle.module.url(forResource: "printer-k2plus-material_database",
                                          withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }
}

let realPrinterDatabaseTests = TestSuite(name: "Real K2 Plus printer database", cases: [

    test("decodes the real 98-record database") { t in
        guard let data = t.unwrap(RealFixture.data(), "fixture") else { return }
        let file = try MaterialDatabase.decode(data)
        t.equal(file.code, 0, "code")
        t.equal(file.msg, "ok", "msg")
        t.equal(file.result.list.count, 98, "record count")
        t.equal(file.result.count, 98, "declared count matches actual list length")
        t.equal(file.result.version, "1784284303", "version")
    },

    test("every record is the K2 printer family, matching our metadata") { t in
        guard let data = t.unwrap(RealFixture.data()) else { return }
        let file = try MaterialDatabase.decode(data)
        let names = Set(file.result.list.map(\.printerIntName))
        t.equal(names, ["F008"], "printerIntName across all 98 records")
        t.equal(PrinterType.k2.printerIntName, "F008", "our K2 metadata agrees with the printer")
    },

    // diameter ships as a STRING, density as a NUMBER. Getting either backwards fails to decode,
    // and this is the real wire format rather than our own fixture's.
    test("handles the real string-vs-number field typing") { t in
        guard let data = t.unwrap(RealFixture.data()) else { return }
        let file = try MaterialDatabase.decode(data)
        guard let first = t.unwrap(file.result.list.first, "first record") else { return }
        t.equal(first.base.diameter, "1.75", "diameter is a string on the wire")
        t.expect(first.base.density > 1.0, "density decoded as a number")
    },

    test("preserves the misspelled meterialType key from real firmware") { t in
        guard let data = t.unwrap(RealFixture.data()) else { return }
        let file = try MaterialDatabase.decode(data)
        let text = String(decoding: try JSONEncoder().encode(file), as: UTF8.self)
        t.expect(text.contains("meterialType"), "must re-emit the vendor's misspelling")
        t.expect(!text.contains("\"materialType\""), "must not emit the corrected spelling")
    },

    // The load-bearing test: real firmware carries fields the spec never documented.
    // If the model silently drops any of them, uploading a round-tripped database would
    // strip settings from the user's printer.
    test("round-trips real firmware fields without losing any") { t in
        guard let data = t.unwrap(RealFixture.data()) else { return }
        let file = try MaterialDatabase.decode(data)
        let reencoded = try JSONEncoder().encode(file)

        // Compare parsed structures, not bytes: key order and whitespace are not meaningful.
        guard let before = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let after = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any],
              let beforeList = (before["result"] as? [String: Any])?["list"] as? [[String: Any]],
              let afterList = (after["result"] as? [String: Any])?["list"] as? [[String: Any]]
        else { t.expect(false, "could not reparse for comparison"); return }

        t.equal(afterList.count, beforeList.count, "record count preserved")

        for (i, original) in beforeList.enumerated() {
            guard let originalBase = original["base"] as? [String: Any],
                  let afterBase = afterList[i]["base"] as? [String: Any] else {
                t.expect(false, "record \(i) lost its base object"); return
            }
            let missingBase = Set(originalBase.keys).subtracting(afterBase.keys)
            if !missingBase.isEmpty {
                t.expect(false, "record \(i) lost base keys: \(missingBase.sorted())")
                return
            }
            // kvParam carries ~90 slicer settings per record; none may be dropped.
            let originalKV = Set((original["kvParam"] as? [String: Any] ?? [:]).keys)
            let afterKV = Set((afterList[i]["kvParam"] as? [String: Any] ?? [:]).keys)
            let missingKV = originalKV.subtracting(afterKV)
            if !missingKV.isEmpty {
                t.expect(false, "record \(i) lost kvParam keys: \(Array(missingKV.sorted().prefix(5)))")
                return
            }
        }

        let baseKeyCount = Set((beforeList[0]["base"] as? [String: Any] ?? [:]).keys).count
        t.equal(baseKeyCount, 20, "real firmware ships 20 base keys (the spec documented 18)")
    },
])
