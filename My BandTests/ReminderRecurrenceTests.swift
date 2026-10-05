import EventKit
import Foundation
import Testing
@testable import My_Band

@MainActor
struct ReminderRecurrenceTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    /// Monday 2026-10-05 09:00 UTC.
    private var monday: Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 9)) ?? .distantPast
    }

    private func rule(_ f: EKRecurrenceFrequency, interval: Int = 1, days: [EKRecurrenceDayOfWeek]? = nil,
                      end: EKRecurrenceEnd? = nil) -> EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: f, interval: interval, daysOfTheWeek: days, daysOfTheMonth: nil,
                         monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: end)
    }

    private func map(_ r: EKRecurrenceRule?) -> ReminderService.Repeat {
        CalendarSyncService.repeatRule(r, firing: monday, calendar: cal)
    }

    @Test func plainRulesMapToTheBandsRepeats() {
        #expect(map(nil) == .once)
        #expect(map(rule(.daily)) == .daily)
        #expect(map(rule(.weekly)) == .weekly)
        #expect(map(rule(.monthly)) == .monthly)
        #expect(map(rule(.yearly)) == .yearly)
    }

    @Test func weeklyOnTheFiringWeekdayMapsButOtherDaysDoNot() {
        #expect(map(rule(.weekly, days: [EKRecurrenceDayOfWeek(.monday)])) == .weekly)
        #expect(map(rule(.weekly, days: [EKRecurrenceDayOfWeek(.tuesday)])) == .once)
        #expect(map(rule(.weekly, days: [EKRecurrenceDayOfWeek(.monday), EKRecurrenceDayOfWeek(.friday)])) == .once)
    }

    @Test func monthlyAndYearlyNamingTheFiringDayStillMap() {
        func full(_ f: EKRecurrenceFrequency, monthDays: [NSNumber]?, months: [NSNumber]?) -> EKRecurrenceRule {
            EKRecurrenceRule(recurrenceWith: f, interval: 1, daysOfTheWeek: nil, daysOfTheMonth: monthDays,
                             monthsOfTheYear: months, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
        }
        #expect(map(full(.monthly, monthDays: [5], months: nil)) == .monthly)
        #expect(map(full(.monthly, monthDays: [20], months: nil)) == .once)
        #expect(map(full(.yearly, monthDays: [5], months: [10])) == .yearly)
        #expect(map(full(.yearly, monthDays: nil, months: [3])) == .once)
    }

    @Test func intervalsAndEndingRulesGoOneOccurrenceAtATime() {
        #expect(map(rule(.daily, interval: 2)) == .once)
        #expect(map(rule(.daily, end: EKRecurrenceEnd(occurrenceCount: 5))) == .once)
        #expect(map(rule(.weekly, end: EKRecurrenceEnd(end: monday.addingTimeInterval(86_400 * 30)))) == .once)
    }
}
