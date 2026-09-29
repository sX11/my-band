import CoreLocation
import Foundation
import OSLog

// MARK: - WorkoutLiveService
//
// The workout running on the band right now, for the Dashboard's workout card (ADR 0008). The band
// announces it (workoutStatusWatch, 8/26); heart rate, steps and calories come from the realtime
// stream held for the workout's duration, distance from the phone GPS fixes streamed to the band.
// In memory only: the workout reaches Apple Health from the band's own file after it ends.
//
// There is no command to ask the band whether a workout is running, so one started while the app was
// not connected stays unknown until its next pause/resume. A dropped link keeps the session, because
// the app drops links on purpose too, but only for `linkGrace`: a finish sent into the gap is lost.

@Observable
@MainActor
final class WorkoutLiveService {

    enum State: Equatable { case running, paused }

    struct Workout: Equatable {
        let sport: UInt32
        var startedAt: Date
        var state: State = .running
        /// The app saw the workout only after it started, so steps and kcal miss its beginning.
        var joinedLate = false
        var pausedTotal: TimeInterval = 0
        var pausedAt: Date?
        var heartRate: Int?
        var steps: Int?
        var calories: Int?
        var distanceMeters: Double?
        /// Time between the fixes counted into `distanceMeters`: pace divided by elapsed time would
        /// include GPS lock-on and everything before a late join.
        var movingSeconds: TimeInterval = 0

        var kind: WorkoutKind? { WorkoutSummaryParser.workoutKind(fromCode: Int(sport)) }

        func elapsed(at now: Date) -> TimeInterval {
            let paused = pausedTotal + (pausedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0)
            return max(0, now.timeIntervalSince(startedAt) - paused)
        }
    }

    private(set) var current: Workout? {
        didSet { if current != oldValue { onChange?(current) } }
    }

    /// Every change to `current`, for the Live Activity; the UI observes `current` directly.
    var onChange: ((Workout?) -> Void)?

