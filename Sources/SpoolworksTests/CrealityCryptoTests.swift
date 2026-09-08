import Foundation
@testable import SpoolworksCore

/// Verifies the AES layer against values that two independent implementations in this repo agree on.
///
/// None of these need a reader or a tag — they pin the algorithm itself, so a regression in the
/// crypto path fails in CI rather than by corrupting somebody's spool.
let crealityCryptoTests = TestSuite(name: "Creality crypto", cases: [

    // MARK: - Keys match the Arduino firmware byte-for-byte

    // Arduino/*/Spool_ID/src/AES/AES.cpp stores the keys as decimal byte arrays.
    // If either implementation ever drifts, this is what catches it.
    test("derivation key matches Arduino u_key") { t in
        let arduinoUKey: [UInt8] = [113, 51, 98, 117, 94, 116, 49, 110,
                                    113, 102, 90, 40, 112, 102, 36, 49]
        t.equal(Array(CrealityCrypto.derivationKey.utf8), arduinoUKey, "u_key")
        t.equal(CrealityCrypto.derivationKey, "q3bu^t1nqfZ(pf$1")
    },

    test("payload key matches Arduino d_key") { t in
        let arduinoDKey: [UInt8] = [72, 64, 67, 70, 107, 82, 110, 122,
                                    64, 75, 65, 116, 66, 74, 112, 50]
        t.equal(Array(CrealityCrypto.payloadKey.utf8), arduinoDKey, "d_key")
        t.equal(CrealityCrypto.payloadKey, "H@CFkRnz@KAtBJp2")
    },

    test("both keys are AES-128 sized") { t in
        t.equal(CrealityCrypto.derivationKey.utf8.count, 16, "derivation key length")
        t.equal(CrealityCrypto.payloadKey.utf8.count, 16, "payload key length")
    },

    // MARK: - Primitives

    test("encrypt/decrypt round-trips") { t in
        guard let plain = t.unwrap([UInt8](hexString: "000102030405060708090A0B0C0D0E0F")) else { return }
        let cipher = try CrealityCrypto.encryptBlock(plain, key: CrealityCrypto.payloadKey)
        t.expect(cipher != plain, "ciphertext must differ from plaintext")
        t.equal(try CrealityCrypto.decryptBlock(cipher, key: CrealityCrypto.payloadKey), plain)
    },

    // ECB has no IV, so identical plaintext must always yield identical ciphertext.
    // The tag format depends on this — it is how the padding block stays constant.
    test("ECB is deterministic") { t in
        let block = [UInt8](repeating: 0x41, count: 16)
        let a = try CrealityCrypto.encryptBlock(block, key: CrealityCrypto.payloadKey)
        let b = try CrealityCrypto.encryptBlock(block, key: CrealityCrypto.payloadKey)
        t.equal(a, b)
    },

    test("rejects wrong block size") { t in
        t.throwsError(CrealityCrypto.CryptoError.badBlockSize(1)) {
            _ = try CrealityCrypto.encryptBlock([0x00], key: CrealityCrypto.payloadKey)
        }
    },

    test("rejects wrong key size") { t in
        t.throwsError(CrealityCrypto.CryptoError.badKeySize(5)) {
            _ = try CrealityCrypto.encryptBlock([UInt8](repeating: 0, count: 16), key: "short")
        }
    },

    // MARK: - Key derivation

    test("derived key is six bytes and deterministic") { t in
        let uid: [UInt8] = [0x80, 0xA6, 0x79, 0x39]
        let k1 = try CrealityCrypto.deriveSectorKey(uid: uid)
        let k2 = try CrealityCrypto.deriveSectorKey(uid: uid)
        t.equal(k1.bytes.count, 6, "key length")
        t.equal(k1, k2, "derivation must be stable")
    },

    test("derived key differs per UID") { t in
        let a = try CrealityCrypto.deriveSectorKey(uid: [0x80, 0xA6, 0x79, 0x39])
        let b = try CrealityCrypto.deriveSectorKey(uid: [0x01, 0x02, 0x03, 0x04])
        t.expect(a != b, "key derivation must be UID-dependent, or every tag shares a key")
    },

    test("derived key is never the factory default") { t in
        let derived = try CrealityCrypto.deriveSectorKey(uid: [0x80, 0xA6, 0x79, 0x39])
        t.expect(derived != .default,
                 "a derived key equal to FFFFFFFFFFFF would mean the KDF silently failed")
    },

    // The UID is tiled to 16 bytes. This used to be asserted by deriving twice, once from the
    // 4-byte UID and once from a pre-tiled 16-byte one — which only worked because
    // `deriveSectorKey` accepted any non-empty UID. It no longer does (a wrong-length UID tiles
    // to a plausible key no tag will accept), so the tiling is now checked against the primitive
    // directly, which is a stronger statement about the same property.
    test("UID tiling equals explicit repetition") { t in
        let uid: [UInt8] = [0x80, 0xA6, 0x79, 0x39]
        let viaTiling = try CrealityCrypto.deriveSectorKey(uid: uid)
        let cipher = try CrealityCrypto.encryptBlock(uid + uid + uid + uid,
                                                     key: CrealityCrypto.derivationKey)
        guard let expected = t.unwrap(MifareKey(bytes: Array(cipher.prefix(6)))) else { return }
        t.equal(viaTiling, expected)
    },

    // MARK: - Payload

    test("payload round-trips through three blocks") { t in
        var payload = Array("AB1240276A21010010FFFFFF0165000001000000".utf8)
        payload += [UInt8](repeating: 0, count: 48 - payload.count)
        let blocks = try CrealityCrypto.encryptPayload(payload)
        t.equal(blocks.count, 3, "block count")
        t.expect(blocks.allSatisfy { $0.count == 16 }, "every block must be 16 bytes")
        t.equal(try CrealityCrypto.decryptPayload(blocks), payload)
    },

    test("payload rejects wrong length") { t in
        t.throwsError("encryptPayload with 32 bytes") {
            _ = try CrealityCrypto.encryptPayload([UInt8](repeating: 0, count: 32))
        }
        t.throwsError("decryptPayload with 2 blocks") {
            _ = try CrealityCrypto.decryptPayload([[UInt8]](repeating: [], count: 2))
        }
    },

    // ECB encrypts each block independently, so two records sharing their final 16 bytes must
    // produce an identical block 6. This is the property the format actually relies on.
    test("ECB independence: equal tails produce equal block 6") { t in
        func padded(_ s: String) -> [UInt8] {
            var p = Array(s.utf8)
            p += [UInt8](repeating: 0, count: 48 - p.count)
            return p
        }
        // Differ in the first 32 bytes, share the last 16.
        let a = try CrealityCrypto.encryptPayload(padded("AB1240276A21010010FFFFFF0165000001000000"))
        let b = try CrealityCrypto.encryptPayload(padded("9A2240276A210100100000000165000001000000"))
        t.equal(a[2], b[2], "shared tail must yield an identical block 6")
        t.expect(a[0] != b[0], "differing heads must yield differing block 4")
    },

    // MARK: - Golden vectors, cross-validated against the reference implementation
    //
    // These values were produced by compiling this repository's own Arduino AES
    // (reference/arduino-aes/AES.cpp) natively and running it — not by hand
    // calculation. They are the ground truth this port is measured against.
    // Regenerate with: Tools/aes-reference-check.sh

    test("golden: derived key for UID 80A67939 matches the Arduino reference") { t in
        let derived = try CrealityCrypto.deriveSectorKey(uid: [0x80, 0xA6, 0x79, 0x39])
        t.equal(derived.description, "E05E87259A4F")
    },

    test("golden: full KDF ciphertext matches the Arduino reference") { t in
        let uid: [UInt8] = [0x80, 0xA6, 0x79, 0x39]
        var tiled = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { tiled[i] = uid[i % 4] }
        let cipher = try CrealityCrypto.encryptBlock(tiled, key: CrealityCrypto.derivationKey)
        t.equal(cipher.hexString, "E05E87259A4FEFD136C382194A1BBE06")
    },

    test("golden: AES(zeros) under the payload key matches the Arduino reference") { t in
        let zeros = [UInt8](repeating: 0, count: 16)
        let cipher = try CrealityCrypto.encryptBlock(zeros, key: CrealityCrypto.payloadKey)
        t.equal(cipher.hexString, "C3B98E0E7A3D248A5D7813C0E26B581A")
    },

    test("golden: first record block matches the Arduino reference") { t in
        let block = Array("AB1240276A210100".utf8)
        let cipher = try CrealityCrypto.encryptBlock(block, key: CrealityCrypto.payloadKey)
        t.equal(cipher.hexString, "57F25B78076D4C1797B1BE35CA269540")
    },

    test("golden: decryption inverts the reference ciphertext") { t in
        guard let cipher = t.unwrap([UInt8](hexString: "57F25B78076D4C1797B1BE35CA269540")) else { return }
        let plain = try CrealityCrypto.decryptBlock(cipher, key: CrealityCrypto.payloadKey)
        t.equal(String(decoding: plain, as: UTF8.self), "AB1240276A210100")
    },
])
