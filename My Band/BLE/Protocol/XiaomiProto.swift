import Foundation

// MARK: - XiaomiProto
// Minimal protobuf encoder for Xiaomi command messages.
// Covers only the fields needed for auth and sync — no codegen, no external package.
//
// Command proto (inferred from GadgetBridge XiaomiAuthService + XiaomiSyncService):
//   message Command {
//     uint32 type    = 1;   // command category (1=auth, 8=sync, …)
//     uint32 subtype = 2;   // command sub-id within category
//     bytes  payload = 3;   // optional binary payload
//   }

enum XiaomiProto {

    // MARK: - Wire types

    private static let wireVarint: UInt8 = 0
    private static let wireLen:    UInt8 = 2

    // MARK: - Varint encoding

    static func varint(_ value: UInt64) -> Data {
        var v = value
        var bytes: [UInt8] = []
        repeat {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v > 0 { b |= 0x80 }
            bytes.append(b)
        } while v > 0
        return Data(bytes)
    }

    // MARK: - Field helpers

    static func field(number: Int, uint32 value: UInt32) -> Data {
        let tag = varint(UInt64((number << 3) | Int(wireVarint)))
        return tag + varint(UInt64(value))
    }

    static func field(number: Int, bytes value: Data) -> Data {
        let tag = varint(UInt64((number << 3) | Int(wireLen)))
        return tag + varint(UInt64(value.count)) + value
    }

    // MARK: - Command message builder

    static func command(type: UInt32, subtype: UInt32, payload: Data = Data()) -> Data {
        var msg = Data()
        msg += field(number: 1, uint32: type)
        msg += field(number: 2, uint32: subtype)
        if !payload.isEmpty {
            msg += field(number: 3, bytes: payload)
        }
        return msg
    }

    // MARK: - Varint decoder (for parsing band responses)

    /// Reads a varint from `data` starting at `offset`. Returns (value, bytesConsumed).
    static func readVarint(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var i = offset
        while i < data.count {
            let b = data[i]
            i += 1
            result |= UInt64(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { return (result, i - offset) }
            if shift >= 64 { return nil }
        }
        return nil
    }

    // MARK: - Simple response field reader
    // Parses the first occurrence of a length-delimited field `fieldNumber` from `data`.

    static func bytesField(_ fieldNumber: Int, from data: Data) -> Data? {
        let targetTag = UInt64((fieldNumber << 3) | Int(wireLen))
        var i = 0
        while i < data.count {
            guard let (tag, tagLen) = readVarint(data, at: i) else { break }
            i += tagLen
            let wt = tag & 0x07
            let fn = tag >> 3
            switch wt {
            case 0: // varint
                guard let (_, vLen) = readVarint(data, at: i) else { return nil }
                if fn == UInt64(fieldNumber) { return nil } // wrong type
                i += vLen
            case 2: // length-delimited
                guard let (len, lLen) = readVarint(data, at: i) else { return nil }
                i += lLen
                let end = i + Int(len)
                guard end <= data.count else { return nil }
                if tag == targetTag { return data.subdata(in: i..<end) }
                i = end
            default:
                return nil // unknown wire type — stop
            }
        }
        return nil
    }
}
