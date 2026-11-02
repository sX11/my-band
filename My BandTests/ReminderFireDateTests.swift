import Testing
import Foundation
import EventKit
@testable import My_Band

@MainActor
struct ReminderFireDateTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vilnius")!
        return c
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = calendar.timeZone
        return f.date(from: s)!
    }

    private func due(_ y: Int, _ m: Int, _ d: Int, _ h: Int? = nil, _ min: Int? = nil) -> DateComponents {
        DateComponents(year: y, month: m, day: d, hour: h, minute: min)
    }

    private var morning: Date { date("2026-09-26 08:00") }

    private func fire(_ due: DateComponents?, _ alarms: [EKAlarm] = [], after now: Date? = nil) -> Date? {
        CalendarSyncService.fireDate(due: due, alarms: alarms, after: now ?? morning, calendar: calendar)
    }

    @Test func timedReminderFiresAtItsDueTime() {
        #expect(fire(due(2026, 9, 27, 15, 30)) == date("2026-09-27 15:30"))
    }

    @Test func dateOnlyReminderFiresAtNineNotMidnight() {
        #expect(fire(due(2026, 9, 27)) == date("2026-09-27 09:00"))
    }

    @Test func alertWinsOverDueTime() {
        let alert = EKAlarm(absoluteDate: date("2026-09-27 14:00"))
        #expect(fire(due(2026, 9, 27, 15, 30), [alert]) == date("2026-09-27 14:00"))
    }

    @Test func relativeAlertIsMeasuredFromDueTime() {
        #expect(fire(due(2026, 9, 27, 15, 30), [EKAlarm(relativeOffset: -600)]) == date("2026-09-27 15:20"))
    }

    @Test func passedEarlyAlertFallsThroughToTheNextAlert() {
        let alarms = [EKAlarm(relativeOffset: -5400), EKAlarm(relativeOffset: 0)]
        #expect(fire(due(2026, 9, 27, 15, 30), alarms, after: date("2026-09-27 14:30")) == date("2026-09-27 15:30"))
    }

    @Test func dateOnlyRelativeAlertCountsFromMidnight() {
        #expect(fire(due(2026, 9, 27), [EKAlarm(relativeOffset: -15 * 3600)]) == date("2026-09-26 09:00"))
    }

    @Test func locationAlertIsNotATime() {
        let arriving = EKAlarm()
        arriving.structuredLocation = EKStructuredLocation(title: "Home")
        arriving.proximity = .enter
        #expect(fire(due(2026, 9, 27), [arriving]) == date("2026-09-27 09:00"))
    }

    @Test func absoluteAlertWithoutDueDateStillFires() {
        #expect(fire(nil, [EKAlarm(absoluteDate: date("2026-09-27 14:00"))]) == date("2026-09-27 14:00"))
    }

    @Test func overdueReminderHasNoFireDate() {
        #expect(fire(due(2026, 9, 25, 10, 0)) == nil)
        #expect(fire(nil) == nil)
    }

    private func daily() -> EKRecurrenceRule { EKRecurrenceRule(recurrenceWith: .daily, interval: 1, end: nil) }

    private func fires(_ due: DateComponents?, _ alarms: [EKAlarm], _ rule: EKRecurrenceRule?,
                       after now: Date) -> [(date: Date, repeats: ReminderService.Repeat)] {
        CalendarSyncService.upcomingFires(due: due, alarms: alarms, rule: rule, after: now, calendar: calendar)
    }

    @Test func eachAlertOfADailyReminderBecomesItsOwnDailyReminder() {
        let alarms = [10, 13, 16, 19].map { EKAlarm(absoluteDate: date("2026-10-18 \($0):00")) }
        let result = fires(due(2026, 10, 18, 10, 0), alarms, daily(), after: date("2026-10-18 14:00"))
        #expect(result.map(\.date) == [date("2026-10-18 16:00"), date("2026-10-18 19:00"),
                                      date("2026-10-19 10:00"), date("2026-10-19 13:00")])
        #expect(result.allSatisfy { $0.repeats == .daily })
    }

    @Test func passedAlertOfAOneOffReminderIsDropped() {
        let alarms = [EKAlarm(absoluteDate: date("2026-10-18 10:00")), EKAlarm(absoluteDate: date("2026-10-18 16:00"))]
        let result = fires(due(2026, 10, 18, 10, 0), alarms, nil, after: date("2026-10-18 14:00"))
        #expect(result.map(\.date) == [date("2026-10-18 16:00")])
        #expect(result.first?.repeats == .once)
    }

    @Test func overdueDailyReminderRollsToItsNextTime() {
        let result = fires(due(2026, 10, 15, 9, 0), [], daily(), after: date("2026-10-18 14:00"))
        #expect(result.map(\.date) == [date("2026-10-19 09:00")])
    }

    @Test func monthlyRollForwardKeepsTheEndOfMonthDay() {
        let rule = EKRecurrenceRule(recurrenceWith: .monthly, interval: 1, end: nil)
        let result = fires(due(2026, 1, 31, 9, 0), [], rule, after: date("2026-03-01 08:00"))
        #expect(result.map(\.date) == [date("2026-03-31 09:00")])
    }

    @Test func yearlyLeapDayReturnsToFebruary29InALeapYear() {
        let rule = EKRecurrenceRule(recurrenceWith: .yearly, interval: 1, end: nil)
        let result = fires(due(2024, 2, 29, 9, 0), [], rule, after: date("2027-03-01 08:00"))
        #expect(result.map(\.date) == [date("2028-02-29 09:00")])
    }

    @Test func duplicateAlertTimesCollapse() {
        let alarms = [EKAlarm(relativeOffset: 0), EKAlarm(absoluteDate: date("2026-10-18 16:00"))]
        #expect(fires(due(2026, 10, 18, 16, 0), alarms, nil, after: date("2026-10-18 14:00")).count == 1)
    }

    @Test func reminderKeyMatchesWhatWasPushed() {
        let pushed = XiaomiProto.reminderDetails(date: date("2026-09-27 15:30"), title: "Call")
        var echoed = Xiaomi_ReminderDetails()
        echoed.title = "Call"
        echoed.date = pushed.date
        echoed.time = pushed.time
        #expect(CalendarSyncService.reminderKey(echoed) == CalendarSyncService.reminderKey(pushed))
    }

    private func bandReminder(_ id: UInt32, _ title: String, _ at: String) -> Xiaomi_Reminder {
        var r = Xiaomi_Reminder()
        r.id = id
        r.reminderDetails = XiaomiProto.reminderDetails(date: date(at), title: title)
        return r
    }

    @Test func reminderWhoseDeleteWasLostStaysOwned() {
        let lost = bandReminder(7, "капли", "2026-10-17 16:00")
        let gone = bandReminder(8, "капли", "2026-10-17 13:00")
        let pushed = XiaomiProto.reminderDetails(date: date("2026-10-18 19:00"), title: "капли")
        var after = Xiaomi_Reminders()
        after.reminder = [lost, bandReminder(9, "капли", "2026-10-18 19:00")]
        let owned = CalendarSyncService.owned(created: [9], pushed: [pushed], deleting: [lost, gone], listedAfter: after)
        #expect(owned.ids == [9, 7])
        #expect(owned.undeleted == 1)
        #expect(owned.keys == [CalendarSyncService.reminderKey(pushed), CalendarSyncService.reminderKey(lost.reminderDetails)])
    }

    @Test func withoutAListEveryDeletedReminderStaysOwned() {
        let deleting = [bandReminder(7, "капли", "2026-10-17 16:00")]
        let owned = CalendarSyncService.owned(created: [], pushed: [], deleting: deleting, listedAfter: nil)
        #expect(owned.ids == [7])
    }

    @Test func eventAlertBecomesMinutesBefore() {
        let start = date("2026-09-27 10:00")
        let alarms = [EKAlarm(relativeOffset: -300), EKAlarm(absoluteDate: date("2026-09-27 09:30"))]
        #expect(CalendarSyncService.notifyMinutesBefore(start: start, alarms: alarms) == 30)
    }

    @Test func alertAfterStartIsDropped() {
        let start = date("2026-09-27 00:00")
        #expect(CalendarSyncService.notifyMinutesBefore(start: start, alarms: [EKAlarm(relativeOffset: 9 * 3600)]) == nil)
        #expect(CalendarSyncService.notifyMinutesBefore(start: start, alarms: []) == nil)
    }
}
