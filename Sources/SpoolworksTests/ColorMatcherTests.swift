import Foundation
@testable import SpoolworksCore

// Colour-matching tests.
//
// Every expected name, hex and row index below was derived by running an independent
// re-implementation of ColorMatcher.cs:70-99 over the actual extracted colornames.csv — not by
// reading them out of the spec. That matters: the spec's own vector table calls row 1
// ("18th Century Green") the *first* data row when it is the second, and a hand-computed
// constant in a sibling spec was outright wrong. Anything asserted here was observed in the
// real 31,861-row dataset.
//
// Row indices are asserted, not just names. They are the tie-break key, so a port that
// returned the right name for the wrong reason (a sorted table that happens to agree) would
// pass a name-only test and fail on the next tie.

private func colorTable() throws -> ColorTable { try ColorTable.shared() }
private func colorMatcher() throws -> ColorMatcher { try ColorMatcher.shared() }

/// Asserts that `hex` resolves to `name` at `row`, and that the match really is at `distance²`.
private func assertMatch(_ t: TestContext, _ hex: String, name: String, row: Int,
                         squared: Int32, file: String = #file, line: Int = #line) throws {
    let matcher = try colorMatcher()
    let color = try RGB8(hex: hex)
    guard let match = t.unwrap(matcher.nearest(to: color), "match for \(hex)",
                               file: file, line: line) else { return }
    t.equal(match.name, name, "\(hex) name", file: file, line: line)
    t.equal(match.index, row, "\(hex) row index", file: file, line: line)
    t.equal(matcher.squaredDistance(from: color, toIndex: match.index), squared,
            "\(hex) squared distance", file: file, line: line)
}

let colorTableTests = TestSuite(name: "Colour table", cases: [

    // The generator refuses to write a table with any other count, so this failing means the
    // bundled resource is stale relative to reference/colors.db.
    test("loads exactly 31,861 records") { t in
        t.equal(try colorTable().count, 31_861, "record count")
    },

    // CSV line 1 is the literal attribution URL "https://github.com/meodai/color-names", not a
    // header. ColorMatcher.cs:48 discards it with a bare reader.ReadLine(). If the generator
    // ever stopped discarding it, every row index would shift by one and every tie-break vector
    // in this file would fail — but so would this, first and most legibly.
    test("discards the attribution line, so row 0 is the first real colour") { t in
        let entry = try colorTable().entry(at: 0)
        t.equal(entry.name, "100 Mph")
        t.equal(entry.hexString, "#c93f38")
        t.equal(entry.index, 0)
    },

    // The CSV has no trailing newline (SPEC-05 §1.1), so a naive line reader drops this row.
    test("keeps the last row despite the missing trailing newline") { t in
        let table = try colorTable()
        let entry = table.entry(at: table.count - 1)
        t.equal(entry.name, "Zydeco Blue")
        t.equal(entry.hexString, "#2b61a0")
        t.equal(entry.index, 31_860)
    },

    // 739 rows are non-ASCII. A Latin-1 misread corrupts these without failing anything else.
    test("names survive UTF-8 round-trip") { t in
        let table = try colorTable()
        t.equal(table.name(at: 12), "5-Masted Preußen")
        t.equal(table.name(at: 31_858), "Zürich Blue")
        t.equal(table.name(at: 8_950), "Éclair au Chocolat")
        t.equal(table.name(at: 19_150), "№5")
        t.equal(table.name(at: 674), "Àn Zǐ Purple")
    },

    // SPEC-05 §1.4: the upstream dataset uses a natural/locale sort, so the file is NOT in
    // ordinal order. The first inversion is at rows 9/10. This is the direct evidence that the
    // generator preserved file order rather than sorting — a sorted table cannot reproduce it.
    test("preserves original CSV order, including the row 9/10 ordinal inversion") { t in
        let table = try colorTable()
        t.equal(table.name(at: 9), "3AM in Shibuya")
        t.equal(table.name(at: 10), "3AM Latte")
        t.expect(table.name(at: 9) > table.name(at: 10),
                 "row 9 must sort after row 10 ordinally; the table is not sorted")
    },

    test("name to hex lookup") { t in
        let table = try colorTable()
        t.equal(table.hex(forName: "Cherry Pie"), "#bd2c22")
        t.equal(table.hex(forName: "Zydeco Blue"), "#2b61a0")
        t.equal(table.entry(forName: "Meadowlark")?.index, 17_219)
    },

    test("name lookup is case- and whitespace-insensitive, and misses return nil") { t in
        let table = try colorTable()
        t.equal(table.hex(forName: "cherry pie"), "#bd2c22")
        t.equal(table.hex(forName: "  CHERRY PIE  "), "#bd2c22")
        t.expect(table.hex(forName: "Not A Colour In This Dataset") == nil, "unknown name")
        t.expect(table.hex(forName: "") == nil, "empty name")
    },
])

