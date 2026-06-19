import CoreBluetooth

// MARK: - Mi Band 10 BLE V2 UUIDs
// Confirmed via GadgetBridge XiaomiUuids.java (BLE_V2_CHARACTERISTIC_*):
// Service FE95 carries ALL communication via only 2 characteristics in V2:
//   005F — notify (band → app): ALL SPP V2 frames — command responses AND activity data
//   005E — write  (app → band): ALL SPP V2 frames — session config, auth, health commands
//
// Activity data is NOT on a separate characteristic in V2 — it arrives on 005F
// and is differentiated by the channel byte (0x05) inside the SPP DATA packet payload.
//
// V1 (Mi Band 8) used 0051/0052/0053 — Mi Band 10 uses V2 (005E/005F only).

enum MiBandUUID {

    // MARK: - Service

    static let mainService = CBUUID(string: "0000FE95-0000-1000-8000-00805F9B34FB")

    // MARK: - Characteristics (V2)

    /// Notify (band → app): ALL SPP V2 frames — commands, auth responses, AND activity data
    /// GadgetBridge: BLE_V2_CHARACTERISTIC_RX_UUID (phone receives on this)
    static let commandRead  = CBUUID(string: "0000005E-0000-1000-8000-00805F9B34FB")
    /// Write (app → band): SPP V2 frames — session config, auth, health commands
    /// GadgetBridge: BLE_V2_CHARACTERISTIC_TX_UUID (phone transmits on this)
    static let commandWrite = CBUUID(string: "0000005F-0000-1000-8000-00805F9B34FB")

    // MARK: - Scan

    static let scanServices: [CBUUID] = [mainService]
}
