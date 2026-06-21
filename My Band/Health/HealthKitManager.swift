import Foundation
import HealthKit
import CoreLocation
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
    private let bodyTemp    = HKQuantityType(.bodyTemperature)
    private let restingHR   = HKQuantityType(.restingHeartRate)
    private let vo2Max      = HKQuantityType(.vo2Max)
    private let distanceCycling  = HKQuantityType(.distanceCycling)
    private let distanceSwimming = HKQuantityType(.distanceSwimming)
    private let swimStrokes      = HKQuantityType(.swimmingStrokeCount)
    private let workoutType      = HKObjectType.workoutType()
    private let routeType        = HKSeriesType.workoutRoute()

    private var shareTypes: Set<HKSampleType> {
        [sleepType, heartRate, stepCount, distance, activeEnergy, spo2,
         bodyTemp, restingHR, vo2Max, distanceCycling, distanceSwimming, swimStrokes,
         workoutType, routeType]
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
            guard session.endDate > session.startDate else { continue }
            // Enclosing in-bed window so Apple Health reports "Time in Bed" alongside the stages.
            let inBedId = "mb-inbed-\(Int(session.startDate.timeIntervalSince1970))-\(Int(session.endDate.timeIntervalSince1970))"
            samples.append(HKCategorySample(
                type: sleepType, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                start: session.startDate, end: session.endDate,
                metadata: syncMetadata(inBedId)
            ))
            for phase in session.phases {
                guard phase.endDate > phase.startDate, let value = Self.sleepValue(phase.type) else { continue }
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
        if let resting = s.restingHR {
            samples.append(quantity(restingHR, bpm, Double(resting),
                                    start: dayStart, end: dayEnd, id: "mb-hrresting-\(dayKey)"))
        }
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
        // NOTE: standingHours (DailySummary) is intentionally NOT written. HKCategoryType
        // .appleStandHour is reserved — HealthKit disallows third-party apps from sharing it
        // (requesting authorization throws NSInvalidArgumentException). There is no
        // third-party-writable "stand hour" type, so the band's mask stays local-only.
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

    // MARK: - Manual (on-demand) measurements

    func writeManualSamples(_ manual: [ManualSample]) async throws -> Int {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = []
        for m in manual {
            let key = Int(m.date.timeIntervalSince1970)
            switch m.kind {
            case .heartRate where (30...250).contains(m.value):
                samples.append(quantity(heartRate, bpm, m.value, start: m.date, end: m.date, id: "mb-mhr-\(key)"))
            case .spo2 where (50...100).contains(m.value):
                samples.append(quantity(spo2, .percent(), m.value / 100.0, start: m.date, end: m.date, id: "mb-mspo2-\(key)"))
            case .temperature where (30...45).contains(m.value):
                samples.append(quantity(bodyTemp, .degreeCelsius(), m.value, start: m.date, end: m.date, id: "mb-mtemp-\(key)"))
            default:
                continue   // stress (no Apple Health type) or out-of-range reading
            }
        }
        return try await save(samples)
    }

    // MARK: - Workouts
    //
    // Each workout becomes an HKWorkout via HKWorkoutBuilder. Energy/distance/stroke totals
    // are added as samples so Apple Health computes the summary; VO₂max is written as its own
    // sample timestamped at the workout end. A GPS track, when present, becomes an
    // HKWorkoutRoute attached to the finished workout. HKMetadataKeySyncIdentifier makes
    // re-syncing idempotent.

    func writeWorkouts(_ workouts: [WorkoutSummary],
                       routes: [Int: [WorkoutTrackPoint]]) async throws -> Int {
        var written = 0

        for w in workouts {
            guard w.endDate > w.startDate else { continue }
            let key = Int(w.startDate.timeIntervalSince1970)

            let config = HKWorkoutConfiguration()
            config.activityType = Self.activityType(w.kind)
            if let loc = Self.swimmingLocation(w.kind) { config.swimmingLocationType = loc }

            let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: .local())
            try await builder.beginCollection(at: w.startDate)

            var samples: [HKSample] = []
            if let kcal = w.caloriesKcal {
                samples.append(quantity(activeEnergy, .kilocalorie(), kcal,
                                        start: w.startDate, end: w.endDate, id: "mb-wkcal-\(key)"))
            }
            if let dist = w.distanceMeters {
                samples.append(quantity(Self.distanceType(w.kind, distance, distanceCycling, distanceSwimming),
                                        .meter(), dist, start: w.startDate, end: w.endDate, id: "mb-wdist-\(key)"))
            }
            if let strokes = w.strokes, Self.activityType(w.kind) == .swimming {
                samples.append(quantity(swimStrokes, .count(), strokes,
                                        start: w.startDate, end: w.endDate, id: "mb-wstrokes-\(key)"))
            }
            if !samples.isEmpty {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    builder.add(samples) { _, error in
                        if let error { cont.resume(throwing: error) } else { cont.resume() }
                    }
                }
            }

            var metadata: [String: Any] = [
                HKMetadataKeySyncIdentifier: "mb-workout-\(key)",
                HKMetadataKeySyncVersion: syncVersion,
                HKMetadataKeyIndoorWorkout: Self.swimmingLocation(w.kind) == nil && Self.isIndoor(w.kind),
            ]
            if let avg = w.hrAvg { metadata["MiBandAverageHeartRate"] = avg }
            if let mx = w.hrMax  { metadata["MiBandMaxHeartRate"] = mx }
            if let mn = w.hrMin  { metadata["MiBandMinHeartRate"] = mn }
            if let style = w.swimStyle { metadata["MiBandSwimStyle"] = style }
            try await builder.addMetadata(metadata)

            try await builder.endCollection(at: w.endDate)
            guard let workout = try await builder.finishWorkout() else { continue }
            written += 1

            // VO₂max is a standalone sample (not a workout statistic).
            if let vo2 = w.vo2Max, (10...90).contains(vo2) {
                let unit = HKUnit.literUnit(with: .milli)
                    .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
                try await save([quantity(vo2Max, unit, vo2, start: w.endDate, end: w.endDate, id: "mb-vo2-\(key)")])
            }

            // Attach the GPS route, if this workout had one.
            if let track = routes[key], track.count >= 2 {
                let locations = track.map { p in
                    CLLocation(coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                               altitude: 0,
                               horizontalAccuracy: p.hdop ?? -1,
                               verticalAccuracy: -1,
                               timestamp: p.date)
                }
                let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
                try await routeBuilder.insertRouteData(locations)
                _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
            }
        }
        return written
    }

    // MARK: - Workout type mapping

    private static func activityType(_ kind: WorkoutKind) -> HKWorkoutActivityType {
        switch kind {
        case .running, .trailRun, .treadmill:        .running
        case .hiking, .trekking:                     .hiking
        case .walking:                               .walking
        case .outdoorCycling, .indoorCycling:        .cycling
        case .poolSwim, .openWaterSwim:              .swimming
        case .elliptical:                            .elliptical
        case .rowing, .rowingMachine:                .rowing
        case .jumpRoping:                            .jumpRope
        case .hiit:                                  .highIntensityIntervalTraining
        case .yoga:                                  .yoga
        case .freeTraining, .other:                  .other
        }
    }

    private static func swimmingLocation(_ kind: WorkoutKind) -> HKWorkoutSwimmingLocationType? {
        switch kind {
        case .poolSwim:      .pool
        case .openWaterSwim: .openWater
        default:             nil
        }
    }

    private static func isIndoor(_ kind: WorkoutKind) -> Bool {
        switch kind {
        case .treadmill, .indoorCycling, .elliptical, .rowingMachine, .hiit, .yoga, .freeTraining: true
        default: false
        }
    }

    private static func distanceType(_ kind: WorkoutKind, _ walkRun: HKQuantityType,
                                     _ cycling: HKQuantityType, _ swimming: HKQuantityType) -> HKQuantityType {
        switch kind {
        case .outdoorCycling, .indoorCycling: cycling
        case .poolSwim, .openWaterSwim:        swimming
        default:                               walkRun
        }
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
