import Foundation
import OSLog

// MARK: - LatestMetrics
//
// The newest value of each band-only health reading seen by a sync, for the Dashboard's Health
// sheet (ADR 0006). One snapshot, overwritten in place — the history stays in Apple Health.

struct LatestMetrics: Codable, Equatable {

    struct Reading: Codable, Equatable {
        var value: Double
        var at: Date
    }

    /// The newest daily summary's day, and that day's aggregates.
    var summaryDay: Date?
    var restingHR: Int?
    var avgHR: Int?
    var maxHR: Reading?
    var minHR: Reading?
    var avgStress: Int?
    var spo2Avg: Int?
    var spo2Min: Reading?
    var spo2Max: Reading?
    /// Bit `h` set ⇒ stood during hour `h` of `summaryDay`.
    var standingMask: Int?

    /// Newest single samples across the all-day series and the band's on-demand measurements.
    var heartRate: Reading?
    var spo2: Reading?
    var stress: Reading?
    var temperature: Reading?

    var standingHours: Int? { standingMask.map { $0.nonzeroBitCount } }

    var isEmpty: Bool { self == LatestMetrics() }

    mutating func record(_ s: DailySummary) {
        let day = Calendar.current.startOfDay(for: s.date)
        // A future day from a wrong band clock would never be replaced.
        guard day <= Calendar.current.startOfDay(for: .now) else { return }
        // Files arrive oldest-first from the backlog; an older day must not replace a newer one.
        if let summaryDay, day < summaryDay { return }
        summaryDay = day
        restingHR = s.restingHR
        avgHR = s.avgHR
        maxHR = s.maxHR.map { Reading(value: Double($0.bpm), at: $0.at) }
        minHR = s.minHR.map { Reading(value: Double($0.bpm), at: $0.at) }
        avgStress = s.avgStress
        spo2Avg = s.spo2Avg
        spo2Min = s.spo2Min.map { Reading(value: Double($0.pct), at: $0.at) }
        spo2Max = s.spo2Max.map { Reading(value: Double($0.pct), at: $0.at) }
        standingMask = s.standingHours
    }

    mutating func record(_ minutes: [ActivityMinuteSample]) {
        for m in minutes {
            if let hr = m.heartRate, (30...250).contains(hr) { Self.keepNewer(&heartRate, Double(hr), m.date) }
            if let o = m.spo2, (50...100).contains(o) { Self.keepNewer(&spo2, Double(o), m.date) }
            if let st = m.stress, (1...100).contains(st) { Self.keepNewer(&stress, Double(st), m.date) }
        }
    }

    mutating func record(_ samples: [ManualSample]) {
        for s in samples {
            switch s.kind {
            case .heartRate:   Self.keepNewer(&heartRate, s.value, s.date)
            case .spo2:        Self.keepNewer(&spo2, s.value, s.date)
            case .stress:      Self.keepNewer(&stress, s.value, s.date)
            case .temperature: Self.keepNewer(&temperature, s.value, s.date)
            }
        }
    }

    private static func keepNewer(_ slot: inout Reading?, _ value: Double, _ at: Date) {
        // The band's clock can hand out a sample from the future; it would then never be replaced.
        guard at <= Date().addingTimeInterval(5 * 60) else { return }
        if let current = slot, current.at >= at { return }
        slot = Reading(value: value, at: at)
    }
}

// MARK: - LatestMetricsStore

@Observable
@MainActor
final class LatestMetricsStore {

    private(set) var metrics: LatestMetrics
    private(set) var updatedAt: Date?

    private let defaults: UserDefaults
    private static let metricsKey = "latestMetricsV1"
    private static let updatedKey = "latestMetricsUpdatedAt"
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "LatestMetrics")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        metrics = defaults.data(forKey: Self.metricsKey)
            .flatMap { try? JSONDecoder().decode(LatestMetrics.self, from: $0) } ?? LatestMetrics()
        let at = defaults.double(forKey: Self.updatedKey)
        updatedAt = at > 0 ? Date(timeIntervalSince1970: at) : nil
    }

    func update(_ change: (inout LatestMetrics) -> Void) {
        var next = metrics
        change(&next)
        guard next != metrics else { return }
        metrics = next
        updatedAt = .now
        do {
            defaults.set(try JSONEncoder().encode(next), forKey: Self.metricsKey)
            defaults.set(Date.now.timeIntervalSince1970, forKey: Self.updatedKey)
        } catch {
            log.error("Could not save the latest metrics: \(error.localizedDescription)")
        }
    }

    /// Forget / re-pair: the readings belonged to the old band.
    func reset() {
        metrics = LatestMetrics()
        updatedAt = nil
        defaults.removeObject(forKey: Self.metricsKey)
        defaults.removeObject(forKey: Self.updatedKey)
    }
}
