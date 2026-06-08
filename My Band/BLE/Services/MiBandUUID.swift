import CoreBluetooth

// MARK: - Mi Band 10 BLE V2 UUIDs
// Confirmed via GadgetBridge XiaomiUuids.java / XiaomiBleProtocolV2.java.
// The band communicates over a single service (FE95) with two characteristics:
//   005E — write channel (app → band, XiaomiSppPacketV2 frames)
//   005F — notify channel (band → app, XiaomiSppPacketV2 frames)

enum MiBandUUID {

    // MARK: - Services

    /// Xiaomi BLE V2 main service — carries all commands and data
    static let mainService = CBUUID(string: "0000FE95-0000-1000-8000-00805F9B34FB")

    // MARK: - V2 Characteristics

    /// Write (app → band): XiaomiSppPacketV2 command/data frames
    static let commandTX = CBUUID(string: "0000005E-0000-1000-8000-00805F9B34FB")
    /// Notify (band → app): XiaomiSppPacketV2 response/data frames
    static let commandRX = CBUUID(string: "0000005F-0000-1000-8000-00805F9B34FB")

    // MARK: - Standard GATT (Heart Rate)

    static let heartRateService      = CBUUID(string: "0000180D-0000-1000-8000-00805F9B34FB")
    static let heartRateMeasurement  = CBUUID(string: "00002A37-0000-1000-8000-00805F9B34FB")
    static let heartRateControlPoint = CBUUID(string: "00002A39-0000-1000-8000-00805F9B34FB")

    // MARK: - Scan helpers

    static let scanServices: [CBUUID] = [mainService]
}
