import Foundation

// MARK: - Errors

/// Failures specific to the Creality spool-tag layer, as opposed to the PC/SC transport.
public enum TagError: Error, Equatable, CustomStringConvertible {
    /// The card on the reader is not a MIFARE Classic 1K, so it cannot carry this layout.
    case unsupportedCard(CardType)
    /// The UID is not 4 bytes. The key derivation consumes exactly 4 UID bytes, and both the
    /// Windows and Android apps reject anything longer (`Reader.cs:17-26`,
    /// `MainActivity.java:426`), so a 7-byte-UID tag would silently get the wrong sector key.
    case unsupportedUID(length: Int)
    /// The sector trailer read back with all-zero access bytes, which almost certainly means the
    /// read failed rather than that the card really holds `00 00 00 00`. Writing it back would
    /// author access bits from scratch and could permanently lock the sector.
    case unsafeTrailer(block: Int)
    /// The pre-write backup could not capture the sector about to be overwritten, so there would
    /// be no record of what was replaced.
    case backupIncomplete(sector: Int)
    /// Programming this tag requires rewriting its sector keys, which is irreversible, and the
    /// caller did not authorise it. Thrown BEFORE anything is written.
    case trailerWriteNotAuthorised(block: Int)
    /// The tag was written, but reading it back did not return what was written. The write did
    /// not take, whatever the reader reported.
    case verificationFailed(block: Int, detail: String)
    /// The printer-type string does not fit sector 2, or is not ASCII.
    case invalidPrinterType(String)

    public var description: String {
        switch self {
        case let .unsupportedCard(type):
            return "\(type) is not supported — Creality spool tags are MIFARE Classic 1K"
        case let .unsupportedUID(length):
            return "expected a 4-byte UID, got \(length) bytes; this tag family uses 4-byte UIDs only"
        case let .unsafeTrailer(block):
            return "refusing to write block \(block): its access bytes read back as zeros, which would risk locking the sector permanently"
        case let .backupIncomplete(sector):
            return "could not read sector \(sector) before writing, so no backup of the current contents exists. Nothing was written"
        case let .trailerWriteNotAuthorised(block):
            return "this tag is blank, so programming it means rewriting the sector keys at block \(block) — an irreversible change that has not been authorised. Nothing was written"
        case let .verificationFailed(block, detail):
            return "write verification failed at block \(block): \(detail). The tag may be partly written — re-read it before relying on it"
        case let .invalidPrinterType(value):
            return "printer type \"\(value)\" must be at most \(TagService.sector2Length) ASCII characters"
        }
    }
}

extension TagError: LocalizedError {
    public var errorDescription: String? { description }
}

// MARK: - Results

/// Everything one read of a spool tag produced.
public struct TagReadResult: Equatable {
    /// The 4-byte UID, in transmission order — the same order `CreateKey` consumes.
    public let uid: [UInt8]
    /// `AES-ECB(q3bu^t1nqfZ(pf$1, UID×4)[0..<6]`, the sector-1 key this tag should carry.
    public let derivedKey: MifareKey
    /// True when sector 1 opened with `derivedKey` rather than the factory key — i.e. this tag has
    /// already been programmed by an app in this family.
    public let isProgrammed: Bool
    /// Which key and key type actually opened sector 1. Worth surfacing: on the hardware here,
    /// key B succeeds where key A does not, and that is still unexplained.
    public let sector1Key: MifareKey
    public let sector1KeyType: MifareKeyType
    /// The 48 decrypted bytes of blocks 4, 5 and 6.
    public let decryptedSector1: [UInt8]
    /// The parsed record, or nil if the decrypted bytes are not a valid record (a blank tag, a
    /// foreign tag, or a wrong key that still authenticated).
    public let record: SpoolRecord?
    /// Why parsing failed, when `record` is nil.
    public let recordError: SpoolRecordError?
    /// The 48 plaintext bytes of blocks 8, 9 and 10, or nil if sector 2 could not be authenticated.
    public let sector2: [UInt8]?
    /// The printer-type string from sector 2, trimmed. Nil when sector 2 was unreadable.
    public let printerType: String?
}

