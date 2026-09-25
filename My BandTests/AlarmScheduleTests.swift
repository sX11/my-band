import Testing
import Foundation
@testable import My_Band

@MainActor
struct AlarmScheduleTests {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vilnius") ?? .current
        return c
    }

    private func date(_ s: String) -> Date {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = calendar.timeZone
        guard let d = f.date(from: s) else { fatalError("bad fixture date") }
        return d
    }

    private func alarm(_ h: Int, _ m: Int, days: UInt32) -> AlarmService.Alarm {
        AlarmService.Alarm(id: 1, hour: h, minute: m, repeatDays: days, enabled: true, smart: false)
    }

    @Test func mondayIsTheLowestBitAndSundayTheHighest() {
        #expect(AlarmService.dayBit(2) == 1)    // Monday
        #expect(AlarmService.dayBit(1) == 64)   // Sunday
        #expect(AlarmService.dayBit(7) == 32)   // Saturday
    }

    @Test func onceAlarmLaterTodayFiresToday() {
        // 2026-09-25 is a Friday.
        let fire = AlarmService.nextFire(of: alarm(18, 0, days: 0), after: date("2026-09-25 13:00"), calendar: calendar)
        #expect(fire == date("2026-09-25 18:00"))
    }

    @Test func onceAlarmAlreadyPastFiresTomorrow() {
        let fire = AlarmService.nextFire(of: alarm(7, 0, days: 0), after: date("2026-09-25 13:00"), calendar: calendar)
        #expect(fire == date("2026-09-26 07:00"))
    }

    @Test func weekdayAlarmOnFridayAfternoonSkipsToMonday() {
        let fire = AlarmService.nextFire(of: alarm(7, 0, days: 0x1F), after: date("2026-09-25 13:00"), calendar: calendar)
        #expect(fire == date("2026-09-28 07:00"))
    }
}
