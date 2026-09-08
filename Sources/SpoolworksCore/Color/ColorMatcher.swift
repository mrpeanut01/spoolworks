import Foundation

/// Nearest-named-colour lookup. Port of `Windows/CFS-RFID/ColorMatcher.cs:70-99`.
///
/// The metric is plain unweighted Euclidean distance on raw 8-bit sRGB codes — no channel
/// weighting, no CIELAB, no HSV, no gamma linearisation (SPEC-05 §2.2 and §6). That is a poor
/// perceptual metric, but it is what the Windows and Android apps do, and matching them is the
/// whole point: the same tag must resolve to the same name on every platform.
///
/// Cost is a 31,861-iteration scan per lookup: measured at 0.037 ms in a release build on
/// Apple silicon, so there is no reason to reach for a spatial index. Note that an unoptimised
/// debug build is ~370× slower (~14 ms) because of bounds and overflow checks — that is a
/// build-configuration artifact, not a reason to restructure the loop. The C# version
/// re-unzips and re-parses the entire 704 KB CSV on every dialog (`SmDialog.cs:58`); we hold
/// one parsed `ColorTable` instead.
public struct ColorMatcher {
    public let table: ColorTable

    public init(table: ColorTable) {
        self.table = table
    }

    /// A matcher over the bundled dataset, sharing the process-wide table.
    public static func shared() throws -> ColorMatcher {
        ColorMatcher(table: try ColorTable.shared())
    }

    // MARK: - rgb → name

    /// Index of the nearest table entry, or nil only if the table is empty.
    ///
    /// Two deliberate properties, both required for cross-platform parity:
    ///
    /// 1. **Squared distance, integer arithmetic, no `sqrt`.** C# computes
    ///    `Math.Sqrt(Math.Pow(dr,2) + …)` in `Double`. `sqrt` is strictly monotonic on
    ///    non-negative reals, so it cannot change which entry is smallest — dropping it removes
    ///    every floating-point rounding concern and makes this *provably* identical to the C#
    ///    across all 2^24 possible inputs rather than identical-in-practice. The maximum
    ///    squared distance is `3 × 255² = 195,075`, which is nowhere near `Int32.max`, so no
    ///    overflow is possible (SPEC-05 §8.2).
    ///
    /// 2. **Strict `<`, scanned front to back.** `ColorMatcher.cs:87` is `if (distance <
    ///    minDistance)`, so the *first* row in CSV order wins any tie. Ties are real and
    ///    reachable: `#EAD742` is exactly equidistant from `Meadowlark` (row 17,219) and
    ///    `Sandstorm` (row 24,631). This loop must therefore stay sequential and ascending —
    ///    do not parallelise the reduction, do not substitute a k-d tree or octree, and do not
    ///    sort the table. A naive parallel min picks a nondeterministic winner on ties, which
    ///    would show up as a name that silently changes between runs (SPEC-05 §2.3).
    public func nearestIndex(to color: RGB8) -> Int? {
        let targetR = Int32(color.r)
        let targetG = Int32(color.g)
        let targetB = Int32(color.b)

        var bestIndex = -1
        var bestDistance = Int32.max

        table.packedColors.withUnsafeBufferPointer { entries in
            for i in 0..<entries.count {
                let packed = entries[i]
                let dr = targetR - Int32((packed >> 16) & 0xFF)
                let dg = targetG - Int32((packed >> 8) & 0xFF)
                let db = targetB - Int32(packed & 0xFF)
                let distance = dr * dr + dg * dg + db * db
                if distance < bestDistance {      // strict `<` ⇒ lowest row index wins
                    bestDistance = distance
                    bestIndex = i
                }
            }
        }

        return bestIndex >= 0 ? bestIndex : nil
    }

    /// The nearest entry, including its row index and its own hex.
    ///
    /// The C# returns only the name and discards the index, hex, and distance
    /// (SPEC-05 §2.4); we keep them because they are free and the index is what makes
    /// tie-break behaviour testable.
    public func nearest(to color: RGB8) -> ColorEntry? {
        nearestIndex(to: color).map { table.entry(at: $0) }
    }

    /// The nearest entry's name, or nil if the table is empty.
    ///
    /// Callers should mirror the Windows fallback chain — user text → matched name → raw hex
    /// (`MainForm.cs:899-911`) — rather than showing an empty string.
    public func nearestName(to color: RGB8) -> String? {
        nearest(to: color)?.name
    }

    /// Squared Euclidean distance to a specific entry. Exposed for tests and diagnostics;
    /// take `sqrt` only if you want to print a number, never to compare two of them.
    public func squaredDistance(from color: RGB8, toIndex index: Int) -> Int32 {
        let other = table.rgb(at: index)
        let dr = Int32(color.r) - Int32(other.r)
        let dg = Int32(color.g) - Int32(other.g)
        let db = Int32(color.b) - Int32(other.b)
        return dr * dr + dg * dg + db * db
    }

    // MARK: - Hex entry points

    /// Nearest name for a hex string.
    ///
    /// Accepts `"RRGGBB"`, `"#RRGGBB"` and the 7-character tag field `"0RRGGBB"`, and throws
    /// `ColorHexError` on anything else — notably on a 7-character field whose leading nibble
    /// is not `'0'`, which the C# would silently mis-parse into a shifted colour. See
    /// `RGB8.init(hex:)` for why that case is rejected rather than masked.
    ///
    /// This is the direct analogue of `ColorMatcher.FindNearestColor(string)`, except that the
    /// C# returns `null` for an empty table and `String.Empty` for a hex-parse failure
    /// (SPEC-05 §7 open question 5). Nothing observes that distinction, so here a parse failure
    /// throws and an empty table returns nil.
    public func nearestName(forHex hex: String) throws -> String? {
        nearestName(to: try RGB8(hex: hex))
    }

    public func nearest(forHex hex: String) throws -> ColorEntry? {
        nearest(to: try RGB8(hex: hex))
    }

    // MARK: - name → hex

    /// Exact (case-insensitive) name lookup, returning `"#rrggbb"`.
    ///
    /// This is *not* the inverse of `nearestName`: 31,861 names map onto 16.7 million colours,
    /// so `hex(forName: nearestName(to: c))` returns the palette entry, not `c`.
    public func hex(forName name: String) -> String? {
        table.hex(forName: name)
    }

    public func entry(forName name: String) -> ColorEntry? {
        table.entry(forName: name)
    }
}
