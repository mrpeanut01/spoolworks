import Foundation
import CPCSC

/// A PC/SC layer failure, or a card-level failure reported through an APDU status word.
public enum PCSCError: Error, Equatable {
    /// A `SCARD_*` status code returned by the PC/SC stack.
    case pcsc(code: Int32, message: String)
    /// The card returned a status word other than 90 00.
    case statusWord(sw1: UInt8, sw2: UInt8)
    /// A response was shorter than the minimum two status bytes.
    case truncatedResponse(length: Int)
    /// No reader matching the request is attached.
    case noReader
    /// A reader is attached but no card is on it.
    case noCard
    /// Authentication against a sector failed with every key we tried.
    case authenticationFailed(sector: Int)
    /// The operation is not supported by this reader or by macOS's PC/SC stack.
    case unsupported(String)
    /// A block index outside the range this card can address.
    ///
    /// Every MIFARE APDU carries the block as a single byte, so an out-of-range `Int` used to be
    /// a `fatalError` in `UInt8(block)` rather than an error a caller could handle.
    case blockOutOfRange(block: Int, count: Int)
    /// Another application reset the card while we were using it (`SCARD_W_RESET_CARD`).
    ///
    /// Worth its own case: it is recoverable — reconnect and retry — and mid-write it is the one
    /// failure the user most needs told apart from "the tag is broken".
    case cardReset
    /// The PC/SC request timed out (`SCARD_E_TIMEOUT`).
    case timedOut
    /// The request was cancelled, e.g. by `PCSCContext.cancelPendingWaits()` during shutdown.
    case cancelled

    /// Raw `SCARD_*` status codes we branch on. PC/SC returns these as unsigned 32-bit values;
    /// the shim widens them to Int32, so the bit patterns are negative here.
    ///
    /// Nested so the code constants cannot collide with the case names they map to.
    enum Code {
        static let noSmartcard = Int32(bitPattern: 0x8010_000C)
        static let unsupportedFeature = Int32(bitPattern: 0x8010_0011)
        static let readerUnavailable = Int32(bitPattern: 0x8010_0017)
        static let removedCard = Int32(bitPattern: 0x8010_0069)
        static let resetCard = Int32(bitPattern: 0x8010_0068)
        static let timeout = Int32(bitPattern: 0x8010_000A)
        static let cancelled = Int32(bitPattern: 0x8010_0002)
    }

    /// Maps a raw PC/SC status code to an error, or `nil` on success.
    static func from(_ rv: Int32) -> PCSCError? {
        guard rv != 0 else { return nil }
        switch rv {
        case Code.noSmartcard, Code.removedCard: return .noCard
        case Code.readerUnavailable: return .noReader
        case Code.unsupportedFeature: return .unsupported(stringify(rv))
        // These three were declared and never mapped, so a recoverable mid-write card reset
        // surfaced as an opaque hex code with no hint that retrying would work.
        case Code.resetCard: return .cardReset
        case Code.timeout: return .timedOut
        case Code.cancelled: return .cancelled
        default: return .pcsc(code: rv, message: stringify(rv))
        }
    }

    static func stringify(_ rv: Int32) -> String {
        guard let c = k2_error_string(rv) else { return String(format: "0x%08X", UInt32(bitPattern: rv)) }
        return String(cString: c)
    }
}

extension PCSCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .pcsc(code, message):
            return "\(message) (0x\(String(format: "%08X", UInt32(bitPattern: code))))"
        case let .statusWord(sw1, sw2):
            return "Card returned \(String(format: "%02X %02X", sw1, sw2)): \(Self.describeSW(sw1, sw2))"
        case let .truncatedResponse(length):
            return "Card response was too short (\(length) bytes)"
        case .noReader:
            return "No card reader is connected."
        case .noCard:
            return "No tag is on the reader."
        case let .authenticationFailed(sector):
            return "Could not authenticate to sector \(sector) with any known key."
        case let .unsupported(what):
            return "Not supported on this system: \(what)"
        case let .blockOutOfRange(block, count):
            return "Block \(block) is outside this card's range of 0…\(count - 1)."
        case .cardReset:
            return "The tag was reset by another application. Leave it on the reader and try again."
        case .timedOut:
            return "The reader did not respond in time."
        case .cancelled:
            return "The operation was cancelled."
        }
    }

    /// Human-readable meaning for the status words the ACS readers actually emit.
    static func describeSW(_ sw1: UInt8, _ sw2: UInt8) -> String {
        switch (sw1, sw2) {
        case (0x90, 0x00): return "Success"
        case (0x63, 0x00): return "Operation failed"
        case (0x69, 0x81): return "Command incompatible with file structure"
        case (0x69, 0x82): return "Security status not satisfied — wrong key"
        case (0x69, 0x86): return "Command not allowed"
        case (0x6A, 0x81): return "Function not supported"
        case (0x6A, 0x82): return "File or block not found"
        case (0x6B, 0x00): return "Wrong parameter"
        case (0x67, 0x00): return "Wrong length"
        case (0x6D, 0x00): return "Instruction not supported by this reader"
        default: return "Unknown status"
        }
    }
}

/// A card response: payload plus the trailing two status bytes.
public struct APDUResponse: Equatable {
    public let data: [UInt8]
    public let sw1: UInt8
    public let sw2: UInt8

    public init(raw: [UInt8]) throws {
        guard raw.count >= 2 else { throw PCSCError.truncatedResponse(length: raw.count) }
        self.data = Array(raw.dropLast(2))
        self.sw1 = raw[raw.count - 2]
        self.sw2 = raw[raw.count - 1]
    }

    public init(data: [UInt8], sw1: UInt8, sw2: UInt8) {
        self.data = data; self.sw1 = sw1; self.sw2 = sw2
    }

    public var isSuccess: Bool { sw1 == 0x90 && sw2 == 0x00 }

    /// Returns the payload, or throws if the card reported a non-success status.
    @discardableResult
    public func checked() throws -> [UInt8] {
        guard isSuccess else { throw PCSCError.statusWord(sw1: sw1, sw2: sw2) }
        return data
    }
}
