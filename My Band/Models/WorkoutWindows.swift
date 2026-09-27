import Foundation

// MARK: - WorkoutWindows
//
// When the workouts written to Apple Health ran, so a daily-details file fetched by a later sync
// can still leave out the distance and energy those workouts already carry. Kept across a band
// forget: the workouts stay in Apple Health.

struct WorkoutWindows {

    struct Window: Codable, Equatable {
        var start: Date
        var end: Date
    }

    private let defaults: UserDefaults
    private static let key = "recentWorkoutWindowsV1"
    /// The band re-offers an un-ACKed daily-details file for days; a workout older than this has no
    /// file left that could still cover it.
    static let keep: TimeInterval = 30 * 86_400

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func all(now: Date = .now) -> [Window] {
        let stored = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([Window].self, from: $0) } ?? []
        return stored.filter { now.timeIntervalSince($0.end) < Self.keep }
    }

    func record(_ windows: [Window], now: Date = .now) {
        guard !windows.isEmpty else { return }
        var merged = all(now: now)
        for w in windows where !merged.contains(w) { merged.append(w) }
        if let data = try? JSONEncoder().encode(merged) { defaults.set(data, forKey: Self.key) }
    }
}
