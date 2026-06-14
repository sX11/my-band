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
    case sessionConfig       // waiting for band session config response
    case authenticating      // nonce exchange in progress
    case connected
    case error(String)

    var isConnected: Bool { self == .connected }
    var isScanning:  Bool { self == .scanning }

    static func == (lhs: ConnectionState, rhs: ConnectionState) -> Bool {
        switch (lhs, rhs) {
        case (.bluetoothUnavailable, .bluetoothUnavailable),
             (.disconnected,         .disconnected),
             (.scanning,             .scanning),
             (.connecting,           .connecting),
             (.discoveringServices,  .discoveringServices),
             (.sessionConfig,        .sessionConfig),
             (.authenticating,       .authenticating),
             (.connected,            .connected):      return true
        case (.error(let a), .error(let b)):          return a == b
        default:                                       return false
        }
    }
}

// MARK: - BandManager
//
// Central BLE orchestrator for Mi Band 10 V2 protocol.
//
// Key differences from previous implementation (confirmed from GadgetBridge XiaomiSppPacketV2):
//   • Characteristics: 0051 (cmd notify), 0052 (cmd write), 0053 (activity notify)
//   • 8-byte SPP frame header (NOT 10); CRC over payload only
//   • Packet types: ACK=1, SESSION_CONFIG=2, DATA=3
//   • DATA inner payload: [channel & 0xf][opCode][data]
//   • Auth commands use channel=PROTOBUF=1, opCode=PLAINTEXT=1
//   • Post-auth commands use channel=PROTOBUF=1, opCode=ENCRYPTED=2 (AES-CTR key=IV)
//   • Session config is binary (NOT protobuf), packet type=SESSION_CONFIG
//   • Must wait for session config response before sending nonce

@Observable
@MainActor
final class BandManager: NSObject {

    // MARK: - Published state

    private(set) var connectionState: ConnectionState = .disconnected
    private(set) var discoveredDevices: [CBPeripheral] = []
    private(set) var connectedPeripheral: CBPeripheral?
    private(set) var lastError: Error?

    // MARK: - BLE objects

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    // 0051 — notify (band → app)
    private var cmdReadChar:    CBCharacteristic?
    // 0052 — write  (app → band)
    private var cmdWriteChar:   CBCharacteristic?
    // 0053 — notify (band → app): activity data
    private var activityChar:   CBCharacteristic?

    // MARK: - Auth state

    private var phoneNonce:  Data?
    private var sessionKeys: XiaomiCrypto.SessionKeys?
    private var authContinuation: CheckedContinuation<Void, Error>?

    // Per-session sequence counter (single counter for all SPP frames sent)
    private var seqNum: UInt8 = 0

    // MARK: - Reconnect

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var pendingScan = false

    // MARK: - Callbacks (consumed by BandSyncer)

