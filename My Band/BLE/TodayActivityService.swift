import Foundation
import OSLog

// MARK: - TodayActivityService
//
// Today's steps and calories plus a current heart rate, for the Dashboard. Read as
// a one-shot from the realtime stats stream (as GadgetBridge's realtimeOneShot does): START, take
// events until one carries a real heart rate, STOP. Leaving the stream on keeps the band measuring
// heart rate continuously, which costs battery.
//
// The stream's standingHours field reads 0 on a Band 10 that counts stand hours on its own screen, so
// stood hours come from the daily summary instead (LatestMetrics).

@Observable
@MainActor
final class TodayActivityService {

    private(set) var steps: Int?
    private(set) var calories: Int?
    private(set) var heartRate: Int?
    private(set) var updatedAt: Date?
    private(set) var reading = false

    private weak var bandManager: BandManager?
    private var timeout: Task<Void, Never>?
    private var loggedRaw = false
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "TodayActivity")

    /// The band needs a few seconds to lock onto a pulse; past this the reading keeps what it has.
    private static let readingWindow: Duration = .seconds(30)

    func setup(manager: BandManager) {
        bandManager = manager
        manager.observeRealtime { [weak self] stats in
            Task { @MainActor in self?.ingest(stats) }
        }
    }

    /// Forget / re-pair: the numbers belonged to the old band.
    func reset() {
        finish()
        steps = nil
        calories = nil
        heartRate = nil
        updatedAt = nil
    }

    /// Restarts a reading already under way: after a reconnect the new link has no stream yet.
    func refresh() {
        guard let bandManager else { return }
        timeout?.cancel()
        reading = true
        heartRate = nil
        loggedRaw = false
        bandManager.setRealtimeStats(enabled: true, holder: .todayActivity)
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.readingWindow)
            guard !Task.isCancelled else { return }
            self?.log.info("No heart rate within the reading window — keeping the activity totals")
            self?.finish()
        }
    }

    private func ingest(_ stats: Xiaomi_RealTimeStats) {
        // Recovery capture shares the stream; only a reading this service started updates the tile.
        guard reading else { return }
        if stats.hasSteps { steps = Int(stats.steps) }
        if stats.hasCalories { calories = Int(stats.calories) }
        if !loggedRaw {
            loggedRaw = true
            // Fields 3, 5 and 6 are unmapped for this band; the raw values are the evidence for mapping them.
            log.info("Realtime raw: steps=\(stats.steps, privacy: .public) kcal=\(stats.calories, privacy: .public) f3=\(stats.unknown3, privacy: .public) hr=\(stats.heartRate, privacy: .public) f5=\(stats.unknown5, privacy: .public) f6=\(stats.hasStandingHours ? String(stats.standingHours) : "-", privacy: .public)")
        }
        updatedAt = .now
        // GadgetBridge's one-shot threshold: at or below 10 the band hasn't measured yet.
        if stats.hasHeartRate, stats.heartRate > 10 {
            heartRate = Int(stats.heartRate)
            finish()
        }
    }

    /// Also called when the link drops, so the tile stops claiming a reading is under way.
    func finish() {
        timeout?.cancel()
        timeout = nil
        guard reading else { return }
        reading = false
        bandManager?.setRealtimeStats(enabled: false, holder: .todayActivity)
    }
}
