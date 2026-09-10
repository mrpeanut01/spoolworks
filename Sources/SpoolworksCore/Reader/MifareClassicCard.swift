import Foundation

/// High-level MIFARE Classic 1K operations over the ACS pseudo-APDU set.
///
/// These pseudo-APDUs (class `FF`) are implemented by ACS readers including the ACR122U that the
/// Windows app targets and the ACR1552 used here, so the same code drives both. Reader-specific
/// escapes (buzzer, firmware string) are deliberately kept optional and non-fatal — see D-004.
public final class MifareClassicCard {
    public static let blockSize = 16
    public static let blockCount = 64
    public static let sectorCount = 16
    public static let blocksPerSector = 4

    private let transport: APDUTransport
    /// Volatile key slot on the reader that `loadKey` writes into.
    private let keySlot: UInt8 = 0x00

    public init(transport: APDUTransport) {
        self.transport = transport
    }

    // MARK: - Geometry
    //
    // This type models a MIFARE Classic **1K** and nothing else: 64 blocks, 16 sectors, four
    // blocks per sector, trailer at `block % 4 == 3`.
    //
    // A 4K card is a different shape. Its sectors 32…39 hold sixteen blocks each, so their
    // trailers sit at `block % 16 == 15` and the 1K arithmetic would wave a real trailer through
    // `writeBlock` as an ordinary data block — defeating the `allowTrailer` gate on the one
    // operation that can permanently brick a sector. Rather than leave that assumption implicit,
    // it is now enforced: every public entry point runs `validate(block:)` against `blockRange`,
    // so a 4K block index cannot reach 1K arithmetic through this class, and callers holding a
    // genuine `CardType` can ask `isTrailer(block:cardType:)` instead.

    /// The blocks a 1K card can address.
    public static let blockRange = 0..<blockCount

    /// First block index of a sector.
    public static func firstBlock(ofSector sector: Int) -> Int { sector * blocksPerSector }
    /// Trailer (last) block index of a sector. Holds keys and access bits.
    public static func trailerBlock(ofSector sector: Int) -> Int { sector * blocksPerSector + 3 }
    /// Sector containing a block.
    public static func sector(ofBlock block: Int) -> Int { block / blocksPerSector }

    /// True if the block is a sector trailer on a **1K** card — writing one can permanently lock
    /// the sector. See `isTrailer(block:cardType:)` for other card types.
    public static func isTrailer(block: Int) -> Bool {
        isTrailer(block: block, cardType: .mifareClassic1K)
    }

    /// True if the block is a sector trailer on a card of the given type.
    ///
    /// Only the 4K layout differs from the uniform four-block sector, and only above block 128.
    public static func isTrailer(block: Int, cardType: CardType) -> Bool {
        guard block >= 0 else { return false }
        switch cardType {
        case .mifareClassic4K:
            // Sectors 0…31 are four blocks (0…127); sectors 32…39 are sixteen (128…255).
            return block < 128 ? block % 4 == 3 : block % 16 == 15
        default:
            return block % blocksPerSector == blocksPerSector - 1
        }
    }

    /// Block 0 is the read-only manufacturer block (UID + vendor data).
    public static func isManufacturer(block: Int) -> Bool { block == 0 }

    /// Rejects a block index this card cannot address.
    ///
    /// Every APDU below carries the block as a single byte, and `UInt8(block)` is a `fatalError`
    /// outside 0…255 — so a `public` method taking an unchecked `Int` was a crash, not an error.
    /// Bounding to the 1K range is also what keeps the 1K trailer arithmetic above honest.
    static func validate(block: Int) throws {
        guard blockRange.contains(block) else {
            throw PCSCError.blockOutOfRange(block: block, count: blockCount)
        }
    }

    // MARK: - Identity

    /// Reads the card UID (`FF CA 00 00 00`).
    public func readUID() throws -> [UInt8] {
        try transport.transmit([0xFF, 0xCA, 0x00, 0x00, 0x00]).checked()
    }

    /// Reader firmware string (`FF 00 48 00 00`). Best-effort: many readers answer only on a
    /// direct connection, which macOS does not support (D-005), so failure is not an error.
    public func readerFirmware() -> String? {
        guard let r = try? transport.transmit([0xFF, 0x00, 0x48, 0x00, 0x00]), r.isSuccess,
              !r.data.isEmpty else { return nil }
        return String(bytes: r.data, encoding: .ascii)
    }

