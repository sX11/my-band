import Foundation
import OSLog
import EventKit

// MARK: - CalendarSyncService
//
// Pushes phone-side configuration TO the band (app → band, encrypted):
//   • UI language   (System / CMD_LANGUAGE)        — from the current locale
//   • calendar events (CMD_CALENDAR_SET)           — EventKit, next 30 days, ≤50 events
//   • reminders     (Schedule / CMD_REMINDERS_*)   — EventKit reminders still to fire, ≤20
//
// Calendar sync is replace-semantics (the band swaps its whole event set), so it's idempotent.
// Reminders have no bulk-replace, so this app's reminders on the band are deleted before
// re-creating — this mirrors the iPhone's reminders without accumulating duplicates on the band.

@MainActor
final class CalendarSyncService {

    private weak var bandManager: BandManager?
    private let store = EKEventStore()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "CalSync")

    private let maxEvents = 50
    private let maxReminders = 20
    private static let createdReminderIDsKey = "myband.createdReminderIDs"
    private static let pushedRemindersKey = "myband.pushedReminders"

    // Each section is pushed on every sync, but the payloads rarely change between syncs (language
    // almost never, calendar/reminders only when the user edits them). Pushing an unchanged set every
    // few minutes is wasted radio time and, for reminders, a needless delete+recreate churn on the
    // band. We cache a stable signature of the last successfully-sent payload and skip when it matches.
    private static let lastLanguageKey  = "myband.lastPushedLanguage"
    private static let lastCalendarKey  = "myband.lastPushedCalendarSig"
    private static let lastRemindersKey = "myband.lastPushedRemindersSig"

    /// Launch-stable signature (Swift's Hashable is per-process salted, so it can't be persisted).
    private func signature(_ s: String) -> String {
        String(Checksums.crc32(Data(s.utf8)), radix: 16)
    }

    func setup(manager: BandManager) {
        bandManager = manager
    }

    // MARK: - Push entry point

    /// Pushes language, calendar and reminders to the band. Each section is independent: a denied
    /// permission or empty data set skips that section without blocking the others.
    func pushAll() async {
        guard bandManager?.connectionState.isConnected == true else { return }
        pushLanguage()
        await pushCalendar()
        await pushReminders()
    }

    // MARK: - Language

    private func pushLanguage() {
        // Locale.current reflects the app's resolved locale, which may fall back to English
        // when the app has no Portuguese localization — even if the user's preferred language
        // is pt-BR. Locale.preferredLanguages.first always returns the user's actual choice.
        let raw    = Locale.preferredLanguages.first ?? "en-US"
        let locale = Locale(identifier: raw)
        let lang   = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? Locale.current.region?.identifier ?? "US"
        let code   = "\(lang)_\(region)".lowercased()
        guard UserDefaults.standard.string(forKey: Self.lastLanguageKey) != code else {
            log.debug("Language unchanged (\(code)) — skipping push")
            return
        }
        log.info("Pushing language: \(code)")
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.languageCommand(code: code))
        UserDefaults.standard.set(code, forKey: Self.lastLanguageKey)
    }

    // MARK: - Calendar

    private func pushCalendar() async {
        guard await requestEventsAccess() else {
            log.info("Calendar access not granted — skipping")
            return
        }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(maxEvents)
            .map { ev -> Xiaomi_CalendarEvent in
                var e = Xiaomi_CalendarEvent()
                e.title    = ev.title ?? ""
                if let notes = ev.notes, !notes.isEmpty { e.description_p = notes }
                if let loc = ev.location, !loc.isEmpty { e.location = loc }
                e.start  = UInt32(ev.startDate.timeIntervalSince1970)
                e.end    = UInt32(ev.endDate.timeIntervalSince1970)
                e.allDay = ev.isAllDay
                if let minutes = Self.notifyMinutesBefore(start: ev.startDate, alarms: ev.alarms ?? []) {
                    e.notifyMinutesBefore = minutes
                }
                return e
            }
        let sig = signature(events.map { "\($0.title)|\($0.start)|\($0.end)|\($0.allDay)|\($0.notifyMinutesBefore)" }
            .joined(separator: ";"))
        guard UserDefaults.standard.string(forKey: Self.lastCalendarKey) != sig else {
            log.debug("Calendar unchanged (\(events.count) event(s)) — skipping push")
            return
        }
        log.info("Pushing \(events.count) calendar event(s)")
        bandManager?.sendEncryptedCommand(
            protoBytes: XiaomiProto.calendarSyncCommand(events: Array(events), disabled: events.isEmpty)
        )
        UserDefaults.standard.set(sig, forKey: Self.lastCalendarKey)
    }

    // MARK: - Reminders

    private func pushReminders() async {
        guard await requestRemindersAccess() else {
            log.info("Reminders access not granted — skipping")
            return
        }

        // Only reminders that will still fire: an overdue one is created on the band in the past.
        let now = Date()
        let upcoming = await fetchDueReminders()
            .compactMap { r in Self.fireDate(of: r, after: now).map { (title: r.title ?? "Reminder", fires: $0) } }
            .sorted { $0.fires < $1.fires }
            .prefix(maxReminders)

        // Skip the delete+recreate churn when the upcoming set hasn't changed since the last push.
        let sig = signature(upcoming.map { "\($0.title)|\($0.fires.timeIntervalSince1970)" }
            .joined(separator: ";"))
        guard UserDefaults.standard.string(forKey: Self.lastRemindersKey) != sig else {
            log.debug("Reminders unchanged — skipping push")
            return
        }

        // Without the band's list there is nothing to reconcile against; the unsaved signature
        // makes the next sync try again.
        guard let onBand = await fetchBandReminders() else {
            log.info("Band didn't list its reminders — skipping push")
            return
        }

        // Only this app's reminders are deleted: an id acked on a previous push, or one whose title
        // and time match what was pushed (its create-ack was missed, so its id was never known).
        let previousIDs = Set((UserDefaults.standard.array(forKey: Self.createdReminderIDsKey) as? [Int] ?? []).map { UInt32($0) })
        let previousKeys = Set(UserDefaults.standard.stringArray(forKey: Self.pushedRemindersKey) ?? [])
        let stale = onBand.reminder
            .filter { previousIDs.contains($0.id) || previousKeys.contains(Self.reminderKey($0.reminderDetails)) }
            .map(\.id)
        if !stale.isEmpty {
            log.info("Deleting \(stale.count) reminder(s) from the band")
            bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderDeleteCommand(ids: stale))
        }

        let slots = onBand.hasMaxReminders && onBand.maxReminders > 0
            ? Int(onBand.maxReminders) - (onBand.reminder.count - stale.count)
            : maxReminders
        let toPush = upcoming.prefix(max(0, slots))
            .map { XiaomiProto.reminderDetails(date: $0.fires, title: $0.title) }

        // The band assigns each reminder's id and returns it in the create ack.
        var ackedIDs: [Int] = []
        bandManager?.onScheduleAck = { id in ackedIDs.append(Int(id)) }
        defer { bandManager?.onScheduleAck = nil }

        for details in toPush {
            bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderCreateCommand(details))
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ackedIDs.count < toPush.count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        UserDefaults.standard.set(ackedIDs, forKey: Self.createdReminderIDsKey)
        UserDefaults.standard.set(toPush.map(Self.reminderKey), forKey: Self.pushedRemindersKey)
        UserDefaults.standard.set(sig, forKey: Self.lastRemindersKey)
        log.info("Pushed \(toPush.count) of \(upcoming.count) reminder(s), \(ackedIDs.count) acked")
    }

    /// The band's reminder list, or nil if it didn't answer in time.
    private func fetchBandReminders() async -> Xiaomi_Reminders? {
        guard let bandManager else { return nil }
        var list: Xiaomi_Reminders?
        bandManager.onReminderList = { list = $0 }
        defer { bandManager.onReminderList = nil }
        bandManager.sendEncryptedCommand(protoBytes: XiaomiProto.remindersGetCommand())
        let deadline = ContinuousClock.now + .seconds(3)
        while list == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return list
    }

    /// Title and local wall time, the only fields the band echoes back that identify a reminder.
    static func reminderKey(_ d: Xiaomi_ReminderDetails) -> String {
        "\(d.title)|\(d.date.year)-\(d.date.month)-\(d.date.day) \(d.time.hour):\(d.time.minute)"
    }

    /// Clears what was pushed, so a newly paired band gets the full set on its first sync.
    static func forgetBand() {
        for key in [createdReminderIDsKey, pushedRemindersKey, lastLanguageKey, lastCalendarKey, lastRemindersKey] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    // MARK: - Fire times

    /// The next time after `now` the iPhone would alert: its timed alerts if it has any (relative
    /// ones counted from the due time, or from midnight for a date-only reminder), else the due
    /// time, else 09:00 on a date-only due day (the iOS default for all-day reminders).
    static func fireDate(due: DateComponents?, alarms: [EKAlarm], after now: Date,
                         calendar: Calendar = .current) -> Date? {
        var base: Date?
        var dueDate: Date?
        if let comps = due, let y = comps.year, let m = comps.month, let d = comps.day {
            var cal = calendar
            if let tz = comps.timeZone { cal.timeZone = tz }
            if comps.hour != nil {
                base = cal.date(from: comps)
                dueDate = base
            } else {
                base = cal.date(from: DateComponents(year: y, month: m, day: d))
                dueDate = base.flatMap { cal.date(byAdding: .hour, value: 9, to: $0) }
            }
        }
        let alerts = alarms.filter(\.isTimed).compactMap { $0.absoluteDate ?? base?.addingTimeInterval($0.relativeOffset) }
        let candidates = alerts.isEmpty ? [dueDate].compactMap { $0 } : alerts
        return candidates.filter { $0 > now }.min()
    }

    static func fireDate(of reminder: EKReminder, after now: Date) -> Date? {
        fireDate(due: reminder.dueDateComponents, alarms: reminder.alarms ?? [], after: now)
    }

    /// Minutes before `start` of the earliest alert. Nil for an alert at or after the start (an
    /// all-day event's "9:00 on the day"), which the band's unsigned field cannot express.
    static func notifyMinutesBefore(start: Date, alarms: [EKAlarm]) -> UInt32? {
        guard let first = alarms.filter(\.isTimed)
                .map({ $0.absoluteDate ?? start.addingTimeInterval($0.relativeOffset) }).min(),
              first < start else { return nil }
        return UInt32(start.timeIntervalSince(first) / 60)
    }

    private func fetchDueReminders() async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                let scheduled = (reminders ?? [])
                    .filter { $0.dueDateComponents != nil || ($0.alarms ?? []).contains { $0.absoluteDate != nil } }
                cont.resume(returning: scheduled)
            }
        }
    }

    // MARK: - Authorization (iOS 17+ full-access APIs)

    private func requestEventsAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToEvents()) ?? false
        default: return false
        }
    }

    private func requestRemindersAccess() async -> Bool {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return true
        case .notDetermined: return (try? await store.requestFullAccessToReminders()) ?? false
        default: return false
        }
    }
}

private extension EKAlarm {
    /// A location alert ("arriving home") has no time; iOS never fires it on a schedule.
    var isTimed: Bool { structuredLocation == nil && proximity == .none }
}
