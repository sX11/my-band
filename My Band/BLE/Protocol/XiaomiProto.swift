import Foundation
import SwiftProtobuf

// MARK: - XiaomiProto
//
// Thin builder/parser layer over the SwiftProtobuf-generated types in xiaomi.pb.swift.
// Source proto: gadgetbridge/app/src/main/proto/xiaomi.proto (GadgetBridge, AGPL-3.0)
// Generated with: protoc --plugin=protoc-gen-swift --swift_out=. xiaomi.proto (SwiftProtobuf 1.38)

enum XiaomiProto {

    // MARK: - Command parsing

    static func parseCommand(_ data: Data) -> Xiaomi_Command? {
        try? Xiaomi_Command(serializedBytes: data)
    }

    // MARK: - Auth command builders

    static func phoneNonceCommand(nonce: Data) -> Data {
        var phoneNonce = Xiaomi_PhoneNonce()
        phoneNonce.nonce = nonce

        var auth = Xiaomi_Auth()
        auth.phoneNonce = phoneNonce

        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiAuthCmd.cmdType
        cmd.subtype = XiaomiAuthCmd.nonce
        cmd.auth    = auth

        return (try? cmd.serializedData()) ?? Data()
    }

    static func authStep3Command(encryptedNonces: Data, encryptedDeviceInfo: Data) -> Data {
        var step3 = Xiaomi_AuthStep3()
        step3.encryptedNonces     = encryptedNonces
        step3.encryptedDeviceInfo = encryptedDeviceInfo

        var auth = Xiaomi_Auth()
        auth.authStep3 = step3

        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiAuthCmd.cmdType
        cmd.subtype = XiaomiAuthCmd.auth
        cmd.auth    = auth

        return (try? cmd.serializedData()) ?? Data()
    }

    /// CompanionDevice proto serialised for AES-CCM encryption during auth step 3.
    /// Fields mirror Xiaomi's CompanionDevice (AstroBox wear_account.proto):
    ///   field 1 = device_type  (1 = iOS — BLE connection from iOS sends iOS, not Android)
    ///   field 2 = phoneApiLevel (iOS major version as float)
    ///   field 3 = phoneName
    ///   field 4 = app_capability (0xFFFF_FFFF = all capabilities enabled)
    ///   field 5 = region
    static func authDeviceInfo() -> Data {
        var info = Xiaomi_AuthDeviceInfo()
        info.unknown1      = 1         // iOS device type (AstroBox: DeviceType::Ios = 1)
        info.phoneApiLevel = Float(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        info.phoneName     = "iPhone"
        info.unknown3      = 0xFFFF_FFFF   // app_capability: all features enabled
        let lang = Locale.current.language.languageCode?.identifier.prefix(2).uppercased() ?? "EN"
        info.region        = String(lang)
        return (try? info.serializedData()) ?? Data()
    }

    // MARK: - System command builders

    static func setCurrentTimeCommand() -> Data {
        let now   = Date()
        let cal   = Calendar.current
        let tz    = TimeZone.current
        let comps = cal.dateComponents(in: tz, from: now)

        var time = Xiaomi_Time()
        time.hour   = UInt32(comps.hour   ?? 0)
        time.minute = UInt32(comps.minute ?? 0)
        time.second = UInt32(comps.second ?? 0)

        var date = Xiaomi_Date()
        date.year  = UInt32(comps.year  ?? 2025)
        date.month = UInt32(comps.month ?? 1)
        date.day   = UInt32(comps.day   ?? 1)

        let zoneOffset = Int32(tz.secondsFromGMT(for: now) / (15 * 60))
        let dstSecs    = Int(tz.daylightSavingTimeOffset(for: now))
        let dstOffset  = Int32(dstSecs / (15 * 60))

        var tzMsg = Xiaomi_TimeZone()
        tzMsg.zoneOffset = zoneOffset
        if dstOffset != 0 { tzMsg.dstOffset = dstOffset }
        tzMsg.name = tz.identifier

        var clock = Xiaomi_Clock()
        clock.date     = date
        clock.time     = time
        clock.timezone = tzMsg

        var system = Xiaomi_System()
        system.clock = clock

        var cmd = Xiaomi_Command()
        cmd.type    = 2   // SYSTEM
        cmd.subtype = 3   // CMD_CLOCK / SET_SYSTEM_TIME
        cmd.system  = system

        return (try? cmd.serializedData()) ?? Data()
    }

    /// Bare Command with only type+subtype (no payload) — used for the post-auth init
    /// requests GadgetBridge sends after onAuthSuccess (get device info / status / battery).
    static func systemCommand(subtype: UInt32) -> Data {
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiSystemCmd.cmdType
        cmd.subtype = subtype
        return (try? cmd.serializedData()) ?? Data()
    }

    // MARK: - Health command builders

    static func healthCommand(subtype: UInt32, fileIds: Data = Data()) -> Data {
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiHealthCmd.cmdType
        cmd.subtype = subtype

        if !fileIds.isEmpty {
            var health = Xiaomi_Health()
            health.activityRequestFileIds = fileIds
            cmd.health = health
        }

        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_ACTIVITY_FETCH_TODAY — lists today's pending activity file IDs.
    static func fetchTodayCommand() -> Data {
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiHealthCmd.cmdType
        cmd.subtype = XiaomiHealthCmd.fetchToday
        var health = Xiaomi_Health()
        var today = Xiaomi_ActivitySyncRequestToday()
        today.unknown1 = 0           // official app sends 0 (GadgetBridge note)
        health.activitySyncRequestToday = today
        cmd.health = health
        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_ACTIVITY_FETCH_PAST — lists the backlog of older, not-yet-synced file IDs.
    static func fetchPastCommand() -> Data {
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiHealthCmd.cmdType
        cmd.subtype = XiaomiHealthCmd.fetchPast
        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_ACTIVITY_FETCH_ACK — marks a file synced. Must use the dedicated ack field
    /// (`activitySyncAckFileIds`), not `activityRequestFileIds`, or the band acks nothing.
    static func ackCommand(fileId: Data) -> Data {
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiHealthCmd.cmdType
        cmd.subtype = XiaomiHealthCmd.fetchAck
        var health = Xiaomi_Health()
        health.activitySyncAckFileIds = fileId
        cmd.health = health
        return (try? cmd.serializedData()) ?? Data()
    }
}
