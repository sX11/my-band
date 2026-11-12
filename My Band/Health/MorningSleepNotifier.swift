import Foundation
import OSLog
import UserNotifications

// MARK: - MorningSleepNotifier
//
// One notification a morning that opens last night's sheet on Sleep & trends (ADR 0010 addendum).
// A sync that brings a closed night posts it with the band's numbers; a fixed-time fallback,
// planned 7 mornings ahead, covers mornings no sync runs. Both share `morningSleep-<day>`, so the
// numbered one replaces the fallback instead of adding a second.

@MainActor
enum MorningSleepNotifier {

    static let enabledKey = "morningSleepNotification"
    static let notifiedDayKey = "morningNotifiedDay"
    static let fallbackEnabledKey = "morningFallbackEnabled"
    /// Minutes after midnight.
    static let fallbackTimeKey = "morningFallbackTime"
    static let defaultFallbackMinutes = 8 * 60 + 30
    nonisolated static let identifierPrefix = "morningSleep-"
    nonisolated static let nightKey = "night"
    static let planDays = 7
    static let alarmDelayMinutes = 30

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "MorningSleep")

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
    static var isFallbackEnabled: Bool { UserDefaults.standard.object(forKey: fallbackEnabledKey) as? Bool ?? true }
    static var fallbackMinutes: Int { UserDefaults.standard.object(forKey: fallbackTimeKey) as? Int ?? defaultFallbackMinutes }

    static func identifier(_ day: String) -> String { identifierPrefix + day }

    // MARK: - Decision

    /// A closed nap is a session too, so only a night of at least 3 h, begun before 03:00 and
    /// ended this morning, counts: a long morning nap starts too late.
    static func shouldNotify(nightStart: Date, nightEnd: Date, awakeFlag: Int?, now: Date,
                             lastNotifiedDay: String?, enabled: Bool, calendar: Calendar = .current) -> Bool {
        guard enabled, let awakeFlag, awakeFlag != 0,
              nightEnd.timeIntervalSince(nightStart) >= 3 * 3600,
              calendar.isDate(nightEnd, inSameDayAs: now),
              let three = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: now),
              let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now),
              let five = calendar.date(bySettingHour: 5, minute: 0, second: 0, of: now)
        else { return false }
        return nightStart < three && nightEnd >= three && nightEnd <= noon && now >= five
            && lastNotifiedDay != NightRatings.dayKey(now, calendar: calendar)
    }

    // MARK: - After a sync

    /// Called once a sync's nights are saved locally and written to Apple Health, so the sheet the
    /// notification opens can already read the night.
    static func notifyIfDue(_ sessions: [SleepSession], now: Date = .now) async {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: notifiedDayKey)
        guard let night = sessions
            .filter({ shouldNotify(nightStart: $0.startDate, nightEnd: $0.endDate, awakeFlag: $0.awakeFlag,
                                   now: now, lastNotifiedDay: last, enabled: isEnabled) })
            .max(by: { $0.endDate < $1.endDate })
        else { return }
        guard await canPost() else {
            log.info("Morning summary skipped: notifications not allowed")
            return
        }
        let day = NightRatings.dayKey(now)
        let id = identifier(day)
        let center = UNUserNotificationCenter.current()
        // The fallback already rang this morning: its replacement only updates the text.
        let fallbackShown = await center.deliveredNotifications().contains { $0.request.identifier == id }
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])

        let asleep = night.phases.filter { $0.type != .awake }.reduce(0) { $0 + $1.duration }
        let content = UNMutableNotificationContent()
        content.body = "Last night: \(MBFormat.hoursMinutesShort(asleep)) asleep. Rate it and see HR, HRV and SpO₂."
        content.sound = fallbackShown ? nil : .default
        content.userInfo = [nightKey: day]
        do {
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        } catch {
            log.error("Morning summary not posted: \(error.localizedDescription, privacy: .public)")
            return
        }
        defaults.set(day, forKey: notifiedDayKey)
        log.info("Morning summary posted for \(day, privacy: .public)")
    }

    // MARK: - Fallback

    /// The first enabled band alarm firing 03:00–12:00 that morning plus 30 min; with none, or no
    /// list read yet, the picked time. A one-time alarm rings once, so it counts only for the
    /// morning its next firing after `now` lands on.
    static func fallbackTime(for day: Date, alarms: [AlarmService.Alarm]?, picked: DateComponents,
                             now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        if let alarms,
           let three = calendar.date(bySettingHour: 3, minute: 0, second: 0, of: start),
           let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: start),
           let first = alarms.filter(\.enabled)
               .compactMap({ alarm in
                   alarm.repeatDays == 0
                       ? AlarmService.nextFire(of: alarm, after: now, calendar: calendar)
                       : AlarmService.nextFire(of: alarm, after: three.addingTimeInterval(-1), calendar: calendar)
               })
               .filter({ $0 >= three && $0 <= noon }).min(),
           let fire = calendar.date(byAdding: .minute, value: alarmDelayMinutes, to: first) {
            return fire
        }
        return calendar.date(bySettingHour: picked.hour ?? 0, minute: picked.minute ?? 0, second: 0, of: start) ?? start
    }

    /// The mornings from today on that still need a fallback: not yet notified, and not yet past.
    static func fallbacks(now: Date, alarms: [AlarmService.Alarm]?, picked: DateComponents,
                          notifiedDay: String?, calendar: Calendar = .current) -> [(day: String, fire: Date)] {
        let today = calendar.startOfDay(for: now)
        return (0 ..< planDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let key = NightRatings.dayKey(day, calendar: calendar)
            let fire = fallbackTime(for: day, alarms: alarms, picked: picked, now: now, calendar: calendar)
            guard key != notifiedDay, fire > now else { return nil }
            return (key, fire)
        }
    }

    /// Year to minute only, so a trigger read back from the centre compares equal to the plan.
    static func fireComponents(_ c: DateComponents) -> DateComponents {
        DateComponents(year: c.year, month: c.month, day: c.day, hour: c.hour, minute: c.minute)
    }

    /// What turns the pending fallbacks into the plan, both keyed by identifier: `upsert` adds a
    /// new or moved one (an add under a pending identifier replaces it), `remove` drops the rest.
    static func fallbackChanges(pending: [String: DateComponents], planned: [String: DateComponents])
        -> (upsert: [String], remove: [String]) {
        let upsert = planned.filter { id, fire in pending[id].map(fireComponents) != fireComponents(fire) }.keys.sorted()
        let remove = pending.keys.filter { planned[$0] == nil }.sorted()
        return (upsert, remove)
    }

    /// Why a replan runs, weakest first. Without the band's alarm list a sync keeps the last plan,
    /// and so does a foreground once fallbacks are pending, rather than dropping alarm-based times.
    enum Reason: Int, Comparable {
        case sync, foreground, change
        static func < (a: Reason, b: Reason) -> Bool { a.rawValue < b.rawValue }
    }

    private static var replanning = false
    private static var queued: Reason?

    /// One replan at a time: a request during one runs once after it, with the inputs read then.
    static func replan(_ reason: Reason) async {
        if replanning {
            queued = max(queued ?? reason, reason)
            return
        }
        replanning = true
        defer { replanning = false }
        var next: Reason? = reason
        while let current = next {
            await replanOnce(current)
            next = queued
            queued = nil
        }
    }

    private static func replanOnce(_ reason: Reason) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(identifierPrefix) }
        guard isEnabled, isFallbackEnabled, await canPost() else {
            center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier))
            return
        }
        let alarmService = AppServices.shared.alarms
        if !alarmService.loaded, reason == .sync || (reason == .foreground && !pending.isEmpty) { return }

        let minutes = fallbackMinutes
        let planned = fallbacks(now: .now, alarms: alarmService.loaded ? alarmService.alarms : nil,
                                picked: DateComponents(hour: minutes / 60, minute: minutes % 60),
                                notifiedDay: UserDefaults.standard.string(forKey: notifiedDayKey))
        var plan: [String: (day: String, when: DateComponents)] = [:]
        for f in planned {
            plan[identifier(f.day)] = (f.day, Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: f.fire))
        }
        var current: [String: DateComponents] = [:]
        for r in pending { current[r.identifier] = (r.trigger as? UNCalendarNotificationTrigger)?.dateComponents ?? DateComponents() }
        let changes = fallbackChanges(pending: current, planned: plan.mapValues(\.when))
        guard !changes.upsert.isEmpty || !changes.remove.isEmpty else { return }

        for id in changes.upsert {
            guard let f = plan[id] else { continue }
            // A sync may have posted this morning's summary while the plan was computed.
            if UserDefaults.standard.string(forKey: notifiedDayKey) == f.day { continue }
            let content = UNMutableNotificationContent()
            content.body = "See last night and rate it."
            content.sound = .default
            content.userInfo = [nightKey: f.day]
            let request = UNNotificationRequest(identifier: id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: f.when, repeats: false))
            do { try await center.add(request) } catch {
                log.error("Fallback for \(f.day, privacy: .public) not scheduled: \(error.localizedDescription, privacy: .public)")
            }
        }
        center.removePendingNotificationRequests(withIdentifiers: changes.remove)
    }

    /// No request of its own: FindPhoneService asks on every launch.
    private static func canPost() async -> Bool {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }
}
