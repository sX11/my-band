import Testing
import Foundation
import CoreLocation
@testable import My_Band

@MainActor
struct WorkoutLiveTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func stats(steps: UInt32, kcal: UInt32, hr: UInt32 = 0) -> Xiaomi_RealTimeStats {
        var s = Xiaomi_RealTimeStats()
        s.steps = steps
        s.calories = kcal
        s.heartRate = hr
        return s
    }

    private func fix(_ lat: Double, accuracy: Double = 5, at seconds: TimeInterval = 0) -> CLLocation {
        CLLocation(coordinate: .init(latitude: lat, longitude: 0), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: 5, timestamp: t0 + seconds)
    }

    private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)) ?? .distantPast
    }

    @Test func counterDeltaStartsAtZeroAndCountsUp() {
        var d = DailyCounterDelta()
        #expect(d.update(4200, at: t0) == 0)
        #expect(d.update(4350, at: t0 + 60) == 150)
    }

    @Test func counterDeltaSurvivesMidnightRollover() {
        var d = DailyCounterDelta()
        _ = d.update(9000, at: day(2026, 9, 29, 23, 50))
        #expect(d.update(9100, at: day(2026, 9, 29, 23, 58)) == 100)
        #expect(d.update(40, at: day(2026, 9, 30, 0, 2)) == 140)
        #expect(d.update(90, at: day(2026, 9, 30, 0, 5)) == 190)
    }

    @Test func counterDeltaIgnoresSameDayDrop() {
        var d = DailyCounterDelta()
        _ = d.update(5000, at: day(2026, 9, 29, 10, 0))
        #expect(d.update(0, at: day(2026, 9, 29, 10, 1)) == 0)
        #expect(d.update(5010, at: day(2026, 9, 29, 10, 2)) == 10)
    }

    @Test func startedStatusBeginsRunningWorkoutWithSport() {
        let live = WorkoutLiveService()
        live.ingest(status: 0, sport: 1, timestamp: UInt32(t0.timeIntervalSince1970), now: t0)
        #expect(live.current?.state == .running)
        #expect(live.current?.kind == .running)
        #expect(live.current?.joinedLate == false)
    }

    @Test func elapsedExcludesPausedTime() {
        let live = WorkoutLiveService()
        live.ingest(status: 0, sport: 1, timestamp: UInt32(t0.timeIntervalSince1970), now: t0)
        live.ingest(status: 2, sport: 1, timestamp: nil, now: t0 + 600)
        #expect(live.current?.elapsed(at: t0 + 900) == 600)
        live.ingest(status: 1, sport: 1, timestamp: nil, now: t0 + 900)
        #expect(live.current?.elapsed(at: t0 + 1000) == 700)
    }

    @Test func startedStatusWithOldStampStartsNowAndIsNotLate() {
        let live = WorkoutLiveService()
        live.ingest(status: 0, sport: 1, timestamp: UInt32(t0.timeIntervalSince1970), now: t0 + 90)
        #expect(live.current?.joinedLate == false)
        #expect(live.current?.startedAt == t0 + 90)
    }

    @Test func finishedStatusClearsWorkout() {
        let live = WorkoutLiveService()
        live.ingest(status: 0, sport: 1, timestamp: nil, now: t0)
        live.ingest(status: 3, sport: 1, timestamp: nil, now: t0 + 60)
        #expect(live.current == nil)
    }

    @Test func statusSeenMidWorkoutIsMarkedJoinedLate() {
        let live = WorkoutLiveService()
        live.ingest(status: 1, sport: 6, timestamp: UInt32(t0.timeIntervalSince1970), now: t0 + 1200)
        #expect(live.current?.joinedLate == true)
        #expect(live.current?.elapsed(at: t0 + 1200) == 1200)
    }

    @Test func realtimeCountsFromWorkoutStart() {
        let live = WorkoutLiveService()
        live.ingest(status: 0, sport: 17, timestamp: nil, now: t0)
        live.ingest(realtime: stats(steps: 5000, kcal: 300, hr: 5), now: t0)
        live.ingest(realtime: stats(steps: 5600, kcal: 340, hr: 132), now: t0 + 300)
        #expect(live.current?.steps == 600)
        #expect(live.current?.calories == 40)
        #expect(live.current?.heartRate == 132)
    }

    @Test func distanceSkipsPausesAndInaccurateFixes() {
        let live = WorkoutLiveService()
        live.ingest(status: 0, sport: 1, timestamp: nil, now: t0)
        live.ingest(fix: fix(0))
        live.ingest(fix: fix(0.001))
        live.ingest(fix: fix(0.5, accuracy: 200))
        let beforePause = live.current?.distanceMeters ?? 0
        #expect(abs(beforePause - 110.6) < 1)
        live.ingest(status: 2, sport: 1, timestamp: nil, now: t0 + 60)
        live.ingest(fix: fix(0.002))
        live.ingest(status: 1, sport: 1, timestamp: nil, now: t0 + 120)
        live.ingest(fix: fix(0.010))
        #expect(live.current?.distanceMeters == beforePause)
        live.ingest(fix: fix(0.011))
        #expect(abs((live.current?.distanceMeters ?? 0) - 2 * beforePause) < 1)
    }

    @Test func paceTimeCountsOnlyBetweenCountedFixes() {
        let live = WorkoutLiveService()
        live.ingest(status: 0, sport: 1, timestamp: nil, now: t0)
        live.ingest(fix: fix(0, at: 120))
        live.ingest(fix: fix(0.009, at: 420))
        #expect(live.current?.movingSeconds == 300)
        let pace = live.current.flatMap(WorkoutFormat.pace)
        #expect(pace?.value == "5:01 /km")
    }
}
