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

    static func setCurrentTimeCommand(now: Date = Date(), tz: TimeZone = .current) -> Data {
        let comps = Calendar.current.dateComponents(in: tz, from: now)

        var time = Xiaomi_Time()
        time.hour   = UInt32(comps.hour   ?? 0)
        time.minute = UInt32(comps.minute ?? 0)
        time.second = UInt32(comps.second ?? 0)

        var date = Xiaomi_Date()
        date.year  = UInt32(comps.year  ?? 2025)
        date.month = UInt32(comps.month ?? 1)
        date.day   = UInt32(comps.day   ?? 1)

        // zoneOffset is the standard offset WITHOUT DST (Java's Calendar.ZONE_OFFSET, which
        // GadgetBridge sends); secondsFromGMT already includes DST, so the band counted it twice.
        let dstSecs    = Int(tz.daylightSavingTimeOffset(for: now))
        let zoneOffset = Int32((tz.secondsFromGMT(for: now) - dstSecs) / (15 * 60))
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

    /// CMD_LANGUAGE — sets the band UI language. GadgetBridge sends the locale lowercased as
    /// "language_region" (e.g. "pt_br", "en_us") in system.language.code.
    static func languageCommand(code: String) -> Data {
        var language = Xiaomi_Language()
        language.code = code
        var system = Xiaomi_System()
        system.language = language
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiSystemCmd.cmdType
        cmd.subtype = XiaomiSystemCmd.language
        cmd.system  = system
        return (try? cmd.serializedData()) ?? Data()
    }

    // MARK: - Calendar command builders

    /// CMD_CALENDAR_SET — replaces the band's synced event set with `events` (band caps at 50).
    /// `disabled = true` with an empty list clears the calendar on the band.
    static func calendarSyncCommand(events: [Xiaomi_CalendarEvent], disabled: Bool = false) -> Data {
        var sync = Xiaomi_CalendarSync()
        sync.event = events
        if disabled { sync.disabled = true }
        var calendar = Xiaomi_Calendar()
        calendar.calendarSync = sync
        var cmd = Xiaomi_Command()
        cmd.type     = XiaomiCalendarCmd.cmdType
        cmd.subtype  = XiaomiCalendarCmd.set
        cmd.calendar = calendar
        return (try? cmd.serializedData()) ?? Data()
    }

    // MARK: - Alarm (schedule) command builders — GadgetBridge XiaomiScheduleService

    static func alarmsGetCommand() -> Data {
        command(type: XiaomiScheduleCmd.cmdType, subtype: XiaomiScheduleCmd.alarmsGet) { _ in }
    }

    static func alarmCreateCommand(_ details: Xiaomi_AlarmDetails) -> Data {
        command(type: XiaomiScheduleCmd.cmdType, subtype: XiaomiScheduleCmd.alarmCreate) {
            $0.schedule.createAlarm = details
        }
    }

    static func alarmEditCommand(id: UInt32, _ details: Xiaomi_AlarmDetails) -> Data {
        var alarm = Xiaomi_Alarm()
        alarm.id = id
        alarm.alarmDetails = details
        return command(type: XiaomiScheduleCmd.cmdType, subtype: XiaomiScheduleCmd.alarmEdit) {
            $0.schedule.editAlarm = alarm
        }
    }

    static func alarmDeleteCommand(ids: [UInt32]) -> Data {
        var del = Xiaomi_AlarmDelete()
        del.id = ids
        return command(type: XiaomiScheduleCmd.cmdType, subtype: XiaomiScheduleCmd.alarmDelete) {
            $0.schedule.deleteAlarm = del
        }
    }

    // MARK: - Reminder (schedule) command builders

    static func remindersGetCommand() -> Data {
        command(type: XiaomiScheduleCmd.cmdType, subtype: XiaomiScheduleCmd.remindersGet) { _ in }
    }

    /// CMD_REMINDERS_CREATE — adds one reminder. `repeatMode` 0=once; `repeatFlags` 64 = unset.
    static func reminderCreateCommand(_ details: Xiaomi_ReminderDetails) -> Data {
        var schedule = Xiaomi_Schedule()
        schedule.createReminder = details
        var cmd = Xiaomi_Command()
        cmd.type     = XiaomiScheduleCmd.cmdType
        cmd.subtype  = XiaomiScheduleCmd.reminderCreate
        cmd.schedule = schedule
        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_REMINDERS_DELETE — removes reminders by id.
    static func reminderDeleteCommand(ids: [UInt32]) -> Data {
        var del = Xiaomi_ReminderDelete()
        del.id = ids
        var schedule = Xiaomi_Schedule()
        schedule.deleteReminder = del
        var cmd = Xiaomi_Command()
        cmd.type     = XiaomiScheduleCmd.cmdType
        cmd.subtype  = XiaomiScheduleCmd.reminderDelete
        cmd.schedule = schedule
        return (try? cmd.serializedData()) ?? Data()
    }

    /// Builds a ReminderDetails from a date/time and title (one-shot reminder).
    static func reminderDetails(date: Date, title: String) -> Xiaomi_ReminderDetails {
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        var d = Xiaomi_Date()
        d.year  = UInt32(comps.year  ?? 2025)
        d.month = UInt32(comps.month ?? 1)
        d.day   = UInt32(comps.day   ?? 1)
        var t = Xiaomi_Time()
        t.hour   = UInt32(comps.hour   ?? 0)
        t.minute = UInt32(comps.minute ?? 0)
        t.second = UInt32(comps.second ?? 0)
        var details = Xiaomi_ReminderDetails()
        details.date        = d
        details.time        = t
        details.repeatMode  = 0    // once
        details.repeatFlags = 64   // unset (GadgetBridge sentinel)
        details.title       = title
        return details
    }

    // MARK: - Weather command builders

    static func weatherUnit(_ value: Int32, _ unit: String) -> Xiaomi_WeatherUnitValue {
        var u = Xiaomi_WeatherUnitValue()
        u.value = value
        u.unit  = unit
        return u
    }

    /// CMD_ADD_LOCATION — registers the weather location before pushing conditions/forecast.
    static func weatherAddLocationCommand(code: String, name: String) -> Data {
        var loc = Xiaomi_WeatherLocation()
        loc.code = code
        loc.name = name
        var weather = Xiaomi_Weather()
        weather.location = loc
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiWeatherCmd.cmdType
        cmd.subtype = XiaomiWeatherCmd.addLocation
        cmd.weather = weather
        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_SET_CURRENT_WEATHER — pushes the current conditions block.
    static func currentWeatherCommand(_ current: Xiaomi_WeatherCurrent) -> Data {
        var weather = Xiaomi_Weather()
        weather.current = current
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiWeatherCmd.cmdType
        cmd.subtype = XiaomiWeatherCmd.setCurrent
        cmd.weather = weather
        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_UPDATE_DAILY_FORECAST — pushes the multi-day forecast block.
    static func dailyForecastCommand(_ forecast: Xiaomi_WeatherForecast) -> Data {
        var weather = Xiaomi_Weather()
        weather.forecast = forecast
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiWeatherCmd.cmdType
        cmd.subtype = XiaomiWeatherCmd.dailyForecast
        cmd.weather = weather
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

    /// A CMD_CONFIG_*_SET carrying one health config (heart rate, SpO₂, stress, …).
    static func healthConfigCommand(subtype: UInt32, _ configure: (inout Xiaomi_Health) -> Void) -> Data {
        command(type: XiaomiHealthCmd.cmdType, subtype: subtype) { configure(&$0.health) }
    }

    static func screenOnNotificationsGetCommand() -> Data {
        bareCommand(type: XiaomiNotificationCmd.cmdType, subtype: XiaomiNotificationCmd.screenOnGet)
    }

    static func screenOnNotificationsSetCommand(_ enabled: Bool) -> Data {
        command(type: XiaomiNotificationCmd.cmdType, subtype: XiaomiNotificationCmd.screenOnSet) {
            $0.notification.screenOnOnNotifications = enabled
        }
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

    // MARK: - Workout / GPS command builders

    /// CMD_WORKOUT_WATCH_OPEN reply — sent in response to the band's workoutOpenWatch request.
    /// gpsReady=true  → {0,2,2}: phone GPS is working, band should wait for location stream.
    /// gpsReady=false → {3,2,10}: GPS unavailable, band starts workout without GPS immediately.
    static func workoutOpenReplyCommand(gpsReady: Bool) -> Data {
        var reply = Xiaomi_WorkoutOpenReply()
        reply.unknown1 = gpsReady ? 0 : 3
        reply.unknown2 = 2
        reply.unknown3 = gpsReady ? 2 : 10
        var health = Xiaomi_Health()
        health.workoutOpenReply = reply
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiHealthCmd.cmdType
        cmd.subtype = XiaomiHealthCmd.workoutOpen
        cmd.health  = health
        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_REALTIME_STATS_START / _STOP — asks the band to stream live stats (heart rate, steps) over
    /// the authenticated channel. No payload; the band then pushes RealTimeStats events (subtype 47).
    static func realtimeStatsCommand(enable: Bool) -> Data {
        bareCommand(type: XiaomiHealthCmd.cmdType,
                    subtype: enable ? XiaomiHealthCmd.realtimeStart : XiaomiHealthCmd.realtimeStop)
    }

    // MARK: - Watch face command builders

    static func watchfaceListCommand() -> Data {
        bareCommand(type: XiaomiWatchfaceCmd.cmdType, subtype: XiaomiWatchfaceCmd.list)
    }

    /// CMD_WATCHFACE_INSTALL — announces an incoming watch face; band replies installStatus.
    static func watchfaceInstallStartCommand(id: String, size: Int) -> Data {
        var start = Xiaomi_WatchfaceInstallStart()
        start.id   = id
        start.size = UInt32(size)
        var wf = Xiaomi_Watchface()
        wf.watchfaceInstallStart = start
        return command(type: XiaomiWatchfaceCmd.cmdType, subtype: XiaomiWatchfaceCmd.install) { $0.watchface = wf }
    }

    /// CMD_WATCHFACE_SET — makes `id` the active face.
    static func watchfaceSetCommand(id: String) -> Data {
        var wf = Xiaomi_Watchface()
        wf.watchfaceID = id
        return command(type: XiaomiWatchfaceCmd.cmdType, subtype: XiaomiWatchfaceCmd.set) { $0.watchface = wf }
    }

    /// CMD_WATCHFACE_DELETE — removes a user-installed face.
    static func watchfaceDeleteCommand(id: String) -> Data {
        var wf = Xiaomi_Watchface()
        wf.watchfaceID = id
        return command(type: XiaomiWatchfaceCmd.cmdType, subtype: XiaomiWatchfaceCmd.delete) { $0.watchface = wf }
    }

    // MARK: - App (RPK) command builders

    static func rpkListCommand() -> Data {
        bareCommand(type: XiaomiRpkCmd.cmdType, subtype: XiaomiRpkCmd.list)
    }

    /// CMD_RPK_INSTALL — announces an incoming quick app; band replies rpkInstallStart.cmd status.
    static func rpkInstallCommand(id: String, versionCode: Int, size: Int) -> Data {
        var info = Xiaomi_RpkInfo()
        info.id       = id
        info.unknown2 = UInt32(versionCode)
        info.size     = UInt32(size)
        var rpk = Xiaomi_Rpk()
        rpk.rpkInfo = info
        return command(type: XiaomiRpkCmd.cmdType, subtype: XiaomiRpkCmd.install) { $0.rpk = rpk }
    }

    /// CMD_RPK_DELETE — removes an installed app by package id + its stored sha.
    static func rpkDeleteCommand(id: String, sha: Data) -> Data {
        var del = Xiaomi_RpkInfoList()
        del.id  = id
        del.sha = sha
        var rpk = Xiaomi_Rpk()
        rpk.rpkDel = del
        return command(type: XiaomiRpkCmd.cmdType, subtype: XiaomiRpkCmd.delete) { $0.rpk = rpk }
    }

    // MARK: - Data upload command builder

    /// CMD_UPLOAD_START — opens an upload of `type` (watchface/rpk); band replies dataUploadAck
    /// with the resume position and negotiated chunk size.
    static func dataUploadRequestCommand(type: UInt8, md5: Data, size: Int) -> Data {
        var req = Xiaomi_DataUploadRequest()
        req.type   = UInt32(type)
        req.md5Sum = md5
        req.size   = UInt32(size)
        var upload = Xiaomi_DataUpload()
        upload.dataUploadRequest = req
        return command(type: XiaomiDataUploadCmd.cmdType, subtype: XiaomiDataUploadCmd.uploadStart) { $0.dataUpload = upload }
    }

    // MARK: - Command helpers

    private static func bareCommand(type: UInt32, subtype: UInt32) -> Data {
        var cmd = Xiaomi_Command()
        cmd.type = type
        cmd.subtype = subtype
        return (try? cmd.serializedData()) ?? Data()
    }

    private static func command(type: UInt32, subtype: UInt32, _ configure: (inout Xiaomi_Command) -> Void) -> Data {
        var cmd = Xiaomi_Command()
        cmd.type = type
        cmd.subtype = subtype
        configure(&cmd)
        return (try? cmd.serializedData()) ?? Data()
    }

    /// CMD_WORKOUT_LOCATION — streams a CoreLocation fix to the band during an active workout.
    static func workoutLocationCommand(
        timestamp: UInt32,
        latitude: Double,
        longitude: Double,
        altitude: Double,
        speed: Float,
        bearing: Float
    ) -> Data {
        var loc = Xiaomi_WorkoutLocation()
        loc.unknown1   = 2
        loc.timestamp  = timestamp
        loc.latitude   = latitude
        loc.longitude  = longitude
        loc.altitude   = altitude
        loc.speed      = speed
        loc.bearing    = bearing
        var health = Xiaomi_Health()
        health.workoutLocation = loc
        var cmd = Xiaomi_Command()
        cmd.type    = XiaomiHealthCmd.cmdType
        cmd.subtype = XiaomiHealthCmd.workoutLocation
        cmd.health  = health
        return (try? cmd.serializedData()) ?? Data()
    }
}
