import Testing
import Foundation
@testable import My_Band

struct BandSettingsCommandTests {

    @Test func spo2AllDayIsSentAsModeTwoNotBoolTrue() throws {
        var spo2 = Xiaomi_SpO2()
        spo2.mode = BandSettingsService.Spo2Mode.allDay
        let bytes: Data = try spo2.serializedData()
        #expect(bytes == Data([0x10, 0x02]))   // field 2, varint 2
    }

    @Test func spo2SleepOnlyModeDecodesDistinctFromAllDay() throws {
        let sleepOnly = try Xiaomi_SpO2(serializedBytes: Data([0x10, 0x01]))
        #expect(sleepOnly.mode == 1)
        #expect(sleepOnly.mode != BandSettingsService.Spo2Mode.allDay)
    }

    @Test func healthConfigCommandCarriesTypeSubtypeAndPayload() throws {
        let data = XiaomiProto.healthConfigCommand(subtype: XiaomiHealthCmd.stressSet) {
            $0.stress.allDayTracking = true
        }
        let cmd = try Xiaomi_Command(serializedBytes: data)
        #expect(cmd.type == XiaomiHealthCmd.cmdType)
        #expect(cmd.subtype == XiaomiHealthCmd.stressSet)
        #expect(cmd.health.stress.allDayTracking)
    }

    @Test func screenOnSetCommandUsesNotificationType() throws {
        let cmd = try Xiaomi_Command(serializedBytes: XiaomiProto.screenOnNotificationsSetCommand(false))
        #expect(cmd.type == XiaomiNotificationCmd.cmdType)
        #expect(cmd.subtype == XiaomiNotificationCmd.screenOnSet)
        #expect(cmd.notification.hasScreenOnOnNotifications)
        #expect(!cmd.notification.screenOnOnNotifications)
    }
}
