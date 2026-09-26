import Foundation
import OSLog

// MARK: - AlarmService
//
// The band's own alarms (it wakes you by vibrating), read and written over the schedule command
// type — a port of GadgetBridge XiaomiScheduleService's alarm half. The band is the source of truth:
// every change is sent, then the list is re-read, so the app never keeps a copy that can drift.
//
// Repeat flags use GadgetBridge's weekday bitmask (Mon = 1 … Sun = 64); 0 = once, 127 = every day.

@Observable
@MainActor
final class AlarmService {

    struct Alarm: Identifiable, Equatable {
        let id: UInt32          // band-assigned slot, starts at 1
        var hour: Int
        var minute: Int
        var repeatDays: UInt32  // weekday bitmask, 0 = once
        var enabled: Bool
        var smart: Bool
        /// The band's own record. Edits start from it so fields and repeat modes this app doesn't
        /// model (monthly, a firmware workday mode) survive a toggle.
        var details = Xiaomi_AlarmDetails()
    }

    static let everyDay: UInt32 = 0x7F

    private(set) var alarms: [Alarm] = []
    private(set) var maxAlarms: Int?
    private(set) var loaded = false

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Alarms")

    private enum RepeatMode {
        static let once: UInt32 = 0
        static let daily: UInt32 = 1
        static let weekly: UInt32 = 5
    }
    private static let smartOn: UInt32 = 1
    private static let smartOff: UInt32 = 2

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onAlarmCommand = { [weak self] cmd in
            Task { @MainActor in self?.handle(cmd) }
        }
    }

    // MARK: - Actions

    /// Forget / re-pair: the list belonged to the old band.
    func reset() {
        alarms = []
        maxAlarms = nil
        loaded = false
    }

    func requestList() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.alarmsGetCommand())
    }

    func add(hour: Int, minute: Int, repeatDays: UInt32, smart: Bool) {
        let details = Self.details(hour: hour, minute: minute, repeatDays: repeatDays, enabled: true, smart: smart)
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.alarmCreateCommand(details))
        // The band assigns the id; the list is re-read when its create ack arrives.
    }

    func setEnabled(_ alarm: Alarm, _ enabled: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[i].enabled = enabled
        alarms[i].details.enabled = enabled
        let a = alarms[i]
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.alarmEditCommand(id: a.id, a.details))
        requestList()
    }

    func setSmart(_ alarm: Alarm, _ smart: Bool) {
        guard let i = alarms.firstIndex(where: { $0.id == alarm.id }) else { return }
        alarms[i].smart = smart
        alarms[i].details.smart = smart ? Self.smartOn : Self.smartOff
        let a = alarms[i]
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.alarmEditCommand(id: a.id, a.details))
        requestList()
    }

    func delete(_ alarm: Alarm) {
        alarms.removeAll { $0.id == alarm.id }
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.alarmDeleteCommand(ids: [alarm.id]))
        requestList()
    }

    // MARK: - Next alarm

    /// The soonest enabled alarm after `now`, with the moment it fires.
    func nextAlarm(after now: Date = .now) -> (alarm: Alarm, fires: Date)? {
        alarms.filter(\.enabled)
            .compactMap { a in Self.nextFire(of: a, after: now).map { (a, $0) } }
            .min { $0.1 < $1.1 }
    }

    static func nextFire(of alarm: Alarm, after now: Date, calendar: Calendar = .current) -> Date? {
        let startOfToday = calendar.startOfDay(for: now)
        for offset in 0 ... 7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  let fire = calendar.date(bySettingHour: alarm.hour, minute: alarm.minute, second: 0, of: day),
                  fire > now else { continue }
            if alarm.repeatDays == 0 { return fire }
            if alarm.repeatDays & dayBit(calendar.component(.weekday, from: day)) != 0 { return fire }
        }
        return nil
    }

    /// Calendar weekday (Sun = 1 … Sat = 7) → the band's bit (Mon = 1 … Sun = 64).
    static func dayBit(_ weekday: Int) -> UInt32 {
        1 << UInt32((weekday + 5) % 7)
    }

    // MARK: - Incoming

    private func handle(_ cmd: Xiaomi_Command) {
        switch cmd.subtype {
        case XiaomiScheduleCmd.alarmsGet where cmd.hasSchedule:
            let list = cmd.schedule.alarms
            maxAlarms = list.hasMaxAlarms ? Int(list.maxAlarms) : nil
            alarms = list.alarm.map(Self.alarm(from:)).sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
            loaded = true
            log.info("Alarms: \(self.alarms.count, privacy: .public) of max \(self.maxAlarms ?? -1, privacy: .public)")
        case XiaomiScheduleCmd.alarmCreate:
            requestList()
        default:
            break
        }
    }

    private static func alarm(from a: Xiaomi_Alarm) -> Alarm {
        let d = a.alarmDetails
        let days: UInt32 = switch d.repeatMode {
        case RepeatMode.daily: everyDay
        case RepeatMode.weekly: d.repeatFlags
        default: 0
        }
        return Alarm(id: a.id, hour: Int(d.time.hour), minute: Int(d.time.minute),
                     repeatDays: days, enabled: d.enabled, smart: d.smart == smartOn, details: d)
    }

    static func details(hour: Int, minute: Int, repeatDays: UInt32,
                                enabled: Bool, smart: Bool) -> Xiaomi_AlarmDetails {
        var time = Xiaomi_HourMinute()
        time.hour = UInt32(hour)
        time.minute = UInt32(minute)
        var d = Xiaomi_AlarmDetails()
        d.time = time
        d.enabled = enabled
        d.smart = smart ? smartOn : smartOff
        switch repeatDays {
        case 0:
            d.repeatMode = RepeatMode.once
        case everyDay:
            d.repeatMode = RepeatMode.daily
        default:
            d.repeatMode = RepeatMode.weekly
            d.repeatFlags = repeatDays
        }
        return d
    }
}
