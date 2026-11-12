import Foundation
import Testing
@testable import My_Band

@MainActor
struct MorningSleepNotifierTests {

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vilnius") ?? .current
        return c
    }()

    /// November 2026; the 12th is a Thursday.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private func notify(start: Date, end: Date, awakeFlag: Int? = 1, now: Date,
                        lastNotifiedDay: String? = nil, enabled: Bool = true) -> Bool {
        MorningSleepNotifier.shouldNotify(nightStart: start, nightEnd: end, awakeFlag: awakeFlag, now: now,
                                          lastNotifiedDay: lastNotifiedDay, enabled: enabled, calendar: cal)
    }

    private func alarm(_ h: Int, _ m: Int, enabled: Bool = true, repeatDays: UInt32 = AlarmService.everyDay) -> AlarmService.Alarm {
        AlarmService.Alarm(id: 1, hour: h, minute: m, repeatDays: repeatDays, enabled: enabled, smart: false)
    }

    private func fallback(_ day: Int, _ alarms: [AlarmService.Alarm]?, now: Date? = nil) -> Date {
        MorningSleepNotifier.fallbackTime(for: at(day, 0), alarms: alarms, picked: picked, now: now ?? at(12, 9), calendar: cal)
    }

    private let picked = DateComponents(hour: 8, minute: 30)

    @Test func aClosedNightThatEndedThisMorningNotifies() {
        #expect(notify(start: at(11, 23), end: at(12, 7), now: at(12, 7, 30)))
    }

    @Test func aNightTheBandStillHasOpenDoesNotNotify() {
        #expect(!notify(start: at(11, 23), end: at(12, 7), awakeFlag: 0, now: at(12, 7, 30)))
        #expect(!notify(start: at(11, 23), end: at(12, 7), awakeFlag: nil, now: at(12, 7, 30)))
    }

    @Test func nothingIsSentBeforeFiveInTheMorning() {
        #expect(!notify(start: at(11, 22), end: at(12, 3, 30), now: at(12, 4, 50)))
    }

    @Test func aMorningAlreadyNotifiedIsNotNotifiedAgain() {
        #expect(!notify(start: at(11, 23), end: at(12, 7), now: at(12, 7, 30), lastNotifiedDay: "2026-11-12"))
        #expect(notify(start: at(11, 23), end: at(12, 7), now: at(12, 7, 30), lastNotifiedDay: "2026-11-11"))
    }

    @Test func theSwitchOffSendsNothing() {
        #expect(!notify(start: at(11, 23), end: at(12, 7), now: at(12, 7, 30), enabled: false))
    }

    @Test func yesterdaysNightSyncedTodayDoesNotNotify() {
        #expect(!notify(start: at(10, 23), end: at(11, 7), now: at(12, 9)))
    }

    @Test func anAfternoonNapDoesNotReadAsLastNight() {
        #expect(!notify(start: at(12, 13), end: at(12, 16, 30), now: at(12, 17)))
    }

    @Test func aMorningNapUnderThreeHoursDoesNotNotify() {
        #expect(!notify(start: at(12, 6), end: at(12, 8, 30), now: at(12, 9)))
    }

    @Test func aLongClosedMorningNapBegunAfterThreeDoesNotReadAsLastNight() {
        #expect(!notify(start: at(12, 6), end: at(12, 10), now: at(12, 10, 30)))
    }

    // MARK: - Fallback time

    @Test func aBandAlarmAtSevenPutsTheFallbackAtHalfPastSeven() {
        #expect(fallback(13, [alarm(7, 0)]) == at(13, 7, 30))
    }

    @Test func anAfternoonAlarmOrNoneLeavesThePickedTime() {
        #expect(fallback(13, [alarm(14, 0)]) == at(13, 8, 30))
        #expect(fallback(13, []) == at(13, 8, 30))
        #expect(fallback(13, [alarm(7, 0, enabled: false)]) == at(13, 8, 30))
    }

    @Test func noAlarmListYetLeavesThePickedTime() {
        #expect(fallback(13, nil) == at(13, 8, 30))
    }

    @Test func aOneTimeAlarmMovesOnlyTheMorningItRingsOn() {
        let once = [alarm(7, 0, repeatDays: 0)]
        #expect(fallback(13, once, now: at(12, 9)) == at(13, 7, 30))
        #expect(fallback(14, once, now: at(12, 9)) == at(14, 8, 30))
        #expect(fallback(15, once, now: at(12, 9)) == at(15, 8, 30))
    }

    // MARK: - Plan diff

    private func when(_ day: Int, _ hour: Int, _ minute: Int = 0) -> DateComponents {
        DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute)
    }

    @Test func anUnchangedPlanNeedsNoChanges() {
        let plan = ["morningSleep-2026-11-13": when(13, 8, 30), "morningSleep-2026-11-14": when(14, 7, 30)]
        let changes = MorningSleepNotifier.fallbackChanges(pending: plan, planned: plan)
        #expect(changes.upsert.isEmpty)
        #expect(changes.remove.isEmpty)
    }

    @Test func aDayDroppedFromThePlanIsOneRemoval() {
        let pending = ["morningSleep-2026-11-13": when(13, 8, 30), "morningSleep-2026-11-14": when(14, 8, 30)]
        let changes = MorningSleepNotifier.fallbackChanges(pending: pending,
                                                           planned: ["morningSleep-2026-11-14": when(14, 8, 30)])
        #expect(changes.upsert.isEmpty)
        #expect(changes.remove == ["morningSleep-2026-11-13"])
    }

    @Test func aMovedTimeIsOneReplacement() {
        let pending = ["morningSleep-2026-11-13": when(13, 8, 30), "morningSleep-2026-11-14": when(14, 8, 30)]
        let planned = ["morningSleep-2026-11-13": when(13, 7, 30), "morningSleep-2026-11-14": when(14, 8, 30)]
        let changes = MorningSleepNotifier.fallbackChanges(pending: pending, planned: planned)
        #expect(changes.upsert == ["morningSleep-2026-11-13"])
        #expect(changes.remove.isEmpty)
    }

    @Test func thePlanSkipsAMorningAlreadyNotifiedAndOnesAlreadyPast() {
        let plan = MorningSleepNotifier.fallbacks(now: at(12, 6), alarms: nil, picked: picked,
                                                  notifiedDay: "2026-11-12", calendar: cal)
        #expect(plan.map(\.day) == (13 ... 18).map { "2026-11-\($0)" })
        #expect(plan.first?.fire == at(13, 8, 30))
        let late = MorningSleepNotifier.fallbacks(now: at(12, 9), alarms: nil, picked: picked,
                                                  notifiedDay: nil, calendar: cal)
        #expect(late.first?.day == "2026-11-13")
    }
}
