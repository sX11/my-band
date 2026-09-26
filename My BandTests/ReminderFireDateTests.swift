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

    @Test func reminderKeyMatchesWhatWasPushed() {
        let pushed = XiaomiProto.reminderDetails(date: date("2026-09-27 15:30"), title: "Call")
        var echoed = Xiaomi_ReminderDetails()
        echoed.title = "Call"
        echoed.date = pushed.date
        echoed.time = pushed.time
        #expect(CalendarSyncService.reminderKey(echoed) == CalendarSyncService.reminderKey(pushed))
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
