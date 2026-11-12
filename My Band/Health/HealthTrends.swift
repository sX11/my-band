import Foundation

// MARK: - Trend values (ADR 0010)
//
// Shapes for the Sleep & trends page, read back from Apple Health and held in memory only.

struct DayValue: Identifiable, Equatable {
    let day: Date
    let value: Double
    var id: Date { day }
}

enum SleepTrend {

    /// The trend window, in days ending today; the queries, the chart domain and the copy share it.
    static let days = 7

    enum Stage: CaseIterable {
        case deep, core, rem, unspecified
        /// Held in the per-minute merge so the band's awake minutes override another source's
        /// asleep ones, then left out of every total.
        case awake

        static var asleep: [Stage] { [.deep, .core, .rem, .unspecified] }

        var title: String {
            switch self {
            case .deep: "Deep"
            case .core: "Light"
            case .rem: "REM"
            case .unspecified: "Asleep"
            case .awake: "Awake"
            }
        }
    }

    struct Interval {
        let start: Date
        let end: Date
        let stage: Stage
        /// Written by this app: the band's stages win a minute another source also claims.
        let preferred: Bool
    }

    struct Segment: Equatable {
        let start: Date
        let end: Date
        let stage: Stage
    }

    struct Night: Identifiable, Equatable {
        let day: Date
        /// Every asleep minute of the day, naps included, as the bar shows it.
        let minutes: [Stage: Int]
        /// The main sleep: the longest run of asleep minutes, so a daytime nap neither stretches
        /// the span nor pulls daytime vitals into it.
        let start: Date
        let end: Date
        /// Runs of one stage inside the span, awake included; a minute no source covers breaks a run.
        let segments: [Segment]
        var id: Date { day }
        var total: Int { minutes.values.reduce(0, +) }
        /// Asleep minutes of the main sleep alone, naps left out, unlike `total`.
        var mainAsleep: Int {
            segments.filter { $0.stage != .awake }.reduce(0) { $0 + Int(($1.end.timeIntervalSince($1.start) / 60).rounded()) }
        }
        var span: DateInterval { DateInterval(start: start, end: end) }
    }

    /// Asleep runs this close are one sleep: waking for a while in the night doesn't split it.
    static let joinGapMinutes = 60

    /// A night belongs to the day it ends on, cut at 18:00, so a nap after six counts for the next day.
    static let nightCutoffHours = 6

    /// Per-night asleep minutes by stage for the `days` nights ending today. Overlapping samples
    /// from several sources (iPhone, band) are counted once per minute; Apple Health itself
    /// shows the overlap merged, and summing them would double a night.
    static func nights(_ intervals: [Interval], days: Int, today: Date, calendar: Calendar) -> [Night] {
        var byMinute: [Int: (stage: Stage, preferred: Bool)] = [:]
        for i in intervals where i.end > i.start {
            // A minute belongs to an interval that covers its midpoint, so a fragment shorter than
            // a minute isn't rounded out to every minute it touches.
            let first = Int(((i.start.timeIntervalSince1970 - 30) / 60).rounded(.up))
            let last = Int(((i.end.timeIntervalSince1970 - 30) / 60).rounded(.up)) - 1
            guard last >= first else { continue }
            for m in first...last {
                if let held = byMinute[m], held.preferred || !i.preferred { continue }
                byMinute[m] = (i.stage, i.preferred)
            }
        }
        guard let firstNight = calendar.date(byAdding: .day, value: -(days - 1), to: calendar.startOfDay(for: today))
        else { return [] }
        var perNight: [Date: [Stage: Int]] = [:]
        var held: [Date: [(minute: Int, stage: Stage)]] = [:]
        for (m, h) in byMinute {
            let at = Date(timeIntervalSince1970: TimeInterval(m * 60))
            guard let shifted = calendar.date(byAdding: .hour, value: nightCutoffHours, to: at) else { continue }
            let night = calendar.startOfDay(for: shifted)
            guard night >= firstNight, night <= today else { continue }
            held[night, default: []].append((m, h.stage))
            if h.stage != .awake { perNight[night, default: [:]][h.stage, default: 0] += 1 }
        }
        return perNight.compactMap { day, minutes in
            mainSleep(held[day] ?? []).map {
                Night(day: day, minutes: minutes, start: $0.start, end: $0.end, segments: $0.segments)
            }
        }
        .sorted { $0.day < $1.day }
    }

