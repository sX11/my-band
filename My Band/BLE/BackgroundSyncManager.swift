import Foundation
import OSLog

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - BackgroundSyncManager
//
// Single entry point for driving an Apple Health sync, foreground or background.
//
// Triggers (all funnel through `syncNow`, which coalesces concurrent calls into one run):
//   • App Intent / Shortcuts        → syncNow()                (keeps a live link open)
//   • BGProcessingTask (heavy)      → handle() → syncNow()      (connects, syncs, disconnects)
//   • BGAppRefreshTask (frequent)   → handle() → syncNow()      (idem — runs far more often)
//   • State-restoration BLE wake    → syncOnBackgroundWakeIfStale() (the band reconnecting in the
//                                      background relaunches the app; we sync if data is stale)
//
// Two task types are registered: app-refresh is short and scheduled often by the OS; processing is
// for the heavier/deferrable run and tends to fire when charging. Registering both widens the
// window in which iOS will wake us. BGTaskScheduler.register MUST run before launch finishes, which
// is why register() is called from the AppDelegate — not a SwiftUI .onAppear.

@MainActor
final class BackgroundSyncManager {

    static let shared = BackgroundSyncManager()

    /// Must match the identifiers in Info.plist → BGTaskSchedulerPermittedIdentifiers.
    static let processingTaskID = "com.myband.sync"
    static let refreshTaskID    = "com.myband.refresh"

    /// Floor the OS treats as the earliest next background run (not a guarantee).
    private let minInterval: TimeInterval = 30 * 60
    /// A background-wake sync is skipped if Health was synced more recently than this — avoids
    /// re-syncing on every transient BLE reconnect.
    private let autoSyncStaleness: TimeInterval = 15 * 60

    private weak var manager: BandManager?
    private weak var syncer: BandSyncer?
    private var didRegister = false

    /// The in-flight sync, shared by every concurrent caller so duplicate triggers coalesce.
    private var inFlight: Task<BandSyncer.HealthSyncOutcome, Error>?

