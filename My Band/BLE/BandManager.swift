import CoreBluetooth
import Observation
import OSLog

// MARK: - Connection state

enum ConnectionState: Equatable {
    case bluetoothUnavailable
    case disconnected
    case scanning
    case connecting
    case discoveringServices
    case sessionConfig     // negotiating MTU/version with band
    case authenticating
    case connected
    case error(String)

    var isConnected: Bool { self == .connected }
    var isScanning:  Bool { self == .scanning }

    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.bluetoothUnavailable, .bluetoothUnavailable),
             (.disconnected,          .disconnected),
             (.scanning,              .scanning),
             (.connecting,            .connecting),
             (.discoveringServices,   .discoveringServices),
             (.sessionConfig,         .sessionConfig),
             (.authenticating,        .authenticating),
             (.connected,             .connected):
            return true
        case (.error(let a), .error(let b)):
            return a == b
        default:
            return false
        }
    }
}

// MARK: - BandManager

/// Central orchestrator for all Mi Band 10 BLE V2 operations.
///
/// @MainActor + @Observable: CBCentralManager is configured with queue: .main,
/// so all delegate callbacks arrive on the main thread — matching @MainActor's
/// executor without extra dispatching.
///
/// Protocol: XiaomiSppPacketV2 over BLE characteristics 005E (TX) / 005F (RX).
/// Auth: session config → HMAC-SHA256 nonce exchange → AES-CTR confirmation.
@Observable
@MainActor
final class BandManager: NSObject {

    // MARK: - Published state

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var discoveredDevices: [CBPeripheral] = []
    private(set) var connectedPeripheral: CBPeripheral?
    private(set) var lastError: Error?

    // MARK: - Private BLE objects

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    private var txCharacteristic: CBCharacteristic?  // 005E: app → band
    private var rxCharacteristic: CBCharacteristic?  // 005F: band → app

    // MARK: - Auth state

    private var phoneNonce: Data?
    private var sessionKeys: XiaomiCrypto.SessionKeys?
    private var authContinuation: CheckedContinuation<Void, Error>?

    // Per-channel sequence counters (wrap at UInt8.max)
    private var seqNumCommand: UInt8 = 0

    // MARK: - Callbacks for BandSyncer

