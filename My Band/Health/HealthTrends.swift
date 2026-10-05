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

    struct Night: Identifiable, Equatable {
        let day: Date
        let minutes: [Stage: Int]
        var id: Date { day }
        var total: Int { minutes.values.reduce(0, +) }
    }

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
        for (m, held) in byMinute where held.stage != .awake {
            let at = Date(timeIntervalSince1970: TimeInterval(m * 60))
            guard let shifted = calendar.date(byAdding: .hour, value: nightCutoffHours, to: at) else { continue }
            let night = calendar.startOfDay(for: shifted)
            guard night >= firstNight, night <= today else { continue }
            perNight[night, default: [:]][held.stage, default: 0] += 1
        }
        return perNight.map { Night(day: $0.key, minutes: $0.value) }.sorted { $0.day < $1.day }
    }
}