    /// The sync each live BGTask is running; an entry leaves the moment its task is completed.
    private var backgroundRuns: [ObjectIdentifier: Task<Void, Never>] = [:]
    /// Tasks whose expiry beat `handle` to the main actor, so `handle` knows not to start them.
    private var expiredBeforeStart: Set<ObjectIdentifier> = []

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "BGSync")

    private init() {}

    // MARK: - Setup

    /// Registers the BGTask handlers. Call once, from the launch path, before launch finishes.
    func register() {
        #if canImport(BackgroundTasks) && os(iOS)
        guard !didRegister else { return }
        didRegister = true
        registerTask(Self.processingTaskID)
        registerTask(Self.refreshTaskID)
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private func registerTask(_ identifier: String) {
        let ok = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            // The expiration handler goes on right here, on the scheduler's queue — not after the hop
            // to the main actor below. That hop can lag by seconds on a freshly resumed app (6 s on
            // hardware, 2026-09-11), and a task that expires with no handler is completed as failed by
            // iOS, which then schedules the app less often.
            task.expirationHandler = { Task { @MainActor in self?.expire(task) } }
            Task { @MainActor in self?.handle(task) }
        }
        log.info("BGTask register \(ok ? "succeeded" : "failed") for \(identifier)")
    }
    #endif

    /// Wires the live dependencies. Called from the UI setup path once the objects exist.
    func configure(manager: BandManager, syncer: BandSyncer) {
        self.manager = manager
        self.syncer = syncer
    }

    // MARK: - Scheduling

    /// Queues both background tasks. Safe to call repeatedly — the scheduler keeps only the latest
    /// pending request per identifier. No-op if no device is paired yet.
    func scheduleNext() {
        #if canImport(BackgroundTasks) && os(iOS)
        guard syncer?.currentDevice != nil else {
            log.debug("No paired device — skipping BGTask schedule")
            return
        }
        submitProcessing()
        submitRefresh()
        #endif
    }

    #if canImport(BackgroundTasks) && os(iOS)
    private func submitProcessing() {
        let request = BGProcessingTaskRequest(identifier: Self.processingTaskID)
        request.requiresNetworkConnectivity = false   // BLE + HealthKit are local
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: minInterval)
        submit(request)
    }

    private func submitRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: minInterval)
        submit(request)
    }

    private func submit(_ request: BGTaskRequest) {
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Scheduled \(request.identifier) (≥\(Int(self.minInterval / 60)) min)")
        } catch {
            log.error("Failed to schedule \(request.identifier): \(error.localizedDescription)")
        }
    }

    // MARK: - Execution

    private func handle(_ task: BGTask) {
        let key = ObjectIdentifier(task)
        // Expired before the main actor got to it — expire(_:) has already completed it.
        if expiredBeforeStart.remove(key) != nil { return }

        log.info("Background task started: \(task.identifier)")
        // Always queue the next run first, so a failure here doesn't break the chain.
        scheduleNext()

        backgroundRuns[key] = Task { @MainActor in
            do {
                _ = try await syncNow()
                log.info("Background sync completed")
                finish(task, success: true)
            } catch is CancellationError {
                finish(task, success: false)
            } catch {
                log.error("Background sync failed: \(error.localizedDescription)")
                finish(task, success: false)
            }
        }
    }

    private func expire(_ task: BGTask) {
        let key = ObjectIdentifier(task)
        log.warning("Background task expired — tearing down")
        guard let work = backgroundRuns[key] else {
            expiredBeforeStart.insert(key)
            task.setTaskCompleted(success: false)
            return
        }
        work.cancel()
        // Release the link but keep auto-reconnect, so the band can wake us again later.
        manager?.disconnect(userInitiated: false)
        // Completed now, not when the sync finally unwinds: past expiry iOS expects it at once.
        finish(task, success: false)
    }

    /// Completes the task exactly once, whichever of the sync and the expiry gets there first.
    private func finish(_ task: BGTask, success: Bool) {
        guard backgroundRuns.removeValue(forKey: ObjectIdentifier(task)) != nil else { return }
        task.setTaskCompleted(success: success)
    }
    #endif

    // MARK: - Sync (coalesced)

    /// Foreground-aware sync. Concurrent callers share a single run.
    /// `disconnectWhenDone`: nil = disconnect only if we opened the link (live foreground links stay
    /// up); true/false force the behaviour (background wakes pass true to free the radio).
    @discardableResult
    func syncNow(disconnectWhenDone: Bool? = nil) async throws -> BandSyncer.HealthSyncOutcome {
        if let inFlight {
            log.debug("Sync already in flight — coalescing")
            return try await inFlight.value
        }
        let task = Task { @MainActor in try await self.performSync(disconnectWhenDone: disconnectWhenDone) }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    private func performSync(disconnectWhenDone: Bool?) async throws -> BandSyncer.HealthSyncOutcome {
        // On a cold launch triggered by a task, the UI .onAppear may not have wired deps yet.
        try await awaitDependencies()
        guard let manager, let syncer, let id = syncer.currentDevice?.peripheralIdentifier else {
            throw SyncError.noDeviceRecord
        }

        // A link mid-handshake (the band re-deriving keys) was already up — this sync didn't open it,
        // so it mustn't be the one to drop it.
        let wasConnected = manager.connectionState.isConnected || manager.connectionState.isAuthInProgress
        if !manager.connectionState.isConnected { try await manager.ensureConnected(identifier: id) }

        let shouldDisconnect = disconnectWhenDone ?? !wasConnected
        // userInitiated: false — releasing the active link must NOT stop auto-reconnect, or the band
        // could never wake us again. BandManager re-arms a standing connect on the resulting drop.
        defer { if shouldDisconnect { manager.disconnect(userInitiated: false) } }
        return try await syncer.syncToHealth()
    }

    /// Called when the band authenticates while the app is in the background — e.g. CoreBluetooth
    /// state restoration relaunched us because the band came back in range. Without this, such a
    /// wake-up would connect but never sync. Throttled and best-effort.
    func syncOnBackgroundWakeIfStale() {
        #if canImport(UIKit)
        guard UIApplication.shared.applicationState == .background else { return }
        #endif
        if let last = syncer?.lastHealthSync, Date().timeIntervalSince(last) < autoSyncStaleness {
            log.debug("Background wake — Health synced recently, skipping")
            return
        }
        let assertion = beginAssertion(name: "bg-wake-sync")
        Task { @MainActor in
            defer { endAssertion(assertion) }
            do {
                // Keep the link up (disconnectWhenDone: false): the band just reached us, so holding
                // the connection is what gives constant background communication (push events: find
                // phone, workout, weather). A later drop re-arms a standing connect on its own.
                let outcome = try await syncNow(disconnectWhenDone: false)
                log.info("Background-wake sync done — \(outcome.healthSamplesWritten) samples")
            } catch {
                log.error("Background-wake sync failed: \(error.localizedDescription)")
            }
        }
    }

    /// Waits up to a few seconds for configure() to run on a cold, task-triggered launch.
    private func awaitDependencies() async throws {
        for _ in 0..<20 {
            if manager != nil, syncer != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SyncError.noDeviceRecord
    }

    // MARK: - Background task assertion

    #if canImport(UIKit)
    private func beginAssertion(name: String) -> UIBackgroundTaskIdentifier {
        UIApplication.shared.beginBackgroundTask(withName: name)
    }
    private func endAssertion(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
    #else
    private func beginAssertion(name: String) -> Int { 0 }
    private func endAssertion(_ id: Int) {}
    #endif
}