let colorMatcherTests = TestSuite(name: "Colour matching", cases: [

    // MARK: - Exact hits

    test("exact palette hits resolve to distance 0") { t in
        try assertMatch(t, "0000FF", name: "Blue", row: 3_001, squared: 0)        // MainForm.cs:60 default
        try assertMatch(t, "FFFFFF", name: "White", row: 30_854, squared: 0)
        try assertMatch(t, "000000", name: "Black", row: 2_674, squared: 0)
        try assertMatch(t, "808080", name: "Grey", row: 12_463, squared: 0)
        try assertMatch(t, "FF0000", name: "Red", row: 23_129, squared: 0)
        try assertMatch(t, "00FF00", name: "Green", row: 12_174, squared: 0)
    },

    test("secondary primaries resolve exactly") { t in
        try assertMatch(t, "FFFF00", name: "Yellow", row: 31_588, squared: 0)
        try assertMatch(t, "00FFFF", name: "Cyan", row: 7_349, squared: 0)
        try assertMatch(t, "FF00FF", name: "Magenta", row: 16_638, squared: 0)
    },

    // Row 0 and the last row, matched by colour rather than by index — proves both ends of the
    // blob are reachable through the scan, not just through direct indexing.
    test("first and last data rows are reachable through the matcher") { t in
        try assertMatch(t, "C93F38", name: "100 Mph", row: 0, squared: 0)
        try assertMatch(t, "2B61A0", name: "Zydeco Blue", row: 31_860, squared: 0)
        try assertMatch(t, "A59344", name: "18th Century Green", row: 1, squared: 0)
    },

    // MARK: - Off-palette

    test("off-palette colours snap to the nearest entry") { t in
        // README example. sqrt(29) = 5.385, matching the spec's quoted distance.
        try assertMatch(t, "C12E1F", name: "Cherry Pie", row: 5_497, squared: 29)
        // The app's own accent colour, two units off Bright Navy Blue's #1974d2.
        try assertMatch(t, "1976D2", name: "Bright Navy Blue", row: 3_866, squared: 4)
        // Mid grey is not in the palette; #807f7e is the closest thing to it.
        try assertMatch(t, "7F7F7F", name: "Platinum Granite", row: 21_682, squared: 2)
    },

    test("near-black and near-white edge values") { t in
        try assertMatch(t, "010203", name: "Black Hole", row: 2_711, squared: 0)
        try assertMatch(t, "000001", name: "Black", row: 2_674, squared: 1)
        try assertMatch(t, "FFFFFE", name: "White", row: 30_854, squared: 1)
    },

    // MARK: - Tie-breaks
    //
    // ColorMatcher.cs:87 updates on a strict `<`, so the FIRST row in CSV order wins a tie.
    // Each case below asserts three things: the winner, the winner's row index, and that the
    // loser is genuinely equidistant — otherwise the test would still pass if the dataset
    // shifted and the "tie" quietly stopped being one.

    test("tie-break: #EAD742 picks Meadowlark (row 17,219) over Sandstorm (row 24,631)") { t in
        let matcher = try colorMatcher()
        let color = try RGB8(hex: "EAD742")
        try assertMatch(t, "EAD742", name: "Meadowlark", row: 17_219, squared: 12)
        t.equal(matcher.squaredDistance(from: color, toIndex: 24_631), 12,
                "Sandstorm must be exactly as close")
        t.equal(matcher.table.name(at: 24_631), "Sandstorm")
    },

    test("tie-break: #2D49CC picks Blue Blue (row 3,036) over Kikorangi Blue (row 14,837)") { t in
        let matcher = try colorMatcher()
        let color = try RGB8(hex: "2D49CC")
        try assertMatch(t, "2D49CC", name: "Blue Blue", row: 3_036, squared: 195)
        t.equal(matcher.squaredDistance(from: color, toIndex: 14_837), 195,
                "Kikorangi Blue must be exactly as close")
        t.equal(matcher.table.name(at: 14_837), "Kikorangi Blue")
    },

    test("tie-break: #FCC327 picks Golden Banner (row 11,708) over Ripe Mango (row 23,629)") { t in
        let matcher = try colorMatcher()
        let color = try RGB8(hex: "FCC327")
        try assertMatch(t, "FCC327", name: "Golden Banner", row: 11_708, squared: 18)
        t.equal(matcher.squaredDistance(from: color, toIndex: 23_629), 18,
                "Ripe Mango must be exactly as close")
        t.equal(matcher.table.name(at: 23_629), "Ripe Mango")
    },

    // The three ties above all happen to have the row-order winner sorting alphabetically
    // first, so a name-sorted table would pass them by luck. These two are adversarial: the
    // winner sorts AFTER the loser by name and ABOVE it by hex value, so only genuine CSV row
    // order produces the right answer.
    test("tie-break survives a winner that sorts last by both name and hex") { t in
        let matcher = try colorMatcher()
        let color = try RGB8(hex: "7E4830")
        try assertMatch(t, "7E4830", name: "Éclair au Chocolat", row: 8_950, squared: 1)
        t.equal(matcher.squaredDistance(from: color, toIndex: 27_687), 1,
                "Sunbathing Beauty must be exactly as close")
        t.equal(matcher.table.name(at: 27_687), "Sunbathing Beauty")
        // Winner #7e4930 > loser #7e4730, and "Éclair…" > "Sunbathing…" ordinally.
        t.expect(matcher.table.entry(at: 8_950).hexString > matcher.table.entry(at: 27_687).hexString,
                 "winner's hex must be the larger one")
    },

    test("tie-break: #58A9FF picks Âbi Blue (row 48) over Joust Blue (row 14,597)") { t in
        let matcher = try colorMatcher()
        let color = try RGB8(hex: "58A9FF")
        try assertMatch(t, "58A9FF", name: "Âbi Blue", row: 48, squared: 10)
        t.equal(matcher.squaredDistance(from: color, toIndex: 14_597), 10,
                "Joust Blue must be exactly as close")
        t.equal(matcher.table.name(at: 14_597), "Joust Blue")
    },

    // MARK: - Determinism

    test("repeated lookups return the identical row") { t in
        let matcher = try colorMatcher()
        let color = try RGB8(hex: "EAD742")
        let first = matcher.nearestIndex(to: color)
        for _ in 0..<50 {
            t.equal(matcher.nearestIndex(to: color), first, "tie winner must not drift")
        }
    },

    // MARK: - Hex entry point

    test("nearestName accepts the same forms the C# does") { t in
        let matcher = try colorMatcher()
        t.equal(try matcher.nearestName(forHex: "C12E1F"), "Cherry Pie")
        t.equal(try matcher.nearestName(forHex: "#C12E1F"), "Cherry Pie")
        t.equal(try matcher.nearestName(forHex: "0C12E1F"), "Cherry Pie")  // 7-char tag field
        t.equal(try matcher.nearestName(forHex: "c12e1f"), "Cherry Pie")
    },

    test("matcher exposes name to hex as well as rgb to name") { t in
        let matcher = try colorMatcher()
        guard let name = t.unwrap(try matcher.nearestName(forHex: "C12E1F")) else { return }
        t.equal(matcher.hex(forName: name), "#bd2c22")
        // Not an inverse: 31,861 names cover 16.7M colours, so this must NOT be "#c12e1f".
        t.expect(matcher.hex(forName: name) != "#c12e1f", "lookup returns the palette entry")
    },
])

