import Foundation
import CommonCrypto

// MARK: - XiaomiCrypto
// Cryptographic primitives for the Xiaomi Mi Band 10 BLE V2 protocol.
// All operations use CommonCrypto — zero external dependencies.

enum XiaomiCrypto {

    // MARK: - HMAC-SHA256

    static func hmacSHA256(message: Data, key: Data) -> Data {
        var digest = Data(count: Int(CC_SHA256_DIGEST_LENGTH))
        digest.withUnsafeMutableBytes { digestBuf in
            message.withUnsafeBytes { msgBuf in
                key.withUnsafeBytes { keyBuf in
                    CCHmac(
                        CCHmacAlgorithm(kCCHmacAlgSHA256),
                        keyBuf.baseAddress, key.count,
                        msgBuf.baseAddress, message.count,
                        digestBuf.baseAddress
                    )
                }
            }
        }
        return digest
    }

    // MARK: - HKDF-Expand (RFC 5869 §2.3, HMAC-SHA256)
    // Used with info = "miwear-auth" to produce 64 bytes of session key material.

    static func hkdfExpand(prk: Data, info: Data, outputLength: Int) -> Data {
        let hashLen = Int(CC_SHA256_DIGEST_LENGTH)
        var output = Data()
        var t = Data()
        var counter: UInt8 = 1

        while output.count < outputLength {
            let block = t + info + Data([counter])
            t = hmacSHA256(message: block, key: prk)
            output.append(t)
            counter += 1
        }
        return Data(output.prefix(outputLength))
    }

    // MARK: - AES-ECB (internal block cipher)

    private static func aesECBEncrypt(block: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, block.count == kCCBlockSizeAES128 else {
            throw CryptoError.invalidKeyLength(key.count)
        }
        var output = Data(count: kCCBlockSizeAES128 + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0

        let status: CCCryptorStatus = output.withUnsafeMutableBytes { outBuf in
            block.withUnsafeBytes { inBuf in
                key.withUnsafeBytes { keyBuf in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES128),
                        CCOptions(kCCOptionECBMode),
                        keyBuf.baseAddress, kCCKeySizeAES128,
                        nil,
                        inBuf.baseAddress, block.count,
                        outBuf.baseAddress, capacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CryptoError.cryptoFailed(status: status) }
        return output.prefix(moved)
    }

    // MARK: - AES-CTR (V2 encryption)
    // Xiaomi V2 peculiarity: IV = encryptionKey (GadgetBridge: "I wish I was kidding").
    // Implemented manually with AES-ECB blocks to avoid needing CCCryptorCreateWithMode.

    static func aesCTR(data: Data, key: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else {
            throw CryptoError.invalidKeyLength(key.count)
        }

        var counter = Array(key)  // 16-byte counter initialized to key value
        var output = Data()
        var offset = 0

        while offset < data.count {
            let keystream = try aesECBEncrypt(block: Data(counter), key: key)
            let blockEnd = min(offset + kCCBlockSizeAES128, data.count)
            for i in offset..<blockEnd {
                output.append(data[i] ^ keystream[i - offset])
            }
            incrementCounterBE(&counter)
            offset += kCCBlockSizeAES128
        }
        return output
    }

    private static func incrementCounterBE(_ counter: inout [UInt8]) {
        var i = counter.count - 1
        while i >= 0 {
            counter[i] = counter[i] &+ 1
            if counter[i] != 0 { break }
            i -= 1
        }
    }

    // MARK: - Session key derivation

    struct SessionKeys {
        let decryptionKey:   Data   // bytes 0–15
        let encryptionKey:   Data   // bytes 16–31
        let decryptionNonce: Data   // bytes 32–35
        let encryptionNonce: Data   // bytes 36–39
    }

    /// Derives the 64-byte session key material from the exchanged nonces and the device secretKey.
    static func deriveSessionKeys(
        phoneNonce: Data,
        watchNonce: Data,
        secretKey: Data
    ) -> SessionKeys {
        let prk = hmacSHA256(message: phoneNonce + watchNonce, key: secretKey)
        let info = Data("miwear-auth".utf8)
        let expanded = hkdfExpand(prk: prk, info: info, outputLength: 64)

        return SessionKeys(
            decryptionKey:   expanded[0..<16],
            encryptionKey:   expanded[16..<32],
            decryptionNonce: expanded[32..<36],
            encryptionNonce: expanded[36..<40]
        )
    }

    // MARK: - Errors

    enum CryptoError: LocalizedError {
        case invalidKeyLength(Int)
        case cryptoFailed(status: CCCryptorStatus)

        var errorDescription: String? {
            switch self {
            case .invalidKeyLength(let n): return "Chave AES inválida: \(n) bytes (esperado 16)."
            case .cryptoFailed(let s):     return "Operação criptográfica falhou (CCCryptorStatus \(s))."
            }
        }
    }
}
