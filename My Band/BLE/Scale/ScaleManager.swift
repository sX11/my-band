import Foundation
import CoreBluetooth
import OSLog

/// Shared key for the user's height (cm), set in the profile UI and read here to derive BMI.
enum ProfileDefaults {
    static let heightCmKey = "userHeightCm"
    static var heightMeters: Double? {
        let cm = UserDefaults.standard.double(forKey: heightCmKey)
        return cm > 0 ? cm / 100.0 : nil
    }
}

// MARK: - ScaleManager
//
// Listens for an OKOK/Chipsea BLE scale and writes each weighing to Apple Health as bodyMass.
//
// The scale is broadcast-only (confirmed on hardware): it never accepts a GATT connection, it just
// advertises the weight, so this only scans — no connect. Its advertisement carries no service UUID,
// which means iOS can only discover it in the foreground (background scanning requires a service
// filter). That's fine for a scale: open the app, step on, the reading is written.
//
// A weighing streams many frames: non-final/zero while you settle, then the final weight repeated for
// a while. We write once per weighing — `lastFinalWeight` is armed (cleared) by any zero/non-final
// frame (you stepped off / the scale reset) and a new non-zero final frame is treated as a new
// weighing, so stepping on again — even at the same weight — logs again.

@Observable
@MainActor
final class ScaleManager: NSObject {

    private(set) var lastWeightKg: Double?
    private(set) var lastWeightDate: Date?
    private(set) var lastError: String?

    private var central: CBCentralManager?
    private var lastFinalWeight: Double?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Scale")

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func stop() {
        central?.stopScan()
        central = nil
    }

    private func handle(_ reading: ScaleReading) {
        // A settling/zero frame means no one is on the scale — arm for the next weighing.
        guard reading.isFinal, reading.weightKg > 0 else {
            lastFinalWeight = nil
            return
        }
        // Same final weight still being re-broadcast → same weighing, already written.
        guard reading.weightKg != lastFinalWeight else { return }
        lastFinalWeight = reading.weightKg

        let now = Date()
        lastWeightKg = reading.weightKg
        lastWeightDate = now
        log.info("Scale weight \(reading.weightKg, format: .fixed(precision: 2)) kg — writing to Apple Health")

        Task { [weak self] in
            guard let self else { return }
            do {
                try await HealthKitManager.shared.requestAuthorization()
                try await HealthKitManager.shared.writeBodyMass(reading.weightKg, date: now,
                                                                heightMeters: ProfileDefaults.heightMeters)
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
                self.log.error("Failed to write body mass: \(error.localizedDescription)")
            }
        }
    }
}

extension ScaleManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // No service UUID to filter on, so scan broadly; allowDuplicates so the final frame isn't
        // missed if it matches an earlier non-final packet length.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let reading = ScaleWeightParser.parse(mfg) else { return }
        handle(reading)
    }
}
