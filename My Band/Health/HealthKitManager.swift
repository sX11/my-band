import Foundation
import HealthKit
import OSLog

// MARK: - HealthKitManager
//
// Writes Mi Band data to Apple Health. Deduplication uses HKMetadataKeySyncIdentifier +
// HKMetadataKeySyncVersion: re-saving a sample with the same identifier and an equal/greater
// version replaces the existing one instead of creating a duplicate — so re-syncing is safe.

@MainActor
final class HealthKitManager {

    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Health")

    private let syncVersion = 1

    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    // Types we write.
    private let sleepType   = HKCategoryType(.sleepAnalysis)
    private let heartRate   = HKQuantityType(.heartRate)
    private let stepCount   = HKQuantityType(.stepCount)
    private let distance    = HKQuantityType(.distanceWalkingRunning)
    private let activeEnergy = HKQuantityType(.activeEnergyBurned)
    private let spo2        = HKQuantityType(.oxygenSaturation)

    private var shareTypes: Set<HKSampleType> {
        [sleepType, heartRate, stepCount, distance, activeEnergy, spo2]
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthError.unavailable }
        try await store.requestAuthorization(toShare: shareTypes, read: shareTypes)
    }

    // MARK: - Sleep

    func writeSleep(_ sessions: [SleepSession]) async throws -> Int {
        var samples: [HKSample] = []
        for session in sessions {
            for phase in session.phases {
                guard let value = Self.sleepValue(phase.type) else { continue }
                let id = "mb-sleep-\(Int(phase.startDate.timeIntervalSince1970))-\(Int(phase.endDate.timeIntervalSince1970))-\(phase.type.rawValue)"
                samples.append(HKCategorySample(
                    type: sleepType, value: value.rawValue,
                    start: phase.startDate, end: phase.endDate,
                    metadata: syncMetadata(id)
                ))
            }
        }
        return try await save(samples)
    }

    private static func sleepValue(_ type: SleepPhaseType) -> HKCategoryValueSleepAnalysis? {
        switch type {
        case .awake: .awake
        case .light: .asleepCore
        case .deep:  .asleepDeep
        case .rem:   .asleepREM
        }
    }

    // MARK: - Daily summary (steps, calories, HR/SpO₂ extremes)

    func writeDailySummary(_ s: DailySummary) async throws -> Int {
        var samples: [HKSample] = []
        let dayStart = Calendar.current.startOfDay(for: s.date)
        let dayEnd = min(dayStart.addingTimeInterval(86_400 - 1), Date())
        let dayKey = Int(dayStart.timeIntervalSince1970)

        if s.steps > 0 {
            samples.append(quantity(stepCount, .count(), Double(s.steps),
                                    start: dayStart, end: dayEnd, id: "mb-steps-day-\(dayKey)"))
        }
        if s.caloriesKcal > 0 {
            samples.append(quantity(activeEnergy, .kilocalorie(), Double(s.caloriesKcal),
                                    start: dayStart, end: dayEnd, id: "mb-cal-day-\(dayKey)"))
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        if let max = s.maxHR {
            samples.append(quantity(heartRate, bpm, Double(max.bpm), start: max.at, end: max.at, id: "mb-hrmax-\(Int(max.at.timeIntervalSince1970))"))
        }
        if let min = s.minHR {
            samples.append(quantity(heartRate, bpm, Double(min.bpm), start: min.at, end: min.at, id: "mb-hrmin-\(Int(min.at.timeIntervalSince1970))"))
        }
        if let mx = s.spo2Max {
            samples.append(quantity(spo2, .percent(), Double(mx.pct) / 100.0, start: mx.at, end: mx.at, id: "mb-spo2max-\(Int(mx.at.timeIntervalSince1970))"))
        }
        if let mn = s.spo2Min {
            samples.append(quantity(spo2, .percent(), Double(mn.pct) / 100.0, start: mn.at, end: mn.at, id: "mb-spo2min-\(Int(mn.at.timeIntervalSince1970))"))
        }
        return try await save(samples)
    }

    // MARK: - Per-minute detail (HR / SpO₂ / distance time series)

    func writeMinuteSamples(_ minutes: [ActivityMinuteSample]) async throws -> Int {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = []
        for m in minutes {
            let key = Int(m.date.timeIntervalSince1970)
            let end = m.date.addingTimeInterval(60)
            if let hr = m.heartRate, (30...250).contains(hr) {
                samples.append(quantity(heartRate, bpm, Double(hr), start: m.date, end: m.date, id: "mb-hr-\(key)"))
            }
            if let s = m.spo2, (50...100).contains(s) {
                samples.append(quantity(spo2, .percent(), Double(s) / 100.0, start: m.date, end: m.date, id: "mb-spo2-\(key)"))
            }
            if let d = m.distanceMeters, d > 0 {
                samples.append(quantity(distance, .meter(), d, start: m.date, end: end, id: "mb-dist-\(key)"))
            }
        }
        return try await save(samples)
    }

    // MARK: - Helpers

    private func quantity(_ type: HKQuantityType, _ unit: HKUnit, _ value: Double,
                          start: Date, end: Date, id: String) -> HKQuantitySample {
        HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: end, metadata: syncMetadata(id))
    }

    private func syncMetadata(_ id: String) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: syncVersion]
    }

    @discardableResult
    private func save(_ samples: [HKSample]) async throws -> Int {
        guard !samples.isEmpty else { return 0 }
        try await store.save(samples)
        return samples.count
    }
}

// MARK: - Errors

enum HealthError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "O Apple Health não está disponível neste dispositivo."
        }
    }
}
