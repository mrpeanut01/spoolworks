import Foundation
import CryptoKit

// Adding one filament to a printer's own `material_database.json`, and nothing else.
//
// `PrinterService.upload` replaces the printer's catalogue with the Mac's. That is the right tool
// for a reset and the wrong one for a single spool: the printer's database moves on without the
// Mac — Creality's updater rewrites it, and Creality Print syncs user presets into it as extra
// records that share their parent's id — so a whole-file upload rolls all of that back to whatever
// the Mac last saw. On 2026-09-11 a K2 Plus held five ids the bundled catalogue does not, newer
// content for all 96 it shares, and three `userMaterial` records under one id that a merge by id
// would have folded into one.
//
// So this works on the printer's own bytes. It finds where `result.list` ends, renders the one new
// record in the file's own layout, and splices it in; the only other change is `result.count`.
// Re-encoding instead would reorder every key and reformat every number in a file the firmware
// wrote — harmless to a JSON parser, but not what was validated on the printer, which was the
// printer's file byte for byte plus one record. See D-013.

/// Why a filament could not be added to a printer's database.
public enum FilamentSpliceError: Error, Equatable, CustomStringConvertible {
    /// The printer already lists this id. Nothing to add.
    case alreadyPresent(id: String)
    /// The file is not the `{code, msg, result: {list: […]}}` envelope the printer writes.
    case malformed(String)
    /// The spliced file did not check out against the original, so it was not used.
    case verificationFailed(String)

    public var description: String {
        switch self {
        case let .alreadyPresent(id):
            return "The printer already lists filament \(id)."
        case let .malformed(detail):
            return "The printer's material database could not be read: \(detail)"
        case let .verificationFailed(detail):
            return "Spoolworks stopped before changing the printer's material database: \(detail)"
        }
    }
}

extension FilamentSpliceError: LocalizedError {
    public var errorDescription: String? { description }
}

public enum PrinterMaterialDocument {

    /// Keys the vendor catalogue adds to say where a record came from (`build-vendor-catalogue.py`).
    /// They describe Spoolworks' sources, not anything the printer reads, so they stay on the Mac.
    public static let provenanceKeys: Set<String> = ["sourceProfile", "sourceTemplate", "sourceConflicts"]

    /// The record-level key order every record in a printer capture follows.
    static let recordKeyOrder = ["engineVersion", "printerIntName", "nozzleDiameter", "kvParam", "base"]

    /// The `base` key order every record in a printer capture follows. `alias` is in every printer
    /// record and in no Spoolworks-built one, which is why ``printerShaped(_:)`` adds it.
    static let baseKeyOrder = ["id", "brand", "name", "alias", "meterialType", "colors", "density",
                               "diameter", "costPerMeter", "weightPerMeter", "rank", "minTemp",
                               "maxTemp", "isSoluble", "isSupport", "shrinkageRate", "softeningTemp",
                               "dryingTemp", "dryingTime", "dryingTempLow", "dryingTempHigh"]

    /// Every `result.list[].base.id`, in file order, duplicates kept.
    public static func filamentIDs(in data: Data) throws -> [String] {
        try list(of: parse(data)).compactMap(id(of:))
    }

    /// `data` with `filament` appended to `result.list` and `result.count` raised by one. Every
    /// other byte is the printer's.
    public static func appending(_ filament: Filament, to data: Data) throws -> Data {
        let original = try parse(data)
        let originalList = try list(of: original)
        guard !originalList.compactMap(id(of:)).contains(filament.id) else {
            throw FilamentSpliceError.alreadyPresent(id: filament.id)
        }

        let bytes = [UInt8](data)
        var scanner = JSONLayoutScanner(bytes: bytes)
        let layout: JSONLayoutScanner.Layout
        do {
            layout = try scanner.scan()
        } catch {
            throw FilamentSpliceError.malformed("\(error)")
        }

        let style = layout.elementStyle
        let rendered = JSONText.render(try printerShaped(filament), style: style, level: 0, path: [])

        var edits: [(range: Range<Int>, replacement: [UInt8])] = []
        if let end = layout.lastElementEnd {
            edits.append((end..<end, Array(("," + style.separatorBeforeElement + rendered).utf8)))
        } else {
            let start = layout.listOpen + 1
            edits.append((start..<start, Array(rendered.utf8)))
        }
        if let countRange = layout.countRange {
            edits.append((countRange, Array(String(originalList.count + 1).utf8)))
        }
        // Back to front, so an edit never moves the bytes a later one points at.
        var output = bytes
        for edit in edits.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            output.replaceSubrange(edit.range, with: edit.replacement)
        }

