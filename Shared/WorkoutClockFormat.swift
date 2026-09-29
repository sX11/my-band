import Foundation

// One format for the app and the Live Activity. Minutes are unpadded to match the widget's running
// `Text(timerInterval:)`, which iOS renders as 5:30, so the clock doesn't change shape when paused.

nonisolated enum WorkoutClockFormat {
    static func string(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
