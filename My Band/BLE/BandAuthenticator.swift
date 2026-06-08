import Foundation
import CommonCrypto

// MARK: - BandAuthenticator
//
// Mi Band 10 BLE V2 authentication protocol (HMAC-SHA256).
// Confirmed via GadgetBridge XiaomiAuthService.java.
//
// Flow:
//   1. Phone generates 16-byte random nonce (phoneNonce)
//   2. Phone sends CMD_NONCE (type=1, sub=26) with phoneNonce wrapped in XiaomiSppPacket
//   3. Band responds with watchNonce(16) + hmac(32) — hmac = HMAC-SHA256(watchNonce+phoneNonce, secretKey)
//   4. Phone verifies band's HMAC
//   5. Phone derives session keys: HKDF-expand(HMAC-SHA256(phoneNonce+watchNonce, secretKey), "miwear-auth", 64)
//   6. Phone sends CMD_AUTH (type=1, sub=27) with AES-CTR encrypted confirmation
//   7. Band confirms success

enum BandAuthenticator {

    // MARK: - Step 1: Build phone nonce packet

    static func phoneNonce() -> Data {
        var nonce = Data(count: 16)
        nonce.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        return nonce
    }

    static func noncePacket(phoneNonce: Data, seqNum: UInt8) -> Data {
        let payload = XiaomiProto.command(
            type: XiaomiAuthCmd.cmdType,
            subtype: XiaomiAuthCmd.nonce,
            payload: phoneNonce
        )
        return XiaomiSppPacket.build(type: .command, channel: .command, seqNum: seqNum, payload: payload)
    }

    // MARK: - Step 3: Parse band nonce response

    struct BandNonceResponse {
        let watchNonce: Data   // bytes 0–15
        let bandHMAC:   Data   // bytes 16–47
    }

    /// Parses the payload of the band's CMD_NONCE response.
    /// Expected: 48 bytes raw (16 nonce + 32 HMAC) or proto-wrapped in field 3.
    static func parseBandNonce(payload: Data) -> BandNonceResponse? {
        // Try raw format first (GadgetBridge sends watchNonce+hmac as raw bytes in payload)
        if payload.count >= 48 {
            return BandNonceResponse(
                watchNonce: payload[0..<16],
                bandHMAC:   payload[16..<48]
            )
        }
        // Try proto-wrapped (field 3 = bytes)
        if let inner = XiaomiProto.bytesField(3, from: payload), inner.count >= 48 {
            return BandNonceResponse(
                watchNonce: inner[0..<16],
                bandHMAC:   inner[16..<48]
            )
        }
        return nil
    }

    // MARK: - Step 4: Verify band HMAC

    /// Returns true if the band's HMAC matches HMAC-SHA256(watchNonce+phoneNonce, secretKey).
    static func verifyBandHMAC(
        bandHMAC: Data,
        phoneNonce: Data,
        watchNonce: Data,
        secretKey: Data
    ) -> Bool {
        let expected = XiaomiCrypto.hmacSHA256(message: watchNonce + phoneNonce, key: secretKey)
        return expected == bandHMAC
    }

    // MARK: - Step 5: Derive session keys

    static func deriveKeys(
        phoneNonce: Data,
        watchNonce: Data,
        secretKey: Data
    ) -> XiaomiCrypto.SessionKeys {
        XiaomiCrypto.deriveSessionKeys(
            phoneNonce: phoneNonce,
            watchNonce: watchNonce,
            secretKey: secretKey
        )
    }

    // MARK: - Step 6: Build CMD_AUTH confirmation packet

    /// Encrypts the phone's HMAC of (phoneNonce+watchNonce) with the encryptionKey
    /// and wraps it in a CMD_AUTH XiaomiSppPacket.
    static func authPacket(
        phoneNonce: Data,
        watchNonce: Data,
        sessionKeys: XiaomiCrypto.SessionKeys,
        seqNum: UInt8
    ) throws -> Data {
        // The confirmation payload: HMAC-SHA256(phoneNonce+watchNonce, encryptionKey)
        // Encrypt it with AES-CTR (V2 mode) before sending.
        let confirmationMsg = XiaomiCrypto.hmacSHA256(
            message: phoneNonce + watchNonce,
            key: sessionKeys.encryptionKey
        )
        let encrypted = try XiaomiCrypto.aesCTR(data: confirmationMsg, key: sessionKeys.encryptionKey)

        let payload = XiaomiProto.command(
            type: XiaomiAuthCmd.cmdType,
            subtype: XiaomiAuthCmd.auth,
            payload: encrypted
        )
        return XiaomiSppPacket.build(type: .command, channel: .command, seqNum: seqNum, payload: payload)
    }
}

// MARK: - Auth handler result

enum AuthHandlerResult {
    case sendPacket(Data)
    case authenticated(sessionKeys: XiaomiCrypto.SessionKeys)
    case failed(Error)
    case ignored
}

// MARK: - Auth errors

enum AuthError: LocalizedError {
    case noAuthKey
    case unexpectedPayload(Int)
    case badHMAC
    case timeout
    case wrongAuthKey

    var errorDescription: String? {
        switch self {
        case .noAuthKey:             return "AuthKey não encontrado no Keychain."
        case .unexpectedPayload(let n): return "Resposta da pulseira com tamanho inesperado: \(n) bytes."
        case .badHMAC:               return "HMAC da pulseira inválido — AuthKey incorreto ou adulteração."
        case .timeout:               return "Tempo esgotado durante a autenticação."
        case .wrongAuthKey:          return "AuthKey incorreto. Verifique a chave da pulseira."
        }
    }
}
