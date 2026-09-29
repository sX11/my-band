import ActivityKit
import Foundation

// MARK: - WorkoutActivityAttributes
//
// The live workout's Lock Screen / Dynamic Island activity (ADR 0008). Compiled into both the app,
// which starts and updates it, and MyBandWidgets, which draws it. `nonisolated` because the app
// target defaults to MainActor isolation and ActivityKit encodes the state off the main actor.

nonisolated struct WorkoutActivityAttributes: ActivityAttributes {

    nonisolated struct ContentState: Codable, Hashable {
        var paused: Bool
        /// The start shifted by the time spent paused, so a running clock is simply now − clockStart
        /// and the widget can draw it with a self-updating timer instead of a push per second.
        var clockStart: Date
        /// The elapsed time frozen at the pause.
        var pausedElapsed: TimeInterval
        var heartRate: Int?
        var distanceMeters: Double?
        var steps: Int?
        var calories: Int?
    }

    var sportTitle: String
    var sportSymbol: String
}