    private static func mainSleep(_ held: [(minute: Int, stage: Stage)])
        -> (start: Date, end: Date, segments: [Segment])? {
        let sorted = held.sorted { $0.minute < $1.minute }
        var runs: [(first: Int, last: Int, asleep: Int)] = []
        for h in sorted where h.stage != .awake {
            if let run = runs.last, h.minute - run.last - 1 <= joinGapMinutes {
                runs[runs.count - 1] = (run.first, h.minute, run.asleep + 1)
            } else {
                runs.append((h.minute, h.minute, 1))
            }
        }
        guard let main = runs.max(by: { $0.asleep < $1.asleep }) else { return nil }
        func date(_ minute: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(minute * 60)) }

        var segments: [Segment] = []
        var open: (first: Int, last: Int, stage: Stage)?
        for h in sorted where h.minute >= main.first && h.minute <= main.last {
            if let run = open, run.stage == h.stage, run.last == h.minute - 1 {
                open = (run.first, h.minute, run.stage)
                continue
            }
            if let run = open { segments.append(Segment(start: date(run.first), end: date(run.last + 1), stage: run.stage)) }
            open = (h.minute, h.minute, h.stage)
        }
        if let run = open { segments.append(Segment(start: date(run.first), end: date(run.last + 1), stage: run.stage)) }
        return (date(main.first), date(main.last + 1), segments)
    }
}

// MARK: - Night vitals

enum VitalKind: CaseIterable {
    case heartRate, hrv, spo2
}

struct VitalPoint: Equatable {
    let date: Date
    let value: Double
}

/// Heart rate (bpm), HRV SDNN (ms) and SpO₂ (%) read inside one night's main sleep.
struct NightVitals: Equatable {
    var hr: [VitalPoint] = []
    var hrv: [VitalPoint] = []
    var spo2: [VitalPoint] = []

    var hrMin: Double? { hr.map(\.value).min() }
    var hrAvg: Double? { Self.mean(hr.map(\.value)) }
    var hrvMedian: Double? { Self.median(hrv.map(\.value)) }
    var spo2Avg: Double? { Self.mean(spo2.map(\.value)) }
    var spo2Min: Double? { spo2.map(\.value).min() }

    /// Each point goes to the night whose span holds it; a point outside every span (daytime, a nap) is dropped.
    static func split(_ points: [VitalKind: [VitalPoint]], spans: [Date: DateInterval]) -> [Date: NightVitals] {
        var out = spans.mapValues { _ in NightVitals() }
        for (kind, list) in points {
            for p in list {
                guard let day = spans.first(where: { p.date >= $0.value.start && p.date < $0.value.end })?.key else { continue }
                switch kind {
                case .heartRate: out[day]?.hr.append(p)
                case .hrv: out[day]?.hrv.append(p)
                case .spo2: out[day]?.spo2.append(p)
                }
            }
        }
        return out.mapValues { v in
            NightVitals(hr: v.hr.sorted { $0.date < $1.date }, hrv: v.hrv.sorted { $0.date < $1.date },
                        spo2: v.spo2.sorted { $0.date < $1.date })
        }
    }

    /// The value against the mean of the other nights; a mean of one night says nothing, so it
    /// takes at least two.
    static func delta(_ value: Double?, others: [Double]) -> Double? {
        guard let value, others.count >= 2, let mean = mean(others) else { return nil }
        return value - mean
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let mid = s.count / 2
        return s.count % 2 == 0 ? (s[mid - 1] + s[mid]) / 2 : s[mid]
    }

    static func mean(_ values: [Double]) -> Double? {
        values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
}