let colorHexTests = TestSuite(name: "Colour hex parsing", cases: [

    test("parses the three accepted forms identically") { t in
        let bare = try RGB8(hex: "C12E1F")
        t.equal(try RGB8(hex: "#C12E1F"), bare, "leading #")
        t.equal(try RGB8(hex: "0C12E1F"), bare, "7-char tag field")
        t.equal(try RGB8(hex: "c12e1f"), bare, "lowercase")
        t.equal(try RGB8(hex: "  #C12E1F \n"), bare, "surrounding whitespace")
        t.equal(bare, RGB8(r: 0xC1, g: 0x2E, b: 0x1F))
    },

    test("formats to the tag's uppercase form and the CSV's lowercase form") { t in
        let color = RGB8(r: 0xC1, g: 0x2E, b: 0x1F)
        t.equal(color.hexString, "C12E1F")        // MainForm.cs:710 ToString("X6")
        t.equal(color.cssHexString, "#c12e1f")
        t.equal(color.packed, 0x00C1_2E1F)
        t.equal(RGB8(packed: 0x00C1_2E1F), color)
    },

    test("tag colour field is the literal '0' nibble plus RRGGBB") { t in
        t.equal(RGB8(r: 0, g: 0, b: 0xFF).tagColorField, "00000FF")   // MainForm.cs:60 default
        t.equal(RGB8(r: 0xFF, g: 0xFF, b: 0xFF).tagColorField, "0FFFFFF")
        t.equal(RGB8(r: 0, g: 0, b: 0).tagColorField, "0000000")
        t.equal(RGB8(r: 0xC1, g: 0x2E, b: 0x1F).tagColorField, "0C12E1F")
        // Round-trip through the parser, which is what a tag read path does.
        t.equal(try RGB8(hex: RGB8(r: 0xC1, g: 0x2E, b: 0x1F).tagColorField),
                RGB8(r: 0xC1, g: 0x2E, b: 0x1F))
    },

    // THE GUARD. ColorMatcher.cs:74 uses Convert.ToInt32(hex, 16), which is length-agnostic:
    // it parses "3C12E1F" as 0x3C12E1 — every channel shifted a nibble — and matches a
    // completely different colour with no error. The nibble's meaning is unknown
    // (SPEC-05 §7 open question 1), so we refuse rather than guess.
    test("rejects a 7-char field with a non-zero leading nibble instead of shifting it") { t in
        t.throwsError(ColorHexError.nonZeroLeadingNibble("3C12E1F")) {
            _ = try RGB8(hex: "3C12E1F")
        }
        t.throwsError(ColorHexError.nonZeroLeadingNibble("FFFFFFF")) {
            _ = try RGB8(hex: "FFFFFFF")
        }
        // The failure mode being prevented: silently becoming a plausible but wrong colour.
        t.equal(RGB8(packed: 0x3C12E1F), RGB8(r: 0xC1, g: 0x2E, b: 0x1F),
                "masking would keep the low 24 bits...")
        t.expect((try? RGB8(hex: "3C12E1F")) == nil, "...but the parser must not do that quietly")
    },

    test("rejects malformed hex") { t in
        t.throwsError(ColorHexError.empty) { _ = try RGB8(hex: "") }
        t.throwsError(ColorHexError.empty) { _ = try RGB8(hex: "#") }
        t.throwsError(ColorHexError.empty) { _ = try RGB8(hex: "   ") }
        t.throwsError(ColorHexError.invalidCharacter("GGGGGG")) { _ = try RGB8(hex: "GGGGGG") }
        t.throwsError(ColorHexError.invalidCharacter("C12E1Z")) { _ = try RGB8(hex: "C12E1Z") }
        t.throwsError(ColorHexError.tooShort("FFF", digits: 3)) { _ = try RGB8(hex: "FFF") }
        t.throwsError(ColorHexError.tooShort("#12345", digits: 5)) { _ = try RGB8(hex: "#12345") }
        t.throwsError(ColorHexError.tooLong("FF00FF00", digits: 8)) { _ = try RGB8(hex: "FF00FF00") }
    },

    test("hex errors carry a readable description") { t in
        let error = ColorHexError.nonZeroLeadingNibble("3C12E1F")
        guard let text = t.unwrap(error.errorDescription) else { return }
        t.expect(text.contains("3C12E1F"), "description should quote the offending input")
        t.expect(!text.isEmpty)
    },

    test("matcher surfaces hex errors rather than matching garbage") { t in
        let matcher = try colorMatcher()
        t.throwsError("nearestName(forHex: \"nope\")") { _ = try matcher.nearestName(forHex: "nope") }
        t.throwsError("nearestName(forHex: \"3C12E1F\")") { _ = try matcher.nearestName(forHex: "3C12E1F") }
    },
])

