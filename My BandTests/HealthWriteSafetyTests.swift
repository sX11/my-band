import Testing
import Foundation
import HealthKit
@testable import My_Band

@MainActor
struct HealthWriteSafetyTests {

    private let at = Date(timeIntervalSince1970: 1_750_000_000)

    private func heartRate(_ bpm: Double, id: String?, offset: TimeInterval = 0) -> HKSample {
        let date = at.addingTimeInterval(offset)
        return HKQuantitySample(type: HKQuantityType(.heartRate),
                                quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: bpm),
                                start: date, end: date,
                                metadata: id.map { [HKMetadataKeySyncIdentifier: $0, HKMetadataKeySyncVersion: 1] })
    }

    private func bpm(_ sample: HKSample) -> Double? {
        (sample as? HKQuantitySample)?.quantity.doubleValue(for: .count().unitDivided(by: .minute()))
    }

    @Test func repeatedSyncIdentifierKeepsTheLastOccurrence() {
        let samples = [heartRate(60, id: "mb-hr-1"), heartRate(70, id: "mb-hr-2"), heartRate(65, id: "mb-hr-1")]
        let unique = HealthKitManager.deduplicatingBySyncIdentifier(samples)
        #expect(unique.map(bpm) == [70, 65])
    }

    @Test func distinctIdentifiersAreKeptInOrder() {
        let samples = [heartRate(60, id: "mb-hr-1"), heartRate(70, id: "mb-hr-2"), heartRate(80, id: "mb-hr-3")]
        #expect(HealthKitManager.deduplicatingBySyncIdentifier(samples).map(bpm) == [60, 70, 80])
    }

    @Test func samplesWithoutAnIdentifierAreNeverDropped() {
        let samples = [heartRate(60, id: nil), heartRate(61, id: nil), heartRate(70, id: "mb-hr-1"), heartRate(71, id: "mb-hr-1")]
        #expect(HealthKitManager.deduplicatingBySyncIdentifier(samples).map(bpm) == [60, 61, 71])
    }

    @Test func validRangeStartsAt2020() {
        let range = HealthKitManager.validDateRange(now: at)
        #expect(range.contains(Date(timeIntervalSince1970: 1_577_836_800)))
        #expect(!range.contains(Date(timeIntervalSince1970: 1_577_836_799)))
        #expect(!range.contains(Date(timeIntervalSince1970: 0)))
        #expect(!range.contains(Date(timeIntervalSince1970: -1_317_000_000)))   // 1928
    }

    @Test func validRangeAllowsADayAheadButNotMore() {
        let range = HealthKitManager.validDateRange(now: at)
        #expect(range.contains(at))
        #expect(range.contains(at.addingTimeInterval(86_400)))
        #expect(!range.contains(at.addingTimeInterval(86_401)))
    }
}
