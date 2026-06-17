import CoreBluetooth

// MARK: - Mi Band 10 BLE V2 UUIDs
// Confirmed via GadgetBridge XiaomiUuids.java:
// Service FE95 carries all communication via four characteristics:
//   0051 — notify (band → app): command responses, encrypted after auth
//   0052 — write  (app → band): commands and session config
//   0053 — notify (band → app): activity data chunks (sleep, HR, steps)
//   0055 — write  (app → band): data upload (firmware, etc.) — not used for basic sync

enum MiBandUUID {

    // MARK: - Service

    static let mainService = CBUUID(string: "0000FE95-0000-1000-8000-00805F9B34FB")

    // MARK: - Characteristics

    /// Notify (band → app): SPP V2 frames with command responses
    static let commandRead    = CBUUID(string: "00000051-0000-1000-8000-00805F9B34FB")
    /// Write (app → band): SPP V2 frames — session config, auth, health commands
    static let commandWrite   = CBUUID(string: "00000052-0000-1000-8000-00805F9B34FB")
    /// Notify (band → app): Activity data chunks [total:2LE][num:2LE][data...]
    static let activityData   = CBUUID(string: "00000053-0000-1000-8000-00805F9B34FB")

    // MARK: - Scan

    static let scanServices: [CBUUID] = [mainService]
}
