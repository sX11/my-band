import Foundation

// MARK: - XiaomiProto
//
// Hand-written protobuf encoder/decoder for Xiaomi Mi Band 10 command protocol.
// Uses no external packages — zero SPM dependencies.
//
// Relevant proto definitions (from GadgetBridge xiaomi.proto):
//
//   message Command {
//     required uint32 type    = 1;
//     optional uint32 subtype = 2;
//     optional Auth   auth    = 3;
//     optional Health health  = 10;
//     optional uint32 status  = 100;
//   }
//   message Auth {
//     optional string    userId    = 7;
//     optional uint32    status    = 8;
//     optional PhoneNonce phoneNonce = 30;
//     optional WatchNonce watchNonce = 31;
//     optional AuthStep3  authStep3  = 32;
//     optional AuthStep4  authStep4  = 33;
//   }
//   message PhoneNonce  { required bytes nonce = 1; }
//   message WatchNonce  { required bytes nonce = 1; required bytes hmac = 2; }
//   message AuthStep3   { required bytes encryptedNonces = 1; required bytes encryptedDeviceInfo = 2; }
//   message AuthDeviceInfo {
//     optional uint32 unknown1     = 1;   // 0
//     optional uint32 phoneApiLevel = 2;  // iOS major version
//     optional string phoneName    = 3;   // e.g. "iPhone"
//     optional uint32 unknown3     = 4;   // 224
//     optional string region       = 5;   // 2-letter upper-case language code
//   }
//   message Health { optional bytes activityRequestFileIds = 7; ... }

enum XiaomiProto {

    // MARK: - Wire type constants

    private static let wtVarint: UInt8 = 0
    private static let wtLen:    UInt8 = 2

    // MARK: - Primitive encoders

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

    static func field(number: Int, uint32 value: UInt32) -> Data {
        varint(UInt64((number << 3) | Int(wtVarint))) + varint(UInt64(value))
    }

    static func field(number: Int, string value: String) -> Data {
        let utf8 = Data(value.utf8)
        return varint(UInt64((number << 3) | Int(wtLen))) + varint(UInt64(utf8.count)) + utf8
    }

    static func field(number: Int, bytes value: Data) -> Data {
        varint(UInt64((number << 3) | Int(wtLen))) + varint(UInt64(value.count)) + value
    }

    static func field(number: Int, message value: Data) -> Data {
        field(number: number, bytes: value)
    }

    // MARK: - Auth command builders

    /// Command { type=1, subtype=26, auth=Auth { phoneNonce=PhoneNonce { nonce } } }
    static func phoneNonceCommand(nonce: Data) -> Data {
        let phoneNonce = field(number: 1, bytes: nonce)              // PhoneNonce.nonce = field 1
        let auth       = field(number: 30, message: phoneNonce)      // Auth.phoneNonce  = field 30
        return command(type: XiaomiAuthCmd.cmdType,
                       subtype: XiaomiAuthCmd.nonce,
                       auth: auth)
    }

    /// Command { type=1, subtype=27, auth=Auth { authStep3=AuthStep3 { encryptedNonces, encryptedDeviceInfo } } }
    static func authStep3Command(encryptedNonces: Data, encryptedDeviceInfo: Data) -> Data {
        var step3 = Data()
        step3 += field(number: 1, bytes: encryptedNonces)            // AuthStep3.encryptedNonces      = field 1
        step3 += field(number: 2, bytes: encryptedDeviceInfo)        // AuthStep3.encryptedDeviceInfo  = field 2
        let auth = field(number: 32, message: step3)                 // Auth.authStep3                 = field 32
        return command(type: XiaomiAuthCmd.cmdType,
                       subtype: XiaomiAuthCmd.auth,
                       auth: auth)
    }

    /// AuthDeviceInfo proto (iOS-adapted: phoneApiLevel = iOS major version, region from locale)
    static func authDeviceInfo() -> Data {
        var info = Data()
        info += field(number: 1, uint32: 0)         // unknown1
        info += field(number: 2, uint32: 17)        // phoneApiLevel (iOS 17)
        info += field(number: 3, string: "iPhone")  // phoneName
        info += field(number: 4, uint32: 224)       // unknown3
        let lang = Locale.current.language.languageCode?.identifier.prefix(2).uppercased() ?? "EN"
        info += field(number: 5, string: lang)      // region
        return info
    }

    // MARK: - Health command builder

    /// Command { type=8, subtype, health=Health { activityRequestFileIds } }
    static func healthCommand(subtype: UInt32, fileIds: Data = Data()) -> Data {
        var msg = Data()
        msg += field(number: 1, uint32: XiaomiHealthCmd.cmdType)
        msg += field(number: 2, uint32: subtype)
        if !fileIds.isEmpty {
            let health = field(number: 7, bytes: fileIds)  // Health.activityRequestFileIds = field 7
            msg += field(number: 10, message: health)      // Command.health = field 10
        }
        return msg
    }

    // MARK: - Generic command builder

    static func command(type: UInt32, subtype: UInt32, auth: Data = Data()) -> Data {
        var msg = Data()
        msg += field(number: 1,  uint32:  type)
        msg += field(number: 2,  uint32:  subtype)
        if !auth.isEmpty {
            msg += field(number: 3, message: auth)
        }
        return msg
    }

    // MARK: - Varint decoder

    /// Reads a varint starting at `offset`. Returns (value, bytesConsumed) or nil on error.
    static func readVarint(_ data: Data, at offset: Int) -> (UInt64, Int)? {
        var result: UInt64 = 0
        var shift = 0
        var i = offset
        while i < data.count {
            let b = data[i]; i += 1
            result |= UInt64(b & 0x7F) << shift
            shift += 7
            if b & 0x80 == 0 { return (result, i - offset) }
            if shift >= 64 { return nil }
        }
        return nil
    }

    // MARK: - Generic field reader

    /// Finds the first occurrence of a varint field `fieldNumber` in `data`.
    static func uint32Field(_ fieldNumber: Int, from data: Data) -> UInt32? {
        let targetTag = UInt64((fieldNumber << 3) | Int(wtVarint))
        var i = 0
        while i < data.count {
            guard let (tag, tagLen) = readVarint(data, at: i) else { break }
            i += tagLen
            let wt = tag & 0x07; let fn = tag >> 3
            if wt == 0 {
                guard let (val, vLen) = readVarint(data, at: i) else { return nil }
                if tag == targetTag { return UInt32(val & 0xFFFF_FFFF) }
                i += vLen
            } else if wt == 2 {
                guard let (len, lLen) = readVarint(data, at: i) else { return nil }
                i += lLen + Int(len)
            } else { break }
        }
        return nil
    }

    /// Finds the first occurrence of a length-delimited field `fieldNumber` in `data`.
    static func bytesField(_ fieldNumber: Int, from data: Data) -> Data? {
        let targetTag = UInt64((fieldNumber << 3) | Int(wtLen))
        var i = 0
        while i < data.count {
            guard let (tag, tagLen) = readVarint(data, at: i) else { break }
            i += tagLen
            let wt = tag & 0x07
            if wt == 0 {
                guard let (_, vLen) = readVarint(data, at: i) else { return nil }
                i += vLen
            } else if wt == 2 {
                guard let (len, lLen) = readVarint(data, at: i) else { return nil }
                i += lLen
                let end = i + Int(len)
                guard end <= data.count else { return nil }
                if tag == targetTag { return data.subdata(in: i ..< end) }
                i = end
            } else { break }
        }
        return nil
    }
}
