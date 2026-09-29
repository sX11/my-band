import Testing
import Foundation
@testable import My_Band

@MainActor
struct HealthSyncLogTests {

    private func freshDefaults() throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: "HealthSyncLogTests"))
        defaults.removePersistentDomain(forName: "HealthSyncLogTests")
        return defaults
    }

    @Test func typeMissingFromALaterSyncKeepsItsEarlierTotal() throws {
        let defaults = try freshDefaults()
        let log = HealthSyncLog(defaults: defaults)
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(HealthSyncReport(at: first, byType: ["HKQuantityTypeIdentifierHeartRate": 120,
                                                        "HKCategoryTypeIdentifierSleepAnalysis": 9]))
        log.record(HealthSyncReport(at: first.addingTimeInterval(600), byType: ["HKQuantityTypeIdentifierHeartRate": 4]))
        #expect(log.lastByType["HKCategoryTypeIdentifierSleepAnalysis"] == .init(count: 9, at: first))
        #expect(log.lastByType["HKQuantityTypeIdentifierHeartRate"]?.count == 4)
        #expect(log.last?.total == 4)
    }

    @Test func reportSurvivesReload() throws {
        let defaults = try freshDefaults()
        HealthSyncLog(defaults: defaults).record(HealthSyncReport(at: .now, filesFetched: 3, byType: ["HKWorkoutTypeIdentifier": 1]))
        let reloaded = HealthSyncLog(defaults: defaults)
        #expect(reloaded.last?.filesFetched == 3)
        #expect(reloaded.lastByType["HKWorkoutTypeIdentifier"]?.count == 1)
    }

    @Test func workoutSyncAddsToTheLastReport() throws {
        let log = HealthSyncLog(defaults: try freshDefaults())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        log.record(HealthSyncReport(at: t, filesFetched: 5, byType: ["HKQuantityTypeIdentifierHeartRate": 100]))
        log.record(HealthSyncReport(at: t.addingTimeInterval(60), filesFetched: 2, workouts: 1,
                                    byType: ["HKWorkoutTypeIdentifier": 1, "HKQuantityTypeIdentifierHeartRate": 30]),
                   addingToLast: true)
        #expect(log.last?.filesFetched == 7)
        #expect(log.last?.byType == ["HKQuantityTypeIdentifierHeartRate": 130, "HKWorkoutTypeIdentifier": 1])
        #expect(log.last?.at == t.addingTimeInterval(60))
    }

    @Test func failureReasonIsKeptOnlyForAFailedSync() throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let defaults = try freshDefaults()
        let log = HealthSyncLog(defaults: defaults)
        log.record(HealthSyncReport(at: .now))
        log.noteFailure(Boom())
        #expect(log.last?.error == nil)
        log.record(HealthSyncReport(at: .now, failed: true))
        log.noteFailure(Boom())
        #expect(HealthSyncLog(defaults: defaults).last?.error == "boom")
    }

    @Test func resetForgetsEverything() throws {
        let defaults = try freshDefaults()
        let log = HealthSyncLog(defaults: defaults)
        log.record(HealthSyncReport(at: .now, byType: ["HKWorkoutTypeIdentifier": 1]))
        log.reset()
        let reloaded = HealthSyncLog(defaults: defaults)
        #expect(reloaded.last == nil)
        #expect(reloaded.lastByType.isEmpty)
    }

    @Test func namesKnownAndUnknownTypes() {
        #expect(HealthSyncLog.name("HKQuantityTypeIdentifierOxygenSaturation") == "Blood oxygen")
        #expect(HealthSyncLog.name("HKQuantityTypeIdentifierWalkingSpeed") == "WalkingSpeed")
    }
}
