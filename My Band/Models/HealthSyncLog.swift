import Foundation
import OSLog

// MARK: - HealthSyncLog
//
// What each sync sent to Apple Health, per HealthKit type, for the Dashboard's sync sheet. Counts
// are samples sent: Apple Health replaces one it already holds under the same sync identifier, so
// a resent sample is counted again here without being duplicated there.

struct HealthSyncReport: Codable, Equatable {

    struct TypeTotal: Codable, Equatable {
        var count: Int
        var at: Date
    }

    var at: Date
    /// A write threw part-way: the counts are what reached Apple Health before it did.
    var failed = false
    var filesFetched = 0
    /// Requested files the band never delivered.
    var filesFailed = 0
    var sleepSessions = 0
    var dailySummaries = 0
    var minuteSamples = 0
    var manualSamples = 0
    var workouts = 0
    /// HealthKit type identifier → samples sent by this sync.
    var byType: [String: Int] = [:]

    var total: Int { byType.values.reduce(0, +) }

    /// A post-workout sync adds to the full sync before it instead of replacing its report.
    func adding(_ other: HealthSyncReport) -> HealthSyncReport {
        var r = self
        r.at = other.at
        r.failed = failed || other.failed
        r.filesFetched += other.filesFetched
        r.filesFailed += other.filesFailed
        r.sleepSessions += other.sleepSessions
        r.dailySummaries += other.dailySummaries
        r.minuteSamples += other.minuteSamples
        r.manualSamples += other.manualSamples
        r.workouts += other.workouts
        r.byType.merge(other.byType, uniquingKeysWith: +)
        return r
    }
}

@Observable
@MainActor
final class HealthSyncLog {

    private(set) var last: HealthSyncReport?
    /// Every type ever sent, with its count and time from the latest sync that sent any.
    private(set) var lastByType: [String: HealthSyncReport.TypeTotal]

    private let defaults: UserDefaults
    private static let lastKey = "healthSyncLastReportV2"
    private static let byTypeKey = "healthSyncLastByTypeV2"
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "HealthSyncLog")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let decoder = JSONDecoder()
        last = defaults.data(forKey: Self.lastKey).flatMap { try? decoder.decode(HealthSyncReport.self, from: $0) }
        lastByType = defaults.data(forKey: Self.byTypeKey)
            .flatMap { try? decoder.decode([String: HealthSyncReport.TypeTotal].self, from: $0) } ?? [:]
    }

    func record(_ incoming: HealthSyncReport, addingToLast: Bool = false) {
        let report = addingToLast ? (last?.adding(incoming) ?? incoming) : incoming
        last = report
        for (type, count) in report.byType where count > 0 {
            lastByType[type] = .init(count: count, at: report.at)
        }
        do {
            let encoder = JSONEncoder()
            defaults.set(try encoder.encode(report), forKey: Self.lastKey)
            defaults.set(try encoder.encode(lastByType), forKey: Self.byTypeKey)
        } catch {
            log.error("Could not save the sync report: \(error.localizedDescription)")
        }
    }

    /// Forget / re-pair: the report described the old band's syncs.
    func reset() {
        last = nil
        lastByType = [:]
        defaults.removeObject(forKey: Self.lastKey)
        defaults.removeObject(forKey: Self.byTypeKey)
    }

    /// Readable name for a HealthKit type identifier; unknown ones lose the HealthKit prefix.
    static func name(_ identifier: String) -> String {
        if let known = names[identifier] { return known }
        var s = identifier
        for prefix in ["HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HK"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
            break
        }
        return s
    }

    private static let names: [String: String] = [
        "HKCategoryTypeIdentifierSleepAnalysis": "Sleep",
        "HKQuantityTypeIdentifierHeartRate": "Heart rate",
        "HKQuantityTypeIdentifierRestingHeartRate": "Resting heart rate",
        "HKQuantityTypeIdentifierHeartRateRecoveryOneMinute": "Cardio recovery",
        "HKQuantityTypeIdentifierOxygenSaturation": "Blood oxygen",
        "HKQuantityTypeIdentifierStepCount": "Steps",
        "HKQuantityTypeIdentifierDistanceWalkingRunning": "Walking + running distance",
        "HKQuantityTypeIdentifierDistanceCycling": "Cycling distance",
        "HKQuantityTypeIdentifierDistanceSwimming": "Swimming distance",
        "HKQuantityTypeIdentifierSwimmingStrokeCount": "Swimming strokes",
        "HKQuantityTypeIdentifierActiveEnergyBurned": "Active energy",
        "HKQuantityTypeIdentifierPhysicalEffort": "Physical effort",
        "HKQuantityTypeIdentifierBodyTemperature": "Body temperature",
        "HKQuantityTypeIdentifierVO2Max": "Cardio fitness (VO₂ max)",
        "HKQuantityTypeIdentifierEstimatedWorkoutEffortScore": "Workout effort",
        "HKQuantityTypeIdentifierBodyMass": "Weight",
        "HKQuantityTypeIdentifierBodyMassIndex": "Body mass index",
        "HKQuantityTypeIdentifierHeight": "Height",
        "HKWorkoutTypeIdentifier": "Workouts",
        "HKWorkoutRouteTypeIdentifier": "Workout routes",
    ]
}
