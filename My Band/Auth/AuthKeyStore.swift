import Foundation
import Security

/// Stores and retrieves the Mi Band AuthKey (16 bytes) from the Keychain.
/// The AuthKey must never touch SwiftData, UserDefaults, or any log output.
struct AuthKeyStore {

    private static let account = "mi-band-auth-key"
    private static let service = Bundle.main.bundleIdentifier ?? "com.myband"

    // MARK: - Public API

    static func save(_ key: Data) throws {
        guard key.count == 16 else { throw AuthKeyError.invalidLength(key.count) }

        let query: [String: Any] = [
            kSecClass as String:            kSecClassGenericPassword,
            kSecAttrService as String:      service,
            kSecAttrAccount as String:      account,
            kSecValueData as String:        key,
            // Accessible in background — required for BLE reconnect while app is suspended
            kSecAttrAccessible as String:   kSecAttrAccessibleAfterFirstUnlock,
        ]

        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw AuthKeyError.keychainError(status) }
    }

    static func load() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            if status == errSecItemNotFound { throw AuthKeyError.notFound }
            throw AuthKeyError.keychainError(status)
        }
        return data
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static var isStored: Bool {
        (try? load()) != nil
    }

    // MARK: - Hardcoded dev key (source-level only — see git history)

    private static let hardcodedHex = "***REMOVED***"

    /// Seeds the Keychain with the hardcoded key if no key is currently stored.
    /// Call once at app launch.
    static func seedIfNeeded() {
        guard !isStored, let data = Data(hexString: hardcodedHex) else { return }
        try? save(data)
    }

    // MARK: - Hex convenience

    /// Parses a 32-character hex string (e.g. "a1b2c3...") into 16 bytes and saves it.
    static func saveHex(_ hex: String) throws {
        let cleaned = hex.replacingOccurrences(of: " ", with: "").lowercased()
        guard cleaned.count == 32 else { throw AuthKeyError.invalidHex }
        guard let data = Data(hexString: cleaned) else { throw AuthKeyError.invalidHex }
        try save(data)
    }
}

// MARK: - Errors

enum AuthKeyError: LocalizedError {
    case notFound
    case invalidLength(Int)
    case invalidHex
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound:               return "AuthKey não encontrado. Configure a chave da pulseira."
        case .invalidLength(let n):   return "AuthKey deve ter 16 bytes; recebido \(n)."
        case .invalidHex:             return "Formato inválido. Informe 32 caracteres hexadecimais."
        case .keychainError(let s):   return "Erro no Keychain (OSStatus \(s))."
        }
    }
}

// MARK: - Data+hexString

extension Data {
    init?(hexString: String) {
        let hex = hexString
        guard hex.count % 2 == 0 else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let nextIndex = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
