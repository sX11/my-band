import Foundation
import CryptoKit

// MARK: - Checksums
//
// MD5 + CRC-32 used by the Xiaomi data-upload envelope (watch faces / apps). The band verifies
// both the per-file MD5 (in the upload request) and the CRC-32 (appended to the upload payload),
// so these must match GadgetBridge's CheckSums exactly.

enum Checksums {

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }

    /// Standard CRC-32 (poly 0xEDB88320, init/xorout 0xFFFFFFFF) — GadgetBridge CheckSums.getCRC32.
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
