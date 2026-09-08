import Foundation
import CommonCrypto

/// The AES layer Creality uses to protect spool-tag data.
///
/// Two independent implementations in this repository agree on both keys and both algorithms,
/// which is why they are treated as settled rather than inferred:
///
/// - Windows C#: `Utils.CreateKey` / `Utils.cs` — AES-128-ECB, `CipherMode.ECB`.
/// - Arduino C++: `Arduino/*/Spool_ID/src/AES/AES.cpp` stores the same two keys as decimal byte
///   arrays (`u_key`, `d_key`) which decode to the identical ASCII strings.
///
/// Scheme:
/// 1. **Sector key derivation** — the 4-byte card UID is repeated to fill 16 bytes, encrypted with
///    `derivationKey`, and the first 6 ciphertext bytes become the MIFARE key for sector 1.
///    This is why a factory key never opens sector 1 on a programmed tag.
/// 2. **Payload encryption** — the 48-byte record occupying blocks 4, 5 and 6 is encrypted
///    block-by-block with `payloadKey`. ECB with no chaining, so each 16-byte block is independent.
public enum CrealityCrypto {

    /// AES-128 key used to derive a tag's sector-1 MIFARE key from its UID.
    /// Arduino `u_key` = 113,51,98,117,94,116,49,110,113,102,90,40,112,102,36,49.
    public static let derivationKey = "q3bu^t1nqfZ(pf$1"

    /// AES-128 key used to encrypt the spool data blocks.
    /// Arduino `d_key` = 72,64,67,70,107,82,110,122,64,75,65,116,66,74,112,50.
    public static let payloadKey = "H@CFkRnz@KAtBJp2"

    public enum CryptoError: Error, Equatable {
        case badBlockSize(Int)
        case badKeySize(Int)
        case ccFailure(Int32)
        /// A UID of a length the derivation is not defined over. See `uidLength`.
        case badUIDLength(Int)
    }

    /// The UID length the derivation is defined over. Not a convenience constant: both reference
    /// implementations tile exactly four bytes into the 16-byte plaintext.
    public static let uidLength = 4

    // MARK: - Primitives

    /// Encrypts exactly one 16-byte block with AES-128-ECB, no padding.
    public static func encryptBlock(_ block: [UInt8], key: String) throws -> [UInt8] {
        try crypt(block, key: key, operation: CCOperation(kCCEncrypt))
    }

    /// Decrypts exactly one 16-byte block with AES-128-ECB, no padding.
    public static func decryptBlock(_ block: [UInt8], key: String) throws -> [UInt8] {
        try crypt(block, key: key, operation: CCOperation(kCCDecrypt))
    }

    private static func crypt(_ block: [UInt8], key: String, operation: CCOperation) throws -> [UInt8] {
        guard block.count == 16 else { throw CryptoError.badBlockSize(block.count) }
        let keyBytes = Array(key.utf8)
        guard keyBytes.count == kCCKeySizeAES128 else { throw CryptoError.badKeySize(keyBytes.count) }

        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = keyBytes.withUnsafeBytes { kp in
            block.withUnsafeBytes { bp in
                CCCrypt(operation,
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionECBMode),   // ECB, and no kCCOptionPKCS7Padding
                        kp.baseAddress, kCCKeySizeAES128,
                        nil,                            // ECB takes no IV
                        bp.baseAddress, 16,
                        &out, 16,
                        &moved)
            }
        }
        guard status == kCCSuccess else { throw CryptoError.ccFailure(status) }
        return out
    }

    // MARK: - Tag operations

    /// Derives the sector-1 MIFARE key for a tag from its UID.
    ///
    /// The UID is tiled across a 16-byte block — four repetitions of the 4-byte UID, matching
    /// `createKey()` in the Arduino firmware and `CreateKey` in the Windows app.
    ///
    /// The length check lives here rather than only in `TagService` because a wrong-length UID
    /// does not fail: it tiles happily and returns a perfectly plausible six-byte key that no tag
    /// will ever accept, which then presents as an authentication mystery. `TagMemoryView` and
    /// `SpoolworksDiag` call this directly and would otherwise have had no guard at all.
    public static func deriveSectorKey(uid: [UInt8]) throws -> MifareKey {
        guard uid.count == uidLength else { throw CryptoError.badUIDLength(uid.count) }
        var plain = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { plain[i] = uid[i % uid.count] }
        let cipher = try encryptBlock(plain, key: derivationKey)
        // A 6-byte MIFARE key from the leading ciphertext bytes.
        guard let key = MifareKey(bytes: Array(cipher.prefix(6))) else {
            throw CryptoError.badKeySize(6)
        }
        return key
    }

    /// Encrypts a 48-byte spool record into the three 16-byte blocks stored at 4, 5 and 6.
    public static func encryptPayload(_ payload: [UInt8]) throws -> [[UInt8]] {
        guard payload.count == 48 else { throw CryptoError.badBlockSize(payload.count) }
        return try stride(from: 0, to: 48, by: 16).map {
            try encryptBlock(Array(payload[$0..<$0 + 16]), key: payloadKey)
        }
    }

    /// Decrypts the three stored blocks back into the 48-byte spool record.
    public static func decryptPayload(_ blocks: [[UInt8]]) throws -> [UInt8] {
        guard blocks.count == 3 else { throw CryptoError.badBlockSize(blocks.count) }
        var out: [UInt8] = []
        out.reserveCapacity(48)
        for block in blocks { out += try decryptBlock(block, key: payloadKey) }
        return out
    }
}