/// Everything one write of a spool tag produced, including the pre-write backup.
public struct TagWriteResult {
    public let uid: [UInt8]
    public let derivedKey: MifareKey
    /// A dump of every sector that could be authenticated, taken **before** the first write APDU.
    /// This is the only route back if a write goes wrong, so it is not optional and not lazy.
    public let backup: [MifareClassicCard.SectorDump]
    /// True when sector 1 already carried the derived key before this write.
    public let wasAlreadyProgrammed: Bool
    /// True when the sector-1 trailer was rewritten (first-time programming only).
    public let wroteTrailer: Bool
    /// False when sector 2 could not be authenticated and blocks 8..10 were skipped.
    public let wroteSector2: Bool
    /// The blocks actually written, block index → 16 bytes. Useful for a verify pass.
    public let writtenBlocks: [Int: [UInt8]]
}

// MARK: - TagService

/// Read/write orchestration for Creality spool tags over a MIFARE Classic 1K.
///
/// The on-tag layout (`SPEC/01-tag-codec.md` §1):
///
/// | Sector | Blocks | Content | Key |
/// |---|---|---|---|
/// | 1 | 4, 5, 6 | 48-byte record, AES-128-ECB | derived from UID |
/// | 1 | 7 | trailer; key A = key B = derived key | derived (default before programming) |
/// | 2 | 8, 9, 10 | 48-byte printer-type string, **plaintext** | factory `FFFFFFFFFFFF` |
/// | 2 | 11 | trailer | never written — sector 2 stays on the factory key |
///
/// ## Deliberate deviations from the Windows app
///
/// 1. **Key type is not hard-coded.** Windows passes `keyType = 0x60` (key A) at all eleven call
///    sites and never tries key B (`SPEC` §0-Q2). On the ACR1552 + tag used here, key A fails
///    `69 82` and key B succeeds — unexplained, and tracked as SPEC OPEN QUESTION 8. So every
///    authentication tries key A first and falls back to key B with the same key value. This
///    changes which authenticate APDU is emitted, never a byte written to the tag.
/// 2. **The read path falls back to the factory key.** Windows authenticates sector 1 with the
///    derived key only and throws otherwise (`Utils.cs:256,271`); Android uses
///    `encrypted ? encKey : KEY_DEFAULT` (`MainActivity.java:545`). Two of the three
///    implementations (Android, and Windows' own *write* path at `MainForm.cs:464-470`) do try
///    both, so this follows the majority: derived key first, then factory.
/// 3. **Status words are checked on every read.** `Reader.ReadBinaryBlocks` never inspects SW and
///    returns 16 zero bytes on failure (`Reader.cs:55-61`), which means a failed trailer read
///    would have the app write `encKey ‖ 00 00 00 00 ‖ encKey` and clobber the access bits. SPEC
///    OPEN QUESTION 4 recommends checking and aborting; that is what happens here, plus an
///    explicit `unsafeTrailer` guard.
/// 4. **A full backup is taken before any write.** No reference implementation does this.
public final class TagService {

    /// Sector holding the encrypted record.
    public static let recordSector = 1
    /// Sector holding the plaintext printer-type string.
    public static let printerSector = 2
    public static let recordBlocks = [4, 5, 6]
    public static let printerBlocks = [8, 9, 10]
    /// Bytes 48..95 of the payload — the plaintext region.
    public static let sector2Length = 48
    /// Sector 2 is space-padded (`PadRight(96, ' ')`, `MainForm.cs:454`), not NUL-padded.
    public static let sector2PadByte: UInt8 = 0x20

    private let card: MifareClassicCard
    private let cardType: CardType
    /// Order in which key types are attempted. Key A first matches the Windows app; the key B
    /// fallback is the deviation described above. Exposed so hardware bring-up can flip it.
    private let keyTypeOrder: [MifareKeyType]

    /// - Parameter cardType: deliberately has no default. Writing a Creality record to a card that
    ///   is not a Classic 1K would be a silent, possibly destructive mistake, so the caller has to
    ///   state what it connected to.
    public init(card: MifareClassicCard,
                cardType: CardType,
                keyTypeOrder: [MifareKeyType] = [.keyA, .keyB]) {
        self.card = card
        self.cardType = cardType
        self.keyTypeOrder = keyTypeOrder
    }

