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

    // 005F — notify (band → app): ALL SPP V2 frames (commands + activity, differentiated by channel byte)
    private var cmdReadChar:  CBCharacteristic?
    // 005E — write  (app → band): SPP V2 frames
    private var cmdWriteChar: CBCharacteristic?

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

    // First-time pairing: the band's first watch-nonce HMAC reliably fails; only a fresh
    // reconnect yields a valid handshake. When the HMAC check fails we tear the link down and
    // reconnect (bounded) rather than dying in .error. Reset to 0 once auth succeeds.
    private var authRetries = 0
    private let maxAuthRetries = 4
    private var retryAuthOnDisconnect = false

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
        // Session config always uses seqNum=0 (GadgetBridge: setSequenceNumber(0)).
        // The DATA packet counter is NOT touched here — CMD_NONCE will get seqNum=0 too.
        seqNum = 0
        let sessionPkt = XiaomiSppPacket.buildSessionConfig()
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
        // Skip writes on a peripheral that's mid-teardown (e.g. an ACK queued right after an
        // auth-retry disconnect) — otherwise CoreBluetooth logs "API MISUSE: can only accept
        // commands while in the connected state".
        guard p.state == .connected else { return }
        // Use withResponse if the characteristic supports it, otherwise withoutResponse.
        // 005E on Mi Band 10 V2 supports write without response (confirmed in GadgetBridge).
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        log.debug("005F write (\(packet.count)B, \(writeType == .withoutResponse ? "noRsp" : "rsp")): \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
        p.writeValue(packet, for: char, type: writeType)
    }

    private func nextSeq() -> UInt8 {
        defer { seqNum = seqNum &+ 1 }
        return seqNum
    }

    // MARK: - Private: Incoming packet dispatch (from 0051)

    private func handleCmdReadNotification(_ raw: Data) {
        log.debug("005E raw (\(raw.count)B): \(raw.map { String(format: "%02x", $0) }.joined(separator: " "))")
        guard let pkt = XiaomiSppPacket.parse(raw) else {
            log.warning("Malformed SPP frame (\(raw.count) bytes), CRC mismatch or bad preamble — raw: \(raw.map { String(format: "%02x", $0) }.joined(separator: " "))")
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
            // SPP V2 is a reliable windowed transport: every DATA frame must be ACKed with its own
            // sequence number (GadgetBridge XiaomiSppProtocolV2.processPacket). Without this the band
            // assumes its frames were lost and retransmits the whole auth handshake every ~6 s.
            sendAck(seqNum: pkt.seqNum)
        }
    }

    /// ACKs a received DATA frame. Uses the *received* packet's sequence number and does NOT
    /// touch our outgoing counter (matches GadgetBridge's separate ack path).
    private func sendAck(seqNum: UInt8) {
        writeSPP(XiaomiSppPacket.buildAck(seqNum: seqNum))
        log.debug("ACK sent for seq \(seqNum)")
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
        guard let cmd = XiaomiProto.parseCommand(protoBytes), cmd.hasType, cmd.hasSubtype else {
            // Fallback during auth: route any proto packet as auth response
            if connectionState == .authenticating {
                handlePotentialWatchNonce(protoBytes)
            }
            return
        }

        switch cmd.type {
        case XiaomiAuthCmd.cmdType:
            handleAuthCommand(subtype: cmd.subtype, protoBytes: protoBytes)
        default:
            log.debug("Proto command type=\(cmd.type) subtype=\(cmd.subtype) — \(protoBytes.count) bytes")
            onProtoCommandReceived?(protoBytes)
        }
    }

    private func handleAuthCommand(subtype: UInt32, protoBytes: Data) {
        log.debug("AUTH cmd subtype=\(subtype) (\(protoBytes.count)B): \(protoBytes.hex)")
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
        case 16:
            // Band sends subtype=16 during first-time pairing. We don't yet know whether it carries
            // a usable watch nonce — try to parse one; if it does, the normal path handles it,
            // otherwise we just wait for sub=26. The hex dump above lets us confirm its contents.
            if let resp = BandAuthenticator.parseWatchNonce(from: protoBytes) {
                log.info("sub=16 carries a watch nonce (nonce=\(resp.watchNonce.hex.prefix(8))…) — processing as auth")
                handlePotentialWatchNonce(protoBytes)
            } else {
                log.info("Band pairing packet (sub=16, no watch nonce) — waiting for sub=26")
            }
        default:
            log.debug("Unknown auth subtype \(subtype) — \(protoBytes.count) bytes")
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
            let expected = XiaomiCrypto.hmacSHA256(message: resp.watchNonce + nonce, key: keys.decryptionKey)
            log.warning("Watch HMAC mismatch — phoneNonce=\(nonce.hex) watchNonce=\(resp.watchNonce.hex)")
            log.warning("  band HMAC=\(resp.bandHMAC.hex)")
            log.warning("  ours HMAC=\(expected.hex)")
            retryAuthAfterReconnect(reason: "watch HMAC mismatch (first-pairing transient)")
            return
        }
        log.info("Watch HMAC verified — deriving session, sending CMD_AUTH")

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
        // The band re-sends its CMD_AUTH confirmation every ~6 s until it receives the post-auth
        // init handshake. If we're already connected, just re-send the init — answering the band's
        // repeat request is what finally lets it settle.
        guard connectionState != .connected else {
            log.debug("Duplicate auth response — re-sending post-auth init")
            sendPostAuthInit()
            return
        }
        connectionState = .connected
        connectedPeripheral = peripheral
        reconnectAttempts = 0
        authRetries = 0
        log.info("Authentication successful — communication is now encrypted")
        authContinuation?.resume()
        authContinuation = nil
        if let p = peripheral {
            onAuthenticated?(p.name ?? "Mi Band 10", p.identifier.uuidString)
        }
        sendPostAuthInit()
    }

    /// Post-auth handshake. Mirrors GadgetBridge XiaomiSupport.onAuthSuccess():
    /// setCurrentTime() followed by SystemService.initialize() (device info / state / battery).
    /// Sending only setCurrentTime is NOT enough — the band keeps re-driving auth every ~6 s
    /// until it receives the device-info request that completes initialization.
    private func sendPostAuthInit() {
        sendEncryptedCommand(protoBytes: XiaomiProto.setCurrentTimeCommand())
        sendEncryptedCommand(protoBytes: XiaomiProto.systemCommand(subtype: XiaomiSystemCmd.deviceInfo))
        sendEncryptedCommand(protoBytes: XiaomiProto.systemCommand(subtype: XiaomiSystemCmd.deviceStateGet))
        sendEncryptedCommand(protoBytes: XiaomiProto.systemCommand(subtype: XiaomiSystemCmd.battery))
        log.debug("Post-auth init sent (time + device info/state/battery)")
    }

    private func failAuth(_ error: Error) {
        log.error("Auth failed: \(error.localizedDescription)")
        lastError = error
        connectionState = .error(error.localizedDescription)
        authContinuation?.resume(throwing: error)
        authContinuation = nil
    }

    /// Tear down the link and reconnect to retry authentication. Used for the first-pairing
    /// HMAC transient: the band only emits a verifiable watch nonce on a fresh connection.
    private func retryAuthAfterReconnect(reason: String) {
        guard authRetries < maxAuthRetries, let p = peripheral else {
            log.error("Auth retry budget exhausted (\(self.authRetries)/\(self.maxAuthRetries)) — giving up")
            failAuth(AuthError.badHMAC)
            return
        }
        authRetries += 1
        log.warning("Retrying auth via reconnect (\(self.authRetries)/\(self.maxAuthRetries)): \(reason)")
        retryAuthOnDisconnect = true
        central.cancelPeripheralConnection(p)
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
        cmdReadChar  = nil
        cmdWriteChar = nil
        phoneNonce   = nil
        sessionKeys  = nil
        seqNum       = 0
        // Only resume the continuation if one is actually waiting — avoids a spurious
        // "Break on All Swift Errors" exception breakpoint hit in Xcode during BLE bonding
        // disconnects, when no continuation is pending.
        if authContinuation != nil {
            failAuth(AuthError.timeout)
        } else {
            connectionState = .disconnected
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

        // Auto-connect to:
        //   a) the first band found when no peripheral is known yet, OR
        //   b) a rediscovery of our already-known peripheral (e.g. after willRestoreState set
        //      self.peripheral but pendingScan consumed the poweredOn event before connect() ran).
        let knownId = self.peripheral?.identifier
        if knownId == nil || knownId == peripheral.identifier {
            connect(to: peripheral)
        }
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
        // A deliberate auth-retry disconnect is "clean" (no error), so check the flag explicitly.
        let shouldReconnect = retryAuthOnDisconnect || (error != nil)
        retryAuthOnDisconnect = false
        if let error {
            log.warning("Disconnected with error: \(error.localizedDescription)")
        } else {
            log.info("Disconnected cleanly")
        }
        resetState()
        connectionState = .disconnected
        if shouldReconnect { scheduleReconnect(to: peripheral) }
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
                [MiBandUUID.commandRead, MiBandUUID.commandWrite],
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
                log.debug("005E (RX, band→app) — notify subscribed")
            case MiBandUUID.commandWrite:
                cmdWriteChar = char
                // Also subscribe to 005F notifications: both chars have Notify capability on Mi Band 10.
                // GadgetBridge only subscribes to 005E, but subscribing to both catches any responses
                // that arrive on the TX characteristic (diagnostic).
                peripheral.setNotifyValue(true, for: char)
                log.debug("005F (TX, app→band) — write ready + notify subscribed")
            default:
                break
            }
        }

        guard cmdReadChar != nil && cmdWriteChar != nil else {
            log.error("Required characteristics 005E/005F not found in service FE95")
            return
        }

        // GadgetBridge calls startEncryptedHandshake() immediately after initializeDevice().
        // Mirror that: trigger auth as soon as both characteristics are ready.
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.authenticate()
            } catch {
                self.log.error("Authentication failed: \(error.localizedDescription)")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard error == nil, let data = characteristic.value else { return }
        // All SPP responses arrive on 005E (commandRead) per GadgetBridge.
        // Also handle 005F notifications in case Mi Band 10 uses the TX char bidirectionally.
        if characteristic.uuid == MiBandUUID.commandRead {
            handleCmdReadNotification(data)
        } else if characteristic.uuid == MiBandUUID.commandWrite {
            log.debug("005F notify (\(data.count)B): \(data.map { String(format: "%02x", $0) }.joined(separator: " "))")
            handleCmdReadNotification(data)
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

// MARK: - Debug helpers

private extension Data {
    /// Lowercase hex string, for diagnostic logging of nonces/HMACs/packets (never the AuthKey).
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
