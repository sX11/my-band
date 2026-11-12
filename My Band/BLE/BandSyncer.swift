import Foundation
import SwiftData
import OSLog
import HealthKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Sync errors

enum SyncError: LocalizedError {
    case notConnected
    case noDeviceRecord
    case timeout
    case emptyPayload
    case unexpectedResponse
    case crcMismatch
    case fileIdMismatch
    case sessionRestarted

    var errorDescription: String? {
        switch self {
        case .notConnected:       return "Band not connected."
        case .noDeviceRecord:     return "Device not registered. Authenticate first."
        case .timeout:            return "Sync timed out."
        case .emptyPayload:       return "No data received from the band."
        case .unexpectedResponse: return "Unexpected response from the band."
        case .crcMismatch:        return "Invalid CRC-32 in activity file."
        case .fileIdMismatch:     return "Received file doesn't match the one requested."
        case .sessionRestarted:   return "The band restarted the session mid-sync."
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
    private var started = false
    /// Last time the band sent anything for this fetch — drives the idle timeout.
    private(set) var lastActivity = ContinuousClock.now

    /// Completion is signalled by the LAST chunk (num == total), matching GadgetBridge
    /// XiaomiActivityFileFetcher.addChunk — more robust than counting received chunks.
    var isComplete: Bool { complete }

    func addChunk(_ payload: Data) {
        lastActivity = ContinuousClock.now
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
            started = true
        }

        // Ignore tail chunks of a previous file's transfer that arrive before this file's first
        // chunk — appending them mid-stream would corrupt the buffer and shift every record.
        guard started else { return }

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
        started = false
    }

    // CRC-32 validation (last 4 bytes of assembled file). Shares the canonical implementation in
    // Checksums (same poly/init/xorout) — no separate copy here.
    func validateCRC() -> Bool {
        let data = buffer
        guard data.count >= 4 else { return false }
        let body      = data.dropLast(4)
        let storedCRC = UInt32(data[data.count - 4]) |
                       (UInt32(data[data.count - 3]) << 8) |
                       (UInt32(data[data.count - 2]) << 16) |
                       (UInt32(data[data.count - 1]) << 24)
        return Checksums.crc32(Data(body)) == storedCRC
    }
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
    /// A sync with the phone locked left files on the band for an unlocked one to rewrite. Lifts the
    /// background-wake throttle and triggers a sync on unlock (BackgroundSyncManager).
    private(set) var filesAwaitingUnlock = false
    var unlockedSyncDue: Bool { filesAwaitingUnlock && Self.healthReadable }
    private(set) var lastError: Error?
    private(set) var currentDevice: BandDevice?
    var latestMetrics: LatestMetricsStore?
    var syncLog: HealthSyncLog?
    var workoutLive: WorkoutLiveService?
    var reminders: ReminderService?
    var workoutWindows = WorkoutWindows()

    private weak var bandManager: BandManager?
    private var modelContext: ModelContext?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Sync")
    private let workoutGps   = WorkoutGpsService()
    private let findPhone    = FindPhoneService()
    private let calendarSync = CalendarSyncService()
    private let weatherSync  = WeatherSyncService()
    private var recoveryPairing = RecoveryPairing<HKWorkout>()

    /// Live only while a command/response exchange is pending; BandManager.onSessionRestart yields
    /// into it so the exchange fails fast instead of waiting out its timeout.
    private var sessionRestartSignal: AsyncStream<Void>.Continuation?
    /// Re-sends allowed per exchange. The band restarts once after the post-auth init; the manager
    /// itself gives up and drops the link past its own limit of 3.
    private static let maxRestartRetries = 3
    /// A file fetch fails after this long without a chunk — not after a fixed total, which a large
    /// file (a night of sleep, with its HR/SpO₂ sections) can legitimately need.
    private static let fileIdleTimeout: Duration = .seconds(10)

    // MARK: - Setup

    func setup(manager: BandManager, context: ModelContext) {
        bandManager = manager
        modelContext = context

        manager.onAuthenticated = { [weak self] name, peripheralID in
            Task { @MainActor in
                guard let self else { return }
                self.persistDevice(name: name, peripheralIdentifier: peripheralID)
                // A background (state-restoration) wake authenticates but has nothing driving a
                // sync; kick one if data is stale. No-op in the foreground.
                BackgroundSyncManager.shared.syncOnBackgroundWakeIfStale()
            }
        }

        manager.onSessionRestart = { [weak self] in self?.sessionRestartSignal?.yield() }

        workoutGps.setup(manager: manager)
        findPhone.setup(manager: manager)
        calendarSync.setup(manager: manager)
        calendarSync.reminders = reminders
        weatherSync.setup(manager: manager)

        workoutGps.onWorkoutFinished = { [weak self] fileIds in
            Task { @MainActor in await self?.handleWorkoutFinished(fileIds) }
        }
        workoutGps.onLocationStreamed = { [weak self] loc in
            self?.workoutLive?.ingest(fix: loc)
        }
        workoutGps.onRecoveryHRRecorded = { [weak self] strengthStart, samples in
            // Taken here, synchronously: the capture stops location updates, the app's keep-alive,
            // right after this returns.
            guard let self, !samples.isEmpty else { return }
            let bg = self.beginBackgroundAssertion(name: "recovery-hr")
            Task { @MainActor in
                defer { self.endBackgroundAssertion(bg) }
                await self.handleRecoveryHR(strengthStart: strengthStart, samples)
            }
        }
    }

    func forgetBand() {
        workoutGps.forgetBand()
        recoveryPairing.reset()
    }

    // MARK: - Post-strength recovery heart rate
    //
    // Saved as soon as the capture ends, linked to its workout if one is already written; otherwise
    // the samples are held and linked when the workout is (processActivityFiles). The capture ends
    // with location updates stopped, which kept the app alive until then, hence the assertion.

    private func handleRecoveryHR(strengthStart: Date?, _ samples: [WorkoutHRSample]) async {
        let workout = strengthStart.flatMap {
            recoveryPairing.recoveryRecorded(strengthStart: Int($0.timeIntervalSince1970), samples)
        }
        _ = await saveRecoveryHR(samples, to: workout, tallied: false)
    }

    /// Best-effort, like the cardio-recovery write: never fails a sync or holds an ACK.
    private func saveRecoveryHR(_ samples: [WorkoutHRSample], to workout: HKWorkout?, tallied: Bool) async -> Int {
        do {
            let written = try await HealthKitManager.shared.writeRecoveryHR(samples, toWorkout: workout, tallied: tallied)
            log.info("Recovery HR: \(written, privacy: .public) sample(s) written (linked to workout: \(workout != nil, privacy: .public))")
            return written
        } catch {
            log.error("Recovery HR write failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    // MARK: - Post-workout sync
    //
    // The band needs a moment to flush the activity file before its id shows up, so wait first; skip
    // if a sync is already running. Fired from a background BLE callback, iOS would suspend the app
    // within seconds, so the wait + sync run inside a background task assertion (≈30 s).

    private func handleWorkoutFinished(_ fileIds: Data) async {
        guard !isSyncing else { return }
        let bg = beginBackgroundAssertion(name: "post-workout-sync")
        defer { endBackgroundAssertion(bg) }
        try? await Task.sleep(for: .seconds(8))
        guard bandManager?.connectionState.isConnected == true else { return }
        do {
            // The band hands us the just-recorded file ids in workoutStatusWatch, so fetch exactly
            // those — skipping the FETCH_TODAY/PAST listing. Older firmware that omits the ids falls
            // back to a full sync. (Daily totals, which a workout also bumps, are left for the next
            // regular/background sync.)
            let ids = Self.splitFileIds(fileIds)
            if ids.isEmpty {
                log.info("Workout finished (no file ids) — running full Apple Health sync")
                try await syncToHealth()
            } else {
                log.info("Workout finished — fetching \(ids.count) named workout file(s)")
                try await syncWorkoutFiles(ids)
            }
        } catch {
            log.error("Post-workout sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Background task assertion

    #if canImport(UIKit)
    private func beginBackgroundAssertion(name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name)
    }
    private func endBackgroundAssertion(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
    #else
    private func beginBackgroundAssertion(name: String) -> Int { 0 }
    private func endBackgroundAssertion(_ id: Int) {}
    #endif

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
    //   daily summary → DailySummaryParser   → HealthKit HR/SpO₂ extremes (+ ActivityDay)
    //   daily details → DailyDetailsParser   → HealthKit per-minute HR/SpO₂ (raw) +
    //                                           steps/distance/energy (raw)
    // Each file is ACKed so the band marks it synced.

    struct HealthSyncOutcome {
        var sleepSessions = 0
        var dailySummaries = 0
        var minuteSamples = 0
        var manualSamples = 0
        var workouts = 0
        var healthSamplesWritten = 0
        var deferredForLock = false
        /// The band was stuck on a sleep file that couldn't be written, so later files went unfetched.
        var fetchStopped = false
    }

    @discardableResult
    func syncToHealth() async throws -> HealthSyncOutcome {
        // Re-entrancy guard. The guard + flag set run synchronously before the first await, so the
        // @MainActor serialises overlapping triggers (manual button, BGTask, background-wake) into
        // a single run — the rest see the flag and bail.
        guard !isSyncing else { return HealthSyncOutcome() }
        // Mid-handshake counts: the band re-deriving keys under a live link is routine, and every
        // exchange waits for it to settle (surviveSessionRestart).
        guard let manager = bandManager,
              manager.connectionState.isConnected || manager.connectionState.isAuthInProgress else {
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

        await repairSleepHistoryOnce(context: context)

        log.info("Health sync started (fetching today's activity files)")
        let fileIds = try await fetchFileIds(manager: manager)
        log.info("Received \(fileIds.count) file ID(s)")

        let outcome = try await reportingFailure {
            try await processActivityFiles(fileIds, manager: manager, context: context)
        }
        filesAwaitingUnlock = outcome.deferredForLock
        // Left unmarked so the background-wake throttle doesn't hold off the retry for 15 min.
        if outcome.fetchStopped { try? context.save() } else { markSynced(context) }

        log.info("Health sync done — \(outcome.healthSamplesWritten) samples written")

        // Push phone-side config (language, calendar, reminders) as part of the same sync, while
        // the link is up. Best-effort: a failure here must not fail the health sync.
        if manager.connectionState.isConnected {
            await calendarSync.pushAll()
        }
        if manager.connectionState.isConnected {
            await weatherSync.pushWeather()
        }

        // Last, so FETCH_TODAY isn't held behind a rewrite of every stored night.
        dropExpiredRawDataDaily(context: context)
        await reparseStoredSleepIfParserChanged(context: context)
        await rewriteStoredHRVIfNeeded(context: context)

        return outcome
    }

    // MARK: - Targeted post-workout sync
    //
    // Pulls exactly the activity files the band named in workoutStatusWatch (the summary + GPS
    // track of the session just finished) into Apple Health, skipping the FETCH_TODAY/FETCH_PAST
    // listing. Daily totals — which a workout also bumps — are left for the next regular sync.

    @discardableResult
    func syncWorkoutFiles(_ fileIds: [Data]) async throws -> HealthSyncOutcome {
        guard !isSyncing else { return HealthSyncOutcome() }
        // Mid-handshake counts: the band re-deriving keys under a live link is routine, and every
        // exchange waits for it to settle (surviveSessionRestart).
        guard let manager = bandManager,
              manager.connectionState.isConnected || manager.connectionState.isAuthInProgress else {
            throw SyncError.notConnected
        }
        guard let context = modelContext else { throw SyncError.noDeviceRecord }
        guard !fileIds.isEmpty else { return HealthSyncOutcome() }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        do {
            try await HealthKitManager.shared.requestAuthorization()
        } catch {
            lastError = error
            throw error
        }

        log.info("Targeted workout sync — \(fileIds.count) file(s)")
        let outcome = try await reportingFailure {
            try await processActivityFiles(fileIds, manager: manager, context: context,
                                           addingToLastReport: true)
        }
        if outcome.deferredForLock { filesAwaitingUnlock = true }
        markSynced(context)
        log.info("Targeted workout sync done — \(outcome.healthSamplesWritten) samples written")
        return outcome
    }

    /// Splits a concatenated activity-file-id blob (each id is 7 bytes) into individual ids,
    /// dropping the placeholder ids the band can list with no timestamp and no version —
    /// GadgetBridge skips them too; fetching one only burns a timeout.
    static func splitFileIds(_ raw: Data) -> [Data] {
        guard !raw.isEmpty, raw.count % 7 == 0 else { return [] }
        return stride(from: raw.startIndex, to: raw.endIndex, by: 7)
            .map { Data(raw[$0 ..< $0 + 7]) }
            .filter { id in
                guard let meta = XiaomiActivityFileMeta(id) else { return false }
                return !(meta.timestamp.timeIntervalSince1970 == 0 && meta.version == 0)
            }
    }

    private func markSynced(_ context: ModelContext) {
        try? context.save()
        let now = Date()
        currentDevice?.lastHealthSyncDate = now
        currentDevice?.lastSyncDate = now
        lastHealthSync = now
        lastSyncDate = now
        try? context.save()
    }

    // MARK: - Activity file processing
    //
    // Fetches, parses, writes-to-Health, and ACKs each of `fileIds`. Shared by the full sync (ids
    // discovered via FETCH_TODAY/PAST) and the targeted post-workout sync (ids handed over by
    // workoutStatusWatch). Inserts SwiftData records; the caller persists via markSynced.
    //
    // ACK is sent only after the corresponding HealthKit write is confirmed, and for EVERY file that
    // was fetched — not only the ones that produced writable samples — so a file that parses to
    // nothing (or whose sibling already synced) doesn't get re-offered forever. The daily summary is
    // written and ACK'd inline; sleep, manual, workout, and daily-detail files are batched, so their
    // ACKs go out after the batch write (daily details are batched so the activity write can exclude
    // workout-covered minutes). If a write throws or the app is killed before ACKs are sent, the band
    // re-offers those files on the next connection — no data is lost.

    #if DEBUG
    /// Prints one copy-pasteable fixture block per activity file to the console.
    /// Uses `print` (not `Logger`) so the full hex is emitted untruncated and unredacted.
    private func dumpActivityFileFixture(fileId: Data, meta: XiaomiActivityFileMeta, data: Data) {
        let kind: String
        switch true {
        case meta.isWorkoutSummary: kind = "workout-summary"
        case meta.isWorkoutGps:     kind = "workout-gps"
        case meta.isSleep:          kind = "sleep"
        case meta.isManualSamples:  kind = "manual"
        case meta.isDailySummary:   kind = "daily-summary"
        case meta.isDailyDetails:   kind = "daily-details"
        default:                    kind = "unknown"
        }
        let iso = ISO8601DateFormatter().string(from: meta.timestamp)
        print("""
        ===== FIXTURE BEGIN =====
        kind=\(kind) subtype=\(meta.subtype) detail=\(meta.detail) version=\(meta.version) ts=\(iso) bytes=\(data.count)
        id=\(fileId.hexString)
        data=\(data.hexString)
        ===== FIXTURE END =====
        """)
    }
    #endif

    private func reportingFailure(_ body: () async throws -> HealthSyncOutcome) async throws -> HealthSyncOutcome {
        do {
            return try await body()
        } catch {
            syncLog?.noteFailure(error)
            throw error
        }
    }

    private func processActivityFiles(_ fileIds: [Data],
                                      manager: BandManager,
                                      context: ModelContext,
                                      addingToLastReport: Bool = false) async throws -> HealthSyncOutcome {
        var outcome = HealthSyncOutcome()
        var handled = Set<Data>()
        var completed = false
        HealthKitManager.shared.beginTally()
        // On every exit, so a write that throws still reports what reached Apple Health before it.
        defer {
            syncLog?.record(HealthSyncReport(
                at: .now, failed: !completed, filesFetched: handled.count,
                filesFailed: fileIds.filter { !handled.contains($0) }.count,
                sleepSessions: outcome.sleepSessions, dailySummaries: outcome.dailySummaries,
                minuteSamples: outcome.minuteSamples, manualSamples: outcome.manualSamples,
                workouts: outcome.workouts, byType: HealthKitManager.shared.endTally()),
                addingToLast: addingToLastReport)
        }
        var sleepToWrite: [SleepSession] = []
        /// Per sleep file, keyed by how far into the night it reaches, so the newest report's
        /// reading wins a repeated minute.
        var sleepVitals: [(reach: Date, samples: [ActivityMinuteSample])] = []
        var sleepBeats: [(reach: Date, windows: [BeatWindow])] = []
        var manualToWrite: [ManualSample] = []
        var workoutsToWrite: [WorkoutSummary] = []
        var workoutRoutes: [Int: [WorkoutTrackPoint]] = [:]
        var workoutHeartRates: [Int: [WorkoutHRSample]] = [:]

        var detailMinutes: [ActivityMinuteSample] = []

        var sleepIds:   [Data] = []
        var heldOpenSleepIds = Set<Data>()
        var manualIds:  [Data] = []
        var workoutIds: [Data] = []
        var gpsFileIds: [Int: Data] = [:]
        var detailIds:  [Data] = []

        // Routes one fetched, CRC-valid file into its batch (or writes and ACKs it inline).
        func route(_ fileId: Data, _ fileData: Data) async {
            guard let meta = XiaomiActivityFileMeta(fileId) else { return }

            do {
                #if DEBUG
                // Fixture capture: the full reassembled activity file, before any parser
                // touches it. Sync against real hardware, then copy these blocks from the
                // Xcode console into the test target's fixtures. Remove once captured.
                dumpActivityFileFixture(fileId: fileId, meta: meta, data: fileData)
                #endif

                if meta.isManualSamples {
                    let manual = ManualSamplesParser.parse(fileData, meta: meta)
                    manualToWrite += manual
                    latestMetrics?.update { $0.record(manual) }
                    outcome.manualSamples += manual.count
                    manualIds.append(fileId)
                } else if meta.isWorkoutSummary {
                    if let workout = WorkoutSummaryParser.parse(fileData, meta: meta) {
                        workoutsToWrite.append(workout)
                    }
                    workoutIds.append(fileId)
                } else if meta.isWorkoutGps {
                    let track = WorkoutGpsParser.parse(fileData, meta: meta)
                    log.notice("Workout GPS file: \(track.count, privacy: .public) point(s) for session at \(meta.timestamp.description, privacy: .public)")
                    if !track.isEmpty {
                        workoutRoutes[Int(meta.timestamp.timeIntervalSince1970)] = track
                        gpsFileIds[Int(meta.timestamp.timeIntervalSince1970)] = fileId
                    }
                    workoutIds.append(fileId)
                } else if meta.isWorkoutDetails {
                    // Per-second HR series recorded during the workout. Attached to the matching
                    // HKWorkout below (keyed by the session-start timestamp, like the GPS route).
                    let hr = WorkoutDetailsParser.parse(fileData, meta: meta)
                    if !hr.isEmpty {
                        workoutHeartRates[Int(meta.timestamp.timeIntervalSince1970)] = hr
                        log.info("Workout HR detail: \(hr.count) sample(s) for session at \(meta.timestamp.description)")
                    }
                    workoutIds.append(fileId)
                } else if meta.isSleep {
                    let parsed = Self.parseSleepFile(fileData, meta: meta)
                    let phaseCount = parsed.sessions.reduce(0) { $0 + $1.phases.count }
                    log.info("Sleep file \(fileId.hexString) (subtype=\(meta.subtype) v\(meta.version)): \(parsed.sessions.count) session(s), \(phaseCount) phase(s), \(parsed.heartRates.count) HR, \(parsed.spo2.count) SpO₂, \(parsed.beatWindows.count) beat block(s), awake=\(parsed.awakeFlag.map(String.init) ?? "-")")
                    // A corrupt header never reaches the local store either: GetSleepStateIntent and
                    // the Health sheet read it, not just Apple Health.
                    let (sessions, vitals) = parsed.inRange(HealthKitManager.validDateRange())
                    if Self.shouldHoldOpenSleepFile(parsed, inRange: sessions) {
                        log.info("Sleep file \(fileId.hexString) is a night the band still has open with nothing to write yet — left un-ACKed so it comes back once closed")
                        heldOpenSleepIds.insert(fileId)
                        latestMetrics?.update { $0.record(vitals) }
                        return
                    }
                    for session in sessions {
                        // Always (re)write to HealthKit — its sync-identifier dedup makes this
                        // idempotent, so data deleted from Apple Health is restored on re-sync.
                        // SwiftData keeps one record per distinct file.
                        storeReport(session, raw: fileData, awakeFlag: parsed.awakeFlag, fetchedAt: Date(), context)
                        sleepToWrite.append(session)
                    }
                    // HR/SpO₂ recorded during sleep — written within the sleep window so
                    // Apple Health's sleep "Comparisons" tab can correlate them.
                    let reach = sessions.map(\.endDate).max() ?? .distantPast
                    sleepVitals.append((reach, vitals))
                    sleepBeats.append((reach, Self.writableBeats(parsed, inRange: sessions)))
                    latestMetrics?.update { $0.record(vitals) }
                    sleepIds.append(fileId)
                } else if meta.isDailySummary {
                    if let summary = DailySummaryParser.parse(fileData, meta: meta) {
                        outcome.dailySummaries += 1
                        persistActivityDay(summary, context)
                        latestMetrics?.update { $0.record(summary) }
                        _ = HealthKitManager.shared.takeSkippedForPermission()
                        outcome.healthSamplesWritten += try await HealthKitManager.shared.writeDailySummary(summary)
                    }
                    ackUnlessSkipped([fileId], "daily summary", manager: manager)
                } else if meta.isDailyDetails {
                    // Batched (not written inline) so the activity write can exclude minutes covered
                    // by a workout — those file ids are only fully known after the loop.
                    let minutes = DailyDetailsParser.parse(fileData, meta: meta)
                    outcome.minuteSamples += minutes.count
                    detailMinutes += minutes
                    latestMetrics?.update { $0.record(minutes) }
                    detailIds.append(fileId)
                } else {
                    // No parser matches this file. We still ACK it so the band stops re-offering it on
                    // every connection (one such file was 12 KB, re-downloaded each sync forever). This
                    // mirrors GadgetBridge, whose fetcher ACKs every fetched file BEFORE creating a parser
                    // and discards whatever has none. Inline ACK is safe: we only reach here after
                    // fetchActivityFile returned without throwing, so the "ACK only after a successful
                    // fetch" invariant holds. (Workout per-second detail — sports/details — is handled
                    // above by isWorkoutDetails; an unknown future subtype/version lands here.)
                    log.info("No parser for file \(fileId.hexString) (type=\(String(describing: meta.type)) subtype=\(meta.subtype) detail=\(String(describing: meta.detail))) — ACKing to stop re-offering")
                    sendAck(fileId: fileId, manager: manager)
                }
            } catch {
                log.error("Failed file \(fileId.hexString): \(error.localizedDescription)")
            }
        }

        var ackedSleepIds = Set<Data>()
        var writtenSleepIds = Set<Data>()
        // writeSleep clears each night's window before writing, so a later flush rewrites the
        // sessions an earlier one wrote together with its own, or the night would lose them.
        var sleepWritten: [SleepSession] = []

        /// Writes the pending sleep batch, then ACKs its files. An ACK makes the band delete the file,
        /// so nothing is ACKed unless the sessions are saved locally and the night is in Health.
        func flushSleep(clearExisting: Bool) async {
            // Local sessions reach disk first: GetSleepStateIntent reads them, and a background
            // launch can be suspended before SwiftData's autosave runs.
            var contextSaved = true
            do { try context.save() } catch {
                contextSaved = false
                log.error("Saving local records failed: \(error.localizedDescription, privacy: .public)")
            }
            guard !sleepIds.isEmpty else { return }
            defer { sleepToWrite = []; sleepVitals = []; sleepBeats = []; sleepIds = [] }
            _ = HealthKitManager.shared.takeSkippedForPermission()
            var cleared = clearExisting
            do {
                if !sleepToWrite.isEmpty {
                    let night = sleepWritten + sleepToWrite
                    do {
                        outcome.healthSamplesWritten += try await HealthKitManager.shared.writeSleep(night, clearExisting: cleared)
                    } catch let error as HKError where error.code == .errorDatabaseInaccessible && cleared {
                        // The phone locked after `healthReadable` was read.
                        cleared = false
                        outcome.deferredForLock = true
                        outcome.healthSamplesWritten += try await HealthKitManager.shared.writeSleep(night, clearExisting: false)
                    }
                    outcome.sleepSessions += sleepToWrite.count
                    sleepWritten = night
                }
                let vitals = sleepVitals.sorted { $0.reach < $1.reach }.flatMap(\.samples)
                if !vitals.isEmpty {
                    outcome.healthSamplesWritten += try await HealthKitManager.shared.writeMinuteSamples(vitals)
                    outcome.minuteSamples += vitals.count
                }
            } catch {
                log.error("Sleep write failed — \(sleepIds.count) sleep file(s) left un-ACKed for the next sync: \(error.localizedDescription, privacy: .public)")
                return
            }
            outcome.healthSamplesWritten += await writeHRV(HeartRateVariability.nightBlocks(sleepBeats),
                                                           clearExisting: cleared)
            writtenSleepIds.formUnion(sleepIds)
            guard cleared else { return }
            guard contextSaved else {
                log.warning("\(sleepIds.count, privacy: .public) sleep file(s) left un-ACKed — local sessions weren't saved")
                return
            }
            if ackUnlessSkipped(sleepIds, "sleep", manager: manager) { ackedSleepIds.formUnion(sleepIds) }
        }

        // A fetch can come back with a different file than the one requested: the band is still
        // pushing one it hasn't had ACKed. That file is complete and CRC-valid, so it is routed like
        // any other, then ACKed to unstick the band; a sleep file only once its night is written and
        // saved. With the phone locked, a file whose rewrite needs an unlocked sync is not ACKed.
        fetching: for fileId in fileIds where !handled.contains(fileId) {
            for _ in 0 ..< 3 {
                let delivered: (id: Data, data: Data)
                do {
                    let (id, data) = try await surviveSessionRestart("Fetch \(fileId.hexString)", manager: manager) {
                        try await self.fetchActivityFile(fileId: fileId, manager: manager)
                    }
                    delivered = (id, data)
                } catch {
                    log.error("Failed file \(fileId.hexString): \(error.localizedDescription)")
                    break
                }
                if handled.insert(delivered.id).inserted {
                    await route(delivered.id, delivered.data)
                }
                if delivered.id == fileId { break }
                if !Self.healthReadable, (sleepIds + workoutIds + detailIds).contains(delivered.id) {
                    log.warning("Asked for \(fileId.hexString), band sent \(delivered.id.hexString) — phone locked, leaving both for a sync after unlock")
                    outcome.deferredForLock = true
                    break
                }
                if XiaomiActivityFileMeta(delivered.id)?.isSleep == true {
                    if ackedSleepIds.contains(delivered.id) {
                        sendAck(fileId: delivered.id, manager: manager)
                    } else {
                        await flushSleep(clearExisting: true)
                        if !ackedSleepIds.contains(delivered.id) {
                            // Written but held (a Health type off, a failed local save), or an open
                            // night with nothing to write yet: the band stays stuck on it, so skip
                            // to the next file instead of retrying.
                            if writtenSleepIds.contains(delivered.id) || heldOpenSleepIds.contains(delivered.id) {
                                log.warning("Asked for \(fileId.hexString), band is stuck on sleep file \(delivered.id.hexString), written but held un-ACKed — skipping to the next file")
                                continue fetching
                            }
                            // Unwritten: the band would only push the same file again.
                            log.warning("Asked for \(fileId.hexString), band is stuck on sleep file \(delivered.id.hexString), which wasn't written — stopping the fetch, it stays un-ACKed for the next sync")
                            outcome.fetchStopped = true
                            break fetching
                        }
                    }
                    log.warning("Asked for \(fileId.hexString), band sent sleep file \(delivered.id.hexString) — wrote it, ACKed to unstick, retrying")
                    continue
                }
                log.warning("Asked for \(fileId.hexString), band sent \(delivered.id.hexString) — routed it, ACKing to unstick, retrying")
                sendAck(fileId: delivered.id, manager: manager)
            }
        }

        // Weight, age, sleep cleanup and recovery pairing read Health, which a locked phone refuses
        // while still accepting saves. Everything is written; the files those reads feed stay
        // un-ACKed so an unlocked sync rewrites them in full under the same sync identifiers.
        let healthReadable = Self.healthReadable
        if !healthReadable {
            log.notice("Phone locked — sleep, workout and daily detail files left un-ACKed for a sync after unlock")
            outcome.deferredForLock = !(sleepIds + workoutIds + detailIds).isEmpty
        }

        // Isolated from the rest of the batch: a failing sleep write leaves only the sleep files
        // un-ACKed (the band re-offers them) and the manual/workout/daily-detail writes go through.
        await flushSleep(clearExisting: healthReadable)

        // ACK every file we successfully fetched — NOT gated on the write batch being non-empty.
        // A fetched file that parsed to nothing (or whose sibling already synced) still has to be
        // ACKed, otherwise the band re-offers it forever and shows it as "not synced". The ACK runs
        // after the write so a thrown write skips it (the band then re-offers — no data loss). Only
        // files that fetched without throwing reach the *Ids arrays.
        _ = HealthKitManager.shared.takeSkippedForPermission()
        if !manualToWrite.isEmpty {
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeManualSamples(manualToWrite)
        }
        ackUnlessSkipped(manualIds, "manual", manager: manager)

        _ = HealthKitManager.shared.takeSkippedForPermission()
        // A strength workout's band files carry no GPS track; the phone's sparse one stands in.
        let phoneRoutes = StrengthWorkoutExtras.phoneRoutes(workoutGps.recordedStrengthRoutes,
                                                            for: workoutsToWrite, bandRoutes: workoutRoutes)
        var savedWorkouts: [Int: HKWorkout] = [:]
        var routedWorkouts = Set<Int>()
        if !workoutsToWrite.isEmpty {
            outcome.workouts = workoutsToWrite.count
            var routes = workoutRoutes
            for (key, phone) in phoneRoutes {
                routes[key] = phone.track
                log.notice("Strength workout at \(key, privacy: .public): attaching the phone's GPS track (\(phone.track.count, privacy: .public) point(s))")
            }
            let result = try await HealthKitManager.shared.writeWorkouts(workoutsToWrite, routes: routes, heartRates: workoutHeartRates)
            outcome.healthSamplesWritten += result.written
            savedWorkouts = result.saved
            routedWorkouts = result.routed
            workoutWindows.record(workoutsToWrite
                .filter { result.saved[Int($0.startDate.timeIntervalSince1970)] != nil }
                .map { .init(start: $0.startDate, end: $0.endDate) })
        }
        // A GPS track whose summary came in an earlier sync goes onto the workout already in Health.
        // One whose attach failed keeps its file un-ACKed, so the band offers it again.
        let writtenStarts = workoutsToWrite.map { Int($0.startDate.timeIntervalSince1970) }
        let lateRoutes = workoutRoutes.filter { route in !writtenStarts.contains { abs($0 - route.key) <= 120 } }
        var heldGpsIds = Set<Data>()
        if healthReadable, !lateRoutes.isEmpty {
            let failed = await HealthKitManager.shared.attachLateRoutes(lateRoutes)
            heldGpsIds = Set(failed.compactMap { gpsFileIds[$0] })
            if !heldGpsIds.isEmpty {
                log.warning("\(heldGpsIds.count, privacy: .public) GPS file(s) left un-ACKed — their route couldn't be attached")
            }
        }
        // Workout summary + GPS files: a GPS file can be pending without a parseable summary (its
        // summary was ACKed in an earlier sync), which used to leave it dangling forever.
        let workoutsAcked = healthReadable
            && ackUnlessSkipped(workoutIds.filter { !heldGpsIds.contains($0) }, "workout", manager: manager)
        if workoutsAcked {
            // A failed attach keeps its entry, so a later rewrite of the workout can try again.
            workoutGps.discardStrengthRoutes(phoneRoutes.filter { routedWorkouts.contains($0.key) }.map(\.value.stashKey))
        }
        for workout in workoutsToWrite where workout.kind == .strengthTraining {
            let key = Int(workout.startDate.timeIntervalSince1970)
            guard let saved = savedWorkouts[key],
                  let held = recoveryPairing.workoutSaved(start: key, saved) else { continue }
            outcome.healthSamplesWritten += await saveRecoveryHR(held, to: saved, tallied: true)
        }

        // Daily details last: HR/SpO₂ and steps/distance/energy per minute, leaving out distance and
        // energy inside a workout, which the workout samples above already contribute.
        _ = HealthKitManager.shared.takeSkippedForPermission()
        if !detailMinutes.isEmpty {
            // Stored windows, not just this batch: a workout the post-workout sync already wrote is
            // missing from workoutsToWrite when its daily-details file arrives later.
            let windows = workoutWindows.all().map { (start: $0.start, end: $0.end) }
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeMinuteSamples(detailMinutes)
            outcome.healthSamplesWritten += try await HealthKitManager.shared.writeActivity(detailMinutes, excludingWorkouts: windows)
            // Cardio Recovery: pairs recent workouts already in Health with the post-workout
            // per-minute HR this batch carries. Best-effort — must not block the ACKs below. It reads
            // Health, so a locked phone defers it with the un-ACKed detail files.
            if healthReadable {
                do {
                    outcome.healthSamplesWritten += try await HealthKitManager.shared.writeHeartRateRecoveries(minutes: detailMinutes)
                } catch {
                    log.error("Cardio recovery write failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if healthReadable { ackUnlessSkipped(detailIds, "daily detail", manager: manager) }

        completed = true
        return outcome
    }

    private static var healthReadable: Bool {
        #if canImport(UIKit)
        UIApplication.shared.isProtectedDataAvailable
        #else
        true
        #endif
    }

    /// The band re-offers an un-ACKed file, so one whose samples were dropped for a Health type
    /// switched off is written on a later sync once it is on, instead of being deleted unwritten.
    @discardableResult
    private func ackUnlessSkipped(_ ids: [Data], _ kind: String, manager: BandManager) -> Bool {
        guard !ids.isEmpty else { return true }
        if HealthKitManager.shared.takeSkippedForPermission() {
            log.warning("\(ids.count, privacy: .public) \(kind, privacy: .public) file(s) left un-ACKed — a Health type is switched off for My Band")
            return false
        }
        ids.forEach { sendAck(fileId: $0, manager: manager) }
        return true
    }

    // MARK: - One-time sleep history repair
    //
    // `HealthKitManager.writeSleep` used to key each phase's sync identifier on its exact
    // (start, end) pair. A resync of a still-in-progress night reports the same real segment with
    // a later end, so the identifier changed and the old, shorter write was never superseded —
    // years of nights ended up with overlapping, double-counted stage/in-bed records in Apple
    // Health. The write path is now stable/self-healing, but it can only clean up a night the next
    // time that night's data happens to be resynced. This repairs everything already on disk in
    // one pass: local SwiftData still holds every synced `SleepSession` (unlike Apple Health, its
    // `rawDataHash` dedup doesn't collapse multiple files for the same overlapping night), so
    // feeding the *entire* history back through the fixed `writeSleep` groups and re-sanitizes it
    // and clears the stale duplicates. Runs once, gated by a flag, and only advances that flag on
    // success — a failure just retries on the next sync.
    private static let sleepRepairKey = "sleepHistoryRepairedV1"

    private func repairSleepHistoryOnce(context: ModelContext) async {
        // The repair's cleanup delete needs a readable Health store; it runs on an unlocked sync.
        guard !UserDefaults.standard.bool(forKey: Self.sleepRepairKey), Self.healthReadable else { return }
        let all = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        guard !all.isEmpty else {
            UserDefaults.standard.set(true, forKey: Self.sleepRepairKey)
            return
        }
        do {
            let written = try await HealthKitManager.shared.writeSleep(all)
            log.info("One-time sleep history repair: rewrote \(written) samples from \(all.count) local session(s)")
            UserDefaults.standard.set(true, forKey: Self.sleepRepairKey)
        } catch {
            log.error("Sleep history repair failed, will retry next sync: \(error.localizedDescription)")
        }
    }

    /// Most recent locally-synced sleep session, for `GetSleepStateIntent` — a pull-based read of
    /// whatever the last sync happened to capture (the band has no "fell asleep"/"woke up" push).
    func mostRecentSleepSession() -> SleepSession? {
        guard let context = modelContext else { return nil }
        return Self.mostRecentSleepSession(in: context)
    }

    /// Ordered by end, not start: every report of a night shares its bedtime, so a start-ordered
    /// fetch returned an arbitrary copy. A tie goes to the latest fetch. An end past the clock is a
    /// misread header, and sorting first it would hide every real night.
    static func mostRecentSleepSession(in context: ModelContext, now: Date = Date()) -> SleepSession? {
        let latest = now.addingTimeInterval(SleepStateRule.clockSkewTolerance)
        var descriptor = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.endDate <= latest },
                                                       sortBy: [SortDescriptor(\.endDate, order: .reverse),
                                                                SortDescriptor(\.fetchedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    // MARK: - Stored sleep reports

    static func parseSleepFile(_ data: Data, meta: XiaomiActivityFileMeta) -> ParsedSleep {
        meta.isSleepStages ? SleepStagesParser.parse(data, meta: meta) : SleepDetailsParser.parse(data, meta: meta)
    }

    /// An open night with nothing to write is held un-ACKed: an ACK makes the band delete it, and
    /// the same file closed is the one that carries the nap.
    static func shouldHoldOpenSleepFile(_ parsed: ParsedSleep, inRange sessions: [SleepSession]) -> Bool {
        sessions.isEmpty && parsed.awakeFlag == 0
    }

    /// The blocks of a file that made a night, only those overlapping its sessions: the parser keeps
    /// blocks up to 6 h around the night, and one before bedtime or after waking isn't sleep. All of a
    /// closed night's; an open one's last block is still growing, unless the night has settled. A
    /// report from before `awakeFlag` was kept can't tell, so none.
    static func writableBeats(_ parsed: ParsedSleep, inRange sessions: [SleepSession],
                              settled: Bool = false) -> [BeatWindow] {
        guard !sessions.isEmpty, let flag = parsed.awakeFlag else { return [] }
        let blocks = flag != 0 || settled ? parsed.beatWindows : Array(parsed.beatWindows.dropLast())
        return blocks.filter { block in sessions.contains { block.start < $0.endDate && block.end > $0.startDate } }
    }

    /// A night's blocks overlapping none of `sessions` (its files' own and every other stored night's),
    /// whose values an older parse may have written. Deleted by sync id: a time span could reach a
    /// neighbouring nap's values. An open night's withheld last block overlaps its session, so it stays.
    static func staleBeats(_ files: [ParsedSleep], sessions: [SleepSession]) -> [BeatWindow] {
        var byStart: [Date: BeatWindow] = [:]
        for block in files.flatMap(\.beatWindows)
        where !sessions.contains(where: { block.start < $0.endDate && block.end > $0.startDate }) {
            byStart[block.start] = block
        }
        return byStart.values.sorted { $0.start < $1.start }
    }

    /// Best-effort, and never a reason to hold a sleep file. Without the permission it re-arms the
    /// stored-night pass, which backfills once HRV is granted; a failed night is queued for that pass.
    private func writeHRV(_ blocks: [BeatWindow], clearExisting: Bool) async -> Int {
        guard !blocks.isEmpty else { return 0 }
        guard HealthKitManager.shared.canShareHRV else {
            UserDefaults.standard.removeObject(forKey: Self.hrvRevisionKey)
            return 0
        }
        do {
            let result: (written: Int, medianMs: Double?)
            do {
                result = try await HealthKitManager.shared.writeHeartRateVariability(blocks, clearExisting: clearExisting)
            } catch let error as HKError where error.code == .errorDatabaseInaccessible && clearExisting {
                // The phone locked after the sleep write; the delete is left to a foreground rewrite.
                Self.queueHRVRetry(HeartRateVariability.nightSpans(blocks))
                result = try await HealthKitManager.shared.writeHeartRateVariability(blocks, clearExisting: false)
            }
            let median = result.medianMs.map { "\(Int($0.rounded())) ms" } ?? "—"
            log.info("HRV: \(result.written) SDNN value(s) from \(blocks.count) beat block(s), median \(median, privacy: .public)")
            return result.written
        } catch {
            Self.queueHRVRetry(HeartRateVariability.nightSpans(blocks))
            log.error("HRV write failed, its night(s) queued for the next foreground sync: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }

    /// Inserts a new report, or refreshes the stored one with the same bytes: its phases take the
    /// current parse, and its fetch time moves while its end doesn't — the night stopped growing,
    /// which is how the sleep intent tells the user woke up.
    func storeReport(_ session: SleepSession, raw: Data, awakeFlag: Int?, fetchedAt: Date,
                     _ context: ModelContext) {
        let hash = session.rawDataHash
        let sameHash = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.rawDataHash == hash })
        // The hash is 64-bit, so a stored length that differs is a collision, not the same file.
        // A pruned report has no bytes left to compare and is taken as the same.
        let sameBytes = ((try? context.fetch(sameHash)) ?? []).first { ($0.rawData?.count ?? raw.count) == raw.count }
        let report: SleepSession
        if let existing = sameBytes {
            existing.startDate = session.startDate
            existing.endDate = session.endDate
            existing.phases = session.phases
            report = existing
        } else {
            session.device = currentDevice
            context.insert(session)
            report = session
        }
        report.awakeFlag = awakeFlag
        report.fetchedAt = fetchedAt
        if report.rawData == nil { report.rawData = raw }
        Self.pruneRawData(around: report, in: context)
    }

    /// A long night is ~140 KB and every sync of it stores another report, so only the report
    /// reaching furthest keeps its bytes. Earlier cuts of the same file share its bedtime and
    /// subtype; an overlapping report without both is another file, whose bytes nothing else holds.
    static func pruneRawData(around report: SleepSession, in context: ModelContext) {
        guard let subtype = rawSubtype(report) else { return }
        let start = report.startDate
        let sameBedtime = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.startDate == start })
        // Filtered here, not in the predicate: an external-storage attribute may live outside the row.
        let holders = ((try? context.fetch(sameBedtime)) ?? []).filter { rawSubtype($0) == subtype }
        guard let keep = SleepSession.furthest(holders) else { return }
        for other in holders where other !== keep { other.rawData = nil }
    }

    private static func rawSubtype(_ report: SleepSession) -> Int? {
        report.rawData.flatMap { XiaomiActivityFileMeta(Data($0.prefix(7)))?.subtype }
    }

    static let rawSleepRetention: TimeInterval = 90 * 86_400
    private static let rawSleepExpiryKey = "rawSleepExpiryLastRun"

    static func dropExpiredRawData(in context: ModelContext, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-rawSleepRetention)
        let old = FetchDescriptor<SleepSession>(predicate: #Predicate { $0.endDate < cutoff })
        for report in (try? context.fetch(old)) ?? [] where report.rawData != nil { report.rawData = nil }
    }

    /// Reading each old report's external bytes costs more than a background wake should spend.
    private func dropExpiredRawDataDaily(context: ModelContext, now: Date = Date()) {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else { return }
        #endif
        if let last = UserDefaults.standard.object(forKey: Self.rawSleepExpiryKey) as? Date,
           now.timeIntervalSince(last) < 86_400 { return }
        Self.dropExpiredRawData(in: context, now: now)
        try? context.save()
        UserDefaults.standard.set(now, forKey: Self.rawSleepExpiryKey)
    }

    // MARK: - Re-reading stored sleep files
    //
    // Bump when SleepDetailsParser/SleepStagesParser read the same bytes differently: the next
    // foreground, unlocked sync re-parses every stored file and rewrites its night in Apple Health.
    // Nights stored before raw files were kept have nothing to re-read and are left as they are.
    static let sleepParserRevision = 2
    private static let sleepParserRevisionKey = "sleepParserRevisionApplied"

    private func reparseStoredSleepIfParserChanged(context: ModelContext) async {
        guard UserDefaults.standard.integer(forKey: Self.sleepParserRevisionKey) != Self.sleepParserRevision,
              Self.healthReadable else { return }
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else { return }
        #endif
        // Every night would be held back for permission; retried once sleep is switched back on.
        guard HealthKitManager.shared.canShareSleep else {
            log.notice("Sleep re-parse (revision \(Self.sleepParserRevision)) skipped — sleep is switched off for My Band in Health")
            return
        }
        let result = await reparseStoredSleep(context)
        try? context.save()
        guard result.failed == 0 else {
            log.error("Sleep re-parse (revision \(Self.sleepParserRevision)): \(result.failed) of \(result.nights) night(s) failed, retrying next sync")
            return
        }
        log.notice("Sleep re-parse (revision \(Self.sleepParserRevision)): \(result.nights) night(s) rewritten")
        UserDefaults.standard.set(Self.sleepParserRevision, forKey: Self.sleepParserRevisionKey)
    }

    /// Earlier cuts of a night keep no bytes (`pruneRawData`), so they can't be re-parsed: they follow
    /// the report holding the file to its new start, or `mergeReports` would bring back what it dropped.
    static func moveCuts(from oldStart: Date, to newStart: Date, among reports: [SleepSession]) {
        for cut in reports where cut.startDate == oldStart && cut.rawData == nil {
            cut.phases = cut.phases.compactMap { phase in
                let start = max(phase.startDate, newStart)
                return phase.endDate > start ? SleepPhase(startDate: start, endDate: phase.endDate, type: phase.type) : nil
            }
            cut.startDate = newStart
            cut.endDate = max(cut.endDate, newStart)
        }
    }

    /// Each night is written on its own, so one that fails is retried without holding back the rest.
    private func reparseStoredSleep(_ context: ModelContext) async -> (nights: Int, failed: Int) {
        let all = (try? context.fetch(FetchDescriptor<SleepSession>())) ?? []
        let validDates = HealthKitManager.validDateRange()
        let stored = Self.parseStoredFiles(all)
        var vitals: [ObjectIdentifier: [ActivityMinuteSample]] = [:]
        var oldWindows: [ObjectIdentifier: (start: Date, end: Date)] = [:]
        var moved: [(from: Date, to: Date)] = []
        for report in all {
            oldWindows[ObjectIdentifier(report)] = (report.startDate, report.endDate)
            guard let parsed = stored.parsed[ObjectIdentifier(report)] else { continue }
            let fresh = parsed.inRange(validDates)
            vitals[ObjectIdentifier(report)] = fresh.vitals
            // A file the current parser makes no valid night of keeps its old record.
            guard let session = fresh.sessions.first else { continue }
            if session.startDate != report.startDate { moved.append((report.startDate, session.startDate)) }
            report.startDate = session.startDate
            report.endDate = session.endDate
            report.phases = session.phases
            report.awakeFlag = parsed.awakeFlag
        }
        for move in moved { Self.moveCuts(from: move.from, to: move.to, among: all) }
        let nights = HealthKitManager.groupOverlapping(all).filter { night in
            night.contains { vitals[ObjectIdentifier($0)] != nil }
        }
        var failed = 0
        // All windows, old and new, are cleared before any night is written: a night's old window
        // can reach into a neighbour's new one, and clearing it later would erase that rewrite.
        var uncleared = Set<Int>()
        for (index, night) in nights.enumerated() {
            let starts = night.flatMap { [$0.startDate, oldWindows[ObjectIdentifier($0)]?.start].compactMap { $0 } }
            let ends = night.flatMap { [$0.endDate, oldWindows[ObjectIdentifier($0)]?.end].compactMap { $0 } }
            guard let start = starts.min(), let end = ends.max(), end > start else { continue }
            do {
                try await HealthKitManager.shared.clearSleep(overlapping: start, to: end)
            } catch {
                failed += 1
                uncleared.insert(index)
                log.error("Sleep re-parse: clearing the night from \(start.description) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        for (index, night) in nights.enumerated() where !uncleared.contains(index) {
            let nightVitals = night.flatMap { vitals[ObjectIdentifier($0)] ?? [] }
            let from = night.map(\.startDate).min()?.description ?? "?"
            _ = HealthKitManager.shared.takeSkippedForPermission()
            do {
                _ = try await HealthKitManager.shared.writeSleep(night)
                if !nightVitals.isEmpty { _ = try await HealthKitManager.shared.writeMinuteSamples(nightVitals) }
            } catch {
                failed += 1
                log.error("Sleep re-parse: night from \(from) failed: \(error.localizedDescription, privacy: .public)")
                continue
            }
            if HealthKitManager.shared.takeSkippedForPermission() {
                failed += 1
                log.warning("Sleep re-parse: night from \(from) dropped samples for permission — retrying next sync")
            }
        }
        return (nights.count, failed)
    }

    // MARK: - HRV of stored nights
    //
    // Rewrites stored nights' HRV from their raw files, apart from the sleep re-parse, whose phases don't
    // change with HRV: every night when `HealthKitManager.hrvAlgorithmVersion` differs from the one
    // applied, otherwise only the nights a failed write queued and the open nights that settled.
    private static let hrvRevisionKey = "hrvBackfillRevisionApplied"
    private static let hrvSkipLoggedKey = "hrvBackfillSkipLogged"
    private static let hrvRetryKey = "hrvRetrySpans"
    private static let hrvSettledKey = "hrvSettledReports"

    /// An open night whose report the band last sent this long ago has stopped growing: the band closes
    /// a night about an hour after waking, and a closed report would have come by now. One that comes
    /// anyway rewrites the night under the same sync ids.
    static let openNightSettle: TimeInterval = 3 * 3600

    struct StoredHRVNight {
        var reports: [SleepSession]
        var window: ClosedRange<Date>
        /// An open night that settled: its last block is written too.
        var settled: Bool
    }

    /// The nights the pass rewrites. `settledDone` holds the furthest report of each settled night
    /// already written with its last block.
    static func storedHRVNights(_ nights: [[SleepSession]], full: Bool, retry: [ClosedRange<Date>],
                                settledDone: Set<Int>, now: Date) -> [StoredHRVNight] {
        nights.compactMap { reports in
            guard let furthest = SleepSession.furthest(reports), let start = reports.map(\.startDate).min(),
                  let end = reports.map(\.endDate).max(), end >= start else { return nil }
            let window = start ... end
            let settled = furthest.awakeFlag == 0
                && furthest.fetchedAt.map { now.timeIntervalSince($0) >= openNightSettle } == true
            let due = full || retry.contains { $0.overlaps(window) }
                || (settled && !settledDone.contains(furthest.rawDataHash))
            return due ? StoredHRVNight(reports: reports, window: window, settled: settled) : nil
        }
    }

    static func hrvRetrySpans(_ defaults: UserDefaults = .standard) -> [ClosedRange<Date>] {
        ((defaults.array(forKey: hrvRetryKey) as? [[Double]]) ?? []).compactMap { pair in
            guard pair.count == 2, pair[0] <= pair[1] else { return nil }
            return Date(timeIntervalSince1970: pair[0]) ... Date(timeIntervalSince1970: pair[1])
        }
    }

    static func setHRVRetrySpans(_ spans: [ClosedRange<Date>], _ defaults: UserDefaults = .standard) {
        let pairs = spans.map { [$0.lowerBound.timeIntervalSince1970, $0.upperBound.timeIntervalSince1970] }
        if pairs.isEmpty { defaults.removeObject(forKey: hrvRetryKey) } else { defaults.set(pairs, forKey: hrvRetryKey) }
    }

    static func queueHRVRetry(_ spans: [ClosedRange<Date>], _ defaults: UserDefaults = .standard) {
        var queued = hrvRetrySpans(defaults)
        for span in spans where !queued.contains(where: { $0.lowerBound <= span.lowerBound && span.upperBound <= $0.upperBound }) {
            queued.append(span)
        }
        setHRVRetrySpans(queued, defaults)
    }

    /// Each stored file parsed once, told apart by hash and byte count as `storeReport` does. Every
    /// report holding it gets the parse, but its blocks come only from the first (`firstHolders`), or a
    /// file kept on two records would be written twice.
    static func parseStoredFiles(_ reports: [SleepSession])
        -> (parsed: [ObjectIdentifier: ParsedSleep], firstHolders: Set<ObjectIdentifier>) {
        var byFile: [String: ParsedSleep] = [:]
        var parsed: [ObjectIdentifier: ParsedSleep] = [:]
        var firstHolders = Set<ObjectIdentifier>()
        for report in reports {
            guard let raw = report.rawData, let meta = XiaomiActivityFileMeta(Data(raw.prefix(7))), meta.isSleep else { continue }
            let key = "\(report.rawDataHash):\(raw.count)"
            if let known = byFile[key] {
                parsed[ObjectIdentifier(report)] = known
                continue
            }
            let fresh = parseSleepFile(raw, meta: meta)
            byFile[key] = fresh
            parsed[ObjectIdentifier(report)] = fresh
            firstHolders.insert(ObjectIdentifier(report))
        }
        return (parsed, firstHolders)
    }

    private func rewriteStoredHRVIfNeeded(context: ModelContext, now: Date = Date()) async {
        guard Self.healthReadable else { return }
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState != .background else { return }
        #endif
        let defaults = UserDefaults.standard
        let version = HealthKitManager.hrvAlgorithmVersion
        guard HealthKitManager.shared.canShareHRV else {
            // Re-armed so a later grant backfills; logged once, not on every sync until then.
            defaults.removeObject(forKey: Self.hrvRevisionKey)
            if !defaults.bool(forKey: Self.hrvSkipLoggedKey) {
                log.notice("HRV of stored nights skipped — heart rate variability isn't granted to My Band in Health")
                defaults.set(true, forKey: Self.hrvSkipLoggedKey)
            }
            return
        }
        defaults.removeObject(forKey: Self.hrvSkipLoggedKey)
        let full = defaults.integer(forKey: Self.hrvRevisionKey) != version
        let cutoff = now.addingTimeInterval(-Self.rawSleepRetention)
        let recent = (try? context.fetch(FetchDescriptor<SleepSession>(predicate: #Predicate { $0.endDate >= cutoff }))) ?? []
        var settledDone = Set(defaults.array(forKey: Self.hrvSettledKey) as? [Int] ?? [])
            .intersection(recent.map(\.rawDataHash))
        let nights = Self.storedHRVNights(HealthKitManager.groupOverlapping(recent), full: full,
                                          retry: Self.hrvRetrySpans(), settledDone: settledDone, now: now)
        let stored = Self.parseStoredFiles(nights.flatMap(\.reports))
        let validDates = HealthKitManager.validDateRange()
        var written = 0
        var failed: [ClosedRange<Date>] = []
        for night in nights {
            let beats = night.reports.compactMap { report -> (reach: Date, windows: [BeatWindow])? in
                guard stored.firstHolders.contains(ObjectIdentifier(report)),
                      let parsed = stored.parsed[ObjectIdentifier(report)] else { return nil }
                let sessions = parsed.inRange(validDates).sessions
                return (sessions.map(\.endDate).max() ?? .distantPast,
                        Self.writableBeats(parsed, inRange: sessions, settled: night.settled))
            }
            let blocks = HeartRateVariability.nightBlocks(beats)
            let inNight = Set(night.reports.map(ObjectIdentifier.init))
            let files = night.reports.filter { stored.firstHolders.contains(ObjectIdentifier($0)) }
                .compactMap { stored.parsed[ObjectIdentifier($0)] }
            let stale = Self.staleBeats(files, sessions: files.flatMap { $0.inRange(validDates).sessions }
                                            + recent.filter { !inNight.contains(ObjectIdentifier($0)) })
            do {
                if !blocks.isEmpty || !stale.isEmpty {
                    written += try await HealthKitManager.shared.writeHeartRateVariability(blocks, clearExisting: true,
                                                                                          stale: stale).written
                }
                if night.settled, let furthest = SleepSession.furthest(night.reports) {
                    settledDone.insert(furthest.rawDataHash)
                }
            } catch {
                failed.append(night.window)
                log.error("HRV of stored nights: night from \(night.window.lowerBound.description) failed, queued for the next sync: \(error.localizedDescription, privacy: .public)")
            }
        }
        // A queued span that matched no stored file has nothing left to rebuild from.
        Self.setHRVRetrySpans(failed)
        defaults.set(Array(settledDone), forKey: Self.hrvSettledKey)
        if full { defaults.set(version, forKey: Self.hrvRevisionKey) }
        guard !nights.isEmpty else { return }
        let scope = full ? "every night (revision \(version))" : "queued and settled nights"
        log.notice("HRV of stored nights, \(scope, privacy: .public): \(written) value(s) across \(nights.count) night(s), \(failed.count) queued")
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

    // MARK: - Band session restarts
    //
    // Right after the post-auth init the band reopens its session and re-derives keys (see
    // BandManager.handleSessionConfigResponse). A command sent across that boundary is transport-
    // ACKed and silently dropped, so its reply never comes. A sync that opened the link itself sends
    // FETCH_TODAY straight into that window — ensureConnected resolves on the first auth — and a lost
    // listing used to time out and take the whole sync down with it. Each exchange now fails fast on
    // the restart signal and is re-sent once the new session is up.

    private func surviveSessionRestart<T>(_ label: String, manager: BandManager,
                                          _ exchange: () async throws -> T) async throws -> T {
        var restarts = 0
        while true {
            try await manager.awaitSession()
            do {
                return try await exchange()
            } catch SyncError.sessionRestarted where restarts < Self.maxRestartRetries {
                restarts += 1
                log.warning("\(label) cut short by a band session restart — re-sending after re-auth (\(restarts)/\(Self.maxRestartRetries))")
            }
        }
    }

    /// Yields once if the band restarts its session while the calling exchange is pending.
    private func watchSessionRestart() -> AsyncStream<Void> {
        let (stream, cont) = AsyncStream<Void>.makeStream()
        sessionRestartSignal?.finish()
        sessionRestartSignal = cont
        return stream
    }

    private func endSessionRestartWatch() {
        sessionRestartSignal?.finish()
        sessionRestartSignal = nil
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

        let today = try await surviveSessionRestart("FETCH_TODAY", manager: manager) {
            try await self.requestFileIds(subtype: XiaomiHealthCmd.fetchToday,
                                          proto: XiaomiProto.fetchTodayCommand(),
                                          manager: manager)
        }
        log.info("FETCH_TODAY → \(today.count) file ID(s)")
        merge(today)

        // The backlog is best-effort: an empty response or timeout shouldn't abort the sync.
        do {
            let past = try await surviveSessionRestart("FETCH_PAST", manager: manager) {
                try await self.requestFileIds(subtype: XiaomiHealthCmd.fetchPast,
                                              proto: XiaomiProto.fetchPastCommand(),
                                              manager: manager)
            }
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
            let restarts = watchSessionRestart()
            defer {
                manager.onProtoCommandReceived = nil
                cont.finish()
                endSessionRestartWatch()
            }

            manager.sendEncryptedCommand(protoBytes: proto)

            group.addTask { @MainActor in
                for await _ in restarts { throw SyncError.sessionRestarted }
                throw CancellationError()
            }

            // Pinned to the main actor: the proto callback delivers on .main and the parsers are
            // main-actor-isolated (module default), so processing here keeps it all on one actor.
            group.addTask { @MainActor in
                for await chunk in stream {
                    if let ids = self.extractFileIds(from: chunk, subtype: subtype) { return ids }
                }
                return []
            }
            group.addTask {
                try await Task.sleep(for: .seconds(10))
                self.log.error("File-id listing (subtype \(subtype)) got no reply in 10 s")
                throw SyncError.timeout
            }

            let result = try await group.next() ?? []
            group.cancelAll()
            return result
        }
    }

    private func extractFileIds(from protoBytes: Data, subtype: UInt32) -> [Data]? {
        // Expect Command { type=8, subtype=<requested>, health { activityRequestFileIds } }.
        // An empty list still matches (no pending records) and completes the wait.
        guard let cmd = XiaomiProto.parseCommand(protoBytes),
              cmd.type == XiaomiHealthCmd.cmdType,
              cmd.subtype == subtype else { return nil }
        let raw = cmd.health.activityRequestFileIds
        guard raw.count % 7 == 0 else { return nil }
        return Self.splitFileIds(raw)
    }

    // MARK: - Private: fetch individual activity file

    private func fetchActivityFile(fileId: Data, manager: BandManager) async throws -> (Data, Data) {
        let proto = XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.fetchRequest, fileIds: fileId)

        return try await withThrowingTaskGroup(of: (Data, Data).self) { group in
            let receiver = ActivityFileReceiver()
            let (stream, cont) = AsyncStream<Data>.makeStream()

            manager.onActivityChunkReceived = { data in cont.yield(data) }
            let restarts = watchSessionRestart()
            defer {
                manager.onActivityChunkReceived = nil
                cont.finish()
                endSessionRestartWatch()
            }

            manager.sendEncryptedCommand(protoBytes: proto)

            group.addTask { @MainActor in
                for await _ in restarts { throw SyncError.sessionRestarted }
                throw CancellationError()
            }

            let log = self.log
            // Pinned to the main actor: chunks arrive on .main and ActivityFileReceiver is
            // main-actor-isolated (module default). Reassembly/CRC are light, so staying on main is fine.
            group.addTask { @MainActor in
                for await chunk in stream {
                    receiver.addChunk(chunk)
                    log.debug("Activity chunk \(receiver.chunkProgress) (\(chunk.count)B)")
                    if receiver.isComplete {
                        guard receiver.validateCRC() else { throw SyncError.crcMismatch }
                        let file = receiver.assembled()
                        guard file.count >= 7 else { throw SyncError.fileIdMismatch }
                        let actualId = Data(file.prefix(7))
                        return (actualId, file)
                    }
                }
                throw SyncError.emptyPayload
            }
            group.addTask { @MainActor in
                while true {
                    try await Task.sleep(for: .seconds(1))
                    if ContinuousClock.now - receiver.lastActivity > Self.fileIdleTimeout {
                        self.log.error("File \(fileId.hexString, privacy: .public) stalled — no chunk for \(Self.fileIdleTimeout, privacy: .public)")
                        throw SyncError.timeout
                    }
                }
            }

            guard let result = try await group.next() else { throw SyncError.emptyPayload }
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