    /// Convenience for a live PC/SC session: reads the ATR to identify the card.
    public convenience init(session: CardSession, keyTypeOrder: [MifareKeyType] = [.keyA, .keyB]) throws {
        let atr = try session.atr()
        self.init(card: MifareClassicCard(transport: session),
                  cardType: CardType.from(atr: atr),
                  keyTypeOrder: keyTypeOrder)
    }

    // MARK: - Read

    /// Reads a tag end to end: derive the key, open sector 1, decrypt, parse, then read sector 2.
    ///
    /// Sector-1 authentication failure throws. A sector 1 that authenticates but does not decrypt
    /// to a valid record does **not** throw — `record` comes back nil with `recordError` set, so a
    /// blank or foreign tag can still be inspected rather than becoming an opaque failure.
    /// Sector 2 being unreadable is likewise non-fatal, matching the Windows app, which skips it
    /// silently (`MainForm.cs:501-511`); here it is at least reported as `sector2 == nil`.
    public func readTag() throws -> TagReadResult {
        try requireSupportedCard()
        let uid = try readUID()
        let derivedKey = try CrealityCrypto.deriveSectorKey(uid: uid)

        // Derived key first, factory key second — see deviation 2.
        let auth = try card.authenticateAny(sector: Self.recordSector,
                                            keys: [derivedKey, .default],
                                            keyTypes: keyTypeOrder)
        let cipherBlocks = try Self.recordBlocks.map { try card.readBlock($0) }
        let decrypted = try CrealityCrypto.decryptPayload(cipherBlocks)

        var record: SpoolRecord?
        var recordError: SpoolRecordError?
        do {
            record = try SpoolRecord(validating: decrypted)
        } catch let error as SpoolRecordError {
            recordError = error
        }

        // Sector 2 refusing to open is non-fatal; the link to the card failing is not. A `try?`
        // here used to turn a tag lifted after sector 1 into a read that looked complete.
        let sector2 = try unlessCardRefuses { try readSector2(derivedKey: derivedKey) }

        return TagReadResult(uid: uid,
                             derivedKey: derivedKey,
                             isProgrammed: auth.key == derivedKey,
                             sector1Key: auth.key,
                             sector1KeyType: auth.keyType,
                             decryptedSector1: decrypted,
                             record: record,
                             recordError: recordError,
                             sector2: sector2,
                             printerType: sector2.map(Self.printerType(fromSector2:)))
    }

    private func readSector2(derivedKey: MifareKey) throws -> [UInt8] {
        // Sector 2 is left on the factory key by every implementation, so that is tried first.
        // The derived key is offered as a fallback in case a future firmware keys it.
        _ = try card.authenticateAny(sector: Self.printerSector,
                                     keys: [.default, derivedKey],
                                     keyTypes: keyTypeOrder)
        return try Self.printerBlocks.flatMap { try card.readBlock($0) }
    }

    // MARK: - Write

