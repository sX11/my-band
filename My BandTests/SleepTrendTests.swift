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

    private func core(_ start: Date, _ end: Date) -> SleepTrend.Interval {
        SleepTrend.Interval(start: start, end: end, stage: .core, preferred: true)
    }

    @Test func anAwakeStretchInsideTheNightIsOneAwakeSegmentWithinTheSpan() throws {
        let awake = SleepTrend.Interval(start: at(2, 2), end: at(2, 2, 20), stage: .awake, preferred: true)
        let deep = SleepTrend.Interval(start: at(2, 2, 20), end: at(2, 6), stage: .deep, preferred: true)
        let night = try #require(SleepTrend.nights([core(at(1, 23), at(2, 2)), awake, deep],
                                                   days: 7, today: at(2, 12), calendar: cal).first)
        #expect(night.start == at(1, 23))
        #expect(night.end == at(2, 6))
        #expect(night.segments == [
            .init(start: at(1, 23), end: at(2, 2), stage: .core),
            .init(start: at(2, 2), end: at(2, 2, 20), stage: .awake),
            .init(start: at(2, 2, 20), end: at(2, 6), stage: .deep),
        ])
        #expect(night.total == 180 + 220)
    }

    @Test func anAfternoonNapCountsInTheTotalButNotInTheNightsSpan() throws {
        let night = try #require(SleepTrend.nights([core(at(1, 23), at(2, 7)), core(at(2, 14), at(2, 15))],
                                                   days: 7, today: at(2, 20), calendar: cal).first)
        #expect(night.start == at(1, 23))
        #expect(night.end == at(2, 7))
        #expect(night.segments.count == 1)
        #expect(night.total == 8 * 60 + 60)
    }

    @Test func aGapOfUnderAnHourJoinsTheSleepButBreaksTheStageRun() throws {
        let night = try #require(SleepTrend.nights([core(at(1, 23), at(2, 2)), core(at(2, 2, 45), at(2, 6))],
                                                   days: 7, today: at(2, 12), calendar: cal).first)
        #expect(night.start == at(1, 23))
        #expect(night.end == at(2, 6))
        #expect(night.segments == [
            .init(start: at(1, 23), end: at(2, 2), stage: .core),
            .init(start: at(2, 2, 45), end: at(2, 6), stage: .core),
        ])
    }

    @Test func aBandAwakeMinuteOverAnotherSourcesSleepShowsAsAwakeInTheStrip() throws {
        let iphone = SleepTrend.Interval(start: at(1, 23), end: at(2, 7), stage: .unspecified, preferred: false)
        let awake = SleepTrend.Interval(start: at(2, 3), end: at(2, 3, 40), stage: .awake, preferred: true)
        let night = try #require(SleepTrend.nights([iphone, awake], days: 7, today: at(2, 12), calendar: cal).first)
        #expect(night.segments == [
            .init(start: at(1, 23), end: at(2, 3), stage: .unspecified),
            .init(start: at(2, 3), end: at(2, 3, 40), stage: .awake),
            .init(start: at(2, 3, 40), end: at(2, 7), stage: .unspecified),
        ])
    }

    @Test func theMainSleepsAsleepTimeLeavesOutANapAndAwakeMinutesThatTheTotalCounts() throws {
        let awake = SleepTrend.Interval(start: at(2, 2), end: at(2, 2, 20), stage: .awake, preferred: true)
        let night = try #require(SleepTrend.nights([awake, core(at(1, 23), at(2, 7)), core(at(2, 14), at(2, 15))],
                                                   days: 7, today: at(2, 20), calendar: cal).first)
        #expect(night.mainAsleep == 8 * 60 - 20)
        #expect(night.total == 8 * 60 - 20 + 60)
    }

    // MARK: - Night vitals

    @Test func eachVitalGoesToTheNightHoldingItAndOneBetweenNightsIsDropped() {
        let spans = [at(2, 0): DateInterval(start: at(1, 23), end: at(2, 7)),
                     at(3, 0): DateInterval(start: at(2, 23), end: at(3, 7))]
        let first = VitalPoint(date: at(2, 3), value: 55)
        let between = VitalPoint(date: at(2, 15), value: 80)
        let second = VitalPoint(date: at(3, 1), value: 50)
        let hrv = VitalPoint(date: at(2, 4), value: 30)
        let split = NightVitals.split([.heartRate: [second, between, first], .hrv: [hrv]], spans: spans)
        #expect(split[at(2, 0)]?.hr == [first])
        #expect(split[at(2, 0)]?.hrv == [hrv])
        #expect(split[at(3, 0)]?.hr == [second])
        #expect(split[at(3, 0)]?.hrv == [])
    }

    @Test func theMedianOfAnEvenCountIsTheMeanOfTheMiddleTwo() {
        let hrv = [30.0, 10, 20, 40].map { VitalPoint(date: at(2, 3), value: $0) }
        #expect(NightVitals(hrv: hrv).hrvMedian == 25)
        #expect(NightVitals().hrvMedian == nil)
    }

    @Test func heartRateAndOxygenGiveTheirLowestAndAverage() {
        let v = NightVitals(hr: [60.0, 50, 58].map { VitalPoint(date: at(2, 3), value: $0) },
                            spo2: [95.0, 92, 98].map { VitalPoint(date: at(2, 3), value: $0) })
        #expect(v.hrMin == 50)
        #expect(v.hrAvg == 56)
        #expect(v.spo2Avg == 95)
        #expect(v.spo2Min == 92)
    }

    @Test func aDeltaNeedsAtLeastTwoOtherNights() {
        #expect(NightVitals.delta(400, others: [300]) == nil)
        #expect(NightVitals.delta(nil, others: [300, 360]) == nil)
        #expect(NightVitals.delta(400, others: [300, 360]) == 70)
    }
}