let colorTableIntegrityTests = TestSuite(name: "Colour table integrity", cases: [

    // The C# loader is `try { … } catch {}` (ColorMatcher.cs:37,67): a corrupt or missing
    // dataset yields an empty list and every lookup silently returns null, with no signal to
    // the user or the log. These tests pin the opposite behaviour — a descriptive throw.

    test("missing resource throws rather than yielding an empty table") { t in
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("k2-empty-bundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let empty = t.unwrap(Bundle(url: dir), "bundle for empty directory") else { return }
        t.throwsError(ColorTableError.resourceMissing(name: "colors.bin")) {
            _ = try ColorTable(bundle: empty)
        }
    },

    test("an empty blob throws tooSmall") { t in
        t.throwsError(ColorTableError.tooSmall(bytes: 0)) { _ = try ColorTable(blob: Data()) }
        t.throwsError(ColorTableError.tooSmall(bytes: 4)) {
            _ = try ColorTable(blob: Data([0x4B, 0x32, 0x43, 0x54]))
        }
    },

    test("a foreign file throws badMagic") { t in
        var blob = Data(repeating: 0, count: 64)
        blob.replaceSubrange(0..<4, with: Array("SQLi".utf8))
        t.throwsError(ColorTableError.badMagic(found: "SQLi")) { _ = try ColorTable(blob: blob) }
    },

    test("a future format version throws instead of misreading the layout") { t in
        var blob = try loadColorBlob()
        blob[4] = 99
        t.throwsError(ColorTableError.unsupportedVersion(99)) { _ = try ColorTable(blob: blob) }
    },

    test("a truncated blob throws sizeMismatch") { t in
        let blob = try loadColorBlob()
        t.throwsError("truncated blob") { _ = try ColorTable(blob: blob.dropLast(1)) }
        t.throwsError("blob with trailing junk") {
            _ = try ColorTable(blob: blob + Data([0x00]))
        }
    },

    test("a single flipped payload byte throws checksumMismatch") { t in
        var blob = try loadColorBlob()
        // Byte 24 is the red channel of record 0 — the difference between "100 Mph" being
        // #c93f38 and being something else entirely.
        blob[24] ^= 0x01
        t.throwsError("corrupt payload") { _ = try ColorTable(blob: blob) }
        do {
            _ = try ColorTable(blob: blob)
        } catch let error as ColorTableError {
            if case .checksumMismatch = error {
                guard let text = t.unwrap(error.errorDescription) else { return }
                t.expect(text.contains("corrupt"), "description should say what went wrong")
            } else {
                t.expect(false, "expected checksumMismatch, got \(error)")
            }
        }
    },

    test("the bundled blob parses and its header agrees with the payload") { t in
        let blob = try loadColorBlob()
        t.equal(String(decoding: blob[0..<4], as: UTF8.self), "K2CT", "magic")
        let table = try ColorTable(blob: blob)
        t.equal(table.count, 31_861)
        t.equal(table.packedColors.count, 31_861)
        t.equal(table.packedColors[0], 0x00C9_3F38, "record 0 packed value")
        t.equal(table.packedColors[31_860], 0x002B_61A0, "last record packed value")
    },
])

/// Reads the generated resource straight off disk so integrity tests can damage a copy.
private func loadColorBlob() throws -> Data {
    try Data(contentsOf: ColorTable.resourceURL())
}