    /// Encrypts and writes a record, then writes sector 2, taking a full backup first.
    ///
    /// Order of operations, and why:
    /// 1. Refuse anything that is not a Classic 1K with a 4-byte UID.
    /// 2. **Dump every readable sector.** This happens before the first write APDU and its result
    ///    is returned to the caller whatever else happens — it is the only way back.
    /// 3. Authenticate sector 1 with the derived key, falling back to the factory key. Which one
    ///    worked decides whether this is a first-time programming.
    /// 4. Write blocks 4, 5, 6 with the encrypted record.
    /// 5. On a first-time programming only, read block 7, splice the derived key into bytes 0..5
    ///    and 10..15, leave bytes 6..9 (access bits + GPB) exactly as they were read, and write it
    ///    back through `allowTrailer: true`. Access bits are never authored, only preserved.
    /// 6. Authenticate sector 2 with the factory key and write blocks 8, 9, 10 in plaintext.
    ///
    /// Block 0 is never written; `MifareClassicCard.writeBlock` refuses it structurally.
    @discardableResult
    /// - Parameters:
    ///   - allowTrailerWrite: authorises rewriting the sector-1 keys, which is irreversible and is
    ///     required only the first time a blank tag is programmed. Defaults to `false` so the
    ///     destructive path is opt-in at the point it actually happens, not merely in the UI.
    ///   - onBackup: called with the pre-write dump as soon as it is taken, before any write APDU.
    ///     The dump is otherwise reachable only through a successful return, which is exactly when
    ///     it is *not* needed — a caller that wants to offer recovery after a failure must receive
    ///     it here.
    public func writeTag(record: SpoolRecord,
                         printerType: String = "",
                         allowTrailerWrite: Bool = false,
                         onBackup: (([MifareClassicCard.SectorDump]) -> Void)? = nil) throws -> TagWriteResult {
        try requireSupportedCard()
        let uid = try readUID()
        let derivedKey = try CrealityCrypto.deriveSectorKey(uid: uid)
        let sector2Payload = try Self.sector2Payload(printerType: printerType)

        // SAFETY: full dump before anything is written. Both known keys are offered so a
        // half-programmed tag still backs up completely. The factory key goes first: fifteen of
        // the sixteen sectors are on it whatever the tag's state, and every failed attempt costs
        // a card reset — which is the field churn that makes the reader drop a stationary tag.
        // Derived-first cost thirty resets per write on an ordinary tag; this order costs one.
        let backup = try card.dumpAll(keys: [.default, derivedKey], keyTypes: keyTypeOrder)
        // Deliver it now. Reaching the caller only via a successful return means it is absent in
        // exactly the cases it exists for.
        onBackup?(backup)

        // A backup that did not capture the record sector cannot document what is about to be
        // overwritten, so treat it as a failed prerequisite rather than writing blind.
        if let recordBackup = backup.first(where: { $0.sector == Self.recordSector }),
           recordBackup.authFailed {
            throw TagError.backupIncomplete(sector: Self.recordSector)
        }

        let auth = try card.authenticateAny(sector: Self.recordSector,
                                            keys: [derivedKey, .default],
                                            keyTypes: keyTypeOrder)
        let wasProgrammed = auth.key == derivedKey

        // Everything that can REFUSE the write is resolved before the first write APDU, so an
        // abort leaves the tag exactly as it was. Previously the trailer was read and validated
        // only after blocks 4-6 had already been overwritten, so a refusal left new ciphertext on
        // the tag under the old key while telling the user nothing had happened.
        var pendingTrailer: (block: Int, bytes: [UInt8])?
        if !wasProgrammed {
            let trailerBlock = MifareClassicCard.trailerBlock(ofSector: Self.recordSector)
            // Gate the irreversible operation on the RUNTIME decision, not the caller's snapshot.
            // A UI that decided "no trailer needed" in an earlier session can be wrong here: a
            // derived-key auth that flakes and falls back to the factory key flips `wasProgrammed`
            // and would otherwise rewrite the sector keys with no authorisation at all.
            guard allowTrailerWrite else {
                throw TagError.trailerWriteNotAuthorised(block: trailerBlock)
            }
            pendingTrailer = (trailerBlock, try updatedTrailer(block: trailerBlock, key: derivedKey))
        }

        var written: [Int: [UInt8]] = [:]
        let cipherBlocks = try CrealityCrypto.encryptPayload(record.paddedPayload)
        for (block, data) in zip(Self.recordBlocks, cipherBlocks) {
            try card.writeBlock(block, data: data)
            written[block] = data
        }

        var wroteTrailer = false
        if let pendingTrailer {
            try card.writeBlock(pendingTrailer.block, data: pendingTrailer.bytes, allowTrailer: true)
            written[pendingTrailer.block] = pendingTrailer.bytes
            wroteTrailer = true
        }

        var wroteSector2 = false
        // Windows skips sector 2 in silence if it cannot authenticate (`MainForm.cs:501-511`).
        // The skip is preserved so a tag with a keyed sector 2 still gets a valid sector 1, but
        // it is reported rather than hidden — and only the card's refusal is skipped, never a
        // lifted tag.
        if try unlessCardRefuses({ try card.authenticateAny(sector: Self.printerSector,
                                                            keys: [.default, derivedKey],
                                                            keyTypes: keyTypeOrder) }) != nil {
            for (index, block) in Self.printerBlocks.enumerated() {
                let chunk = Array(sector2Payload[(index * 16)..<((index + 1) * 16)])
                try card.writeBlock(block, data: chunk)
                written[block] = chunk
            }
            wroteSector2 = true
        }

        // VERIFY. A MIFARE write that returns 90 00 has been accepted by the reader, which is not
        // the same as the bytes being on the tag: a card leaving the field mid-transaction, or a
        // sector whose keys changed underneath us, both produce a "successful" write that did not
        // land. Reading the record back and comparing is the only honest confirmation, and
        // reporting a silent failure as success is the worst outcome available here.
        // After a trailer write the sector answers only to the derived key. Before one, the key
        // is unchanged, so offer both rather than assuming which applies.
        try verify(sector: Self.recordSector,
                   keys: wroteTrailer ? [derivedKey] : [derivedKey, .default],
                   blocks: Self.recordBlocks,
                   expected: cipherBlocks,
                   reopenFailure: wroteTrailer
                       ? "the tag would not re-open with the key just written to it"
                       : "the tag would not re-open after writing")
        if wroteSector2 {
            try verify(sector: Self.printerSector,
                       keys: [.default, derivedKey],
                       blocks: Self.printerBlocks,
                       expected: Self.printerBlocks.indices.map {
                           Array(sector2Payload[($0 * 16)..<(($0 + 1) * 16)])
                       },
                       reopenFailure: "sector 2 would not re-open after writing")
        }

        return TagWriteResult(uid: uid,
                              derivedKey: derivedKey,
                              backup: backup,
                              wasAlreadyProgrammed: wasProgrammed,
                              wroteTrailer: wroteTrailer,
                              wroteSector2: wroteSector2,
                              writtenBlocks: written)
    }

