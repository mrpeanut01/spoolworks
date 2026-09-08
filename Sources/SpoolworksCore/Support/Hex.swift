import Foundation

public extension Array where Element == UInt8 {
    /// Uppercase hex with no separator, e.g. `"80A67939"`.
    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }

    /// Uppercase hex, space-separated, e.g. `"80 A6 79 39"`.
    var hexStringSpaced: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// Printable-ASCII rendering with `.` for non-printable bytes, as in a hex dump.
    var asciiDump: String {
        String(map { $0 >= 0x20 && $0 < 0x7F ? Character(UnicodeScalar($0)) : "." })
    }

    /// Parses a hex string. Ignores spaces and colons. Returns nil on odd length or bad digits.
    init?(hexString: String) {
        let cleaned = hexString
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ":", with: "")
        guard cleaned.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }
}

public extension String {
    /// Convenience for building APDUs and fixtures from hex literals.
    var hexBytes: [UInt8]? { [UInt8](hexString: self) }
}
