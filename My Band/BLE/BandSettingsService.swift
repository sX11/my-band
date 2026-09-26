import Foundation
import OSLog
import SwiftProtobuf

// MARK: - BandSettingsService
//
// The band's own health-monitoring and display settings — a port of GadgetBridge
// XiaomiHealthService's CMD_CONFIG_* pairs plus the notification screen-on setting. Like
// AlarmService the band is the source of truth: an edit starts from the band's last record (so
// fields this app doesn't model survive), is sent, and that config is re-read.

@Observable
@MainActor
final class BandSettingsService {

    enum Spo2Mode {
        static let off: UInt32 = 0
        static let allDay: UInt32 = 2
    }

    /// Heart-rate monitoring: nil = off, 0 = smart, otherwise minutes between readings.
    static let heartRateIntervals: [UInt32?] = [nil, 0, 1, 10, 30]
    static let heartRateHighThresholds: [UInt32] = [0, 100, 110, 120, 130, 140, 150]
    static let heartRateLowThresholds: [UInt32] = [0, 40, 45, 50]
    static let spo2LowThresholds: [UInt32] = [0, 80, 85, 90]

    private(set) var heartRate: Xiaomi_HeartRate?
    private(set) var spo2: Xiaomi_SpO2?
    private(set) var stress: Xiaomi_Stress?
    private(set) var standingReminder: Xiaomi_StandingReminder?
    private(set) var goalNotification: Xiaomi_GoalNotification?
    private(set) var screenOnNotifications: Bool?

