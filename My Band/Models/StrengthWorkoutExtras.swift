import Foundation

// MARK: - StrengthWorkoutExtras
//
// The phone's strength-workout route and post-workout heart rate (`WorkoutGpsService`), keyed by the
// app-side start: seconds off the band's session start, so matched within the same two minutes as
// the band's own GPS track (`HealthKitManager.route(forWorkoutStart:in:)`).

enum StrengthWorkoutExtras {

    static let matchWindow = 120
    /// In-memory only, so this bounds a stash whose workout never arrives, not what survives a relaunch.
    static let keep: TimeInterval = 48 * 3600

    static func nearest<Value>(to key: Int, in entries: [Int: Value]) -> (key: Int, value: Value)? {
        entries
            .filter { abs($0.key - key) <= matchWindow }
            .min { abs($0.key - key) < abs($1.key - key) }
            .map { ($0.key, $0.value) }
    }

    /// The phone's track for each strength workout in the batch whose band files carried none, keyed
    /// by the workout's own start. `stashKey` names the stash entry it came from.
    static func phoneRoutes(_ stashed: [Int: [WorkoutTrackPoint]],
                            for workouts: [WorkoutSummary],
                            bandRoutes: [Int: [WorkoutTrackPoint]]) -> [Int: (stashKey: Int, track: [WorkoutTrackPoint])] {
        var unused = stashed
        var picked: [Int: (stashKey: Int, track: [WorkoutTrackPoint])] = [:]
        for workout in workouts where workout.kind == .strengthTraining {
            let key = Int(workout.startDate.timeIntervalSince1970)
            guard nearest(to: key, in: bandRoutes) == nil,
                  let match = nearest(to: key, in: unused), match.value.count >= 2 else { continue }
            unused[match.key] = nil
            picked[key] = (match.key, match.value)
        }
        return picked
    }

    static func pruned<Value>(_ entries: [Int: Value], now: Date = .now) -> [Int: Value] {
        let oldest = Int(now.addingTimeInterval(-keep).timeIntervalSince1970)
        return entries.filter { $0.key >= oldest }
    }
}

// MARK: - RecoveryPairing
//
// Pairs the post-workout heart rate with its strength workout, whichever reaches the app first. The
// samples are saved to Apple Health on arrival, so an entry that ages out loses only the link.

struct RecoveryPairing<Workout> {

    private var workouts: [Int: Workout] = [:]
    private var held: [Int: [WorkoutHRSample]] = [:]

    var heldCount: Int { held.count }

    /// The workout these samples follow, or nil, and then they are held for `workoutSaved`.
    mutating func recoveryRecorded(strengthStart: Int, _ samples: [WorkoutHRSample], now: Date = .now) -> Workout? {
        prune(now)
        if let match = StrengthWorkoutExtras.nearest(to: strengthStart, in: workouts) {
            workouts[match.key] = nil
            return match.value
        }
        held[strengthStart] = samples
        return nil
    }

    /// The held samples that follow this workout, released once.
    mutating func workoutSaved(start: Int, _ workout: Workout, now: Date = .now) -> [WorkoutHRSample]? {
        prune(now)
        guard let match = StrengthWorkoutExtras.nearest(to: start, in: held) else {
            workouts[start] = workout
            return nil
        }
        held[match.key] = nil
        return match.value
    }

    mutating func reset() {
        workouts = [:]
        held = [:]
    }

    private mutating func prune(_ now: Date) {
        workouts = StrengthWorkoutExtras.pruned(workouts, now: now)
        held = StrengthWorkoutExtras.pruned(held, now: now)
    }
}
