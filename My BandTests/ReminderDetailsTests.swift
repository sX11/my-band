import Foundation
import Testing
@testable import My_Band

@MainActor
struct ReminderDetailsTests {

    private func date(_ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 9, minute: 30)) ?? .distantPast
    }

    @Test func repeatModesMatchGadgetbridge() {
        #expect(ReminderService.Repeat.allCases.map(\.mode) == [0, 1, 5, 7, 8])
        #expect(ReminderService.Repeat(mode: 7) == .monthly)
        #expect(ReminderService.Repeat(mode: 42) == .once)
    }

    @Test func weeklyCarriesTheWeekdayAsTheAlarmBitmask() {
        let weekly = ReminderService.Repeat.weekly.mode
        let monday = XiaomiProto.reminderDetails(date: date(5), title: "Gym", repeatMode: weekly)
        let saturday = XiaomiProto.reminderDetails(date: date(10), title: "Gym", repeatMode: weekly)
        let sunday = XiaomiProto.reminderDetails(date: date(11), title: "Gym", repeatMode: weekly)
        #expect(monday.repeatMode == 5)
        #expect(monday.repeatFlags == 1)
        #expect(saturday.repeatFlags == 32)
        #expect(sunday.repeatFlags == 64)
    }

    @Test func otherRepeatsLeaveTheFlagsUnset() {
        let once = XiaomiProto.reminderDetails(date: date(5), title: "Call")
        let daily = XiaomiProto.reminderDetails(date: date(5), title: "Call", repeatMode: ReminderService.Repeat.daily.mode)
        #expect(once.repeatMode == 0)
        #expect(once.repeatFlags == 64)
        #expect(daily.repeatFlags == 64)
        #expect(once.time.hour == 9 && once.time.minute == 30)
    }
}