    /// True for a failure the *card* reported — a status word, every key refused, a short
    /// answer — as opposed to the link to the card failing.
    private static func isCardAnswer(_ error: PCSCError) -> Bool {
        switch error {
        case .statusWord, .authenticationFailed, .truncatedResponse: return true
        default: return false
        }
    }

    /// Runs a step whose card-level refusal is an acceptable outcome, returning `nil` for it.
    ///
    /// A transport failure — the tag lifted off the antenna, the reader reset underneath us —
    /// propagates with its own type. Laundering it into "sector 2 unreadable" made a lifted tag
    /// look like a complete read, and laundering it into ``TagError/verificationFailed`` told
    /// the user the key just written did not open the tag while also hiding the one error
    /// `ReaderMonitor` knows how to retry.
    private func unlessCardRefuses<T>(_ body: () throws -> T) throws -> T? {
        do { return try body() }
        catch let error as PCSCError where Self.isCardAnswer(error) { return nil }
    }

    /// Re-authenticates a sector and confirms each block holds exactly the bytes just written.
    ///
    /// Authentication is re-run first, because a trailer write changes the sector's keys: after
    /// programming, only the derived key opens sector 1, and continuing on the pre-write session
    /// would read through stale authentication. Sector 2 was previously trusted purely because
    /// three writes returned 90 00 — the same reasoning rejected for sector 1.
    ///
    /// Only the card's own answers become ``TagError/verificationFailed``; see
    /// ``unlessCardRefuses(_:)`` for why a transport failure keeps its type.
    private func verify(sector: Int,
                        keys: [MifareKey],
                        blocks: [Int],
                        expected: [[UInt8]],
                        reopenFailure: String) throws {
        guard try unlessCardRefuses({
            try card.authenticateAny(sector: sector, keys: keys, keyTypes: keyTypeOrder)
        }) != nil else {
            throw TagError.verificationFailed(block: blocks.first ?? 0, detail: reopenFailure)
        }
        for (block, want) in zip(blocks, expected) {
            let got: [UInt8]
            do {
                got = try card.readBlock(block)
            } catch let error as PCSCError where Self.isCardAnswer(error) {
                throw TagError.verificationFailed(block: block,
                                                  detail: "could not read it back (\(error.localizedDescription))")
            }
            guard got == want else {
                throw TagError.verificationFailed(
                    block: block,
                    detail: "expected \(want.hexString) but the tag holds \(got.hexString)")
            }
        }
    }

