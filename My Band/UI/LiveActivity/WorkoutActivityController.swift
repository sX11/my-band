import ActivityKit
import Foundation
import OSLog
import UserNotifications

// MARK: - WorkoutActivityController
//
// Mirrors WorkoutLiveService onto a Lock Screen / Dynamic Island Live Activity (ADR 0008).
//
// iOS starts a Live Activity only while the app is in the foreground, and a band workout usually
// begins with the phone locked in a pocket. So a request that fails is kept pending, a notification
// asks to open the app, and the next foreground (`retryIfNeeded`) starts it. Once running it updates
// from the background freely.

@MainActor
final class WorkoutActivityController {

    private weak var live: WorkoutLiveService?
    private var activity: Activity<WorkoutActivityAttributes>?
    private var lastState: WorkoutActivityAttributes.ContentState?
    private var lastPush = Date.distantPast
    /// Updates arrive at ~1 Hz; one refused request per workout is enough, the foreground retries.
    private var startAttempted = false
    private var notifiedPending = false
    private var trailingPush: Task<Void, Never>?
    private var keepalive: Task<Void, Never>?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "WorkoutActivity")

    /// The clock draws itself; pushes only carry the numbers, which don't need more than this.
    private static let minPushInterval: TimeInterval = 5
    /// Past this without a push the widget shows "Not updating": the app was killed or suspended.
    private static let staleAfter: TimeInterval = 10 * 60
    /// Re-pushes an unchanged state (a long pause) so it doesn't go stale while the app is alive.
    private static let keepaliveInterval: Duration = .seconds(4 * 60)
    private static let notificationID = "workout-live-activity"

    func setup(live: WorkoutLiveService) {
        self.live = live
        live.onChange = { [weak self] workout in self?.update(workout) }
        // One left over from a crash or a kill would sit on the Lock Screen with a clock running forever.
        for stale in Activity<WorkoutActivityAttributes>.activities {
            Task { await stale.end(nil, dismissalPolicy: .immediate) }
        }
    }

    func retryIfNeeded() {
        guard activity == nil, let workout = live?.current else { return }
        start(workout)
    }

    private func update(_ workout: WorkoutLiveService.Workout?) {
        guard let workout else {
            end()
            return
        }
        guard activity != nil else {
            if !startAttempted { start(workout) }
            return
        }
        let state = Self.content(workout)
        guard state != lastState else { return }
        let wait = Self.minPushInterval - Date.now.timeIntervalSince(lastPush)
        if state.paused != lastState?.paused || wait <= 0 {
            push(state)
        } else if trailingPush == nil {
            // Without it, the last change before a quiet spell would never reach the Lock Screen.
            trailingPush = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, !Task.isCancelled else { return }
                self.trailingPush = nil
                if let current = self.live?.current { self.push(Self.content(current)) }
            }
        }
    }

    private func push(_ state: WorkoutActivityAttributes.ContentState) {
        guard let activity else { return }
        trailingPush?.cancel()
        trailingPush = nil
        lastState = state
        lastPush = .now
        Task { await activity.update(ActivityContent(state: state, staleDate: .now + Self.staleAfter)) }
    }

    private func start(_ workout: WorkoutLiveService.Workout) {
        startAttempted = true
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            log.info("Live Activities are off for My Band in Settings")
            return
        }
        let attributes = WorkoutActivityAttributes(sportTitle: workout.kind.title, sportSymbol: workout.kind.symbol)
        let state = Self.content(workout)
        do {
            activity = try Activity.request(attributes: attributes,
                                            content: ActivityContent(state: state, staleDate: .now + Self.staleAfter))
            lastState = state
            lastPush = .now
            notifiedPending = false
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
            keepalive = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.keepaliveInterval)
                    guard let self, !Task.isCancelled, let current = self.live?.current else { return }
                    self.push(Self.content(current))
                }
            }
            log.info("Workout Live Activity started")
        } catch {
            log.info("Workout Live Activity deferred until the app is in front: \(error.localizedDescription, privacy: .public)")
            notifyPending(sport: attributes.sportTitle)
        }
    }

    private func end() {
        activity = nil
        lastState = nil
        startAttempted = false
        notifiedPending = false
        trailingPush?.cancel()
        trailingPush = nil
        keepalive?.cancel()
        keepalive = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        // Every one, not just the tracked reference: a copy started around a relaunch would otherwise
        // stay on the Lock Screen with its timer still counting.
        let running = Activity<WorkoutActivityAttributes>.activities
        guard !running.isEmpty else { return }
        for activity in running {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
        log.info("Workout Live Activity ended (\(running.count))")
    }

    private func notifyPending(sport: String) {
        guard !notifiedPending else { return }
        notifiedPending = true
        let content = UNMutableNotificationContent()
        content.title = "\(sport) on the band"
        content.body = "Open My Band to follow it on the Lock Screen."
        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private static func content(_ w: WorkoutLiveService.Workout) -> WorkoutActivityAttributes.ContentState {
        // Built from fixed instants, not from now, so an unchanged workout yields an equal state.
        .init(paused: w.state == .paused,
              clockStart: w.startedAt.addingTimeInterval(w.pausedTotal),
              pausedElapsed: w.pausedAt.map { w.elapsed(at: $0) } ?? 0,
              heartRate: w.heartRate,
              distanceMeters: w.distanceMeters,
              steps: w.steps,
              calories: w.calories)
    }
}