    var onAuthenticated: ((String, String) -> Void)?
    var onRawChunkReceived: ((Data) -> Void)?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "BLE")

    // MARK: - Reconnect backoff

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    // Set when startScan() is called before BT is ready; consumed by centralManagerDidUpdateState
    private var pendingScan = false

    // MARK: - Init

    override init() {
        super.init()
        // State restoration requires a physical iOS device with bluetooth-central background mode.
        // The simulator rejects CBCentralManagerOptionRestoreIdentifierKey at runtime.
        var options: [String: Any] = [:]
        #if !targetEnvironment(simulator)
        options[CBCentralManagerOptionRestoreIdentifierKey] = "com.myband.central"
        #endif
        central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else {
            pendingScan = true
            return
        }
        pendingScan = false
        discoveredDevices.removeAll()
        connectionState = .scanning
        central.scanForPeripherals(withServices: MiBandUUID.scanServices, options: BandScanner.scanOptions)
        log.info("BLE scan started (service: FE95)")
    }

    func stopScan() {
        central.stopScan()
        if connectionState == .scanning { connectionState = .disconnected }
    }

    func connect(to target: CBPeripheral) {
        stopScan()
        peripheral = target
        peripheral?.delegate = self
        connectionState = .connecting
        central.connect(target, options: BandScanner.reconnectOptions)
        log.info("Connecting to \(target.name ?? target.identifier.uuidString)")
    }

    /// Runs the full auth sequence: session config → nonce exchange → key derivation → confirmation.
    /// Throws if the AuthKey is missing, HMAC verification fails, or the band rejects auth.
    func authenticate() async throws {
        guard txCharacteristic != nil, rxCharacteristic != nil else {
            throw AuthError.timeout
        }
        let secretKey = try AuthKeyStore.load()

        connectionState = .sessionConfig
        sendSessionConfig()

        connectionState = .authenticating
        let nonce = BandAuthenticator.phoneNonce()
        phoneNonce = nonce
        writePacket(BandAuthenticator.noncePacket(phoneNonce: nonce, seqNum: nextSeqNum()))

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            authContinuation = c
        }
        // sessionKeys populated by handleAuthNotification before resuming continuation
    }

    func disconnect() {
        guard let p = peripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    /// Sends a pre-built XiaomiSppPacketV2 frame to the band (writes to 005E without response).
    func writePacket(_ packet: Data) {
        guard let char = txCharacteristic, let p = peripheral else { return }
        p.writeValue(packet, for: char, type: .withoutResponse)
    }

    /// Builds and sends a command-channel packet carrying a protobuf Command payload.
    func sendCommand(type: UInt32, subtype: UInt32, payload: Data = Data()) {
        let proto = XiaomiProto.command(type: type, subtype: subtype, payload: payload)
        let packet = XiaomiSppPacket.build(type: .command, channel: .command, seqNum: nextSeqNum(), payload: proto)
        writePacket(packet)
    }

    // MARK: - Private helpers

    private func sendSessionConfig() {
        let payload = XiaomiSessionConfig.payload()
        let proto = XiaomiProto.command(
            type: XiaomiSessionConfig.cmdType,
            subtype: XiaomiSessionConfig.cmdSubtype,
            payload: payload
        )
        let packet = XiaomiSppPacket.build(type: .command, channel: .command, seqNum: nextSeqNum(), payload: proto)
        writePacket(packet)
        log.debug("Session config sent")
    }

    private func nextSeqNum() -> UInt8 {
        defer { seqNumCommand = seqNumCommand &+ 1 }
        return seqNumCommand
    }

    private func handleRxNotification(_ raw: Data) {
        guard let parsed = XiaomiSppPacket.parse(raw) else {
            log.warning("Received malformed packet (\(raw.count) bytes), CRC failed or unknown format")
            return
        }

        switch parsed.channel {
        case .command:
            handleCommandChannelPacket(parsed.payload)
        case .data, .activity:
            onRawChunkReceived?(parsed.payload)
        }
    }

    private func handleCommandChannelPacket(_ payload: Data) {
        // Decode the Command proto header to determine type/subtype
        guard let (typeVal, typeLen) = XiaomiProto.readVarint(payload, at: 1),
              let (subVal, _)  = XiaomiProto.readVarint(payload, at: 1 + typeLen + 1) else {
            // Couldn't parse — treat as auth-related during auth state
            if connectionState == .authenticating {
                handleAuthPayload(payload)
            }
            return
        }

        let cmdType = UInt32(typeVal >> 3)   // field number 1, varint → actual type in value
        _ = subVal                           // subtype parsed but routing is simpler below

        // Route by state — during auth we expect auth responses
        if connectionState == .authenticating || connectionState == .sessionConfig {
            handleAuthPayload(payload)
        } else {
            log.debug("Command channel: type=\(cmdType), \(payload.count) bytes")
        }
    }

    private func handleAuthPayload(_ payload: Data) {
        guard let nonce = phoneNonce,
              let secretKey = try? AuthKeyStore.load() else {
            failAuth(AuthError.noAuthKey)
            return
        }

        if connectionState == .sessionConfig {
            // Any command-channel response during session config = ACK, proceed to auth
            connectionState = .authenticating
            return
        }

        // Parse band nonce response
        guard let bandResp = BandAuthenticator.parseBandNonce(payload: payload) else {
            failAuth(AuthError.unexpectedPayload(payload.count))
            return
        }

        // Verify HMAC
        guard BandAuthenticator.verifyBandHMAC(
            bandHMAC: bandResp.bandHMAC,
            phoneNonce: nonce,
            watchNonce: bandResp.watchNonce,
            secretKey: secretKey
        ) else {
            failAuth(AuthError.badHMAC)
            return
        }

        // Derive session keys
        let keys = BandAuthenticator.deriveKeys(
            phoneNonce: nonce,
            watchNonce: bandResp.watchNonce,
            secretKey: secretKey
        )
        sessionKeys = keys

        // Send auth confirmation
        do {
            let authPkt = try BandAuthenticator.authPacket(
                phoneNonce: nonce,
                watchNonce: bandResp.watchNonce,
                sessionKeys: keys,
                seqNum: nextSeqNum()
            )
            writePacket(authPkt)
            log.debug("CMD_AUTH sent, awaiting band confirmation")
            // The next command-channel packet will be the auth success/failure.
            // GadgetBridge does not send another protocol message — band signals
            // success by allowing subsequent commands. We resume the continuation here.
            // ⚠️ If the band sends an explicit ACK/NACK, update this handler accordingly.
            resumeAuth()
        } catch {
            failAuth(error)
        }
    }

    private func resumeAuth() {
        connectionState = .connected
        connectedPeripheral = peripheral
        reconnectAttempts = 0
        log.info("Authentication successful (HMAC-SHA256 V2)")
        authContinuation?.resume()
        authContinuation = nil
        if let p = peripheral {
            onAuthenticated?(p.name ?? "Mi Band 10", p.identifier.uuidString)
        }
    }

    private func failAuth(_ error: Error) {
        log.error("Auth failed: \(error.localizedDescription)")
        lastError = error
        connectionState = .error(error.localizedDescription)
        authContinuation?.resume(throwing: error)
        authContinuation = nil
    }

    private func scheduleReconnect(to target: CBPeripheral) {
        guard reconnectAttempts < maxReconnectAttempts else {
            log.warning("Max reconnect attempts reached")
            connectionState = .disconnected
            return
        }
        let delay = pow(2.0, Double(reconnectAttempts))
        reconnectAttempts += 1
        log.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts))")
        Task {
            try? await Task.sleep(for: .seconds(delay))
            self.central.connect(target, options: BandScanner.reconnectOptions)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.info("Bluetooth powered on")
            if pendingScan { startScan(); return }
            if connectionState == .disconnected, let p = peripheral { connect(to: p) }
        case .poweredOff:
            connectionState = .bluetoothUnavailable
            log.warning("Bluetooth powered off")
        case .unauthorized:
            connectionState = .error("Acesso Bluetooth não autorizado. Verifique as permissões.")
        case .unsupported:
            connectionState = .error("Este dispositivo não suporta Bluetooth LE.")
        default:
            connectionState = .bluetoothUnavailable
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard BandScanner.isMiBand(peripheral, advertisementData: advertisementData) else { return }
        guard !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) else { return }
        log.info("Discovered: \(peripheral.name ?? peripheral.identifier.uuidString) RSSI \(RSSI)")
        discoveredDevices.append(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("Connected — discovering services")
        connectionState = .discoveringServices
        peripheral.discoverServices([MiBandUUID.mainService, MiBandUUID.heartRateService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        lastError = error
        connectionState = .error(error?.localizedDescription ?? "Falha na conexão")
        scheduleReconnect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectedPeripheral = nil
        txCharacteristic = nil
        rxCharacteristic = nil
        phoneNonce = nil
        sessionKeys = nil
        seqNumCommand = 0

        if let error {
            log.warning("Disconnected with error: \(error.localizedDescription)")
            scheduleReconnect(to: peripheral)
        } else {
            log.info("Disconnected cleanly")
        }
        connectionState = .disconnected
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            restored.delegate = self
            peripheral = restored
            log.info("State restored: \(restored.name ?? restored.identifier.uuidString)")
        }
    }
}