    /// Reads a sector trailer and returns it with both keys replaced and the access bits intact.
    ///
    /// Read-modify-write, never authored from scratch. On a real card key A reads back as zeros
    /// (chip behaviour) and is overwritten anyway; bytes 6..8 are the access bits and byte 9 the
    /// general-purpose byte, and all four must survive untouched.
    ///
    /// The access bits are validated, not merely checked for zeros. MIFARE stores C1/C2/C3 twice —
    /// plain and inverted — across bytes 6, 7 and 8, and the chip **permanently locks the sector**
    /// if the two copies disagree. A single corrupted bit from a flaky read would otherwise sail
    /// through and be written back, destroying the sector. An earlier version of this guard
    /// rejected exactly one value (`00 00 00 00`), which let every other corruption past, and it
    /// spanned bytes 6...9, so zeroed access bits still passed whenever the GPB was non-zero.
    private func updatedTrailer(block: Int, key: MifareKey) throws -> [UInt8] {
        var trailer = try card.readBlock(block)
        guard trailer.count == MifareClassicCard.blockSize else {
            throw PCSCError.truncatedResponse(length: trailer.count)
        }
        guard Self.accessBitsAreSelfConsistent(Array(trailer[6...8])) else {
            throw TagError.unsafeTrailer(block: block)
        }
        trailer.replaceSubrange(0..<6, with: key.bytes)     // key A
        trailer.replaceSubrange(10..<16, with: key.bytes)   // key B
        return trailer                                       // bytes 6..9 untouched
    }

    /// True when the three access bytes carry a consistent plain/inverted encoding.
    ///
    /// Layout (MF1S50, §8.7.2):
    ///
    ///     byte 6: ~C2[3..0] ~C1[3..0]
    ///     byte 7:  C1[3..0] ~C3[3..0]
    ///     byte 8:  C3[3..0]  C2[3..0]
    ///
    /// so each nibble must be the complement of its partner. The factory value `FF 07 80`
    /// satisfies this; `FF 07 00`, `00 00 00` and any single-bit corruption do not.
    static func accessBitsAreSelfConsistent(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 3 else { return false }
        let b6 = bytes[0], b7 = bytes[1], b8 = bytes[2]
        let c1 = (b7 >> 4) & 0x0F, c1Inverted = b6 & 0x0F
        let c2 = b8 & 0x0F,        c2Inverted = (b6 >> 4) & 0x0F
        let c3 = (b8 >> 4) & 0x0F, c3Inverted = b7 & 0x0F
        return c1 == (~c1Inverted & 0x0F)
            && c2 == (~c2Inverted & 0x0F)
            && c3 == (~c3Inverted & 0x0F)
    }

    // MARK: - Sector 2 helpers

    /// Builds bytes 48..95 of the payload: the printer-type string, space-padded to 48 bytes.
    ///
    /// Windows writes `printerModel.Text` and pads the whole 96-byte payload with `' '`
    /// (`MainForm.cs:453-454`). Arduino writes the literal `"00000000"` there instead
    /// (`Spool_ID.ino:395`) and is reported to work, so the field looks advisory.
    public static func sector2Payload(printerType: String) throws -> [UInt8] {
        let bytes = Array(printerType.utf8)
        guard bytes.count <= sector2Length, bytes.allSatisfy({ $0 < 0x80 }) else {
            throw TagError.invalidPrinterType(printerType)
        }
        return bytes + [UInt8](repeating: sector2PadByte, count: sector2Length - bytes.count)
    }

    /// Recovers the printer type from sector 2's bytes.
    ///
    /// Trims spaces **and** NULs. `.NET String.Trim()` does not strip `\0` (`SPEC` §11.2 pitfall
    /// 7), so on a formatted tag the Windows app gets 48 NUL characters back; Android works around
    /// it by testing `startsWith("\0")` (`MainActivity.java:915`). Trimming both here means a
    /// formatted tag reports an empty printer type instead of a string of control characters.
    public static func printerType(fromSector2 bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
            .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
    }

    // MARK: - Guards

    private func requireSupportedCard() throws {
        guard cardType.isSupported else { throw TagError.unsupportedCard(cardType) }
    }

    private func readUID() throws -> [UInt8] {
        let uid = try card.readUID()
        guard uid.count == 4 else { throw TagError.unsupportedUID(length: uid.count) }
        return uid
    }
}
