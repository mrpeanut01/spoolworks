import Foundation
import CryptoKit

// MARK: - Content fingerprint

/// A short, stable digest of what a catalogue record *says* — its `base` and its `kvParam` — used
/// to tell a record nobody has touched from one that has been changed.
///
/// ## Why content, not a flag
///
/// A catalogue update has to reach the records someone already has, and must not reach the ones
/// they changed. A "modified" flag would only ever see edits made in this app's editor; it would
/// miss a printer download, a hand-edited file, and every record added before the flag existed.
/// Comparing content catches all of them. Every version of every record this app has shipped has a
/// fingerprint in the bundled refresh index, so a local record whose fingerprint is one of those is
/// *by construction* exactly as shipped and may be brought up to date. Anything else differs from
/// every version we shipped, for whatever reason, and is left alone.
///
/// ## Two implementations must agree
///
/// The index is built by `Tools/build-refresh-index.py` from the catalogues' git history, so this
/// digest is computed in Python there and in Swift here. The canonical form avoids everything two
/// JSON libraries disagree about: keys sort by UTF-8 bytes, every value carries a type tag,
/// integral numbers are written without a fraction (so `0`, `0.0` and `1.0` cannot diverge), other
/// numbers use the shortest round-trip form both languages print, and nothing depends on
/// whitespace, escaping or the key order in a file. A test recomputes every fingerprint in the
/// bundled index, so a disagreement fails the build instead of silently refreshing nothing.
///
/// Provenance (`sourceProfile`, `sourceTemplate`, `sourceConflicts`) sits outside `base` and
/// `kvParam` and is deliberately not covered: it records where a record came from, not what it
/// tells the printer.
public enum FilamentFingerprint {

    /// Sixteen hex characters: the first 64 bits of a SHA-256 over the canonical form.
    public static func of(_ filament: Filament) -> String {
        guard let base = canonicalBase(filament.base) else { return "" }
        var entries: [String] = []
        for key in base.keys.sorted(by: byteOrder) {
            entries.append("base." + key + unit + render(base[key]!))
        }
        for key in filament.kvParam.keys.sorted(by: byteOrder) {
            entries.append("kv." + key + unit + "s:" + filament.kvParam[key]!)
        }
        let digest = SHA256.hash(data: Data(entries.joined(separator: record).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// `base` as the JSON object it is written as. Going through the encoder rather than reading
    /// properties is what gets the key set right: `MaterialBase` emits the keys its source carried
    /// plus the unmodelled ones, and that — not every modelled key — is the record.
    static func canonicalBase(_ base: MaterialBase) -> [String: JSONValue]? {
        guard let data = try? JSONEncoder().encode(base) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    static func render(_ value: JSONValue) -> String {
        switch value {
        case .null:
            return "z"
        case let .bool(flag):
            return flag ? "b:1" : "b:0"
        case let .int(number):
            return "n:\(number)"
        case let .double(number):
            if number.isFinite, number == number.rounded(), abs(number) < 9_007_199_254_740_992 {
                return "n:\(Int64(number))"
            }
            return "n:\(number)"
        case let .string(text):
            return "s:" + text
        case let .array(items):
            return "a:[" + items.map(render).joined(separator: group) + "]"
        case let .object(fields):
            return "o:{" + fields.keys.sorted(by: byteOrder)
                .map { $0 + unit + render(fields[$0]!) }
                .joined(separator: group) + "}"
        }
    }

    /// UTF-8 byte order — what Python's `sorted()` gives for the same keys. Swift's `<` on `String`
    /// is defined over Unicode and is not a promise about bytes.
    private static func byteOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }

    private static let unit = "\u{1F}"
    private static let group = "\u{1D}"
    private static let record = "\u{1E}"
}
