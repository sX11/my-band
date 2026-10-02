import Foundation
import HealthKit
import CoreLocation
import OSLog

// MARK: - HealthKitManager
//
// Writes Mi Band data to Apple Health. Deduplication uses HKMetadataKeySyncIdentifier +
// HKMetadataKeySyncVersion: re-saving a sample with the same identifier and an equal/greater
// version replaces the existing one instead of creating a duplicate — so re-syncing is safe.
//
// Steps / distance / active energy overlap the iPhone's own and are written raw per minute
// (`writeActivity`): Apple Health merges overlapping sources by the Data Sources order rather than
// summing them. Mobility types (walkingSpeed, step length) stay iPhone-only; nothing writes them.

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
    private let bodyMass         = HKQuantityType(.bodyMass)
    private let bodyMassIndex    = HKQuantityType(.bodyMassIndex)
    private let height           = HKQuantityType(.height)
    private let physicalEffort   = HKQuantityType(.physicalEffort)
    private let runningSpeed     = HKQuantityType(.runningSpeed)
    private let runningStride    = HKQuantityType(.runningStrideLength)
    private let cyclingSpeedType = HKQuantityType(.cyclingSpeed)
    private let hrRecovery       = HKQuantityType(.heartRateRecoveryOneMinute)
    private let workoutType      = HKObjectType.workoutType()
    private let routeType        = HKSeriesType.workoutRoute()

    /// MET: 1 kcal por kg por hora — a unidade do physicalEffort e do HKMetadataKeyAverageMETs.
    private static let metUnit = HKUnit.kilocalorie()
        .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .hour()))

    private var shareTypes: Set<HKSampleType> {
        var types: Set<HKSampleType> = [sleepType, heartRate, stepCount, distance, activeEnergy, spo2,
         bodyTemp, restingHR, vo2Max, distanceCycling, distanceSwimming, swimStrokes,
         bodyMass, bodyMassIndex, height, workoutType, routeType,
         physicalEffort, runningSpeed, runningStride, cyclingSpeedType, hrRecovery]
        if #available(iOS 18.0, *) {
            types.insert(HKQuantityType(.estimatedWorkoutEffortScore))
            types.insert(HKQuantityType(.distanceRowing))
        }
        return types
    }

    // MARK: - Authorization

    func requestAuthorization() async throws {
        guard isAvailable else { throw HealthError.unavailable }
        // Date of birth is read-only (characteristic): age drives the max-HR estimate behind the
        // workout effort score. Denial is fine — the score falls back to a fixed max HR.
        var readTypes: Set<HKObjectType> = shareTypes
        readTypes.insert(HKCharacteristicType(.dateOfBirth))
        try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
    }

    /// The newer, enrichment-only types are guarded by this before being added to a save batch: a
    /// single denied type fails the whole `store.save`, which would break the established pipeline
    /// (HR/SpO₂/workouts) over an optional metric. Denied/undetermined → that metric is skipped.
    private func canShare(_ type: HKSampleType) -> Bool {
        store.authorizationStatus(for: type) == .sharingAuthorized
    }

    // MARK: - Sleep

    // A resync of a still-in-progress (or previously partial) night reports a superset of what an
    // earlier sync already wrote, with different boundaries: each `SleepSession` is internally
    // sanitized (`SleepDetailsParser.sanitizeStages`), but two sessions covering the same/overlapping
    // window — whether from multiple files in one batch or from separate background-wake resyncs
    // hours apart — never get sanitized *against each other*. The old per-phase/per-inBed identifier
    // also baked in `endDate`, which is exactly what changes between resyncs of an ongoing night, so
    // HealthKit's sync-identifier dedup (see header comment) never recognized them as updates.
    // Fixed by: (1) pooling and re-sanitizing phases across every session whose window overlaps,
    // (2) keying identifiers on the phase's own start + type only (stable across a growing end),
    // and (3) clearing whatever this app already wrote for the window as a backstop, so a
    // reclassified stage (same start, different type — not caught by a stable id alone) still gets
    // superseded instead of sitting alongside the old one.
    func writeSleep(_ sessions: [SleepSession]) async throws -> Int {
        guard !sessions.isEmpty else { return 0 }
        var samples: [HKSample] = []
        for group in Self.groupOverlapping(sessions) {
            guard let start = group.map(\.startDate).min(), let end = group.map(\.endDate).max(),
                  end > start else { continue }

            try await deleteExistingSleep(overlapping: start, to: end)

            // Enclosing in-bed window so Apple Health reports "Time in Bed" alongside the stages.
            let inBedId = "mb-inbed-\(Int(start.timeIntervalSince1970))"
            samples.append(HKCategorySample(
                type: sleepType, value: HKCategoryValueSleepAnalysis.inBed.rawValue,
                start: start, end: end,
                metadata: syncMetadata(inBedId)
            ))

            let sanitized = SleepDetailsParser.sanitizeStages(group.flatMap(\.phases))
            for phase in sanitized {
                guard phase.endDate > phase.startDate, let value = Self.sleepValue(phase.type) else { continue }
                let id = "mb-sleep-\(Int(phase.startDate.timeIntervalSince1970))-\(phase.type.rawValue)"
                samples.append(HKCategorySample(
                    type: sleepType, value: value.rawValue,
                    start: phase.startDate, end: phase.endDate,
                    metadata: syncMetadata(id)
                ))
            }
        }
        return try await save(samples)
    }

    /// Groups sessions whose `[startDate, endDate]` windows transitively overlap — incremental
    /// resyncs of the same night, however many files/sessions it was split across. Public so tests
    /// can validate grouping independent of HealthKit.
    static func groupOverlapping(_ sessions: [SleepSession]) -> [[SleepSession]] {
        let sorted = sessions.sorted { $0.startDate < $1.startDate }
        var groups: [[SleepSession]] = []
        for s in sorted {
            if let lastEnd = groups.last?.map(\.endDate).max(), s.startDate < lastEnd {
                groups[groups.count - 1].append(s)
            } else {
                groups.append([s])
            }
        }
        return groups
    }

    private func deleteExistingSleep(overlapping start: Date, to end: Date) async throws {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let time = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, time])
        do {
            _ = try await store.deleteObjects(of: sleepType, predicate: predicate)
        } catch let error as HKError where error.code == .errorNoData {
            // Nothing of ours in the window yet — a night's first write. Letting this throw would
            // fail the save that follows, every time a new night shows up.
        }
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

        // Steps, distance and active energy are intentionally NOT written here: the per-minute
        // daily-details file carries the same totals (writeActivity), and a day-long sample would
        // win or lose the whole day against the iPhone instead of minute by minute.
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let validDateRange: ClosedRange<Date> = Date(timeIntervalSince1970: 1_600_000_000)...Date().addingTimeInterval(86400)

        if let resting = s.restingHR, (35...150).contains(resting) {
            samples.append(quantity(restingHR, bpm, Double(resting),
                                    start: dayStart, end: dayEnd, id: "mb-hrresting-\(dayKey)"))
        }
        if let max = s.maxHR, (35...220).contains(max.bpm), validDateRange.contains(max.at) {
            samples.append(quantity(heartRate, bpm, Double(max.bpm), start: max.at, end: max.at, id: "mb-hrmax-\(Int(max.at.timeIntervalSince1970))"))
        }
        if let min = s.minHR, (35...220).contains(min.bpm), validDateRange.contains(min.at) {
            samples.append(quantity(heartRate, bpm, Double(min.bpm), start: min.at, end: min.at, id: "mb-hrmin-\(Int(min.at.timeIntervalSince1970))"))
        }
        if let mx = s.spo2Max, (50...100).contains(mx.pct), validDateRange.contains(mx.at) {
            samples.append(quantity(spo2, .percent(), Double(mx.pct) / 100.0, start: mx.at, end: mx.at, id: "mb-spo2max-\(Int(mx.at.timeIntervalSince1970))"))
        }
        if let mn = s.spo2Min, (50...100).contains(mn.pct), validDateRange.contains(mn.at) {
            samples.append(quantity(spo2, .percent(), Double(mn.pct) / 100.0, start: mn.at, end: mn.at, id: "mb-spo2min-\(Int(mn.at.timeIntervalSince1970))"))
        }
        // NOTE: standingHours (DailySummary) is intentionally NOT written. HKCategoryType
        // .appleStandHour is reserved — HealthKit disallows third-party apps from sharing it
        // (requesting authorization throws NSInvalidArgumentException). There is no
        // third-party-writable "stand hour" type, so the band's mask stays local-only.
        return try await save(samples)
    }

    // MARK: - Per-minute detail (HR / SpO₂ / Physical Effort time series)
    //
    // Band-exclusive vitals only; steps, distance and energy go through writeActivity. HR and SpO₂
    // have no iPhone equivalent here, so they're written raw at full granularity. Also used for the
    // HR/SpO₂ samples recorded during sleep.
    //
    // Physical Effort (METs, the same all-day metric the Apple Watch populates) derives from the
    // band's per-minute active calories and the user's weight: MET = 1 (resting baseline, which the
    // band's *active* kcal excludes by definition) + kcal·60/kg. The iPhone never writes
    // physicalEffort. Sleep-vitals batches carry no calories, so they skip it.

    func writeMinuteSamples(_ minutes: [ActivityMinuteSample]) async throws -> Int {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var weightKg: Double?
        if canShare(physicalEffort), minutes.contains(where: { ($0.caloriesKcal ?? 0) > 0 }) {
            weightKg = (try? await latestBodyMassKg()) ?? nil
        }
        var samples: [HKSample] = []
        for m in minutes {
            let key = Int(m.date.timeIntervalSince1970)
            if let hr = m.heartRate, (30...250).contains(hr) {
                samples.append(quantity(heartRate, bpm, Double(hr), start: m.date, end: m.date, id: "mb-hr-\(key)"))
            }
            if let s = m.spo2, (50...100).contains(s) {
                samples.append(quantity(spo2, .percent(), Double(s) / 100.0, start: m.date, end: m.date, id: "mb-spo2-\(key)"))
            }
            if let kcal = m.caloriesKcal, kcal > 0, let w = weightKg, w > 0 {
                let met = 1.0 + Double(kcal) * 60.0 / w
                if (1.0...30.0).contains(met) {
                    samples.append(quantity(physicalEffort, Self.metUnit, met,
                                            start: m.date, end: m.date.addingTimeInterval(60),
                                            id: "mb-effort-\(key)"))
                }
            }
        }
        return try await save(samples)
    }

    // MARK: - Activity (steps / distance / active energy)
    //
    // The band's raw per-minute values; Apple Health resolves minutes the iPhone also recorded by
    // the Data Sources order, so nothing here reads Health. The monotonic version lets a re-sync
    // replace the same minute's earlier sample (HealthKit ignores an equal or lower version).

    func writeActivity(_ minutes: [ActivityMinuteSample],
                       excludingWorkouts windows: [(start: Date, end: Date)] = []) async throws -> Int {
        let version = Int(Date().timeIntervalSince1970)
        let samples: [HKSample] = Self.activityValues(minutes, excludingWorkouts: windows).map { v in
            let type: HKQuantityType, unit: HKUnit, prefix: String
            switch v.kind {
            case .steps:    (type, unit, prefix) = (stepCount, .count(), "mb-steps-rec")
            case .distance: (type, unit, prefix) = (distance, .meter(), "mb-dist-rec")
            case .energy:   (type, unit, prefix) = (activeEnergy, .kilocalorie(), "mb-cal-rec")
            }
            let start = Date(timeIntervalSince1970: TimeInterval(v.key))
            return quantity(type, unit, v.value, start: start, end: start.addingTimeInterval(60),
                            id: "\(prefix)-\(v.key)", version: version)
        }
        return try await save(samples)
    }

    enum ActivityKind { case steps, distance, energy }

    /// Distance and energy inside a workout are left out: the workout's own samples carry them.
    /// Steps aren't part of a workout's samples, so they're always kept.
    static func activityValues(_ minutes: [ActivityMinuteSample],
                               excludingWorkouts windows: [(start: Date, end: Date)] = [])
        -> [(kind: ActivityKind, key: Int, value: Double)] {
        func inWorkout(_ d: Date) -> Bool { windows.contains { d >= $0.start && d < $0.end } }
        var out: [(kind: ActivityKind, key: Int, value: Double)] = []
        for m in minutes {
            let key = Int(m.date.timeIntervalSince1970)
            if let steps = m.steps, steps > 0 { out.append((.steps, key, Double(steps))) }
            guard !inWorkout(m.date) else { continue }
            if let meters = m.distanceMeters, meters > 0 { out.append((.distance, key, meters)) }
            if let kcal = m.caloriesKcal, kcal > 0 { out.append((.energy, key, Double(kcal))) }
        }
        return out
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
                       routes: [Int: [WorkoutTrackPoint]],
                       heartRates: [Int: [WorkoutHRSample]] = [:],
                       weather: [Int: WorkoutWeather] = [:],
                       endExtension: [Int: TimeInterval] = [:]) async throws -> (written: Int, saved: [Int: HKWorkout]) {
        var written = 0
        var saved: [Int: HKWorkout] = [:]
        let bpm = HKUnit.count().unitDivided(by: .minute())
        // Weight (average METs) and age (max-HR estimate behind the effort score) are fetched once
        // per batch; both degrade gracefully when absent.
        let weightKg = (try? await latestBodyMassKg()) ?? nil
        let estimatedMaxHR = estimatedMaxHeartRate()

        guard canShare(workoutType) else {
            if !workouts.isEmpty {
                skippedForPermission = true
                log.warning("Not allowed to write workouts — skipped \(workouts.count, privacy: .public)")
            }
            return (0, [:])
        }

        for w in workouts {
            guard w.endDate > w.startDate else { continue }
            let key = Int(w.startDate.timeIntervalSince1970)
            let track = Self.route(forWorkoutStart: w.startDate, in: routes)
            // A strength workout with a pending cooldown extends its window by the cooldown length so
            // the folded-in cooldown route (attached later) falls inside [start, end]. Samples still
            // span only the real workout window.
            let workoutEnd = w.endDate.addingTimeInterval(endExtension[key] ?? 0)

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
                var distType = Self.distanceType(w.kind, distance, distanceCycling, distanceSwimming)
                // Rowing got its own quantity on iOS 18; before that it fell into the default
                // distanceWalkingRunning branch, silently inflating the walking total.
                if #available(iOS 18.0, *), w.kind == .rowing || w.kind == .rowingMachine,
                   canShare(HKQuantityType(.distanceRowing)) {
                    distType = HKQuantityType(.distanceRowing)
                }
                samples.append(quantity(distType, .meter(), dist,
                                        start: w.startDate, end: w.endDate, id: "mb-wdist-\(key)"))
            }
            if let strokes = w.strokes, Self.activityType(w.kind) == .swimming {
                samples.append(quantity(swimStrokes, .count(), strokes,
                                        start: w.startDate, end: w.endDate, id: "mb-wstrokes-\(key)"))
            }
            // In-workout speed series from the GPS track (V2 points carry m/s), so Apple Health
            // draws the speed/pace graph. Running kinds → runningSpeed, cycling → cyclingSpeed.
            // Walking/hiking are deliberately excluded: walkingSpeed feeds the iPhone's Mobility
            // metrics, which stay iPhone-authoritative (see the type header).
            if let track, let speedType = Self.speedType(w.kind), canShare(speedType) {
                let mps = HKUnit.meter().unitDivided(by: .second())
                for p in track where w.startDate ... w.endDate ~= p.date {
                    guard let v = p.speed, v > 0, v < 30 else { continue }
                    samples.append(quantity(speedType, mps, v, start: p.date, end: p.date,
                                            id: "mb-wspd-\(key)-\(Int(p.date.timeIntervalSince1970))"))
                }
            }
            // Average stride length for runs — the band only has workout totals (distance/steps),
            // so it's one sample spanning the workout, not a per-step series.
            if Self.activityType(w.kind) == .running, canShare(runningStride),
               let dist = w.distanceMeters, let steps = w.steps, steps > 0 {
                let stride = dist / steps
                if (0.3...3.0).contains(stride) {
                    samples.append(quantity(runningStride, .meter(), stride,
                                            start: w.startDate, end: w.endDate, id: "mb-wstride-\(key)"))
                }
            }
            // Per-second HR series recorded during the workout, attached to this HKWorkout so Apple
            // Health shows the in-workout heart-rate graph. Added to the builder collection (before
            // endCollection) so they associate with the workout. Sync ids keep re-sync idempotent.
            if let hr = Self.heartRateSeries(forWorkoutStart: w.startDate, in: heartRates) {
                var attached = 0
                for s in hr where w.startDate ... w.endDate ~= s.date {
                    samples.append(quantity(heartRate, bpm, Double(s.bpm), start: s.date, end: s.date,
                                            id: "mb-whr-\(key)-\(Int(s.date.timeIntervalSince1970))"))
                    attached += 1
                }
                log.info("Workout \(key): attaching \(attached) in-workout HR sample(s) to HKWorkout")
            }
            samples = shareable(samples)
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
            metadata["MiBandWorkoutKind"] = w.kind.rawValue
            // Weather at the workout's location/time (Open-Meteo). Apple Health shows condition,
            // temperature and humidity in the workout detail. Humidity is a fraction (0–1) in the
            // percent unit; condition is the HKWeatherCondition raw value.
            if let wx = weather[key] {
                metadata[HKMetadataKeyWeatherCondition] = Self.weatherCondition(wmo: wx.wmoCode).rawValue
                metadata[HKMetadataKeyWeatherTemperature] = HKQuantity(unit: .degreeCelsius(), doubleValue: wx.temperatureC)
                metadata[HKMetadataKeyWeatherHumidity] = HKQuantity(unit: .percent(), doubleValue: wx.humidityPct / 100.0)
            }
            // Average intensity in METs (same math as the per-minute physicalEffort samples):
            // resting baseline + active kcal per kg per hour. Health shows it in the workout detail.
            if let kcal = w.caloriesKcal, let weightKg, weightKg > 0, w.duration > 60 {
                let met = 1.0 + kcal * 3600.0 / (weightKg * w.duration)
                if (1.0...30.0).contains(met) {
                    metadata[HKMetadataKeyAverageMETs] = HKQuantity(unit: Self.metUnit, doubleValue: met)
                }
            }
            try await builder.addMetadata(metadata)

            try await builder.endCollection(at: workoutEnd)
            guard let workout = try await builder.finishWorkout() else { continue }
            written += 1
            // Only now are the builder's samples in Apple Health.
            count(samples)
            count(workoutType)
            saved[key] = workout

            // VO₂max is a standalone sample (not a workout statistic). The test-type metadata tells
            // Health it's a sub-maximal exercise prediction (which is how the band estimates it),
            // same as the Apple Watch's own samples.
            if let vo2 = w.vo2Max, (10...90).contains(vo2) {
                let unit = HKUnit.literUnit(with: .milli)
                    .unitDivided(by: HKUnit.gramUnit(with: .kilo).unitMultiplied(by: .minute()))
                var meta = syncMetadata("mb-vo2-\(key)")
                meta[HKMetadataKeyVO2MaxTestType] = HKVO2MaxTestType.predictionSubMaxExercise.rawValue
                try await save([HKQuantitySample(type: vo2Max, quantity: HKQuantity(unit: unit, doubleValue: vo2),
                                                 start: w.endDate, end: w.endDate, metadata: meta)])
            }

            // Estimated workout effort (iOS 18): the Fitness app's 1–10 "Effort" scale, derived
            // from the band's average workout HR as a fraction of the age-estimated max HR
            // (linear: 45% → 1, 90%+ → 10). The sample must be saved and then *related* to the
            // workout — the relationship is what Fitness displays. Best-effort: a failure here
            // must not abort the batch (the workout itself is already saved).
            if #available(iOS 18.0, *), let avg = w.hrAvg, (60...220).contains(avg),
               canShare(HKQuantityType(.estimatedWorkoutEffortScore)) {
                let score = min(10.0, max(1.0, ((avg / estimatedMaxHR - 0.40) * 20).rounded()))
                let sample = HKQuantitySample(
                    type: HKQuantityType(.estimatedWorkoutEffortScore),
                    quantity: HKQuantity(unit: .appleEffortScore(), doubleValue: score),
                    start: w.startDate, end: w.endDate,
                    metadata: syncMetadata("mb-weffort-\(key)"))
                do {
                    try await save([sample])
                    _ = try await store.relateWorkoutEffortSample(sample, with: workout, activity: nil)
                } catch {
                    log.error("Workout effort score failed (start \(key)): \(error.localizedDescription)")
                }
            }

            // Attach the GPS route, if this workout had one. A route failure must not abort the
            // whole batch — the workout is already saved, so log it and move on; the file still
            // gets ACKed and the workout itself is intact in Apple Health.
            if let track = Self.route(forWorkoutStart: w.startDate, in: routes) {
                do { try await attachRoute(track, to: workout) }
                catch { log.error("Workout route attach failed (start \(key)): \(error.localizedDescription)") }
            }
        }
        return (written, saved)
    }

    // MARK: - HR recovery (post-strength)

    /// Writes the 3-minute post-workout heart-rate recovery samples. When `workout` is given (the
    /// usual case), they're saved and then associated with it via `add(_:to:)` so they extend the
    /// workout's HR graph into the recovery period; the workout's window was extended by the recovery
    /// length at write time so the samples fall inside it. When it's nil (the workout didn't sync in
    /// time), the samples are still saved as standalone heart rate so the recovery curve isn't lost.
    /// Sync-ids keep re-writes idempotent.
    func writeRecoveryHR(_ samples: [WorkoutHRSample], toWorkout workout: HKWorkout?) async throws -> Int {
        guard !samples.isEmpty else { return 0 }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let hkSamples = samples.map { s in
            quantity(heartRate, bpm, Double(s.bpm), start: s.date, end: s.date,
                     id: "mb-recovery-\(Int(s.date.timeIntervalSince1970))")
        }
        try await save(hkSamples)
        if let workout {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                store.add(hkSamples, to: workout) { _, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                }
            }
        }
        return hkSamples.count
    }

    // MARK: - GPS route

    /// Picks the GPS track for a workout. The band tags the workout summary and its GPS track with
    /// the same session-start timestamp, but the two file ids can differ by a second or two, so
    /// fall back to the nearest track that starts within two minutes of the workout.
    private static func route(forWorkoutStart start: Date,
                              in routes: [Int: [WorkoutTrackPoint]]) -> [WorkoutTrackPoint]? {
        let key = Int(start.timeIntervalSince1970)
        if let exact = routes[key] { return exact }
        return routes
            .filter { abs($0.key - key) <= 120 }
            .min { abs($0.key - key) < abs($1.key - key) }?
            .value
    }

    /// Picks the per-second HR series for a workout. Same nearest-within-two-minutes match as the
    /// GPS route: the summary and detail files share the session-start timestamp but their file ids
    /// can differ by a second or two.
    private static func heartRateSeries(forWorkoutStart start: Date,
                                        in series: [Int: [WorkoutHRSample]]) -> [WorkoutHRSample]? {
        let key = Int(start.timeIntervalSince1970)
        if let exact = series[key] { return exact }
        return series
            .filter { abs($0.key - key) <= 120 }
            .min { abs($0.key - key) < abs($1.key - key) }?
            .value
    }

    /// Builds an HKWorkoutRoute from a band GPS track. Two HealthKit constraints drive the
    /// cleanup here: CoreLocation treats a sample with negative `horizontalAccuracy` as invalid
    /// and `insertRouteData` rejects the whole batch if any is invalid; and the builder requires
    /// strictly increasing timestamps. So duplicate/out-of-order fixes are dropped and the band's
    /// hdop is mapped to a positive metre estimate.
    private func attachRoute(_ track: [WorkoutTrackPoint], to workout: HKWorkout) async throws {
        var lastTime = -Double.greatestFiniteMagnitude
        let locations: [CLLocation] = track
            .sorted { $0.date < $1.date }
            .compactMap { p in
                let t = p.date.timeIntervalSince1970
                guard t > lastTime else { return nil }   // strictly increasing — drop dupes
                lastTime = t
                // hdop is a dimensionless dilution of precision; scale by a nominal 5 m UERE to
                // get a usable accuracy estimate. Missing/zero hdop (V1 tracks) → a conservative
                // fixed value, which keeps the sample valid so HealthKit accepts the route.
                let accuracy: CLLocationAccuracy
                if let hdop = p.hdop, hdop > 0 { accuracy = hdop * 5.0 } else { accuracy = 10.0 }
                return CLLocation(
                    coordinate: CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude),
                    altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                    course: -1, speed: p.speed ?? -1, timestamp: p.date
                )
            }
        guard locations.count >= 2, canShare(routeType) else { return }
        let routeBuilder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        try await routeBuilder.insertRouteData(locations)
        _ = try await routeBuilder.finishRoute(with: workout, metadata: nil)
        count(routeType)
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
        case .strengthTraining:                      .traditionalStrengthTraining
        case .freeTraining, .other:                  .other
        }
    }

    /// WMO weather code (Open-Meteo) → HKWeatherCondition for workout metadata. Unknown codes map to
    /// `.none` so Health simply omits the condition icon rather than showing a wrong one.
    private static func weatherCondition(wmo: Int) -> HKWeatherCondition {
        switch wmo {
        case 0:            return .clear
        case 1:            return .fair
        case 2:            return .partlyCloudy
        case 3:            return .cloudy
        case 45, 48:       return .foggy
        case 51, 53, 55:   return .drizzle
        case 56, 57:       return .freezingDrizzle
        case 61, 63, 65:   return .showers
        case 66, 67:       return .freezingRain
        case 71, 73, 75, 77: return .snow
        case 80, 81:       return .scatteredShowers
        case 82:           return .showers
        case 85, 86:       return .snow
        case 95, 96, 99:   return .thunderstorms
        default:           return .none
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
        case .treadmill, .indoorCycling, .elliptical, .rowingMachine, .hiit, .yoga, .freeTraining, .strengthTraining: true
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

    /// Quantity type for the in-workout GPS speed series. Only kinds whose speed has a dedicated
    /// HealthKit type; walking/hiking return nil on purpose — walkingSpeed would feed the iPhone's
    /// Mobility metrics, which stay iPhone-authoritative.
    private static func speedType(_ kind: WorkoutKind) -> HKQuantityType? {
        switch kind {
        case .running, .trailRun: HKQuantityType(.runningSpeed)
        case .outdoorCycling:     HKQuantityType(.cyclingSpeed)
        default:                  nil
        }
    }

    // MARK: - Cardio Recovery (heartRateRecoveryOneMinute)
    //
    // The band's 1 Hz workout series stops exactly at the workout end (sample count == duration),
    // so recovery can't come from the workout file alone. But the daily per-minute file keeps
    // sampling HR after the workout: once that batch arrives, each recent workout's end-of-exercise
    // peak (the 1 Hz samples already written to Health) is paired with the per-minute reading
    // closest to end+60 s. Both readings are real band measurements — nothing synthesized. This
    // runs on the daily-details path (not writeWorkouts) because the workout may have been written
    // by an earlier targeted post-workout sync, before the minute file existed.

    func writeHeartRateRecoveries(minutes: [ActivityMinuteSample]) async throws -> Int {
        guard canShare(hrRecovery) else { return 0 }
        let hrMinutes = minutes
            .compactMap { m in m.heartRate.map { (date: m.date, bpm: $0) } }
            .filter { (30...250).contains($0.bpm) }
            .sorted { $0.date < $1.date }
        guard let first = hrMinutes.first?.date, let last = hrMinutes.last?.date else { return 0 }

        // Our workouts whose end+60 s reading could be inside this batch's span.
        let workouts = try await ownWorkouts(endingBetween: first.addingTimeInterval(-90),
                                             and: last.addingTimeInterval(-30))
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var samples: [HKSample] = []
        for workout in workouts where workout.duration >= 120 {
            let target = workout.endDate.addingTimeInterval(60)
            // Per-minute grid means the reading rarely lands exactly on end+60; ±30 s tolerance.
            guard let recovery = hrMinutes
                .filter({ abs($0.date.timeIntervalSince(target)) <= 30 })
                .min(by: { abs($0.date.timeIntervalSince(target)) < abs($1.date.timeIntervalSince(target)) })
            else { continue }
            // try? — a window with no samples (workout without a 1 Hz series) reports errorNoData;
            // that just means "no recovery for this one", not a batch failure.
            guard let peak = try? await ownHeartRatePeak(
                from: workout.endDate.addingTimeInterval(-60), to: workout.endDate) else { continue }
            let drop = peak - Double(recovery.bpm)
            guard (1...120).contains(drop) else { continue }   // HR must actually have dropped
            let key = Int(workout.startDate.timeIntervalSince1970)
            samples.append(quantity(hrRecovery, bpm, drop, start: target, end: target, id: "mb-hrr-\(key)"))
        }
        return try await save(samples)
    }

    /// Workouts written by this app whose endDate falls in [start, end].
    private func ownWorkouts(endingBetween start: Date, and end: Date) async throws -> [HKWorkout] {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let time = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictEndDate)
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, time])
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[HKWorkout], Error>) in
            let q = HKSampleQuery(sampleType: workoutType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples as? [HKWorkout]) ?? [])
            }
            store.execute(q)
        }
    }

    /// Peak of this app's own HR samples in [start, end] — the workout's 1 Hz series tail.
    private func ownHeartRatePeak(from start: Date, to end: Date) async throws -> Double? {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let time = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [mine, time])
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double?, Error>) in
            let q = HKStatisticsQuery(quantityType: heartRate, quantitySamplePredicate: predicate,
                                      options: .discreteMax) { _, stats, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: stats?.maximumQuantity()?.doubleValue(for: bpm))
            }
            store.execute(q)
        }
    }

    // MARK: - Workout history (read, ADR 0009)

    /// The newest workouts this app wrote, newest first. Only this app's: another source's workout
    /// would read as the band's. A locked iPhone throws `errorDatabaseInaccessible`.
    func recentWorkouts(limit: Int = 50) async throws -> [WorkoutRecord] {
        let mine = HKQuery.predicateForObjects(from: [HKSource.default()])
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(mine)],
            sortDescriptors: [SortDescriptor(\.startDate, order: .reverse)],
            limit: limit)
        return try await descriptor.result(for: store).map(record)
    }

    private func record(_ w: HKWorkout) -> WorkoutRecord {
        let bpm = HKUnit.count().unitDivided(by: .minute())
        var distanceTypes = [distance, distanceCycling, distanceSwimming]
        if #available(iOS 18.0, *) { distanceTypes.append(HKQuantityType(.distanceRowing)) }
        let meters = distanceTypes.lazy
            .compactMap { w.statistics(for: $0)?.sumQuantity()?.doubleValue(for: .meter()) }
            .first { $0 > 0 }
        let hr = w.statistics(for: heartRate)
        let meta = w.metadata ?? [:]
        let flaggedIndoor = (meta[HKMetadataKeyIndoorWorkout] as? NSNumber)?.boolValue
        let swimLocation = (meta[HKMetadataKeySwimmingLocationType] as? NSNumber)?.intValue
            ?? w.workoutActivities.first?.workoutConfiguration.swimmingLocationType.rawValue
        let kind = (meta["MiBandWorkoutKind"] as? String).flatMap(WorkoutKind.init(rawValue:))
            ?? Self.kind(w.workoutActivityType, indoor: flaggedIndoor ?? false,
                         openWater: swimLocation == HKWorkoutSwimmingLocationType.openWater.rawValue)
        // The write stores indoor = false for every swim, so a swim's location comes from its kind.
        let indoor: Bool? = switch kind {
        case .poolSwim: true
        case .openWaterSwim: false
        default: flaggedIndoor
        }
        // The band's own summary HR wins; the 1 Hz series only exists when its details file arrived.
        return WorkoutRecord(
            id: w.uuid,
            kind: kind,
            start: w.startDate, end: w.endDate, duration: w.duration,
            distanceMeters: meters,
            activeKcal: w.statistics(for: activeEnergy)?.sumQuantity()?.doubleValue(for: .kilocalorie()),
            hrAvg: (meta["MiBandAverageHeartRate"] as? Double) ?? hr?.averageQuantity()?.doubleValue(for: bpm),
            hrMax: (meta["MiBandMaxHeartRate"] as? Double) ?? hr?.maximumQuantity()?.doubleValue(for: bpm),
            hrMin: (meta["MiBandMinHeartRate"] as? Double) ?? hr?.minimumQuantity()?.doubleValue(for: bpm),
            indoor: indoor,
            averageMETs: (meta[HKMetadataKeyAverageMETs] as? HKQuantity)?.doubleValue(for: Self.metUnit))
    }

    /// Inverse of `activityType(_:)`, for workouts written before `MiBandWorkoutKind`. Lossy: trail
    /// runs read back as runs, treks as hikes, free training as a generic workout.
    private static func kind(_ type: HKWorkoutActivityType, indoor: Bool, openWater: Bool) -> WorkoutKind {
        switch type {
        case .running:                         indoor ? .treadmill : .running
        case .walking:                         .walking
        case .hiking:                          .hiking
        case .cycling:                         indoor ? .indoorCycling : .outdoorCycling
        case .swimming:                        openWater ? .openWaterSwim : .poolSwim
        case .elliptical:                      .elliptical
        case .rowing:                          indoor ? .rowingMachine : .rowing
        case .jumpRope:                        .jumpRoping
        case .highIntensityIntervalTraining:   .hiit
        case .yoga:                            .yoga
        case .traditionalStrengthTraining:     .strengthTraining
        default:                               .other
        }
    }

    // MARK: - Helpers

    // MARK: - Body mass (scale)
    //
    // Writes a weight reading from the BLE scale as bodyMass, plus a derived bodyMassIndex when the
    // user's height is available in Apple Health (the scale only measures weight). Sync identifiers
    // key off the reading timestamp so a re-broadcast of the same weighing collapses to one sample.

    @discardableResult
    func writeBodyMass(_ kg: Double, date: Date, heightMeters: Double? = nil) async throws -> Int {
        guard (2...500).contains(kg) else { return 0 }   // reject implausible readings
        let key = Int(date.timeIntervalSince1970)
        var samples: [HKSample] = [
            quantity(bodyMass, .gramUnit(with: .kilo), kg, start: date, end: date, id: "mb-weight-\(key)")
        ]
        // BMI needs height: prefer the value the caller passed (the app's profile), else the most
        // recent height already in Apple Health. Without either, weight is written on its own.
        var m = heightMeters
        if m == nil { m = (try? await latestHeightMeters()) ?? nil }
        if let m, m > 0.5 {
            let bmi = kg / (m * m)
            samples.append(quantity(bodyMassIndex, .count(), bmi, start: date, end: date, id: "mb-bmi-\(key)"))
        }
        return try await save(samples, tallied: false)
    }

    /// Writes the user's height (entered in the app's profile) so Apple Health has it and BMI derives.
    @discardableResult
    func writeHeight(meters: Double, date: Date = Date()) async throws -> Int {
        guard (0.5...2.6).contains(meters) else { return 0 }
        return try await save([quantity(height, .meter(), meters, start: date, end: date, id: "mb-height")], tallied: false)
    }

    /// Most recent height sample from Apple Health, in metres, or nil if none/denied.
    private func latestHeightMeters() async throws -> Double? {
        try await latestQuantity(of: height, unit: .meter())
    }

    /// Most recent body-mass sample from Apple Health (the BLE scale keeps it fresh), in kg.
    /// Feeds the MET math (physical effort, average workout METs); nil when none/denied.
    private func latestBodyMassKg() async throws -> Double? {
        try await latestQuantity(of: bodyMass, unit: .gramUnit(with: .kilo))
    }

    private func latestQuantity(of type: HKQuantityType, unit: HKUnit) async throws -> Double? {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Double?, Error>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let q = HKSampleQuery(sampleType: type, predicate: nil, limit: 1, sortDescriptors: [sort]) { _, samples, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: (samples?.first as? HKQuantitySample)?.quantity.doubleValue(for: unit))
            }
            store.execute(q)
        }
    }

    /// Tanaka estimate (208 − 0.7·idade) from the Health profile's date of birth; 190 bpm when
    /// the characteristic is missing or denied. Drives the workout effort score only — never stored.
    private func estimatedMaxHeartRate() -> Double {
        guard let dob = try? store.dateOfBirthComponents(),
              let birth = Calendar.current.date(from: dob) else { return 190 }
        let age = Date().timeIntervalSince(birth) / 31_557_600
        guard (5...120).contains(age) else { return 190 }
        return 208 - 0.7 * age
    }

    private func quantity(_ type: HKQuantityType, _ unit: HKUnit, _ value: Double,
                          start: Date, end: Date, id: String, version: Int? = nil) -> HKQuantitySample {
        HKQuantitySample(type: type, quantity: HKQuantity(unit: unit, doubleValue: value),
                         start: start, end: end, metadata: syncMetadata(id, version: version))
    }

    /// `version` defaults to the constant syncVersion — fine for immutable data (sleep, manual,
    /// workout). writeActivity passes a monotonic version so re-syncs can replace.
    private func syncMetadata(_ id: String, version: Int? = nil) -> [String: Any] {
        [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: version ?? syncVersion]
    }

    @discardableResult
    /// `tallied: false` for the scale and profile, whose writes can land mid-sync but aren't the band's.
    private func save(_ samples: [HKSample], tallied: Bool = true) async throws -> Int {
        let allowed = shareable(samples)
        guard !allowed.isEmpty else { return 0 }
        try await store.save(allowed)
        if tallied { count(allowed) }
        return allowed.count
    }

    // MARK: - Per-type tally for the sync report

    private var tally: [String: Int]?

    /// Counts what is written from here to `endTally`, per HealthKit type.
    func beginTally() { tally = [:] }

    func endTally() -> [String: Int] {
        defer { tally = nil }
        return tally ?? [:]
    }

    private func count(_ samples: [HKSample]) {
        guard tally != nil else { return }
        for s in samples { tally?[s.sampleType.identifier, default: 0] += 1 }
    }

    private func count(_ type: HKSampleType) {
        guard tally != nil else { return }
        tally?[type.identifier, default: 0] += 1
    }

    /// Set when a write dropped samples for permission. BandSyncer takes it after each write group
    /// and leaves those files un-ACKed: an ACK makes the band delete a file this app never wrote.
    private var skippedForPermission = false

    func takeSkippedForPermission() -> Bool {
        defer { skippedForPermission = false }
        return skippedForPermission
    }

    /// One type switched off in Health → Data Access fails the whole save with "Not authorized", so
    /// samples of a type this app can't write are dropped (and named in the log) instead.
    private func shareable(_ samples: [HKSample]) -> [HKSample] {
        var denied: Set<String> = []
        let allowed = samples.filter { sample in
            if canShare(sample.sampleType) { return true }
            denied.insert(sample.sampleType.identifier)
            return false
        }
        if !denied.isEmpty {
            skippedForPermission = true
            log.warning("Not allowed to write \(denied.sorted().joined(separator: ", "), privacy: .public) — skipped")
        }
        return allowed
    }
}

// MARK: - WorkoutRecord

/// A workout read back from Apple Health for the Workouts screen; held in memory only.
struct WorkoutRecord: Identifiable {
    let id: UUID
    let kind: WorkoutKind
    let start: Date
    let end: Date
    let duration: TimeInterval
    let distanceMeters: Double?
    let activeKcal: Double?
    let hrAvg: Double?
    let hrMax: Double?
    let hrMin: Double?
    let indoor: Bool?
    let averageMETs: Double?
}

// MARK: - Errors

enum HealthError: LocalizedError {
    case unavailable
    var errorDescription: String? {
        switch self {
        case .unavailable: "Apple Health isn't available on this device."
        }
    }
}