    /// Toggles the reader's card-detection buzzer. Best-effort; unsupported on some models.
    @discardableResult
    public func setBuzzer(_ on: Bool) -> Bool {
        guard let r = try? transport.transmit([0xFF, 0x00, 0x52, on ? 0xFF : 0x00, 0x00]) else { return false }
        return r.isSuccess
    }

    // MARK: - Authentication

    /// Loads a key into the reader's volatile key slot (`FF 82`).
    public func loadKey(_ key: MifareKey) throws {
        var apdu: [UInt8] = [0xFF, 0x82, 0x00, keySlot, 0x06]
        apdu.append(contentsOf: key.bytes)
        try transport.transmit(apdu).checked()
    }

    /// Authenticates to a block using the currently loaded key (`FF 86`, the 10-byte form).
    /// Returns false on `69 82` (wrong key) rather than throwing, so callers can try more keys.
    public func authenticate(block: Int, keyType: MifareKeyType) throws -> Bool {
        try Self.validate(block: block)
        let apdu: [UInt8] = [0xFF, 0x86, 0x00, 0x00, 0x05,
                             0x01, 0x00, UInt8(block), keyType.rawValue, keySlot]
        let r = try transport.transmit(apdu)
        if r.isSuccess { return true }
        // 69 82 = security status not satisfied: the key is simply wrong.
        if r.sw1 == 0x69 && r.sw2 == 0x82 { return false }
        throw PCSCError.statusWord(sw1: r.sw1, sw2: r.sw2)
    }

    /// Loads each candidate key and tries both key types until one authenticates.
    ///
    /// Returns the combination that worked. Order matters: callers should pass the most likely
    /// key first.
    ///
    /// Both key types are always tried. On the ACR1552 and tag used here, authenticating with
    /// key A fails `69 82` where key B succeeds *with the same six key bytes* — unexplained, and
    /// tracked as SPEC OPEN QUESTION 8. The default order is key A first, then key B: key A is
    /// what the Windows app hard-codes at all eleven of its call sites, and it is the order
    /// `TagService` passes explicitly, so the two now tell one story rather than contradicting
    /// each other. Key B is the fallback, not the preference.
    ///
    /// The card is reset after every failed attempt. This is not defensive padding — a failed
    /// MIFARE auth poisons the session, so without the reset the *second* key always appears to
    /// fail too, and a whole card reads as unauthenticatable after one wrong guess. See
    /// `APDUTransport.reset()`.
    ///
    /// Only a card-level status word means "this key did not work". A transport failure — the tag
    /// lifted off the antenna, the reader unplugged — propagates untouched, because reporting it
    /// as `authenticationFailed` sends the user hunting for a key problem that does not exist.
    @discardableResult
    public func authenticateAny(
        sector: Int,
        keys: [MifareKey],
        keyTypes: [MifareKeyType] = [.keyA, .keyB]
    ) throws -> (key: MifareKey, keyType: MifareKeyType) {
        let block = Self.firstBlock(ofSector: sector)
        try Self.validate(block: block)
        for key in keys {
            for type in keyTypes {
                // Reload after a reset: the reader's volatile key slot does not survive it.
                try loadKey(key)
                do {
                    if try authenticate(block: block, keyType: type) { return (key, type) }
                } catch let error as PCSCError {
                    // A status word is the card answering "no". Anything else is the link to the
                    // card failing, and must not be laundered into a key problem.
                    guard case .statusWord = error else { throw error }
                }
                try? transport.reset()
            }
        }
        throw PCSCError.authenticationFailed(sector: sector)
    }

    // MARK: - Read / write

    /// Reads one 16-byte block (`FF B0`). The sector must already be authenticated.
    public func readBlock(_ block: Int) throws -> [UInt8] {
        try Self.validate(block: block)
        let data = try transport.transmit([0xFF, 0xB0, 0x00, UInt8(block), UInt8(Self.blockSize)]).checked()
        guard data.count == Self.blockSize else { throw PCSCError.truncatedResponse(length: data.count) }
        return data
    }