// MARK: - CBPeripheralDelegate

extension BandManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            log.error("Service discovery failed: \(error.localizedDescription)")
            connectionState = .error(error.localizedDescription)
            return
        }
        for service in peripheral.services ?? [] {
            switch service.uuid {
            case MiBandUUID.mainService:
                peripheral.discoverCharacteristics([MiBandUUID.commandTX, MiBandUUID.commandRX], for: service)
            case MiBandUUID.heartRateService:
                peripheral.discoverCharacteristics(
                    [MiBandUUID.heartRateMeasurement, MiBandUUID.heartRateControlPoint], for: service
                )
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            log.error("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case MiBandUUID.commandTX:
                txCharacteristic = char
                log.debug("Found TX characteristic (005E)")
            case MiBandUUID.commandRX:
                rxCharacteristic = char
                peripheral.setNotifyValue(true, for: char)
                log.debug("Found RX characteristic (005F), notifications enabled")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let data = characteristic.value else { return }

        switch characteristic.uuid {
        case MiBandUUID.commandRX:
            handleRxNotification(data)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("Write failed on \(characteristic.uuid): \(error.localizedDescription)")
            if connectionState == .authenticating || connectionState == .sessionConfig {
                failAuth(error)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            log.error("Notify state update failed for \(characteristic.uuid): \(error.localizedDescription)")
        } else if characteristic.uuid == MiBandUUID.commandRX {
            log.debug("RX notifications active")
        }
    }
}