        let result = Data(output)
        try verify(result, against: original, adding: filament.id, updatesCount: layout.countRange != nil)
        return result
    }

    /// Lower-case hex MD5, the form busybox `md5sum` prints on the printer. That is the only reason
    /// it is MD5: it notices a file that changed, it does not defend against anyone.
    public static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Record shape

    /// `filament` as the printer's own records spell it: Spoolworks' provenance keys removed, and
    /// `base.alias` present.
    static func printerShaped(_ filament: Filament) throws -> [String: Any] {
        let encoded: Data
        do {
            encoded = try MaterialDatabase.makeEncoder().encode(filament)
        } catch {
            throw FilamentSpliceError.malformed("filament \(filament.id) could not be encoded: \(error)")
        }
        guard var record = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] else {
            throw FilamentSpliceError.malformed("filament \(filament.id) did not encode to an object")
        }
        for key in provenanceKeys { record[key] = nil }
        if var base = record["base"] as? [String: Any] {
            if base["alias"] == nil { base["alias"] = "" }
            record["base"] = base
        }
        return record
    }

    // MARK: Checks

    private static func verify(_ data: Data, against original: [String: Any], adding id: String,
                               updatesCount: Bool) throws {
        func failure(_ why: String) -> FilamentSpliceError { .verificationFailed(why) }

        guard let merged = try? parse(data), let mergedList = try? list(of: merged) else {
            throw failure("the result is not valid JSON")
        }
        let originalList = try list(of: original)
        guard mergedList.count == originalList.count + 1 else {
            throw failure("the record count did not grow by exactly one")
        }
        guard NSArray(array: Array(mergedList.dropLast())).isEqual(to: originalList) else {
            throw failure("an existing record changed")
        }
        guard mergedList.last.flatMap(self.id(of:)) == id else {
            throw failure("the new record is not filament \(id)")
        }

        var envelope = original
        var mergedEnvelope = merged
        envelope["result"] = nil
        mergedEnvelope["result"] = nil
        guard NSDictionary(dictionary: envelope).isEqual(to: mergedEnvelope) else {
            throw failure("the envelope around the list changed")
        }

        var result = original["result"] as? [String: Any] ?? [:]
        var mergedResult = merged["result"] as? [String: Any] ?? [:]
        let mergedCount = mergedResult["count"]
        for key in ["list", "count"] {
            result[key] = nil
            mergedResult[key] = nil
        }
        guard NSDictionary(dictionary: result).isEqual(to: mergedResult) else {
            throw failure("result fields other than list and count changed")
        }
        if updatesCount, (mergedCount as? NSNumber)?.intValue != mergedList.count {
            throw failure("result.count does not match the list")
        }
    }

    // MARK: Envelope

    static func parse(_ data: Data) throws -> [String: Any] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw FilamentSpliceError.malformed("not a JSON object")
        }
        return root
    }

    static func list(of root: [String: Any]) throws -> [Any] {
        guard let result = root["result"] as? [String: Any],
              let list = result["list"] as? [Any] else {
            throw FilamentSpliceError.malformed("no result.list")
        }
        return list
    }

    static func id(of record: Any) -> String? {
        ((record as? [String: Any])?["base"] as? [String: Any])?["id"] as? String
    }
}

// MARK: - Layout

/// How a JSON file lays itself out, read off the file so a spliced record matches its neighbours.
struct JSONTextStyle: Equatable {
    /// `nil` for a compact file.
    var newline: String?
    var indentUnit: String
    /// The indentation of a `result.list` element's own line.
    var elementIndent: String
    var colon: String
    /// What sits between the comma and the next element: `"\n      "` in a printer capture.
    var separatorBeforeElement: String
}

/// Finds the byte positions a splice needs in a printer's `material_database.json` without building
/// a model of the file: where `result.list` ends, where `result.count`'s number is, and how the file
/// indents.
struct JSONLayoutScanner {

