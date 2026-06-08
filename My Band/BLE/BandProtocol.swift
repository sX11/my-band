import Foundation

// MARK: - XiaomiSppPacketV2
//
// Frame format used by Mi Band 10 BLE V2 protocol over characteristics 005E/005F.
// Confirmed via GadgetBridge XiaomiSppPacketV2.java.
//
// Frame layout (total = 10 + payloadLen bytes):
//   [0..1]  preamble: 0xA5 0xA5
//   [2]     packetType (UInt8)
//   [3]     channel (UInt8)
//   [4]     seqNum (UInt8, per-channel sequence counter)
//   [5..6]  payloadLen (UInt16 LE)
//   [7]     flags (reserved, 0x00)
//   [8..9]  CRC-16/ARC of entire frame with bytes [8..9] zeroed
//   [10+]   payload

enum XiaomiPacketType: UInt8 {
    case command = 0x00
    case data    = 0x01
    case ack     = 0x02
}

enum XiaomiChannel: UInt8 {
    case command  = 0x01   // protobuf Command messages (auth, sync control)
    case data     = 0x02   // raw binary data payloads
    case activity = 0x05   // activity/sleep data payloads
}

enum XiaomiSppPacket {

    // MARK: - Frame constants

    static let headerSize = 10
    private static let preamble: [UInt8] = [0xA5, 0xA5]

    // MARK: - Build

    /// Assembles a complete XiaomiSppPacketV2 frame ready for BLE write.
    static func build(
        type: XiaomiPacketType,
        channel: XiaomiChannel,
        seqNum: UInt8,
        payload: Data,
        flags: UInt8 = 0x00
    ) -> Data {
        let len = UInt16(payload.count)
        var frame = Data(capacity: headerSize + payload.count)

        frame.append(contentsOf: preamble)
        frame.append(type.rawValue)
        frame.append(channel.rawValue)
        frame.append(seqNum)
        frame.append(UInt8(len & 0xFF))
        frame.append(UInt8(len >> 8))
        frame.append(flags)
        frame.append(0x00)  // CRC placeholder (lo)
        frame.append(0x00)  // CRC placeholder (hi)
        frame.append(payload)

        let crc = crc16arc(frame)
        frame[8] = UInt8(crc & 0xFF)
        frame[9] = UInt8(crc >> 8)

        return frame
    }

    // MARK: - Parse

    struct Parsed {
        let type:    XiaomiPacketType
        let channel: XiaomiChannel
        let seqNum:  UInt8
        let flags:   UInt8
        let payload: Data
    }

    /// Parses a received BLE notification into a Parsed frame.
    /// Returns nil if the data is malformed or CRC check fails.
    static func parse(_ data: Data) -> Parsed? {
        guard data.count >= headerSize,
              data[0] == 0xA5, data[1] == 0xA5 else { return nil }

        guard let type    = XiaomiPacketType(rawValue: data[2]),
              let channel = XiaomiChannel(rawValue: data[3]) else { return nil }

        let seqNum     = data[4]
        let payloadLen = Int(data[5]) | (Int(data[6]) << 8)
        let flags      = data[7]

        guard data.count >= headerSize + payloadLen else { return nil }

        // CRC check: compute over frame with bytes [8..9] zeroed
        var frameForCRC = data.prefix(headerSize + payloadLen)
        let receivedCRC = UInt16(frameForCRC[8]) | (UInt16(frameForCRC[9]) << 8)
        var frameBytes = Array(frameForCRC)
        frameBytes[8] = 0; frameBytes[9] = 0
        let computed = crc16arc(Data(frameBytes))
        guard computed == receivedCRC else { return nil }

        let payload = data.subdata(in: headerSize..<(headerSize + payloadLen))
        return Parsed(type: type, channel: channel, seqNum: seqNum, flags: flags, payload: payload)
    }

    // MARK: - CRC-16/ARC (poly 0xA001, init 0x0000, refIn=true, refOut=true, xorOut=0x0000)

    static func crc16arc(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0
        for byte in data {
            crc ^= UInt16(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}

// MARK: - Auth command IDs (GadgetBridge XiaomiAuthService)

enum XiaomiAuthCmd {
    static let cmdType:  UInt32 = 1
    static let nonce:    UInt32 = 26   // CMD_NONCE  — phone sends 16-byte nonce
    static let auth:     UInt32 = 27   // CMD_AUTH   — phone sends encrypted confirmation
}

// MARK: - Sync command IDs

enum XiaomiSyncCmd {
    static let cmdType:    UInt32 = 8
    static let fetchSleep: UInt32 = 2   // request sleep history
}

// MARK: - Session config helpers (sent before auth to negotiate MTU and protocol version)

enum XiaomiSessionConfig {
    // message SessionConfig { uint32 mtu = 1; uint32 version = 2; }
    static func payload(mtu: UInt16 = 512) -> Data {
        var p = Data()
        p += XiaomiProto.field(number: 1, uint32: UInt32(mtu))
        p += XiaomiProto.field(number: 2, uint32: 2)
        return p
    }

    // Session config is sent as a COMMAND-type packet on channel=COMMAND with subtype 0.
    // GadgetBridge: type=0, subtype=0 reserved for session negotiation.
    static let cmdType:    UInt32 = 0
    static let cmdSubtype: UInt32 = 1
}
