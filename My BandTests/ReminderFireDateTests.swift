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

    @Test func timedReminderFiresAtItsDueTime() {
        let fires = CalendarSyncService.fireDate(due: due(2026, 9, 27, 15, 30), alarms: [], calendar: calendar)
        #expect(fires == date("2026-09-27 15:30"))
    }

    @Test func dateOnlyReminderFiresAtNineNotMidnight() {
        let fires = CalendarSyncService.fireDate(due: due(2026, 9, 27), alarms: [], calendar: calendar)
        #expect(fires == date("2026-09-27 09:00"))
    }

    @Test func alertWinsOverDueTime() {
        let alert = EKAlarm(absoluteDate: date("2026-09-27 14:00"))
        let fires = CalendarSyncService.fireDate(due: due(2026, 9, 27, 15, 30), alarms: [alert], calendar: calendar)
        #expect(fires == date("2026-09-27 14:00"))
    }

    @Test func relativeAlertIsMeasuredFromDueTime() {
        let fires = CalendarSyncService.fireDate(due: due(2026, 9, 27, 15, 30),
                                                 alarms: [EKAlarm(relativeOffset: -600)], calendar: calendar)
        #expect(fires == date("2026-09-27 15:20"))
    }

    @Test func noDueAndNoAlertHasNoFireDate() {
        #expect(CalendarSyncService.fireDate(due: nil, alarms: [], calendar: calendar) == nil)
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