    /// Writes one 16-byte block (`FF D6`). The sector must already be authenticated.
    ///
    /// Refuses to write block 0 (read-only manufacturer block). Trailer writes are permitted only
    /// with `allowTrailer: true`, because a bad trailer write permanently bricks the sector (D-006).
    public func writeBlock(_ block: Int, data: [UInt8], allowTrailer: Bool = false) throws {
        try Self.validate(block: block)
        guard data.count == Self.blockSize else {
            throw PCSCError.unsupported("write needs exactly \(Self.blockSize) bytes, got \(data.count)")
        }
        guard !Self.isManufacturer(block: block) else {
            throw PCSCError.unsupported("block 0 is the read-only manufacturer block")
        }
        guard !Self.isTrailer(block: block) || allowTrailer else {
            throw PCSCError.unsupported("block \(block) is a sector trailer; refusing to write without explicit opt-in")
        }
        var apdu: [UInt8] = [0xFF, 0xD6, 0x00, UInt8(block), UInt8(Self.blockSize)]
        apdu.append(contentsOf: data)
        try transport.transmit(apdu).checked()
    }

    // MARK: - Whole-card operations

    /// Result of reading one sector.
    ///
    /// A sector that was not captured in full says *why*. A bare bool could not distinguish "no
    /// key opened this sector" from "it opened but a block would not come back", so a flickering
    /// card produced a dump that was reported as a complete backup with blocks silently missing
    /// from it — the one artefact whose whole purpose is to be complete.
    public struct SectorDump {
        /// Why a sector was not captured in full.
        public enum Failure: Equatable, CustomStringConvertible {
            /// No supplied key opened the sector, with either key type.
            case authentication
            /// The sector opened, but a block inside it could not be read.
            case read(block: Int, error: PCSCError)

            public var description: String {
                switch self {
                case .authentication:
                    return "no key opened the sector"
                case let .read(block, error):
                    return "block \(block) could not be read (\(error.errorDescription ?? "unknown"))"
                }
            }
        }

        public let sector: Int
        public let blocks: [Int: [UInt8]]
        public let key: MifareKey?
        public let keyType: MifareKeyType?
        /// Nil when every block of the sector was captured; otherwise the first thing that failed.
        public let failure: Failure?

        /// True when every block of the sector was read.
        public var isComplete: Bool { failure == nil }

        /// True when this sector is **not** a usable capture.
        ///
        /// Kept for callers that only need the yes/no; note that it now covers a partial read as
        /// well as an authentication failure, because a partial sector is no more restorable than
        /// an absent one. Read `failure` when the reason matters.
        public var authFailed: Bool { failure != nil }
    }

    /// Reads every sector it can, recording why any sector it could not read in full failed.
    ///
    /// Used both for the tag-memory inspector and for the safety backup taken before any write.
    ///
    /// A locked sector is an ordinary outcome and is recorded, not thrown — real tags have them.
    /// A transport failure is not: it propagates, because a card lifted mid-dump would otherwise
    /// manufacture an empty "backup" of a tag that is about to be overwritten.
    public func dumpAll(keys: [MifareKey] = [.default],
                        keyTypes: [MifareKeyType] = [.keyA, .keyB]) throws -> [SectorDump] {
        var out: [SectorDump] = []
        for sector in 0..<Self.sectorCount {
            let auth: (key: MifareKey, keyType: MifareKeyType)
            do {
                auth = try authenticateAny(sector: sector, keys: keys, keyTypes: keyTypes)
            } catch let error as PCSCError {
                guard case .authenticationFailed = error else { throw error }
                out.append(SectorDump(sector: sector, blocks: [:], key: nil, keyType: nil,
                                      failure: .authentication))
                continue
            }

            var blocks: [Int: [UInt8]] = [:]
            var failure: SectorDump.Failure?
            for offset in 0..<Self.blocksPerSector {
                let block = Self.firstBlock(ofSector: sector) + offset
                do {
                    blocks[block] = try readBlock(block)
                } catch let error as PCSCError where Self.isCardLevel(error) {
                    // Keep going so the dump is as complete as it can be, but remember the first
                    // block that would not come back rather than dropping it on the floor.
                    if failure == nil { failure = .read(block: block, error: error) }
                }
            }
            out.append(SectorDump(sector: sector, blocks: blocks, key: auth.key,
                                  keyType: auth.keyType, failure: failure))
        }
        return out
    }

    /// True for failures the *card* reported, as opposed to the link to the card failing.
    private static func isCardLevel(_ error: PCSCError) -> Bool {
        switch error {
        case .statusWord, .truncatedResponse: return true
        default: return false
        }
    }
}