    struct Layout: Equatable {
        var listOpen: Int
        var listClose: Int
        var elementCount: Int
        /// Just past the last element's closing byte; `nil` for an empty list.
        var lastElementEnd: Int?
        var countRange: Range<Int>?
        var elementStyle: JSONTextStyle
    }

    enum ScanError: Error, Equatable, CustomStringConvertible {
        case unexpected(at: Int)
        case unterminated
        case missingList

        var description: String {
            switch self {
            case let .unexpected(offset): return "unexpected content at byte \(offset)"
            case .unterminated: return "the file ends part-way through a value"
            case .missingList: return "no result.list"
            }
        }
    }

    private struct ListMarks {
        var open: Int
        var close: Int
        var count: Int
        var lastEnd: Int?
        var separator: [UInt8]
    }

    private let bytes: [UInt8]
    private var index = 0
    private var listMarks: ListMarks?
    private var countRange: Range<Int>?
    private var colonHasSpace: Bool?

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func scan() throws -> Layout {
        index = 0
        listMarks = nil
        countRange = nil
        colonHasSpace = nil

        try value(path: [])
        skipWhitespace()
        guard index == bytes.count else { throw ScanError.unexpected(at: index) }
        guard let marks = listMarks else { throw ScanError.missingList }

        let separator = String(decoding: marks.separator, as: UTF8.self)
        let newline: String? = separator.contains("\r\n") ? "\r\n" : (separator.contains("\n") ? "\n" : nil)
        let elementIndent = newline.flatMap { separator.components(separatedBy: $0).last } ?? ""
        let style = JSONTextStyle(newline: newline,
                                  indentUnit: indentUnit() ?? "  ",
                                  elementIndent: elementIndent,
                                  colon: colonHasSpace == true ? ": " : ":",
                                  separatorBeforeElement: separator)
        return Layout(listOpen: marks.open,
                      listClose: marks.close,
                      elementCount: marks.count,
                      lastElementEnd: marks.lastEnd,
                      countRange: countRange,
                      elementStyle: style)
    }

    // MARK: Grammar

    private mutating func value(path: [String]) throws {
        skipWhitespace()
        guard index < bytes.count else { throw ScanError.unterminated }
        switch bytes[index] {
        case UInt8(ascii: "{"):
            try object(path: path)
        case UInt8(ascii: "["):
            try array(path: path)
        case UInt8(ascii: "\""):
            _ = try string()
        case UInt8(ascii: "t"):
            try literal("true")
        case UInt8(ascii: "f"):
            try literal("false")
        case UInt8(ascii: "n"):
            try literal("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            let start = index
            number()
            if path == ["result", "count"] { countRange = start..<index }
        default:
            throw ScanError.unexpected(at: index)
        }
    }

    private mutating func object(path: [String]) throws {
        index += 1
        skipWhitespace()
        if peek(UInt8(ascii: "}")) {
            index += 1
            return
        }
        while true {
            skipWhitespace()
            guard peek(UInt8(ascii: "\"")) else { throw ScanError.unexpected(at: index) }
            let key = try string()
            skipWhitespace()
            guard peek(UInt8(ascii: ":")) else { throw ScanError.unexpected(at: index) }
            index += 1
            if colonHasSpace == nil { colonHasSpace = peek(UInt8(ascii: " ")) }
            try value(path: path + [key])
            skipWhitespace()
            if peek(UInt8(ascii: ",")) {
                index += 1
                continue
            }
            if peek(UInt8(ascii: "}")) {
                index += 1
                return
            }
            throw ScanError.unexpected(at: index)
        }
    }

    private mutating func array(path: [String]) throws {
        let open = index
        let isList = path == ["result", "list"]
        index += 1
        var gapStart = index
        skipWhitespace()
        if peek(UInt8(ascii: "]")) {
            if isList { listMarks = ListMarks(open: open, close: index, count: 0, lastEnd: nil, separator: []) }
            index += 1
            return
        }
        var count = 0
        var lastEnd: Int?
        var separator: [UInt8] = []
        while true {
            // `value` skips the same whitespace; taking it here is what records the file's layout.
            skipWhitespace()
            let gap = Array(bytes[gapStart..<index])
            try value(path: path + ["[]"])
            count += 1
            if isList {
                lastEnd = index
                separator = gap
            }
            skipWhitespace()
            if peek(UInt8(ascii: ",")) {
                index += 1
                gapStart = index
                continue
            }
            if peek(UInt8(ascii: "]")) {
                if isList {
                    listMarks = ListMarks(open: open, close: index, count: count, lastEnd: lastEnd,
                                          separator: separator)
                }
                index += 1
                return
            }
            throw ScanError.unexpected(at: index)
        }
    }

    /// Consumes a string and returns its content. Escapes are stepped over rather than decoded:
    /// the only keys this scanner compares are plain ASCII.
    private mutating func string() throws -> String {
        index += 1
        var content: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return String(decoding: content, as: UTF8.self)
            }
            if byte == UInt8(ascii: "\\") {
                guard index + 1 < bytes.count else { throw ScanError.unterminated }
                content.append(byte)
                content.append(bytes[index + 1])
                index += 2
                continue
            }
            content.append(byte)
            index += 1
        }
        throw ScanError.unterminated
    }

    private mutating func number() {
        let allowed = Set("-+.eE0123456789".utf8)
        while index < bytes.count, allowed.contains(bytes[index]) { index += 1 }
    }

    private mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)]) == expected else {
            throw ScanError.unexpected(at: index)
        }
        index += expected.count
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private func peek(_ byte: UInt8) -> Bool {
        index < bytes.count && bytes[index] == byte
    }

    /// The leading whitespace of the file's second line — one level of indentation.
    private func indentUnit() -> String? {
        guard let newline = bytes.firstIndex(of: 0x0A) else { return nil }
        var end = newline + 1
        while end < bytes.count, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
        return end > newline + 1 ? String(decoding: bytes[(newline + 1)..<end], as: UTF8.self) : nil
    }
}

