import Foundation
import SwiftData
import OSLog

// MARK: - Sync errors

enum SyncError: LocalizedError {
    case notConnected
    case noDeviceRecord
    case timeout
    case emptyPayload
    case unexpectedResponse
    case crcMismatch

    var errorDescription: String? {
        switch self {
        case .notConnected:       return "Pulseira não conectada."
        case .noDeviceRecord:     return "Dispositivo não registrado. Autentique primeiro."
        case .timeout:            return "Tempo esgotado durante sincronização."
        case .emptyPayload:       return "Nenhum dado recebido da pulseira."
        case .unexpectedResponse: return "Resposta inesperada da pulseira."
        case .crcMismatch:        return "CRC-32 inválido no arquivo de atividade."
        }
    }
}

// MARK: - Activity file receiver
//
// Reassembles chunked activity data sent by the band on characteristic 0053.
// Each chunk: [totalChunks: UInt16 LE][currentChunk: UInt16 LE][data...]
// The complete file has a CRC-32 in its last 4 bytes.

private final class ActivityFileReceiver {

    private var buffer = Data()
    private(set) var expectedTotal: Int = 0
    private(set) var receivedCount: Int = 0
    private var complete = false

    /// Completion is signalled by the LAST chunk (num == total), matching GadgetBridge
    /// XiaomiActivityFileFetcher.addChunk — more robust than counting received chunks.
    var isComplete: Bool { complete }

    func addChunk(_ payload: Data) {
        // payload (decrypted): [total: UInt16 LE][num: UInt16 LE][data...]
        guard payload.count >= 4 else { return }
        let base    = payload.startIndex
        let total   = Int(payload[base]) | (Int(payload[base + 1]) << 8)
        let current = Int(payload[base + 2]) | (Int(payload[base + 3]) << 8)

        if current == 1 {
            buffer = Data()
            expectedTotal = total
            receivedCount = 0
            complete = false
        }

        buffer.append(payload.dropFirst(4))
        receivedCount += 1
        if current == total { complete = true }
    }

    func assembled() -> Data { buffer }
    var chunkProgress: String { "\(receivedCount)/\(expectedTotal)" }

    func reset() {
        buffer = Data()
        expectedTotal = 0
        receivedCount = 0
        complete = false
    }

    // CRC-32 validation (last 4 bytes of assembled file)
    func validateCRC() -> Bool {
        let data = buffer
        guard data.count >= 4 else { return false }
        let body      = data.dropLast(4)
        let storedCRC = UInt32(data[data.count - 4]) |
                       (UInt32(data[data.count - 3]) << 8) |
                       (UInt32(data[data.count - 2]) << 16) |
                       (UInt32(data[data.count - 1]) << 24)
        return crc32(body) == storedCRC
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        let table = Self.crc32Table
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static let crc32Table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var crc = UInt32(i)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? 0xEDB88320 ^ (crc >> 1) : crc >> 1
            }
            return crc
        }
    }()
}

// MARK: - BandSyncer
//
// Health data synchronisation with Mi Band 10.
//
// Fetch flow (from GadgetBridge XiaomiHealthService):
//   1. Send health cmd type=8 subtype=1 (CMD_ACTIVITY_FETCH_TODAY)
//   2. Band responds: Command { health { activityRequestFileIds: <7-byte IDs concatenated> } }
//   3. For each 7-byte file ID, send health cmd type=8 subtype=3 (CMD_ACTIVITY_FETCH_REQUEST)
//   4. Band streams chunks to activity characteristic (0053)
//   5. Reassemble, CRC-32 validate, parse sleep/HR/steps
//   6. Send ACK: health cmd type=8 subtype=5 (CMD_ACTIVITY_FETCH_ACK) with file ID

@Observable
@MainActor
final class BandSyncer {

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastHealthSync: Date?
    private(set) var lastError: Error?
    private(set) var currentDevice: BandDevice?

    private weak var bandManager: BandManager?
    private var modelContext: ModelContext?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Sync")

    // MARK: - Setup

    func setup(manager: BandManager, context: ModelContext) {
        bandManager = manager
        modelContext = context

        manager.onAuthenticated = { [weak self] name, peripheralID in
            Task { await self?.persistDevice(name: name, peripheralIdentifier: peripheralID) }
        }
    }

    // MARK: - Device persistence

    func persistDevice(name: String, peripheralIdentifier: String) {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<BandDevice>(
            predicate: #Predicate { $0.peripheralIdentifier == peripheralIdentifier }
        )
        if let existing = try? context.fetch(descriptor), let device = existing.first {
            device.name = name
            currentDevice = device
        } else {
            let device = BandDevice(name: name, peripheralIdentifier: peripheralIdentifier)
            context.insert(device)
            currentDevice = device
        }
        try? context.save()
        log.info("Device persisted: \(name)")
    }

