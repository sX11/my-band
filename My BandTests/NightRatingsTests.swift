import Foundation
import Testing
@testable import My_Band

struct NightRatingsTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    private func day(_ month: Int, _ day: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: month, day: day)) ?? .distantPast
    }

    private func freshDefaults(_ name: String) throws -> UserDefaults {
        let defaults = try #require(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func aRatingReadsBackForItsNight() throws {
        let defaults = try freshDefaults("NightRatingsTests.roundTrip")
        NightRatings.set(4, for: day(11, 11), now: day(11, 12), defaults: defaults, calendar: cal)
        #expect(NightRatings.rating(for: day(11, 11), defaults: defaults, calendar: cal) == 4)
        #expect(NightRatings.rating(for: day(11, 10), defaults: defaults, calendar: cal) == nil)
    }

    @Test func clearingRemovesTheRating() throws {
        let defaults = try freshDefaults("NightRatingsTests.clear")
        NightRatings.set(0, for: day(11, 11), now: day(11, 12), defaults: defaults, calendar: cal)
        #expect(NightRatings.rating(for: day(11, 11), defaults: defaults, calendar: cal) == 0)
        NightRatings.set(nil, for: day(11, 11), now: day(11, 12), defaults: defaults, calendar: cal)
        #expect(NightRatings.rating(for: day(11, 11), defaults: defaults, calendar: cal) == nil)
    }

    @Test func aRatingOlderThanNinetyDaysIsPrunedOnTheNextWrite() throws {
        let defaults = try freshDefaults("NightRatingsTests.prune")
        let now = day(11, 12)
        let old = try #require(cal.date(byAdding: .day, value: -91, to: now))
        let kept = try #require(cal.date(byAdding: .day, value: -90, to: now))
        NightRatings.set(3, for: old, now: old, defaults: defaults, calendar: cal)
        NightRatings.set(2, for: kept, now: kept, defaults: defaults, calendar: cal)
        NightRatings.set(5, for: now, now: now, defaults: defaults, calendar: cal)
        #expect(NightRatings.rating(for: old, defaults: defaults, calendar: cal) == nil)
        #expect(NightRatings.rating(for: kept, defaults: defaults, calendar: cal) == 2)
        #expect(NightRatings.rating(for: now, defaults: defaults, calendar: cal) == 5)
    }
}
