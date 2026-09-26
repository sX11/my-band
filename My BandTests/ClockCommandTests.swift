import Testing
import Foundation
@testable import My_Band

struct ClockCommandTests {

    private let vilnius = TimeZone(identifier: "Europe/Vilnius")!

    private func clock(at iso: String, in tz: TimeZone) throws -> Xiaomi_Clock {
        let now = try #require(ISO8601DateFormatter().date(from: iso))
        let data = XiaomiProto.setCurrentTimeCommand(now: now, tz: tz)
        return try Xiaomi_Command(serializedBytes: data).system.clock
    }

    @Test func summerTimeSendsStandardOffsetPlusSeparateDST() throws {
        let c = try clock(at: "2026-09-26T08:30:00Z", in: vilnius)
        #expect(c.timezone.zoneOffset == 8)   // +02:00 in 15-minute blocks
        #expect(c.timezone.dstOffset == 4)    // +01:00
        #expect(c.time.hour == 11)
        #expect(c.time.minute == 30)
    }

    @Test func winterTimeSendsNoDST() throws {
        let c = try clock(at: "2026-12-01T08:30:00Z", in: vilnius)
        #expect(c.timezone.zoneOffset == 8)
        #expect(c.timezone.dstOffset == 0)
        #expect(c.time.hour == 10)
    }
}