    func loadStoredDevice() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<BandDevice>(
            sortBy: [SortDescriptor(\.addedDate, order: .reverse)]
        )
        currentDevice = (try? context.fetch(descriptor))?.first
        lastHealthSync = currentDevice?.lastHealthSyncDate
        lastSyncDate = currentDevice?.lastSyncDate
    }

    // MARK: - Apple Health sync
    //
    // Fetches today's activity files and routes each by its file-id metadata:
    //   sleep         → SleepDetailsParser   → HealthKit sleepAnalysis (+ SwiftData)
    //   daily summary → DailySummaryParser   → HealthKit steps/calories/HR/SpO₂ (+ ActivityDay)
    //   daily details → DailyDetailsParser   → HealthKit per-minute HR/SpO₂/distance
    // Each file is ACKed so the band marks it synced.

    struct HealthSyncOutcome {
        var sleepSessions = 0
        var dailySummaries = 0
        var minuteSamples = 0
        var manualSamples = 0
        var workouts = 0
        var healthSamplesWritten = 0
    }

    @discardableResult
    func syncToHealth() async throws -> HealthSyncOutcome {
        guard let manager = bandManager, manager.connectionState.isConnected else {
            throw SyncError.notConnected
        }
        guard let context = modelContext else { throw SyncError.noDeviceRecord }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await HealthKitManager.shared.requestAuthorization()
        } catch {
            lastError = error
            throw error
        }

        log.info("Health sync started (fetching today's activity files)")
        let fileIds = try await fetchFileIds(manager: manager)
        log.info("Received \(fileIds.count) file ID(s)")

        var outcome = HealthSyncOutcome()
        var sleepToWrite: [SleepSession] = []
        var sleepVitals: [ActivityMinuteSample] = []
        var manualToWrite: [ManualSample] = []
        var workoutsToWrite: [WorkoutSummary] = []
        var workoutRoutes: [Int: [WorkoutTrackPoint]] = [:]

        for fileId in fileIds {
            guard let meta = XiaomiActivityFileMeta(fileId) else { continue }
            do {
                let fileData = try await fetchActivityFile(fileId: fileId, manager: manager)

                if meta.isManualSamples {
                    let manual = ManualSamplesParser.parse(fileData, meta: meta)
                    manualToWrite += manual
                    outcome.manualSamples += manual.count
                } else if meta.isWorkoutSummary {
                    if let workout = WorkoutSummaryParser.parse(fileData, meta: meta) {
                        workoutsToWrite.append(workout)
                    }
                } else if meta.isWorkoutGps {
                    let track = WorkoutGpsParser.parse(fileData, meta: meta)
                    if !track.isEmpty {
                        workoutRoutes[Int(meta.timestamp.timeIntervalSince1970)] = track
                    }
                } else if meta.isSleep {
                    let parsed = SleepDetailsParser.parse(fileData, meta: meta)
                    for session in parsed.sessions {
                        // Always (re)write to HealthKit — its sync-identifier dedup makes this
                        // idempotent, so data deleted from Apple Health is restored on re-sync.
                        // SwiftData insertion is still gated to avoid duplicate local records.
                        _ = persistIfNew(session, context)
                        sleepToWrite.append(session)
                    }
                    // HR/SpO₂ recorded during sleep — written within the sleep window so
                    // Apple Health's sleep "Comparisons" tab can correlate them.
                    sleepVitals += parsed.heartRates.map { ActivityMinuteSample(date: $0.date, heartRate: $0.bpm) }
                    sleepVitals += parsed.spo2.map { ActivityMinuteSample(date: $0.date, spo2: $0.pct) }
                } else if meta.isDailySummary {
                    if let summary = DailySummaryParser.parse(fileData, meta: meta) {
                        outcome.dailySummaries += 1
                        persistActivityDay(summary, context)
                        outcome.healthSamplesWritten += try await HealthKitManager.shared.writeDailySummary(summary)
                    }
                } else if meta.isDailyDetails {
                    let minutes = DailyDetailsParser.parse(fileData, meta: meta)
                    outcome.minuteSamples += minutes.count
                    outcome.healthSamplesWritten += try await HealthKitManager.shared.writeMinuteSamples(minutes)
                }

                sendAck(fileId: fileId, manager: manager)
            } catch {
                log.error("Failed file \(fileId.hexString): \(error.localizedDescription)")
            }
        }

        if !sleepToWrite.isEmpty {
            outcome.sleepSessions = sleepToWrite.count
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeSleep(sleepToWrite)
        }
        if !sleepVitals.isEmpty {
            outcome.minuteSamples += sleepVitals.count
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeMinuteSamples(sleepVitals)
        }
        if !manualToWrite.isEmpty {
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeManualSamples(manualToWrite)
        }
        if !workoutsToWrite.isEmpty {
            outcome.workouts = workoutsToWrite.count
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeWorkouts(workoutsToWrite, routes: workoutRoutes)
        }

        try? context.save()
        let now = Date()
        currentDevice?.lastHealthSyncDate = now
        currentDevice?.lastSyncDate = now
        lastHealthSync = now
        lastSyncDate = now
        try? context.save()

        log.info("Health sync done — \(outcome.healthSamplesWritten) samples written")
        return outcome
    }

    private func persistIfNew(_ session: SleepSession, _ context: ModelContext) -> Bool {
        let hash = session.rawDataHash
        let dup = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.rawDataHash == hash })
        guard (try? context.fetch(dup))?.isEmpty ?? true else { return false }
        session.device = currentDevice
        context.insert(session)
        return true
    }

    private func persistActivityDay(_ summary: DailySummary, _ context: ModelContext) {
        let day = Calendar.current.startOfDay(for: summary.date)
        let descriptor = FetchDescriptor<ActivityDay>(predicate: #Predicate { $0.date == day })
        let existing = (try? context.fetch(descriptor))?.first
        let record = existing ?? ActivityDay(date: summary.date)
        record.steps = summary.steps
        record.calories = Double(summary.caloriesKcal)
        record.device = currentDevice
        if existing == nil { context.insert(record) }
    }

    // MARK: - Sleep sync

    @discardableResult
    func syncSleep() async throws -> [SleepSession] {
        guard let manager = bandManager, manager.connectionState.isConnected else {
            throw SyncError.notConnected
        }
        guard let context = modelContext else { throw SyncError.noDeviceRecord }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        log.info("Starting sleep sync (type=8 subtype=1 → today's file IDs)")

        // 1. Request today's activity file IDs
        let fileIds = try await fetchFileIds(manager: manager)
        guard !fileIds.isEmpty else { throw SyncError.emptyPayload }
        log.info("Received \(fileIds.count) file ID(s)")

        // 2. Fetch and parse each sleep file
        var inserted: [SleepSession] = []
        for fileId in fileIds where XiaomiActivityFileId.isSleepFile(fileId) {
            log.debug("Fetching sleep file: \(fileId.hexString)")
            guard let meta = XiaomiActivityFileMeta(fileId) else { continue }

            do {
                let fileData = try await fetchActivityFile(fileId: fileId, manager: manager)
                let sessions = SleepDetailsParser.parse(fileData, meta: meta).sessions
                log.info("Parsed \(sessions.count) session(s) from file")

                for session in sessions {
                    let hash = session.rawDataHash
                    let dup  = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.rawDataHash == hash })
                    guard (try? context.fetch(dup))?.isEmpty ?? true else { continue }
                    session.device = currentDevice
                    context.insert(session)
                    inserted.append(session)
                }

                // 3. ACK the file
                sendAck(fileId: fileId, manager: manager)
            } catch {
                log.error("Failed to fetch/parse file \(fileId.hexString): \(error)")
            }
        }

        if !inserted.isEmpty {
            try context.save()
            currentDevice?.lastSyncDate = Date()
            try context.save()
        }

        lastSyncDate = Date()
        log.info("Sync complete — \(inserted.count) new session(s) saved")
        return inserted
    }

    // MARK: - Private: request file IDs
    //
    // Full sync mirrors GadgetBridge: first FETCH_TODAY (today's pending records), then
    // FETCH_PAST (the backlog of older days not yet synced). Both lists are merged so the
    // app reprocesses every record the band still holds — not just the current day.

    private func fetchFileIds(manager: BandManager) async throws -> [Data] {
        var all: [Data] = []
        var seen = Set<Data>()
        func merge(_ ids: [Data]) {
            for id in ids where !seen.contains(id) { seen.insert(id); all.append(id) }
        }

        let today = try await requestFileIds(subtype: XiaomiHealthCmd.fetchToday,
                                             proto: XiaomiProto.fetchTodayCommand(),
                                             manager: manager)
        log.info("FETCH_TODAY → \(today.count) file ID(s)")
        merge(today)

        // The backlog is best-effort: an empty response or timeout shouldn't abort the sync.
        do {
            let past = try await requestFileIds(subtype: XiaomiHealthCmd.fetchPast,
                                                proto: XiaomiProto.fetchPastCommand(),
                                                manager: manager)
            log.info("FETCH_PAST → \(past.count) file ID(s)")
            merge(past)
        } catch {
            log.warning("FETCH_PAST failed (\(error.localizedDescription)) — using today's files only")
        }

        return all
    }

    /// Sends one fetch command and waits for the matching Command response (same type+subtype),
    /// returning its file IDs. An empty list is a valid response and completes the wait.
    private func requestFileIds(subtype: UInt32, proto: Data, manager: BandManager) async throws -> [Data] {
        try await withThrowingTaskGroup(of: [Data].self) { group in
            let (stream, cont) = AsyncStream<Data>.makeStream()

            // File IDs come back as a proto Command on 0051, not as activity chunks on 0053.
            manager.onProtoCommandReceived = { data in cont.yield(data) }
            defer {
                manager.onProtoCommandReceived = nil
                cont.finish()
            }

            manager.sendEncryptedCommand(protoBytes: proto)

            group.addTask {
                for await chunk in stream {
                    if let ids = self.extractFileIds(from: chunk, subtype: subtype) { return ids }
                }
                return []
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                throw SyncError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result ?? []
        }
    }

    nonisolated private func extractFileIds(from protoBytes: Data, subtype: UInt32) -> [Data]? {
        // Expect Command { type=8, subtype=<requested>, health { activityRequestFileIds } }.
        // An empty list still matches (no pending records) and completes the wait.
        guard let cmd = XiaomiProto.parseCommand(protoBytes),
              cmd.type == XiaomiHealthCmd.cmdType,
              cmd.subtype == subtype else { return nil }
        let raw = cmd.health.activityRequestFileIds
        guard raw.count % 7 == 0 else { return nil }
        return stride(from: raw.startIndex, to: raw.endIndex, by: 7).map { Data(raw[$0 ..< $0 + 7]) }
    }

    // MARK: - Private: fetch individual activity file

    private func fetchActivityFile(fileId: Data, manager: BandManager) async throws -> Data {
        let proto = XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.fetchRequest, fileIds: fileId)

        return try await withThrowingTaskGroup(of: Data.self) { group in
            let receiver = ActivityFileReceiver()
            let (stream, cont) = AsyncStream<Data>.makeStream()

            manager.onActivityChunkReceived = { data in cont.yield(data) }
            defer {
                manager.onActivityChunkReceived = nil
                cont.finish()
            }

            manager.sendEncryptedCommand(protoBytes: proto)

            let log = self.log
            group.addTask {
                for await chunk in stream {
                    receiver.addChunk(chunk)
                    log.debug("Activity chunk \(receiver.chunkProgress) (\(chunk.count)B)")
                    if receiver.isComplete {
                        guard receiver.validateCRC() else { throw SyncError.crcMismatch }
                        return receiver.assembled()
                    }
                }
                throw SyncError.emptyPayload
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw SyncError.timeout
            }

            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Private: ACK file

    private func sendAck(fileId: Data, manager: BandManager) {
        manager.sendEncryptedCommand(protoBytes: XiaomiProto.ackCommand(fileId: fileId))
        log.debug("ACK sent for file \(fileId.hexString)")
    }
}

// MARK: - XiaomiActivityFileId helpers

enum XiaomiActivityFileId {
    // 7-byte file ID:
    //   [0..3] timestamp (UInt32 LE, unix seconds)
    //   [4]    timezone (Int8, blocks of 15 min)
    //   [5]    version (UInt8)
    //   [6]    flags: bit7=type (0=ACTIVITY), bits6:2=subtype, bits1:0=detailType

    static func isSleepFile(_ fileId: Data) -> Bool {
        guard fileId.count == 7 else { return false }
        let flags   = fileId[6]
        let type    = (flags >> 7) & 1       // 0 = ACTIVITY
        let subtype = (flags >> 2) & 0x1F    // 0x03 = ACTIVITY_SLEEP_STAGES, 0x08 = ACTIVITY_SLEEP
        return type == 0 && (subtype == 0x03 || subtype == 0x08)
    }

    static func timestamp(_ fileId: Data) -> Date? {
        guard fileId.count == 7 else { return nil }
        let ts = UInt32(fileId[0]) | (UInt32(fileId[1]) << 8) |
                 (UInt32(fileId[2]) << 16) | (UInt32(fileId[3]) << 24)
        return Date(timeIntervalSince1970: TimeInterval(ts))
    }
}