    /// Called once authentication succeeds with (deviceName, peripheralUUID).
    var onAuthenticated:         ((String, String) -> Void)?
    /// Called for each decoded (and decrypted) proto Command on 0051 after auth.
    /// Receives raw protobuf bytes of the Command message.
    var onProtoCommandReceived:  ((Data) -> Void)?
    /// Called for each decrypted activity data chunk (on characteristic 0053).
    var onActivityChunkReceived: ((Data) -> Void)?

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "BLE")

    // MARK: - Init

    override init() {
        super.init()
        var options: [String: Any] = [:]
        #if !targetEnvironment(simulator)
        options[CBCentralManagerOptionRestoreIdentifierKey] = "com.myband.central"
        #endif
        central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    // MARK: - Public API

    func startScan() {
        guard central.state == .poweredOn else { pendingScan = true; return }
        pendingScan = false
        discoveredDevices.removeAll()
        connectionState = .scanning
        central.scanForPeripherals(withServices: MiBandUUID.scanServices,
                                   options: BandScanner.scanOptions)
        log.info("BLE scan started (service FE95)")
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

    /// Runs the full auth sequence:
    ///   session config → nonce exchange → key derivation → CMD_AUTH → success
    func authenticate() async throws {
        guard cmdWriteChar != nil, cmdReadChar != nil else {
            throw AuthError.noCharacteristics
        }
        let secretKey = try AuthKeyStore.load()
        _ = secretKey  // validated; actual use is inside callbacks

        connectionState = .sessionConfig
        let sessionPkt = XiaomiSppPacket.buildSessionConfig(seqNum: nextSeq())
        writeSPP(sessionPkt)
        log.debug("Session config sent — waiting for band response")

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            authContinuation = c
        }
        // continuation resumed by handleAuthSuccess() or failAuth()
    }

    func disconnect() {
        guard let p = peripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    /// Sends an already-encrypted command packet (for post-auth use by BandSyncer).
    func sendEncryptedCommand(protoBytes: Data) {
        guard let keys = sessionKeys else { return }
        do {
            let encrypted = try XiaomiCrypto.aesCTR(data: protoBytes, key: keys.encryptionKey)
            let packet = XiaomiSppPacket.buildEncryptedCommand(encryptedBytes: encrypted, seqNum: nextSeq())
            writeSPP(packet)
        } catch {
            log.error("Encryption failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: SPP write

    private func writeSPP(_ packet: Data) {
        guard let char = cmdWriteChar, let p = peripheral else { return }
        p.writeValue(packet, for: char, type: .withoutResponse)
    }

    private func nextSeq() -> UInt8 {
        defer { seqNum = seqNum &+ 1 }
        return seqNum
    }

    // MARK: - Private: Incoming packet dispatch (from 0051)

    private func handleCmdReadNotification(_ raw: Data) {
        guard let pkt = XiaomiSppPacket.parse(raw) else {
            log.warning("Malformed SPP frame (\(raw.count) bytes), CRC mismatch or bad preamble")
            return
        }

        if pkt.isAck {
            log.debug("ACK received (seq \(pkt.seqNum))")
            return
        }

        if pkt.isSessionCfg {
            handleSessionConfigResponse(pkt.payload)
            return
        }

        if pkt.isData {
            handleDataPacket(pkt)
        }
    }

    private func handleSessionConfigResponse(_ payload: Data) {
        guard payload.first == 0x02 else {  // OPCODE_START_SESSION_RESPONSE = 2
            log.warning("Unexpected session config opCode: \(payload.first.map { String($0) } ?? "nil")")
            return
        }
        log.debug("Session config accepted — starting auth nonce exchange")
        connectionState = .authenticating
        startNonceExchange()
    }

    private func startNonceExchange() {
        guard let secretKey = try? AuthKeyStore.load() else {
            failAuth(AuthError.noAuthKey); return
        }
        _ = secretKey  // validated; keys used in handleWatchNonce
        let nonce = BandAuthenticator.phoneNonce()
        phoneNonce = nonce
        let pkt = BandAuthenticator.noncePacket(phoneNonce: nonce, seqNum: nextSeq())
        writeSPP(pkt)
        log.debug("CMD_NONCE sent (16-byte phone nonce)")
    }

    private func handleDataPacket(_ pkt: XiaomiParsedPacket) {
        let channel  = pkt.rawChannel
        let opCode   = pkt.opCode
        var innerData = pkt.innerData

        // Decrypt if needed
        if opCode == XiaomiOpCode.encrypted {
            guard let keys = sessionKeys else {
                log.warning("Received encrypted packet but no session keys yet")
                return
            }
            do {
                innerData = try XiaomiCrypto.aesCTR(data: innerData, key: keys.decryptionKey)
            } catch {
                log.error("Decryption failed: \(error.localizedDescription)")
                return
            }
        }

        switch channel {
        case XiaomiRawChannel.protobuf:
            handleProtoCommand(innerData)
        case XiaomiRawChannel.activity:
            // Activity data on command channel (0051) — unusual but route to same handler
            onActivityChunkReceived?(innerData)
        default:
            log.debug("Unhandled channel \(channel) on 0051")
        }
    }

    private func handleProtoCommand(_ protoBytes: Data) {
        guard let type    = XiaomiProto.uint32Field(1, from: protoBytes),
              let subtype = XiaomiProto.uint32Field(2, from: protoBytes) else {
            // Fallback during auth: route any proto packet as auth response
            if connectionState == .authenticating {
                handlePotentialWatchNonce(protoBytes)
            }
            return
        }

        switch type {
        case XiaomiAuthCmd.cmdType:
            handleAuthCommand(subtype: subtype, protoBytes: protoBytes)
        default:
            log.debug("Proto command type=\(type) subtype=\(subtype) — \(protoBytes.count) bytes")
            onProtoCommandReceived?(protoBytes)
        }
    }

    private func handleAuthCommand(subtype: UInt32, protoBytes: Data) {
        switch subtype {
        case XiaomiAuthCmd.nonce:
            handlePotentialWatchNonce(protoBytes)
        case XiaomiAuthCmd.auth:
            // CMD_AUTH response: authentication confirmed with encryption
            log.info("CMD_AUTH response received — authenticated with encryption")
            handleAuthSuccess()
        case XiaomiAuthCmd.sendUserId:
            // Plaintext auth fallback
            log.info("AUTH response with userId subtype — plaintext mode")
            handleAuthSuccess()
        default:
            log.debug("Unknown auth subtype \(subtype)")
        }
    }

    private func handlePotentialWatchNonce(_ protoBytes: Data) {
        guard connectionState == .authenticating,
              let nonce     = phoneNonce,
              let secretKey = try? AuthKeyStore.load() else { return }

        guard let resp = BandAuthenticator.parseWatchNonce(from: protoBytes) else {
            log.warning("Could not parse WatchNonce from proto (\(protoBytes.count) bytes)")
            return
        }

        // Derive session keys
        let keys = BandAuthenticator.deriveKeys(
            phoneNonce: nonce,
            watchNonce: resp.watchNonce,
            secretKey:  secretKey
        )

        // Verify band HMAC
        guard BandAuthenticator.verifyBandHMAC(
            bandHMAC:    resp.bandHMAC,
            phoneNonce:  nonce,
            watchNonce:  resp.watchNonce,
            sessionKeys: keys
        ) else {
            failAuth(AuthError.badHMAC); return
        }

        sessionKeys = keys

        // Send CMD_AUTH
        do {
            let pkt = try BandAuthenticator.authPacket(
                phoneNonce:  nonce,
                watchNonce:  resp.watchNonce,
                sessionKeys: keys,
                seqNum:      nextSeq()
            )
            writeSPP(pkt)
            log.debug("CMD_AUTH sent — awaiting band confirmation")
            // Auth success confirmed by band's CMD_AUTH response (subtype=27)
            // If band sends no explicit response, consider the handshake done here.
            // On real hardware, update this if the band sends a separate confirmation packet.
        } catch {
            failAuth(error)
        }
    }

    private func handleAuthSuccess() {
        connectionState = .connected
        connectedPeripheral = peripheral
        reconnectAttempts = 0
        log.info("Authentication successful — communication is now encrypted")
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

    // MARK: - Private: Activity data (from 0053)

    private func handleActivityNotification(_ raw: Data) {
        guard let pkt = XiaomiSppPacket.parse(raw) else {
            log.warning("Malformed activity SPP frame (\(raw.count) bytes)")
            return
        }

        guard pkt.isData else { return }

        var innerData = pkt.innerData

        if pkt.opCode == XiaomiOpCode.encrypted, let keys = sessionKeys {
            guard let decrypted = try? XiaomiCrypto.aesCTR(data: innerData, key: keys.decryptionKey) else {
                log.error("Activity chunk decryption failed")
                return
            }
            innerData = decrypted
        }

        onActivityChunkReceived?(innerData)
    }

    // MARK: - Reconnect

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

    // MARK: - Reset on disconnect

    private func resetState() {
        connectedPeripheral = nil
        cmdReadChar    = nil
        cmdWriteChar   = nil
        activityChar   = nil
        phoneNonce     = nil
        sessionKeys    = nil
        seqNum         = 0
        failAuth(AuthError.timeout)  // resume any pending continuation
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
        case .unauthorized:
            connectionState = .error("Acesso Bluetooth não autorizado.")
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
        log.info("Connected — discovering service FE95")
        connectionState = .discoveringServices
        peripheral.discoverServices([MiBandUUID.mainService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log.error("Failed to connect: \(error?.localizedDescription ?? "unknown")")
        lastError = error
        connectionState = .error(error?.localizedDescription ?? "Falha na conexão")
        scheduleReconnect(to: peripheral)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        if let error {
            log.warning("Disconnected with error: \(error.localizedDescription)")
            scheduleReconnect(to: peripheral)
        } else {
            log.info("Disconnected cleanly")
        }
        resetState()
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
        for service in peripheral.services ?? [] where service.uuid == MiBandUUID.mainService {
            peripheral.discoverCharacteristics(
                [MiBandUUID.commandRead, MiBandUUID.commandWrite, MiBandUUID.activityData],
                for: service
            )
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        if let error {
            log.error("Characteristic discovery failed: \(error.localizedDescription)")
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case MiBandUUID.commandRead:
                cmdReadChar = char
                peripheral.setNotifyValue(true, for: char)
                log.debug("0051 (cmd read) — notifications enabled")
            case MiBandUUID.commandWrite:
                cmdWriteChar = char
                log.debug("0052 (cmd write) — ready")
            case MiBandUUID.activityData:
                activityChar = char
                peripheral.setNotifyValue(true, for: char)
                log.debug("0053 (activity) — notifications enabled")
            default:
                break
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        switch characteristic.uuid {
        case MiBandUUID.commandRead:
            handleCmdReadNotification(data)
        case MiBandUUID.activityData:
            handleActivityNotification(data)
        default:
            break
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log.error("Write failed on \(characteristic.uuid): \(error.localizedDescription)")
            if connectionState == .authenticating || connectionState == .sessionConfig {
                failAuth(error)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let error {
            log.error("Notify state update failed for \(characteristic.uuid): \(error.localizedDescription)")
        }
    }
}
