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

    var isComplete: Bool { expectedTotal > 0 && receivedCount == expectedTotal }

    func addChunk(_ payload: Data) {
        guard payload.count >= 4 else { return }
        let total   = Int(payload[0]) | (Int(payload[1]) << 8)
        let current = Int(payload[2]) | (Int(payload[3]) << 8)

        if current == 1 {
            buffer = Data()
            expectedTotal = total
            receivedCount = 0
        }

        buffer.append(payload.dropFirst(4))
        receivedCount += 1
    }

    func assembled() -> Data { buffer }

    func reset() {
        buffer = Data()
        expectedTotal = 0
        receivedCount = 0
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

            do {
                let fileData = try await fetchActivityFile(fileId: fileId, manager: manager)
                let sessions = SleepDetailsParser.parse(fileData)
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

    private func fetchFileIds(manager: BandManager) async throws -> [Data] {
        let proto = XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.fetchToday)

        return try await withThrowingTaskGroup(of: [Data].self) { group in
            let (stream, cont) = AsyncStream<Data>.makeStream()

            // File IDs come back as a proto Command on 0051, not as activity chunks on 0053
            manager.onProtoCommandReceived = { data in cont.yield(data) }
            defer {
                manager.onProtoCommandReceived = nil
                cont.finish()
            }

            manager.sendEncryptedCommand(protoBytes: proto)

            group.addTask {
                // Wait for the response on the command channel (proto Command with fileIds)
                // The band responds with Command.health.activityRequestFileIds (field 10 → field 7)
                for await chunk in stream {
                    if let ids = self.extractFileIds(from: chunk) { return ids }
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

    nonisolated private func extractFileIds(from protoBytes: Data) -> [Data]? {
        // Expect Command { type=8, subtype=1, health { activityRequestFileIds } }
        guard let cmd = XiaomiProto.parseCommand(protoBytes),
              cmd.type == XiaomiHealthCmd.cmdType,
              cmd.hasHealth else { return nil }
        let raw = cmd.health.activityRequestFileIds
        guard !raw.isEmpty, raw.count % 7 == 0 else { return nil }
        return stride(from: 0, to: raw.count, by: 7).map { raw[$0 ..< $0 + 7] }
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

            group.addTask {
                for await chunk in stream {
                    receiver.addChunk(chunk)
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
        let proto = XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.fetchAck, fileIds: fileId)
        manager.sendEncryptedCommand(protoBytes: proto)
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
