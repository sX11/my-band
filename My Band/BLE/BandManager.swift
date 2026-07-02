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

    /// Latest battery level (0–100) reported by the band, or nil if unknown yet.
    private(set) var batteryLevel: Int?
    /// Whether the band reports it is currently charging.
    private(set) var batteryCharging: Bool = false

    // MARK: - BLE objects

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    // Reassembly buffer for the 005E byte stream (frames may span multiple notifications).
    private var rxBuffer = Data()

    // 005F — notify (band → app): ALL SPP V2 frames (commands + activity, differentiated by channel byte)
    private var cmdReadChar:  CBCharacteristic?
    // 005E — write  (app → band): SPP V2 frames
    private var cmdWriteChar: CBCharacteristic?

    // MARK: - Auth state

    private var phoneNonce:  Data?
    private var sessionKeys: XiaomiCrypto.SessionKeys?
    private var authContinuation: CheckedContinuation<Void, Error>?

    // Callers awaiting a fully-authenticated link (e.g. the background sync task). Resumed on
    // auth success, or thrown on auth failure / disconnect / timeout. Separate from
    // authContinuation, which tracks a single in-flight authenticate() call.
    private var connectWaiters: [CheckedContinuation<Void, Error>] = []

    // Per-session sequence counter (single counter for all SPP frames sent)
    private var seqNum: UInt8 = 0

    // Resumed by peripheralIsReady(toSendWriteWithoutResponse:) to pace large uploads.
    private var writeReadyContinuation: CheckedContinuation<Void, Never>?

    // MARK: - Reconnect

    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5
    private var reconnectTask: Task<Void, Never>?
    private var pendingScan = false
    // While true, an unexpected disconnect (clean OR error) re-arms a standing reconnect, so the link
    // self-heals across background range loss without any UI. Cleared only on a user-initiated
    // disconnect (forget), so we stop chasing a band the user deliberately detached.
    private var autoReconnect = false
    // Set when reconnectToKnownDevice is called before Bluetooth is powered on; consumed in
    // centralManagerDidUpdateState once .poweredOn.
    private var pendingReconnectID: UUID?

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
    /// Called when the band requests GPS for a workout (workoutOpenWatch, subtype=30). Param = sport code.
    var onWorkoutOpenWatch:      ((UInt32) -> Void)?
    /// Called when the band reports workout status (workoutStatusWatch, subtype=26).
    /// Params = status code + the workout's activity file ids (concatenated 7-byte ids; empty if
    /// the firmware didn't include them). On status=finished these name the just-recorded files.
    var onWorkoutStatusWatch:    ((UInt32, Data) -> Void)?
    /// Called when the band's "find phone" feature is toggled (System, subtype=17).
    /// Param = true to start ringing the phone, false to stop (user dismissed it on the band).
    var onFindPhone:             ((Bool) -> Void)?
    /// Called with the band-assigned id when a Schedule item (e.g. a reminder) is created
    /// (Schedule command carrying schedule.ackId). CalendarSyncService uses it to track which
    /// reminders to delete on the next sync.
    var onScheduleAck:           ((UInt32) -> Void)?
    /// Called when the band requests weather (Weather, subtype=3). Params = (locationKey, locationName);
    /// both empty means the band wants its current-location weather. The band sends this on connect and
    /// when its weather screen opens — it's the trigger WeatherSyncService responds to with a push.
    var onWeatherConditionsRequest: ((String, String) -> Void)?
    /// Called for every Watchface command (type=4) from the band — WatchfaceService handles it.
    var onWatchfaceCommand:      ((Xiaomi_Command) -> Void)?
    /// Called for every Rpk/app command (type=20) from the band — AppInstallService handles it.
    var onRpkCommand:            ((Xiaomi_Command) -> Void)?
    /// Called for every DataUpload command (type=22) from the band — DataUploadService handles it.
    var onDataUploadCommand:     ((Xiaomi_Command) -> Void)?

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

    /// Reconnect to a previously-paired peripheral by its CBPeripheral UUID, skipping the scan.
    /// `connect()` with no timeout means iOS auto-connects as soon as the band is in range —
    /// far faster and more reliable than scanning. Falls back to a scan if the system can no
    /// longer retrieve the peripheral (e.g. it was never connected on this device).
    func reconnectToKnownDevice(identifier: String) {
        guard let uuid = UUID(uuidString: identifier) else { startScan(); return }
        autoReconnect = true
        reconnectAttempts = 0
        guard central.state == .poweredOn else { pendingReconnectID = uuid; return }
        performReconnect(uuid)
    }

    private func performReconnect(_ uuid: UUID) {
        if let target = central.retrievePeripherals(withIdentifiers: [uuid]).first {
            log.info("Reconnecting directly to known peripheral \(uuid)")
            connect(to: target)
        } else {
            log.info("Known peripheral not retrievable — falling back to scan")
            startScan()
        }
    }

    func startScan() {
        guard central.state == .poweredOn else { pendingScan = true; return }
        pendingScan = false
        reconnectAttempts = 0   // fresh user-initiated scan gets a full retry budget
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
        // Fresh connection (user/bootstrap, not the auth-retry reconnect loop): give it a full
        // auth-retry budget. Otherwise a previous key's exhausted budget makes the next key give up
        // after a single first-pairing (sub=16) HMAC mismatch — a correct key then looks "incorreto".
        authRetries = 0
        autoReconnect = true
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
            // A stale continuation (e.g. characteristics rediscovered on a reconnect mid-auth) would
            // leak and hang. Resume the old one before replacing it.
            authContinuation?.resume(throwing: AuthError.timeout)
            authContinuation = c
        }
        // continuation resumed by handleAuthSuccess() or failAuth()
    }

    /// `userInitiated` (forget / explicit "disconnect") clears autoReconnect so we stop chasing the
    /// band. Background teardown (post-sync, BGTask expiry) passes `false`: the active link is
    /// released to free the radio, but autoReconnect stays on, so didDisconnectPeripheral re-arms a
    /// standing connect and iOS brings the link back (and wakes us) when the band is in range.
    func disconnect(userInitiated: Bool = true) {
        if userInitiated { autoReconnect = false }
        reconnectTask?.cancel()
        reconnectTask = nil
        guard let p = peripheral else { return }
        central.cancelPeripheralConnection(p)
    }

    /// Connects to a known peripheral (skipping the scan) and waits until the link is fully
    /// authenticated, or throws on failure/timeout. Used by the background sync task, which must
    /// drive the connection to completion before fetching. Returns immediately if already connected.
    func ensureConnected(identifier: String, timeout: Duration = .seconds(25)) async throws {
        if connectionState.isConnected { return }

        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeConnectWaiters(throwing: SyncError.timeout)
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectWaiters.append(c)
            reconnectToKnownDevice(identifier: identifier)
        }
    }

    private func resumeConnectWaiters(throwing error: Error?) {
        guard !connectWaiters.isEmpty else { return }
        let waiters = connectWaiters
        connectWaiters.removeAll()
        for c in waiters {
            if let error { c.resume(throwing: error) } else { c.resume() }
        }
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

    /// Sends one raw file-upload chunk on the DATA channel (plaintext), pacing against
    /// CoreBluetooth's write-without-response buffer so a large face/app upload doesn't overflow
    /// it and silently drop frames. Awaits peripheralIsReady when the buffer is full.
    func sendDataChunk(_ chunk: Data) async {
        if let p = peripheral, let char = cmdWriteChar,
           char.properties.contains(.writeWithoutResponse), !p.canSendWriteWithoutResponse {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                writeReadyContinuation = cont
            }
        }
        writeSPP(XiaomiSppPacket.buildDataChunk(chunk, seqNum: nextSeq()))
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

        // A single SPP frame can exceed the ATT MTU (e.g. a calendar-sync frame with many events).
        // CoreBluetooth does not fragment a single writeValue beyond the MTU, so split the frame
        // into MTU-sized GATT writes; the band reassembles the byte stream by the frame's declared
        // length (mirrors GadgetBridge's chunked outgoing write). For the small auth/init packets
        // this is a single chunk, so the existing handshake path is unchanged.
        let mtu = max(20, p.maximumWriteValueLength(for: writeType))
        if packet.count <= mtu {
            // Full hex only for small frames (handshake/commands). Upload chunks are large and
            // frequent — building the hex string for every one is wasteful, so log just the length.
            if packet.count <= 64 {
                log.debug("005F write (\(packet.count)B, \(writeType == .withoutResponse ? "noRsp" : "rsp")): \(packet.map { String(format: "%02x", $0) }.joined(separator: " "))")
            } else {
                log.debug("005F write (\(packet.count)B, \(writeType == .withoutResponse ? "noRsp" : "rsp"))")
            }
            p.writeValue(packet, for: char, type: writeType)
            return
        }
        log.debug("005F write (\(packet.count)B in \(mtu)B chunks, \(writeType == .withoutResponse ? "noRsp" : "rsp"))")
        var offset = packet.startIndex
        while offset < packet.endIndex {
            let end = packet.index(offset, offsetBy: mtu, limitedBy: packet.endIndex) ?? packet.endIndex
            p.writeValue(packet.subdata(in: offset..<end), for: char, type: writeType)
            offset = end
        }
    }

    private func nextSeq() -> UInt8 {
        defer { seqNum = seqNum &+ 1 }
        return seqNum
    }

    // MARK: - Private: Incoming byte-stream reassembly (from 005E)
    //
    // 005E is a continuous byte stream, NOT one-frame-per-notification. A single SPP V2 frame
    // can exceed the ATT MTU and arrive split across several notifications (e.g. a 912-byte
    // activity-file frame as 495 + 417). We accumulate bytes and extract complete frames by
    // their declared payload length (GadgetBridge XiaomiSppProtocolV2.processPacket).

    private func handleCmdReadNotification(_ raw: Data) {
        rxBuffer.append(raw)
        drainFrames()
    }

    private func drainFrames() {
        while true {
            // Need at least the 8-byte header to know the frame length.
            guard rxBuffer.count >= XiaomiSppPacket.headerSize else { return }

            // Resync to the 0xA5 0xA5 preamble if we're misaligned.
            let base = rxBuffer.startIndex
            if !(rxBuffer[base] == 0xA5 && rxBuffer[base + 1] == 0xA5) {
                if let next = nextPreambleOffset(in: rxBuffer) {
                    log.warning("Resyncing RX stream — dropped \(next) byte(s) before preamble")
                    rxBuffer = Data(rxBuffer.dropFirst(next))
                    continue
                }
                // No preamble found; keep only a trailing byte in case it's a split 0xA5.
                rxBuffer = Data(rxBuffer.suffix(1))
                return
            }

            let payloadLen = Int(rxBuffer[base + 4]) | (Int(rxBuffer[base + 5]) << 8)
            let frameLen = XiaomiSppPacket.headerSize + payloadLen
            guard rxBuffer.count >= frameLen else { return }   // wait for the rest of the frame

            let frame = Data(rxBuffer.prefix(frameLen))
            rxBuffer = Data(rxBuffer.dropFirst(frameLen))
            handleFrame(frame)
        }
    }

    /// Index of the next 0xA5 0xA5 preamble at or after offset 1, or nil if none.
    /// Indexes the Data directly (no Array copy) — this runs on every misaligned RX byte.
    private func nextPreambleOffset(in data: Data) -> Int? {
        guard data.count >= 2 else { return nil }
        let base = data.startIndex
        var i = 1
        while i < data.count - 1 {
            if data[base + i] == 0xA5 && data[base + i + 1] == 0xA5 { return i }
            i += 1
        }
        return nil
    }

    private func handleFrame(_ raw: Data) {
        guard let pkt = XiaomiSppPacket.parse(raw) else {
            log.warning("Malformed SPP frame (\(raw.count) bytes), CRC mismatch — raw: \(raw.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))…")
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
        case XiaomiSystemCmd.cmdType:
            handleSystemCommand(cmd)
            onProtoCommandReceived?(protoBytes)
        case XiaomiHealthCmd.cmdType:
            handleHealthCommand(subtype: cmd.subtype, cmd: cmd, protoBytes: protoBytes)
        case XiaomiWeatherCmd.cmdType:
            handleWeatherCommand(cmd)
        case XiaomiWatchfaceCmd.cmdType:
            onWatchfaceCommand?(cmd)
        case XiaomiRpkCmd.cmdType:
            onRpkCommand?(cmd)
        case XiaomiDataUploadCmd.cmdType:
            onDataUploadCommand?(cmd)
        case XiaomiScheduleCmd.cmdType where cmd.hasSchedule && cmd.schedule.hasAckID:
            log.debug("Schedule ack id=\(cmd.schedule.ackID)")
            onScheduleAck?(cmd.schedule.ackID)
        default:
            log.debug("Proto command type=\(cmd.type) subtype=\(cmd.subtype) — \(protoBytes.count) bytes")
            onProtoCommandReceived?(protoBytes)
        }
    }

    /// Captures battery info from a System command response (CMD_BATTERY / device state).
    /// GadgetBridge: cmd.system.power.battery → level + charger state.
    private func handleSystemCommand(_ cmd: Xiaomi_Command) {
        // Find-phone (CMD_FIND_PHONE): the band pushes this to make the phone ring. The findDevice
        // value is 0 to start the alert, non-zero (1) when the user dismisses it on the band
        // (GadgetBridge XiaomiSystemService: mode == 0 ? START : STOP).
        if cmd.subtype == XiaomiSystemCmd.findPhone, cmd.hasSystem, cmd.system.hasFindDevice {
            let shouldStart = cmd.system.findDevice == 0
            log.info("Find phone \(shouldStart ? "START" : "STOP") requested by band")
            onFindPhone?(shouldStart)
            return
        }
        guard cmd.hasSystem, cmd.system.hasPower, cmd.system.power.hasBattery else { return }
        let battery = cmd.system.power.battery
        if battery.hasLevel {
            batteryLevel = Int(battery.level)
            // state: 1 = charging (GadgetBridge convertBatteryStateFromRawValue)
            batteryCharging = battery.hasState && battery.state == 1
            log.info("Battery \(self.batteryLevel ?? -1)%\(self.batteryCharging ? " (charging)" : "")")
        }
    }

    /// Weather is request-driven: the band asks the app to push conditions (subtype=3), and the app's
    /// own pushes (add-location / current / forecast) come back as status responses on the same type.
    private func handleWeatherCommand(_ cmd: Xiaomi_Command) {
        switch cmd.subtype {
        case XiaomiWeatherCmd.requestConditions:
            let loc  = (cmd.hasWeather && cmd.weather.hasLocation) ? cmd.weather.location : nil
            let key  = loc?.code ?? ""
            let name = loc?.name ?? ""
            log.info("Weather requested by band (location: \(key.isEmpty ? "current" : key))")
            onWeatherConditionsRequest?(key, name)
        default:
            // Status reply to one of our pushes. status≠0 means the band rejected it (e.g. 1 =
            // unsupported, 3 = location already added) — logged so a failed push is visible.
            if cmd.hasStatus, cmd.status != 0 {
                log.warning("Weather cmd subtype=\(cmd.subtype) rejected (status \(cmd.status))")
            } else {
                log.debug("Weather cmd subtype=\(cmd.subtype) acknowledged")
            }
        }
    }

    private func handleHealthCommand(subtype: UInt32, cmd: Xiaomi_Command, protoBytes: Data) {
        switch subtype {
        case XiaomiHealthCmd.workoutOpen where cmd.hasHealth && cmd.health.hasWorkoutOpenWatch:
            let sport = cmd.health.workoutOpenWatch.sport
            log.info("Workout GPS request (sport=\(sport)) — forwarding to WorkoutGpsService")
            onWorkoutOpenWatch?(sport)
        case XiaomiHealthCmd.workoutStatus where cmd.hasHealth && cmd.health.hasWorkoutStatusWatch:
            let watch = cmd.health.workoutStatusWatch
            let fileIds = watch.hasActivityFileIds ? watch.activityFileIds : Data()
            log.info("Workout status update: \(watch.status) (\(fileIds.count / 7) file id(s))")
            onWorkoutStatusWatch?(watch.status, fileIds)
        default:
            // All other health subtypes (activity fetch responses etc.) go to BandSyncer.
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

        #if DEBUG
        // Irreversible fingerprint (not the key) to compare an extracted beaconkey against a
        // known-working AuthKey when diagnosing HMAC mismatches. Remove once auth is settled.
        log.debug("AuthKey fingerprint sha256[0..12]=\(XiaomiCloudCrypto.sha256(secretKey).hexString.prefix(12)) len=\(secretKey.count)")
        #endif

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
        resumeConnectWaiters(throwing: nil)
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
        resumeConnectWaiters(throwing: error)
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

    /// Arms a no-timeout standing connect to the known peripheral. iOS holds the request pending and
    /// reconnects — relaunching the app via state restoration if it was suspended — whenever the band
    /// returns to range, with NO attempt cap. This is what keeps communication alive across
    /// background range loss: a clean drop, an error drop, the first-pairing auth retry, and an
    /// exhausted connect backoff all funnel here. Cheap: a pending connect is low power; iOS only
    /// wakes us on the actual connect event, not while it waits.
    private func armStandingReconnect() {
        reconnectTask?.cancel(); reconnectTask = nil
        reconnectAttempts = 0
        guard autoReconnect, let p = peripheral else { connectionState = .disconnected; return }
        connectionState = .connecting
        central.connect(p, options: BandScanner.reconnectOptions)
        log.info("Standing reconnect armed for \(p.identifier)")
    }

    /// Short exponential backoff for an active connect *failure* (didFailToConnect), so a transient
    /// error doesn't hammer the radio. Once the budget is spent it falls back to a standing connect,
    /// which never gives up — the app no longer permanently stops trying after a burst of failures.
    private func scheduleReconnect(to target: CBPeripheral) {
        guard autoReconnect else { connectionState = .disconnected; return }
        guard reconnectAttempts < maxReconnectAttempts else {
            log.info("Connect backoff spent — falling back to a standing connect")
            armStandingReconnect()
            return
        }
        let delay = pow(2.0, Double(reconnectAttempts))
        reconnectAttempts += 1
        log.info("Reconnecting in \(delay)s (attempt \(self.reconnectAttempts)/\(self.maxReconnectAttempts))")
        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
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
        rxBuffer     = Data()
        // Only resume the continuation if one is actually waiting — avoids a spurious
        // "Break on All Swift Errors" exception breakpoint hit in Xcode during BLE bonding
        // disconnects, when no continuation is pending.
        if authContinuation != nil {
            failAuth(AuthError.timeout)
        } else {
            connectionState = .disconnected
            // Fail any background-sync waiter so it doesn't hang until its own timeout.
            resumeConnectWaiters(throwing: SyncError.notConnected)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BandManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.info("Bluetooth powered on")
            if let id = pendingReconnectID { pendingReconnectID = nil; performReconnect(id); return }
            if pendingScan { startScan(); return }
            // Bluetooth came back (e.g. toggled off/on, or powered on at launch with a known device):
            // resume chasing the band whenever we want it and aren't already on it.
            if autoReconnect, !connectionState.isConnected, let p = peripheral { connect(to: p) }
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
        // The auth-retry disconnect (first pairing) just wants a fresh connect, which autoReconnect
        // now provides — so the flag no longer gates reconnection, it's only consumed here.
        retryAuthOnDisconnect = false
        if let error {
            log.warning("Disconnected with error: \(error.localizedDescription)")
        } else {
            log.info("Disconnected cleanly")
        }
        resetState()
        // Re-arm on ANY non-user disconnect — clean drops included. The previous code reconnected
        // only on an error, so a clean background drop (app suspended, range loss) stayed dead until
        // the user reopened the app and retried by hand. autoReconnect is cleared only by a
        // user-initiated disconnect (forget), so that path still settles to .disconnected.
        if autoReconnect {
            armStandingReconnect()
        } else {
            connectionState = .disconnected
        }
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

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        writeReadyContinuation?.resume()
        writeReadyContinuation = nil
    }

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