    private weak var bandManager: BandManager?
    private var steps = DailyCounterDelta()
    private var calories = DailyCounterDelta()
    private var lastFix: CLLocation?
    private var linkGraceTimer: Task<Void, Never>?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "WorkoutLive")

    /// Coarser fixes jitter by tens of metres and would add distance while standing still.
    private static let maxFixAccuracy: CLLocationAccuracy = 30
    /// A status message stamped this long before it arrived means the workout began without us.
    private static let lateJoinSlack: TimeInterval = 60
    private static let linkGrace: Duration = .seconds(10 * 60)

    func setup(manager: BandManager) {
        bandManager = manager
        manager.observeWorkoutStatus { [weak self] watch in
            Task { @MainActor in
                self?.ingest(status: watch.status, sport: watch.hasSport ? watch.sport : nil,
                             timestamp: watch.hasTimestamp ? watch.timestamp : nil)
            }
        }
        manager.observeRealtime { [weak self] stats in
            Task { @MainActor in self?.ingest(realtime: stats) }
        }
        manager.observeLinkLost { [weak self] in
            Task { @MainActor in self?.linkLost() }
        }
        manager.observeAuthenticated { [weak self] in
            Task { @MainActor in self?.linkRestored() }
        }
    }

    /// Forget / re-pair: the workout belonged to the old band.
    func reset() {
        endSession(reason: "reset")
    }

    // MARK: Ingest

    func ingest(status: UInt32, sport: UInt32?, timestamp: UInt32?, now: Date = .now) {
        // Whether the timestamp is the workout's start or the event's own time is unconfirmed; the raw
        // value is logged per status so a hardware run can settle it.
        log.info("Workout status \(status) sport=\(sport.map(String.init) ?? "-", privacy: .public) ts=\(timestamp.map(String.init) ?? "-", privacy: .public)")
        let stamped = timestamp.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }

        switch status {
        case 0, 1:
            // A fresh start replaces whatever is held: a finish missed during a drop can't leave the
            // old workout's clock and counters running into the new one.
            if status == 0 { endSession(reason: "new workout") }
            if var w = current {
                if let pausedAt = w.pausedAt { w.pausedTotal += max(0, now.timeIntervalSince(pausedAt)) }
                w.pausedAt = nil
                w.state = .running
                current = w
            } else if status == 0 {
                // Seen live by definition, so `now` wins over a stamp that may be the open, not the start.
                let start = stamped.flatMap { abs(now.timeIntervalSince($0)) <= Self.lateJoinSlack ? $0 : nil } ?? now
                begin(sport: sport, startedAt: start, joinedLate: false, now: now)
            } else {
                begin(sport: sport, startedAt: stamped ?? now, joinedLate: true, now: now)
            }
            lastFix = nil
        case 2:
            if current == nil { begin(sport: sport, startedAt: stamped ?? now, joinedLate: true, now: now) }
            guard var w = current, w.state == .running else { return }
            w.state = .paused
            w.pausedAt = now
            current = w
            // The GPS stream stops while paused; the first fix after resuming must not bridge the gap.
            lastFix = nil
        case 3:
            endSession(reason: "finished")
        default:
            break
        }
    }

    private func begin(sport: UInt32?, startedAt: Date, joinedLate late: Bool, now: Date) {
        current = Workout(sport: sport ?? 0, startedAt: min(startedAt, now), joinedLate: late)
        steps = DailyCounterDelta()
        calories = DailyCounterDelta()
        lastFix = nil
        bandManager?.setRealtimeStats(enabled: true, holder: .workout)
        log.info("Workout live: sport=\(self.current?.sport ?? 0) joinedLate=\(late)")
    }

    /// `releaseStream: false` once the link is gone: its holders are already cleared, and a STOP on a
    /// keyless link only logs a misleading "handshake in flight".
    private func endSession(reason: String, releaseStream: Bool = true) {
        linkGraceTimer?.cancel()
        linkGraceTimer = nil
        guard current != nil else { return }
        current = nil
        lastFix = nil
        if releaseStream { bandManager?.setRealtimeStats(enabled: false, holder: .workout) }
        log.info("Workout live ended (\(reason, privacy: .public))")
    }

    private func linkLost() {
        guard current != nil, linkGraceTimer == nil else { return }
        log.info("Workout live: link lost — holding the session")
        linkGraceTimer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.linkGrace)
            guard !Task.isCancelled else { return }
            self?.endSession(reason: "link lost too long", releaseStream: false)
        }
    }

    /// Every handshake, the band's post-init restart included, so the START lands on the live keys.
    private func linkRestored() {
        linkGraceTimer?.cancel()
        linkGraceTimer = nil
        guard current != nil else { return }
        bandManager?.setRealtimeStats(enabled: true, holder: .workout)
    }

    func ingest(realtime stats: Xiaomi_RealTimeStats, now: Date = .now) {
        guard var w = current else { return }
        if stats.hasSteps { w.steps = steps.update(Int(stats.steps), at: now) }
        if stats.hasCalories { w.calories = calories.update(Int(stats.calories), at: now) }
        // GadgetBridge's one-shot threshold: at or below 10 the band hasn't measured yet.
        if stats.hasHeartRate, stats.heartRate > 10 { w.heartRate = Int(stats.heartRate) }
        current = w
    }

    func ingest(fix: CLLocation) {
        guard var w = current, w.state == .running,
              fix.horizontalAccuracy >= 0, fix.horizontalAccuracy <= Self.maxFixAccuracy else { return }
        if let lastFix {
            w.distanceMeters = (w.distanceMeters ?? 0) + fix.distance(from: lastFix)
            w.movingSeconds += max(0, fix.timestamp.timeIntervalSince(lastFix.timestamp))
        } else if w.distanceMeters == nil {
            w.distanceMeters = 0
        }
        lastFix = fix
        current = w
    }
}

// MARK: - DailyCounterDelta
//
// The realtime stream reports today's running totals; a workout wants the part counted since it
// began. A total that drops on a new day is the band's midnight rollover; one that drops within the
// same day is a bad reading, and taking it as a rollover would add the whole day to the workout.

struct DailyCounterDelta {
    private var baseline: Int?
    private var carried = 0
    private var last = 0
    private var lastAt = Date.distantPast

    mutating func update(_ total: Int, at date: Date) -> Int {
        guard let base = baseline else {
            baseline = total
            last = total
            lastAt = date
            return 0
        }
        if total < last {
            guard !Calendar.current.isDate(date, inSameDayAs: lastAt) else { return carried + last - base }
            carried += last - base
            baseline = 0
        }
        last = total
        lastAt = date
        return carried + total - (baseline ?? 0)
    }
}