    var loaded: Bool { heartRate != nil || spo2 != nil || stress != nil }

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "BandSettings")

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onSettingsCommand = { [weak self] cmd in
            Task { @MainActor in self?.handle(cmd) }
        }
    }

    /// Forget / re-pair: the settings belonged to the old band.
    func reset() {
        heartRate = nil
        spo2 = nil
        stress = nil
        standingReminder = nil
        goalNotification = nil
        screenOnNotifications = nil
    }

    func requestAll() {
        for subtype in [XiaomiHealthCmd.heartRateGet, XiaomiHealthCmd.spo2Get, XiaomiHealthCmd.stressGet,
                        XiaomiHealthCmd.standingReminderGet, XiaomiHealthCmd.goalNotificationGet] {
            send(XiaomiProto.healthCommand(subtype: subtype))
        }
        send(XiaomiProto.screenOnNotificationsGetCommand())
    }

    // MARK: - Heart rate

    /// nil = off, 0 = smart, otherwise minutes.
    var heartRateInterval: UInt32? {
        guard let heartRate, !heartRate.disabled else { return nil }
        return heartRate.interval
    }

    func setHeartRateInterval(_ minutes: UInt32?) {
        editHeartRate {
            $0.disabled = minutes == nil
            $0.interval = minutes ?? 0
        }
    }

    func setHeartRateHighAlert(_ bpm: UInt32) {
        editHeartRate {
            $0.alarmHighEnabled = bpm > 0
            $0.alarmHighThreshold = bpm
        }
    }

    func setHeartRateLowAlert(_ bpm: UInt32) {
        editHeartRate {
            $0.heartRateAlarmLow.alarmLowEnabled = bpm > 0
            $0.heartRateAlarmLow.alarmLowThreshold = bpm
        }
    }

    func setSleepMonitoring(_ on: Bool) {
        editHeartRate { $0.advancedMonitoring.enabled = on }
    }

    func setBreathingQuality(_ on: Bool) {
        editHeartRate { $0.breathingScore = on ? 1 : 2 }
    }

    private func editHeartRate(_ change: (inout Xiaomi_HeartRate) -> Void) {
        guard var hr = heartRate else { return }
        change(&hr)
        // GadgetBridge always sends unknown7 = 1 and a present advancedMonitoring (a required field).
        if !hr.hasUnknown7 { hr.unknown7 = 1 }
        if !hr.hasAdvancedMonitoring { hr.advancedMonitoring.enabled = false }
        heartRate = hr
        log.debug("Heart rate set → \(hr.textFormatString(), privacy: .public)")
        send(XiaomiProto.healthConfigCommand(subtype: XiaomiHealthCmd.heartRateSet) { $0.heartRate = hr })
        send(XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.heartRateGet))
    }

    // MARK: - SpO₂

    /// Sleep-only (mode 1) reads as off: neither the band nor Mi Fitness offers it on a Mi Band 10.
    var spo2AllDay: Bool { spo2?.mode == Spo2Mode.allDay }

    var spo2LowAlert: UInt32 {
        guard let low = spo2?.alarmLow, low.alarmLowEnabled else { return 0 }
        return low.alarmLowThreshold
    }

    func setSpo2AllDay(_ on: Bool) {
        editSpo2 { $0.mode = on ? Spo2Mode.allDay : Spo2Mode.off }
    }

    func setSpo2LowAlert(_ percent: UInt32) {
        editSpo2 {
            $0.alarmLow.alarmLowEnabled = percent > 0
            $0.alarmLow.alarmLowThreshold = percent
        }
    }

    private func editSpo2(_ change: (inout Xiaomi_SpO2) -> Void) {
        guard var s = spo2 else { return }
        change(&s)
        if !s.hasUnknown1 { s.unknown1 = 1 }
        spo2 = s
        send(XiaomiProto.healthConfigCommand(subtype: XiaomiHealthCmd.spo2Set) { $0.spo2 = s })
        send(XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.spo2Get))
    }

    // MARK: - Stress

    func setStressAllDay(_ on: Bool) {
        editStress { $0.allDayTracking = on }
    }

    func setRelaxReminder(_ on: Bool) {
        editStress {
            $0.relaxReminder.enabled = on
            if !$0.relaxReminder.hasUnknown2 { $0.relaxReminder.unknown2 = 0 }
        }
    }

    private func editStress(_ change: (inout Xiaomi_Stress) -> Void) {
        guard var s = stress else { return }
        change(&s)
        stress = s
        send(XiaomiProto.healthConfigCommand(subtype: XiaomiHealthCmd.stressSet) { $0.stress = s })
        send(XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.stressGet))
    }

    // MARK: - Activity

    func setStandingReminder(_ on: Bool) {
        editStandingReminder { $0.enabled = on }
    }

    func setStandingReminderWindow(start: Xiaomi_HourMinute, end: Xiaomi_HourMinute) {
        editStandingReminder {
            $0.start = start
            $0.end = end
        }
    }

    private func editStandingReminder(_ change: (inout Xiaomi_StandingReminder) -> Void) {
        guard var r = standingReminder else { return }
        change(&r)
        standingReminder = r
        send(XiaomiProto.healthConfigCommand(subtype: XiaomiHealthCmd.standingReminderSet) { $0.standingReminder = r })
        send(XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.standingReminderGet))
    }

    func setGoalNotification(_ on: Bool) {
        guard var g = goalNotification else { return }
        g.enabled = on
        if !g.hasUnknown2 { g.unknown2 = 1 }
        goalNotification = g
        send(XiaomiProto.healthConfigCommand(subtype: XiaomiHealthCmd.goalNotificationSet) { $0.goalNotification = g })
        send(XiaomiProto.healthCommand(subtype: XiaomiHealthCmd.goalNotificationGet))
    }

    // MARK: - Display

    func setScreenOnNotifications(_ on: Bool) {
        guard screenOnNotifications != nil else { return }
        screenOnNotifications = on
        send(XiaomiProto.screenOnNotificationsSetCommand(on))
        send(XiaomiProto.screenOnNotificationsGetCommand())
    }

    // MARK: - Incoming

    private func handle(_ cmd: Xiaomi_Command) {
        if cmd.type == XiaomiNotificationCmd.cmdType {
            if cmd.subtype == XiaomiNotificationCmd.screenOnGet, cmd.hasNotification {
                screenOnNotifications = cmd.notification.screenOnOnNotifications
            } else {
                logAck(cmd)
            }
            return
        }
        let h = cmd.health
        switch cmd.subtype {
        case XiaomiHealthCmd.heartRateGet where cmd.hasHealth && h.hasHeartRate:
            log.debug("Heart rate from band ← \(h.heartRate.textFormatString(), privacy: .public)")
            heartRate = h.heartRate
        case XiaomiHealthCmd.spo2Get where cmd.hasHealth && h.hasSpo2:
            spo2 = h.spo2
        case XiaomiHealthCmd.stressGet where cmd.hasHealth && h.hasStress:
            stress = h.stress
        case XiaomiHealthCmd.standingReminderGet where cmd.hasHealth && h.hasStandingReminder:
            standingReminder = h.standingReminder
        case XiaomiHealthCmd.goalNotificationGet where cmd.hasHealth && h.hasGoalNotification:
            goalNotification = h.goalNotification
        default:
            logAck(cmd)
        }
    }

    private func logAck(_ cmd: Xiaomi_Command) {
        if cmd.hasStatus, cmd.status != 0 {
            log.warning("Settings cmd type=\(cmd.type, privacy: .public) subtype=\(cmd.subtype, privacy: .public) rejected (status \(cmd.status, privacy: .public))")
        } else {
            log.debug("Settings cmd type=\(cmd.type, privacy: .public) subtype=\(cmd.subtype, privacy: .public) acknowledged")
        }
    }

    private func send(_ bytes: Data) {
        bandManager?.sendEncryptedCommand(protoBytes: bytes)
    }
}
