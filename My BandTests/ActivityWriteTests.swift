import Testing
import Foundation
@testable import My_Band

@MainActor
struct ActivityWriteTests {

    private let minute0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func minute(_ offset: Int, steps: Int? = nil, meters: Double? = nil, kcal: Int? = nil) -> ActivityMinuteSample {
        ActivityMinuteSample(date: minute0.addingTimeInterval(TimeInterval(offset * 60)),
                             steps: steps, caloriesKcal: kcal, distanceMeters: meters)
    }

    private func key(_ offset: Int) -> Int { Int(minute0.timeIntervalSince1970) + offset * 60 }

    @Test func writesTheBandsFullValuePerMinute() {
        let values = HealthKitManager.activityValues([minute(0, steps: 120, meters: 90, kcal: 5)])
        #expect(values.count == 3)
        #expect(values.contains { $0.kind == .steps && $0.key == key(0) && $0.value == 120 })
        #expect(values.contains { $0.kind == .distance && $0.key == key(0) && $0.value == 90 })
        #expect(values.contains { $0.kind == .energy && $0.key == key(0) && $0.value == 5 })
    }

    @Test func dropsZeroAndMissingValues() {
        let values = HealthKitManager.activityValues([minute(0, steps: 0, kcal: 0), minute(1)])
        #expect(values.isEmpty)
    }

    @Test func workoutMinutesKeepStepsButDropDistanceAndEnergy() {
        let window = (start: minute0, end: minute0.addingTimeInterval(120))
        let values = HealthKitManager.activityValues(
            [minute(1, steps: 100, meters: 80, kcal: 6), minute(2, steps: 50, meters: 40, kcal: 3)],
            excludingWorkouts: [window])
        #expect(values.filter { $0.key == key(1) }.map(\.kind) == [.steps])
        #expect(values.filter { $0.key == key(2) }.count == 3)
    }
}
