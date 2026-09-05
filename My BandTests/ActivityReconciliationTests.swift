import Testing
import Foundation
@testable import My_Band

// `HealthKitManager.surplusValues` is the pure delta math behind cross-source reconciliation
// (steps/distance/active energy): band value minus what the iPhone already recorded for the same
// minute, so Apple Health's per-source summing doesn't double-count a shared walk.
@MainActor
struct ActivityReconciliationTests {

    private let minute0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ offsetMinutes: Int, _ value: Double) -> (date: Date, value: Double) {
        (minute0.addingTimeInterval(TimeInterval(offsetMinutes * 60)), value)
    }

    private func key(_ offsetMinutes: Int) -> Int {
        Int(minute0.addingTimeInterval(TimeInterval(offsetMinutes * 60)).timeIntervalSince1970)
    }

    @Test func returnsOnlyTheBandsSurplusOverTheIPhone() {
        let points = [point(0, 120), point(1, 80)]
        let iphone = [key(0): 50.0, key(1): 80.0]
        let result = HealthKitManager.surplusValues(points, otherSourceSums: iphone)
        // Minute 0: band ahead by 70. Minute 1: iPhone already covers all of it — no surplus.
        #expect(result.count == 1)
        #expect(result.first?.key == key(0))
        #expect(result.first?.delta == 70.0)
    }

    @Test func fallsBackToTheFullBandValueWhenTheIPhoneHasNothingForThatMinute() {
        // No HealthKit read access, or the iPhone just hasn't recorded that minute — safe direction
        // is to keep the band's full value rather than silently dropping steps.
        let points = [point(0, 42)]
        let result = HealthKitManager.surplusValues(points, otherSourceSums: [:])
        #expect(result.count == 1)
        #expect(result.first?.key == key(0))
        #expect(result.first?.delta == 42.0)
    }

    @Test func dropsMinutesWhereTheIPhoneAlreadyCoversOrExceedsTheBand() {
        let points = [point(0, 30)]
        let iphone = [key(0): 45.0]  // iPhone recorded more than the band for this minute
        let result = HealthKitManager.surplusValues(points, otherSourceSums: iphone)
        #expect(result.isEmpty)
    }

    @Test func exactlyEqualValuesProduceNoSurplus() {
        let points = [point(0, 50)]
        let iphone = [key(0): 50.0]
        let result = HealthKitManager.surplusValues(points, otherSourceSums: iphone)
        #expect(result.isEmpty)
    }
}
