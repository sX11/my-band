import Testing
import Foundation
import HealthKit
@testable import My_Band

@MainActor
struct StrengthWorkoutExtrasTests {

    private let start = 1_750_000_000

    private func workout(_ kind: WorkoutKind, start: Int) -> WorkoutSummary {
        WorkoutSummary(kind: kind,
                       startDate: Date(timeIntervalSince1970: TimeInterval(start)),
                       endDate: Date(timeIntervalSince1970: TimeInterval(start + 1800)),
                       rawDataHash: start)
    }

    private func track(_ points: Int, from start: Int) -> [WorkoutTrackPoint] {
        (0 ..< points).map { i in
            WorkoutTrackPoint(date: Date(timeIntervalSince1970: TimeInterval(start + i * 600)),
                              latitude: -25.39, longitude: -51.46, hdop: nil, speed: nil)
        }
    }

    private func hr(_ second: Int, _ bpm: Int) -> WorkoutHRSample {
        WorkoutHRSample(date: Date(timeIntervalSince1970: TimeInterval(second)), bpm: bpm)
    }

    // MARK: Strength route

    @Test func strengthWorkoutWithoutABandTrackGetsThePhoneTrackUnderItsOwnStart() throws {
        let stash = [start + 4: track(3, from: start + 4)]
        let picked = StrengthWorkoutExtras.phoneRoutes(stash, for: [workout(.strengthTraining, start: start)], bandRoutes: [:])
        let route = try #require(picked[start])
        #expect(route.stashKey == start + 4)
        #expect(route.track.count == 3)
    }

    @Test func aBandTrackWinsOverThePhoneTrack() {
        let stash = [start + 4: track(3, from: start + 4)]
        let picked = StrengthWorkoutExtras.phoneRoutes(stash, for: [workout(.strengthTraining, start: start)],
                                                       bandRoutes: [start + 1: track(2, from: start)])
        #expect(picked.isEmpty)
    }

    @Test func onlyAStrengthWorkoutWithinTwoMinutesTakesAPhoneTrackOfTwoPointsOrMore() {
        let picked = StrengthWorkoutExtras.phoneRoutes(
            [start: track(3, from: start), start + 10_000: track(1, from: start + 10_000), start + 20_200: track(3, from: start + 20_200)],
            for: [workout(.running, start: start), workout(.strengthTraining, start: start + 10_000),
                  workout(.strengthTraining, start: start + 20_000)],
            bandRoutes: [:])
        #expect(picked.isEmpty)
    }

    @Test func onePhoneTrackGoesOntoOneWorkout() {
        let picked = StrengthWorkoutExtras.phoneRoutes([start: track(3, from: start)],
                                                       for: [workout(.strengthTraining, start: start - 30),
                                                             workout(.strengthTraining, start: start + 60)],
                                                       bandRoutes: [:])
        #expect(picked.count == 1)
    }

    @Test func stashEntriesOlderThanTheKeepPeriodAreDropped() {
        let now = Date(timeIntervalSince1970: TimeInterval(start))
        let old = start - Int(StrengthWorkoutExtras.keep) - 60
        let kept = StrengthWorkoutExtras.pruned([old: 1, start - 3600: 2], now: now)
        #expect(kept == [start - 3600: 2])
    }

    // MARK: Recovery pairing

    private var soon: Date { Date(timeIntervalSince1970: TimeInterval(start + 2000)) }

    @Test func recoveryAfterItsWorkoutLinksToThatWorkout() {
        var pairing = RecoveryPairing<String>()
        #expect(pairing.workoutSaved(start: start, "strength", now: soon) == nil)
        #expect(pairing.recoveryRecorded(strengthStart: start + 5, [hr(start + 1900, 120)], now: soon) == "strength")
        #expect(pairing.heldCount == 0)
    }

    @Test func recoveryBeforeItsWorkoutIsHeldAndReleasedOnceWhenTheWorkoutIsSaved() {
        var pairing = RecoveryPairing<String>()
        #expect(pairing.recoveryRecorded(strengthStart: start + 5, [hr(start + 1900, 120), hr(start + 1901, 118)], now: soon) == nil)
        #expect(pairing.heldCount == 1)
        let released = pairing.workoutSaved(start: start, "strength", now: soon)
        #expect(released?.map(\.bpm) == [120, 118])
        #expect(pairing.workoutSaved(start: start, "strength", now: soon) == nil)
        #expect(pairing.heldCount == 0)
    }

    @Test func recoveryIsNotLinkedToAWorkoutMoreThanTwoMinutesAway() {
        var pairing = RecoveryPairing<String>()
        _ = pairing.workoutSaved(start: start, "other", now: soon)
        #expect(pairing.recoveryRecorded(strengthStart: start + 600, [hr(start + 2400, 120)], now: soon) == nil)
        #expect(pairing.heldCount == 1)
    }

    @Test func heldRecoveryAgesOut() {
        var pairing = RecoveryPairing<String>()
        _ = pairing.recoveryRecorded(strengthStart: start, [hr(start + 1900, 120)], now: soon)
        let later = soon.addingTimeInterval(StrengthWorkoutExtras.keep)
        #expect(pairing.workoutSaved(start: start, "strength", now: later) == nil)
        #expect(pairing.heldCount == 0)
    }

    @Test func resetForgetsHeldRecoveryAndSavedWorkouts() {
        var pairing = RecoveryPairing<String>()
        _ = pairing.recoveryRecorded(strengthStart: start, [hr(start + 1900, 120)], now: soon)
        _ = pairing.workoutSaved(start: start + 10_000, "later", now: soon)
        pairing.reset()
        #expect(pairing.heldCount == 0)
        #expect(pairing.workoutSaved(start: start, "strength", now: soon) == nil)
        #expect(pairing.recoveryRecorded(strengthStart: start + 10_000, [hr(start + 11_900, 120)], now: soon) == nil)
    }

    // MARK: Recovery samples

    private func syncIds(_ samples: [HKQuantitySample]) -> [String] {
        samples.compactMap { $0.metadata?[HKMetadataKeySyncIdentifier] as? String }
    }

    @Test func recoverySampleIdsAreStableAcrossWrites() {
        let capture = [hr(start, 130), hr(start + 1, 128)]
        let now = Date(timeIntervalSince1970: TimeInterval(start + 200))
        let first = HealthKitManager.shared.recoverySamples(capture, now: now)
        let again = HealthKitManager.shared.recoverySamples(capture, now: now)
        #expect(syncIds(first) == ["mb-recovery-\(start)", "mb-recovery-\(start + 1)"])
        #expect(syncIds(again) == syncIds(first))
    }

    @Test func recoverySamplesKeepOneReadingPerSecondAndOnlyValidDates() {
        let capture = [hr(start, 130), hr(start, 131), hr(0, 90)]
        let samples = HealthKitManager.shared.recoverySamples(capture, now: Date(timeIntervalSince1970: TimeInterval(start + 200)))
        #expect(syncIds(samples) == ["mb-recovery-\(start)"])
        #expect(samples.first?.quantity.doubleValue(for: .count().unitDivided(by: .minute())) == 131)
    }
}
