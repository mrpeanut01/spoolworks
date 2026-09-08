import Foundation

/// Anything that can exchange an APDU with a card.
///
/// The whole MIFARE layer is written against this protocol so it can be driven by
/// `MockTransport` in tests, with no reader attached.
public protocol APDUTransport: AnyObject {
    func transmit(_ apdu: [UInt8]) throws -> APDUResponse

    /// Resets the card session.
    ///
    /// A failed MIFARE authentication leaves the card's crypto state poisoned: every subsequent
    /// command on the same session fails too, so trying a second key without a reset always
    /// reports failure regardless of whether that key is correct. The Arduino firmware works
    /// around this by re-selecting the card (`PICC_IsNewCardPresent` + `PICC_ReadCardSerial`)
    /// between key attempts; over PC/SC the equivalent is `SCardReconnect` with a card reset.
    ///
    /// Observed on real hardware: an ACR1552 with a programmed tag reported auth failure on
    /// *every* sector — including factory-key sector 0 — purely because an earlier wrong-key
    /// attempt was never reset.
    func reset() throws
}

public extension APDUTransport {
    /// Transports with no session state need do nothing.
    func reset() throws {}
}

/// A 6-byte MIFARE Classic sector key.
public struct MifareKey: Equatable, Hashable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(bytes: [UInt8]) {
        guard bytes.count == 6 else { return nil }
        self.bytes = bytes
    }

    public init?(hex: String) {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ":", with: "")
        guard cleaned.count == 12, let b = [UInt8](hexString: cleaned) else { return nil }
        self.bytes = b
    }

    /// The factory-default key, `FFFFFFFFFFFF`.
    public static let `default` = MifareKey(bytes: [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])!

    public var description: String { bytes.hexString }
}

/// Which of a sector's two keys to authenticate with.
public enum MifareKeyType: UInt8, CaseIterable, CustomStringConvertible {
    case keyA = 0x60
    case keyB = 0x61

    public var description: String { self == .keyA ? "A" : "B" }
}

/// Identifies the card type carried in a PC/SC storage-card ATR.
public enum CardType: Equatable, CustomStringConvertible {
    case mifareClassic1K
    case mifareClassic4K
    case mifareUltralight
    case mifareMini
    case mifarePlus
    case desfire
    case other(code: UInt16)
    case unknown

    /// Parses a PC/SC v2 storage-card ATR:
    /// `3B 8F 80 01 80 4F 0C A0 00 00 03 06 <SS> <C0 C1> ...`
    public static func from(atr: [UInt8]) -> CardType {
        guard atr.count >= 15, atr[4] == 0x80, atr[5] == 0x4F else { return .unknown }
        let code = UInt16(atr[13]) << 8 | UInt16(atr[14])
        switch code {
        case 0x0001: return .mifareClassic1K
        case 0x0002: return .mifareClassic4K
        case 0x0003: return .mifareUltralight
        case 0x0026: return .mifareMini
        case 0x0036, 0x0037, 0x0038, 0x0039: return .mifarePlus
        case 0xFF88: return .desfire
        default: return .other(code: code)
        }
    }

    public var description: String {
        switch self {
        case .mifareClassic1K: return "MIFARE Classic 1K"
        case .mifareClassic4K: return "MIFARE Classic 4K"
        case .mifareUltralight: return "MIFARE Ultralight"
        case .mifareMini: return "MIFARE Mini"
        case .mifarePlus: return "MIFARE Plus"
        case .desfire: return "MIFARE DESFire"
        case let .other(code): return String(format: "Unknown card (0x%04X)", code)
        case .unknown: return "Unknown card"
        }
    }

    /// Only Classic 1K carries the Creality spool layout.
    public var isSupported: Bool { self == .mifareClassic1K }
}
