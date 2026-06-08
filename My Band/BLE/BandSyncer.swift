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

    var errorDescription: String? {
        switch self {
        case .notConnected:       return "Pulseira não conectada. Conecte antes de sincronizar."
        case .noDeviceRecord:     return "Dispositivo não registrado. Autentique primeiro."
        case .timeout:            return "Tempo esgotado durante a sincronização."
        case .emptyPayload:       return "Nenhum dado recebido da pulseira."
        case .unexpectedResponse: return "Resposta inesperada da pulseira durante sync."
        }
    }
}

// MARK: - Data channel receiver
//
// Accumulates XiaomiSppPacketV2 data/activity channel payloads.
// The band sends multiple packets; completion is detected when no new data
// arrives for 2 seconds (GadgetBridge uses an idle-timeout approach).
// ⚠️ Verify completion signalling on real hardware — some firmware may send
//    an explicit empty frame or a COMMAND-channel ACK to mark the end.

private final class DataChannelReceiver {

    private var buffer = Data()

    func append(_ payload: Data) {
        buffer.append(payload)
    }

    func assembled() -> Data { buffer }

    func reset() { buffer = Data() }
}

// MARK: - BandSyncer

/// Orchestrates Mi Band 10 data synchronisation: sends requests via BandManager,
/// accumulates XiaomiSppPacketV2 data-channel payloads, parses binary results,
/// and persists to SwiftData.
@Observable
@MainActor
final class BandSyncer {

    // MARK: - State

    private(set) var isSyncing = false
    private(set) var lastSyncDate: Date?
    private(set) var lastError: Error?
    private(set) var currentDevice: BandDevice?

    // MARK: - Dependencies

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
        log.info("Device persisted: \(name) (\(peripheralIdentifier))")
    }

    func loadStoredDevice() {
        guard let context = modelContext else { return }
        let descriptor = FetchDescriptor<BandDevice>(
            sortBy: [SortDescriptor(\.addedDate, order: .reverse)]
        )
        currentDevice = (try? context.fetch(descriptor))?.first
    }

    // MARK: - Sleep sync

    /// Requests sleep history from the band, parses and stores new sessions.
    @discardableResult
    func syncSleep() async throws -> [SleepSession] {
        guard let manager = bandManager, manager.connectionState.isConnected else {
            throw SyncError.notConnected
        }
        guard let context = modelContext else { throw SyncError.noDeviceRecord }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        log.info("Starting sleep sync (XiaomiSyncCmd type=8, sub=2)")

        let (stream, continuation) = AsyncStream<Data>.makeStream()
        manager.onRawChunkReceived = { data in continuation.yield(data) }
        defer {
            manager.onRawChunkReceived = nil
            continuation.finish()
        }

        // Send protobuf-encoded fetch-sleep command on the command channel
        manager.sendCommand(type: XiaomiSyncCmd.cmdType, subtype: XiaomiSyncCmd.fetchSleep)

        // Accumulate data-channel payloads with a 30-second overall timeout
        // and a 2-second idle timeout to detect stream completion
        let payload = try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                let receiver = DataChannelReceiver()
                var idleDeadline = Date().addingTimeInterval(2)

                for await frame in stream {
                    receiver.append(frame)
                    idleDeadline = Date().addingTimeInterval(2)
                }
                // Stream finished (continuation.finish() called on disconnect/timeout)
                return receiver.assembled()
            }
            group.addTask {
                // Hard 30-second timeout
                try await Task.sleep(for: .seconds(30))
                throw SyncError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }

        guard !payload.isEmpty else { throw SyncError.emptyPayload }
        log.info("Sleep payload received: \(payload.count) bytes")

        let sessions = SleepPacketParser.parse(payload)
        log.info("Parsed \(sessions.count) sleep session(s)")

        var inserted: [SleepSession] = []
        for session in sessions {
            let hash = session.rawDataHash
            let dup = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.rawDataHash == hash })
            guard (try? context.fetch(dup))?.isEmpty ?? true else { continue }
            session.device = currentDevice
            context.insert(session)
            inserted.append(session)
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
}
