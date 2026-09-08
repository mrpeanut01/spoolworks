import Foundation

/// An in-memory MIFARE Classic 1K simulator.
///
/// This exists so the entire tag layer — codec, read/write flows, error handling — is testable
/// with no reader and no tag. It models the parts of the card that actually affect our logic:
/// per-sector keys, key-slot state, authentication scope, and the read-only manufacturer block.
public final class MockTransport: APDUTransport {

    /// Per-sector key pair.
    public struct SectorKeys {
        public var keyA: MifareKey
        public var keyB: MifareKey
        public init(keyA: MifareKey = .default, keyB: MifareKey = .default) {
            self.keyA = keyA; self.keyB = keyB
        }
    }

    public private(set) var blocks: [[UInt8]]
    public var sectorKeys: [SectorKeys]
    public var uid: [UInt8]
    /// Sectors listed here refuse every key, modelling the locked sector 1 seen on real hardware.
    public var unauthenticatableSectors: Set<Int> = []
    /// Blocks listed here answer `6A 82` to a read even once their sector has authenticated,
    /// modelling a card that opens but will not hand a block back.
    public var unreadableBlocks: Set<Int> = []
    /// Every APDU received, for assertions about command sequences.
    public private(set) var log: [[UInt8]] = []

    // MARK: - Transport fault injection
    //
    // A card lifted off the antenna mid-sequence is NOT a wrong key: PC/SC reports it as a status
    // code and `transmit` throws, where a wrong key comes back as a perfectly successful exchange
    // carrying `69 82`. Code that cannot tell the two apart sends the user hunting for a key
    // problem, so the mock has to be able to produce both.

    /// Once this many APDUs have been received, every further `transmit` throws `transportError`
    /// instead of answering. Nil disables the fault.
    public var failTransmitsAfter: Int?
    /// The error `failTransmitsAfter` injects. Defaults to a dropped card.
    public var transportError: Error = PCSCError.noCard
    /// When set, `reset()` throws this instead of clearing the session.
    public var resetError: Error?

    /// Number of times `reset()` has been called, for asserting recovery behaviour.
    public private(set) var resetCount = 0
    /// Set when authentication fails, mirroring real MIFARE hardware: until the card is reset,
    /// every subsequent command fails regardless of whether the next key is correct.
    public private(set) var sessionPoisoned = false

    private var loadedKey: MifareKey?
    private var authenticatedSector: Int?

    public func reset() throws {
        if let resetError { throw resetError }
        resetCount += 1
        sessionPoisoned = false
        authenticatedSector = nil
        loadedKey = nil   // the reader's volatile key slot does not survive a reset
    }

