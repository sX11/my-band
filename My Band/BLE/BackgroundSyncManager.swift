import Foundation
import OSLog

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

// MARK: - BackgroundSyncManager
//
// Drives an unattended Apple Health sync while the app is suspended.
//
// On iOS the OS relaunches the app for a registered BGProcessingTask. The handler reconnects to
// the known band (no scan — direct retrieve + auto-connect via CoreBluetooth's bluetooth-central
// background mode), runs a full health sync, then reschedules the next run. The task is also
// scheduled whenever the app moves to the background so a pending request always exists.
//
// IMPORTANT: BGTaskScheduler.register MUST be called before the app finishes launching, which is
// why register() runs from the AppDelegate's didFinishLaunching — not from a SwiftUI .onAppear.
// The BandManager/BandSyncer dependencies are wired later (configure), so the handler waits for
// them on a cold launch triggered by the task itself.

@MainActor
final class BackgroundSyncManager {

    static let shared = BackgroundSyncManager()

    /// Must match the identifier in Info.plist → BGTaskSchedulerPermittedIdentifiers.
    static let taskIdentifier = "com.myband.sync"

    /// Minimum spacing between background syncs. The OS treats this as a floor, not a guarantee.
    private let minInterval: TimeInterval = 30 * 60

    private weak var manager: BandManager?
    private weak var syncer: BandSyncer?
    private var didRegister = false

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "BGSync")

    private init() {}

    // MARK: - Setup

    /// Registers the BGTask handler. Call once, from the app's launch path, before launch finishes.
    func register() {
        #if canImport(BackgroundTasks) && os(iOS)
        guard !didRegister else { return }
        didRegister = true
        let ok = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            // BGTaskScheduler delivers on a background queue; hop to the main actor (BandManager
            // is @MainActor and its CB callbacks run on .main).
            guard let processingTask = task as? BGProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor in self?.handle(processingTask) }
        }
        log.info("BGTask register \(ok ? "succeeded" : "failed") for \(Self.taskIdentifier)")
        #endif
    }

    /// Wires the live dependencies. Called from the UI setup path once the objects exist.
    func configure(manager: BandManager, syncer: BandSyncer) {
        self.manager = manager
        self.syncer = syncer
    }

    // MARK: - Scheduling

    /// Submits a request for the next background sync. Safe to call repeatedly — the scheduler
    /// keeps only the latest pending request per identifier. No-op if no device is paired yet.
    func scheduleNext() {
        #if canImport(BackgroundTasks) && os(iOS)
        guard syncer?.currentDevice != nil else {
            log.debug("No paired device — skipping BGTask schedule")
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
        request.requiresNetworkConnectivity = false   // BLE + HealthKit are local
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: minInterval)
        do {
            try BGTaskScheduler.shared.submit(request)
            log.info("Scheduled next background sync (≥\(Int(self.minInterval / 60)) min)")
        } catch {
            log.error("Failed to schedule BGTask: \(error.localizedDescription)")
        }
        #endif
    }

    // MARK: - Execution

    #if canImport(BackgroundTasks) && os(iOS)
    private func handle(_ task: BGProcessingTask) {
        log.info("Background sync task started")
        // Always queue the next run first, so a failure here doesn't break the chain.
        scheduleNext()

        let work = Task { @MainActor in
            do {
                try await runSync()
                log.info("Background sync completed")
                task.setTaskCompleted(success: true)
            } catch is CancellationError {
                task.setTaskCompleted(success: false)
            } catch {
                log.error("Background sync failed: \(error.localizedDescription)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = { [weak self] in
            self?.log.warning("Background sync expired — tearing down")
            work.cancel()
            self?.manager?.disconnect()
        }
    }
    #endif

    /// Connects to the paired band and runs a full Apple Health sync. Disconnects when done so the
    /// app doesn't hold the BLE link open in the background longer than needed.
    func runSync() async throws {
        // On a cold launch triggered by the task, the UI .onAppear may not have wired deps yet.
        try await awaitDependencies()
        guard let manager, let syncer, let id = syncer.currentDevice?.peripheralIdentifier else {
            throw SyncError.noDeviceRecord
        }

        try await manager.ensureConnected(identifier: id)
        defer { manager.disconnect() }
        try await syncer.syncToHealth()
    }

    /// On-demand sync entry point for the App Intent / Shortcuts trigger. Foreground-aware: if the
    /// band is already connected (e.g. the app is open) it syncs over the live link without tearing
    /// it down; otherwise it connects, syncs, and disconnects like the background path.
    @discardableResult
    func syncNow() async throws -> BandSyncer.HealthSyncOutcome {
        try await awaitDependencies()
        guard let manager, let syncer, let id = syncer.currentDevice?.peripheralIdentifier else {
            throw SyncError.noDeviceRecord
        }
        if manager.connectionState.isConnected {
            return try await syncer.syncToHealth()
        }
        try await manager.ensureConnected(identifier: id)
        defer { manager.disconnect() }
        return try await syncer.syncToHealth()
    }

    /// Waits up to a few seconds for configure() to run on a cold, task-triggered launch.
    private func awaitDependencies() async throws {
        for _ in 0..<20 {
            if manager != nil, syncer != nil { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw SyncError.noDeviceRecord
    }
}
