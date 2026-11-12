import Foundation

// MARK: - NightRatings
//
// How a night felt, 0–5, keyed by the day the night ends on. The app's one stored health-like
// value (ADR 0010 addendum): UserDefaults rather than SwiftData, so a store reset doesn't lose it.

enum NightRatings {

    static let key = "nightRatings"
    static let range = 0 ... 5
    static let keepDays = 90

    static func rating(for day: Date, defaults: UserDefaults = .standard, calendar: Calendar = .current) -> Int? {
        stored(defaults)[dayKey(day, calendar: calendar)]
    }

    /// nil clears the night. Every write drops entries older than `keepDays`.
    static func set(_ rating: Int?, for day: Date, now: Date = .now,
                    defaults: UserDefaults = .standard, calendar: Calendar = .current) {
        var all = stored(defaults)
        all[dayKey(day, calendar: calendar)] = rating.map { min(max($0, range.lowerBound), range.upperBound) }
        if let oldest = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now)) {
            all = all.filter { k, _ in self.day(fromKey: k, calendar: calendar).map { $0 >= oldest } ?? false }
        }
        defaults.set(all, forKey: key)
    }

    private static func stored(_ defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    /// "2026-11-12" in the calendar's time zone; the notification's `night` uses the same form.
    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func day(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
