import CoreBluetooth

// MARK: - Scan configuration

/// Provides scan parameters for CBCentralManager.
/// Actual scanning is driven by BandManager; this namespace keeps
/// scan-related constants and filtering logic in one place.
enum BandScanner {

    static let scanOptions: [String: Any] = [
        CBCentralManagerScanOptionAllowDuplicatesKey: false,
    ]

    // MARK: - Device identification

    /// Returns true if the discovered peripheral is a Mi Band 10.
    /// Device name confirmed from GadgetBridge MiBand10Coordinator.java:
    ///   pattern ^Xiaomi Smart Band 10 [0-9A-F]{4}$
    static func isMiBand(_ peripheral: CBPeripheral, advertisementData: [String: Any]) -> Bool {
        if let name = peripheral.name, isMiBandName(name) { return true }
        if let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
           isMiBandName(localName) { return true }
        if let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID],
           !Set(serviceUUIDs).isDisjoint(with: Set(MiBandUUID.scanServices)) { return true }
        return false
    }

    private static func isMiBandName(_ name: String) -> Bool {
        knownNames.contains(where: { name.hasPrefix($0) })
    }

    // MARK: - Reconnect options

    static let reconnectOptions: [String: Any] = [
        CBConnectPeripheralOptionNotifyOnConnectionKey:    true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
    ]

    // MARK: - Private

    // Primary name: "Xiaomi Smart Band 10 XXXX" (confirmed from GadgetBridge).
    // Legacy aliases kept as fallback in case firmware differs.
    private static let knownNames = ["Xiaomi Smart Band 10", "Mi Band 10", "Mi Smart Band 10"]
}
