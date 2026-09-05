import Foundation
import CommonCrypto
import CryptoKit

// MARK: - XiaomiCloudCrypto
//
// Cryptographic primitives for the Xiaomi Cloud account API (token extraction),
// ported from token_extractor.py (XiaomiCloudConnector). These are SEPARATE from
// the BLE handshake crypto in XiaomiCrypto.swift — different protocol, different keys.
//
// The cloud API encrypts request params with RC4 keyed by a per-request "signed nonce":
//   signedNonce = base64( SHA256( base64decode(ssecurity) || base64decode(nonce) ) )
//   each value  = base64( RC4(key=base64decode(signedNonce), discard first 1024 keystream bytes) )
//   signature   = base64( SHA1( "POST&path&k1=v1&k2=v2&...&signedNonce" ) )
//
// pycryptodome's ARC4 discards the first 1024 keystream bytes (`r.encrypt(bytes(1024))`)
// before encrypting the payload — we replicate that by advancing the cipher state 1024 steps.

enum XiaomiCloudCrypto {

    // MARK: - Digests

    static func sha256(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
        return Data(hash)
    }

    static func sha1(_ data: Data) -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &hash) }
        return Data(hash)
    }

    /// Lowercase hex MD5 — required by the password-based login endpoint (`hash` field), which
    /// predates the account API's move to stronger hashing. CryptoKit's `Insecure.MD5` avoids the
    /// deprecated CommonCrypto entry point; this is protocol compatibility, not a security choice.
    static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - RC4 (ARC4)
    //
    // Standard RC4 keystream. `skip` discards the first N keystream bytes, matching
    // pycryptodome's `r.encrypt(bytes(1024))` warm-up used by the Xiaomi cloud API.

    static func rc4(key: Data, data: Data, skip: Int = 1024) -> Data {
        var s = [Int](0...255)
        let keyBytes = [UInt8](key)
        guard !keyBytes.isEmpty else { return data }

        var j = 0
        for i in 0..<256 {
            j = (j + s[i] + Int(keyBytes[i % keyBytes.count])) & 0xFF
            s.swapAt(i, j)
        }

        var i = 0
        j = 0
        // Warm-up: advance the keystream `skip` steps without producing output.
        for _ in 0..<skip {
            i = (i + 1) & 0xFF
            j = (j + s[i]) & 0xFF
            s.swapAt(i, j)
        }

        var out = [UInt8]()
        out.reserveCapacity(data.count)
        for byte in data {
            i = (i + 1) & 0xFF
            j = (j + s[i]) & 0xFF
            s.swapAt(i, j)
            let k = s[(s[i] + s[j]) & 0xFF]
            out.append(byte ^ UInt8(k))
        }
        return Data(out)
    }
}