    public init(uid: [UInt8] = [0x80, 0xA6, 0x79, 0x39]) {
        self.uid = uid
        self.blocks = (0..<MifareClassicCard.blockCount).map { block in
            if block == 0 {
                // Manufacturer block: UID, BCC, SAK, ATQA, then vendor bytes.
                var b = [UInt8](repeating: 0, count: 16)
                b.replaceSubrange(0..<4, with: uid)
                b[4] = uid.reduce(0, ^)   // BCC
                b[5] = 0x08               // SAK for Classic 1K
                return b
            }
            if MifareClassicCard.isTrailer(block: block) {
                // Key A reads back as zeros on a real card; access bits FF 07 80 69; key B visible.
                return [0, 0, 0, 0, 0, 0, 0xFF, 0x07, 0x80, 0x69, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
            }
            return [UInt8](repeating: 0, count: 16)
        }
        self.sectorKeys = (0..<MifareClassicCard.sectorCount).map { _ in SectorKeys() }
    }

    /// Seeds a data block directly, bypassing authentication. Test setup only.
    public func setBlock(_ block: Int, to data: [UInt8]) {
        precondition(data.count == 16, "block must be 16 bytes")
        blocks[block] = data
    }

    public func transmit(_ apdu: [UInt8]) throws -> APDUResponse {
        log.append(apdu)
        // The APDU is logged first: a transport failure still consumed an exchange, and tests
        // count exchanges to place the fault.
        if let limit = failTransmitsAfter, log.count > limit { throw transportError }
        guard apdu.count >= 4, apdu[0] == 0xFF else { return fail(0x6D, 0x00) }

        // A poisoned session rejects everything except loading a key and resetting, exactly as
        // real hardware does after a failed authentication.
        if sessionPoisoned && apdu[1] != 0x82 {
            return fail(0x69, 0x82)
        }

        switch apdu[1] {
        case 0xCA:  // Get UID
            return APDUResponse(data: uid, sw1: 0x90, sw2: 0x00)

        case 0x00 where apdu.count >= 3 && apdu[2] == 0x48:  // Firmware
            return APDUResponse(data: Array("MOCK1552".utf8), sw1: 0x90, sw2: 0x00)

        case 0x00 where apdu.count >= 3 && apdu[2] == 0x52:  // Buzzer
            return ok()

        case 0x82:  // Load key
            guard apdu.count == 11, let key = MifareKey(bytes: Array(apdu[5..<11])) else { return fail(0x6B, 0x00) }
            loadedKey = key
            return ok()

        case 0x86:  // Authenticate
            guard apdu.count == 10, let key = loadedKey else { return fail(0x69, 0x82) }
            let block = Int(apdu[7])
            guard block < MifareClassicCard.blockCount else { return fail(0x6A, 0x82) }
            let sector = MifareClassicCard.sector(ofBlock: block)
            if unauthenticatableSectors.contains(sector) {
                sessionPoisoned = true
                return fail(0x69, 0x82)
            }
            let keys = sectorKeys[sector]
            let expected = apdu[8] == MifareKeyType.keyA.rawValue ? keys.keyA : keys.keyB
            guard key == expected else {
                sessionPoisoned = true
                return fail(0x69, 0x82)
            }
            authenticatedSector = sector
            return ok()

        case 0xB0:  // Read binary
            guard apdu.count == 5 else { return fail(0x6B, 0x00) }
            let block = Int(apdu[3])
            guard block < MifareClassicCard.blockCount else { return fail(0x6A, 0x82) }
            guard authenticatedSector == MifareClassicCard.sector(ofBlock: block) else { return fail(0x69, 0x82) }
            // An authenticated sector whose block still refuses to come back.
            if unreadableBlocks.contains(block) { return fail(0x6A, 0x82) }
            return APDUResponse(data: blocks[block], sw1: 0x90, sw2: 0x00)

        case 0xD6:  // Update binary
            guard apdu.count == 21 else { return fail(0x6B, 0x00) }
            let block = Int(apdu[3])
            guard block < MifareClassicCard.blockCount else { return fail(0x6A, 0x82) }
            guard authenticatedSector == MifareClassicCard.sector(ofBlock: block) else { return fail(0x69, 0x82) }
            // Block 0 is physically read-only.
            guard block != 0 else { return fail(0x69, 0x86) }
            let payload = Array(apdu[5..<21])
            blocks[block] = payload

            // Writing a trailer re-keys the sector, exactly as a real card does: bytes 0..5 become
            // key A and bytes 10..15 key B, effective immediately. Without this the mock kept its
            // original keys, so a test could "successfully" program a tag and then read it back
            // with a key the real card would have rejected — which is precisely the class of bug
            // that reached hardware.
            if MifareClassicCard.isTrailer(block: block) {
                let trailerSector = MifareClassicCard.sector(ofBlock: block)
                if let keyA = MifareKey(bytes: Array(payload[0..<6])) {
                    sectorKeys[trailerSector].keyA = keyA
                }
                if let keyB = MifareKey(bytes: Array(payload[10..<16])) {
                    sectorKeys[trailerSector].keyB = keyB
                }
                // A real card also drops authentication when the sector is re-keyed.
                authenticatedSector = nil
                loadedKey = nil
            }
            return ok()

        default:
            return fail(0x6D, 0x00)
        }
    }

    private func ok() -> APDUResponse { APDUResponse(data: [], sw1: 0x90, sw2: 0x00) }
    private func fail(_ sw1: UInt8, _ sw2: UInt8) -> APDUResponse { APDUResponse(data: [], sw1: sw1, sw2: sw2) }
}