// MARK: - Rendering

/// Renders a Foundation JSON value in a given layout. It matches what the printer writes — two-space
/// indent, `"key":value`, arrays one element per line, `[]` and `{}` when empty — which is also
/// Python's `json.dumps(indent=2, separators=(",", ":"), ensure_ascii=False)`.
enum JSONText {

    static func render(_ value: Any, style: JSONTextStyle, level: Int, path: [String]) -> String {
        switch value {
        case let object as [String: Any]:
            guard !object.isEmpty else { return "{}" }
            let parts = orderedKeys(object, path: path).map { key in
                quote(key) + style.colon
                    + render(object[key] ?? NSNull(), style: style, level: level + 1, path: path + [key])
            }
            return wrap(parts, open: "{", close: "}", style: style, level: level)
        case let array as [Any]:
            guard !array.isEmpty else { return "[]" }
            let parts = array.map { render($0, style: style, level: level + 1, path: path + ["[]"]) }
            return wrap(parts, open: "[", close: "]", style: style, level: level)
        case let string as String:
            return quote(string)
        case let number as NSNumber:
            return literal(number)
        default:
            return "null"
        }
    }

    static func quote(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case let control where control.value < 0x20:
                out += String(format: "\\u%04x", control.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func wrap(_ parts: [String], open: String, close: String,
                             style: JSONTextStyle, level: Int) -> String {
        guard let newline = style.newline else {
            return open + parts.joined(separator: ",") + close
        }
        let inner = newline + style.elementIndent + String(repeating: style.indentUnit, count: level + 1)
        let outer = newline + style.elementIndent + String(repeating: style.indentUnit, count: level)
        return open + inner + parts.joined(separator: "," + inner) + outer + close
    }

    private static func orderedKeys(_ object: [String: Any], path: [String]) -> [String] {
        let preferred: [String]
        switch path {
        case []: preferred = PrinterMaterialDocument.recordKeyOrder
        case ["base"]: preferred = PrinterMaterialDocument.baseKeyOrder
        default: preferred = []
        }
        let leading = preferred.filter { object[$0] != nil }
        let rest = object.keys.filter { !preferred.contains($0) }.sorted()
        return leading + rest
    }

    private static func literal(_ number: NSNumber) -> String {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        if CFNumberIsFloatType(number as CFNumber) {
            let value = number.doubleValue
            return value.isFinite ? "\(value)" : "null"
        }
        return number.stringValue
    }
}
