import Foundation
import Testing
@testable import My_Band

struct SleepTrendTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    @Test func overlappingSourcesCountEachMinuteOnceWithTheBandsStage() {
        let iphone = SleepTrend.Interval(start: at(1, 23), end: at(2, 7), stage: .unspecified, preferred: false)
        let band = SleepTrend.Interval(start: at(2, 1), end: at(2, 3), stage: .deep, preferred: true)
        let nights = SleepTrend.nights([iphone, band], days: 7, today: at(2, 12), calendar: cal)
        #expect(nights.count == 1)
        #expect(nights.first?.total == 8 * 60)
        #expect(nights.first?.minutes[.deep] == 120)
        #expect(nights.first?.minutes[.unspecified] == 6 * 60)
    }

    @Test func sleepAfterSixInTheEveningCountsForTheNextDay() {
        let evening = SleepTrend.Interval(start: at(1, 19), end: at(1, 20), stage: .core, preferred: true)
        let nap = SleepTrend.Interval(start: at(1, 14), end: at(1, 15), stage: .core, preferred: true)
        let nights = SleepTrend.nights([evening, nap], days: 7, today: at(2, 12), calendar: cal)
        #expect(nights.map(\.day) == [at(1, 0), at(2, 0)])
        #expect(nights.map(\.total) == [60, 60])
    }

    @Test func nightsBeforeTheWindowAreDropped() {
        let old = SleepTrend.Interval(start: at(1, 0), end: at(1, 6), stage: .core, preferred: true)
        let nights = SleepTrend.nights([old], days: 1, today: at(2, 12), calendar: cal)
        #expect(nights.isEmpty)
    }

    @Test func theBandsAwakeMinutesAreNotCountedAsAnotherSourcesSleep() {
        let iphone = SleepTrend.Interval(start: at(1, 23), end: at(2, 7), stage: .unspecified, preferred: false)
        let awake = SleepTrend.Interval(start: at(2, 3), end: at(2, 3, 40), stage: .awake, preferred: true)
        let nights = SleepTrend.nights([iphone, awake], days: 7, today: at(2, 12), calendar: cal)
        #expect(nights.first?.total == 8 * 60 - 40)
        #expect(nights.first?.minutes[.awake] == nil)
    }

    @Test func aFragmentShorterThanAMinuteCountsOnlyTheMinuteWhoseMidpointItCovers() {
        let covers = SleepTrend.Interval(start: at(1, 23).addingTimeInterval(20),
                                         end: at(1, 23).addingTimeInterval(50), stage: .core, preferred: true)
        let straddles = SleepTrend.Interval(start: at(1, 23, 5).addingTimeInterval(40),
                                            end: at(1, 23, 6).addingTimeInterval(10), stage: .core, preferred: true)
        let nights = SleepTrend.nights([covers, straddles], days: 7, today: at(2, 12), calendar: cal)
        #expect(nights.first?.total == 1)
    }
}
