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
// Reminders have no bulk-replace, so every reminder on the band is deleted before re-creating —
// this mirrors the iPhone's reminders without accumulating duplicates on the band.

@MainActor
final class CalendarSyncService {

    private weak var bandManager: BandManager?
    private let store = EKEventStore()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "CalSync")

    private let maxEvents = 50
    private let maxReminders = 20
    private let createdReminderIDsKey = "myband.createdReminderIDs"

    // Each section is pushed on every sync, but the payloads rarely change between syncs (language
    // almost never, calendar/reminders only when the user edits them). Pushing an unchanged set every
    // few minutes is wasted radio time and, for reminders, a needless delete+recreate churn on the
    // band. We cache a stable signature of the last successfully-sent payload and skip when it matches.
    private let lastLanguageKey  = "myband.lastPushedLanguage"
    private let lastCalendarKey  = "myband.lastPushedCalendarSig"
    private let lastRemindersKey = "myband.lastPushedRemindersSig"

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
        guard UserDefaults.standard.string(forKey: lastLanguageKey) != code else {
            log.debug("Language unchanged (\(code)) — skipping push")
            return
        }
        log.info("Pushing language: \(code)")
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.languageCommand(code: code))
        UserDefaults.standard.set(code, forKey: lastLanguageKey)
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
        guard UserDefaults.standard.string(forKey: lastCalendarKey) != sig else {
            log.debug("Calendar unchanged (\(events.count) event(s)) — skipping push")
            return
        }
        log.info("Pushing \(events.count) calendar event(s)")
        bandManager?.sendEncryptedCommand(
            protoBytes: XiaomiProto.calendarSyncCommand(events: Array(events), disabled: events.isEmpty)
        )
        UserDefaults.standard.set(sig, forKey: lastCalendarKey)
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
            .compactMap { r in Self.fireDate(of: r).map { (title: r.title ?? "Reminder", fires: $0) } }
            .filter { $0.fires > now }
            .sorted { $0.fires < $1.fires }
            .prefix(maxReminders)

        // Skip the delete+recreate churn when the upcoming set hasn't changed since the last push.
        let sig = signature(upcoming.map { "\($0.title)|\($0.fires.timeIntervalSince1970)" }
            .joined(separator: ";"))
        guard UserDefaults.standard.string(forKey: lastRemindersKey) != sig else {
            log.debug("Reminders unchanged — skipping push")
            return
        }

        // Clear the reminders we created on a previous sync before re-creating, so the band mirrors
        // the current state instead of accumulating. The ids are the band-assigned ones captured
        // from the create-acks of the previous run (see below).
        // The band's own list is authoritative: an id whose create-ack was missed is never
        // persisted, so deleting only the remembered ids left that reminder firing forever.
        let previous = (UserDefaults.standard.array(forKey: createdReminderIDsKey) as? [Int] ?? []).map { UInt32($0) }
        let onBand = await fetchBandReminderIDs() ?? []
        let stale = Array(Set(previous).union(onBand)).sorted()
        if !stale.isEmpty {
            log.info("Deleting \(stale.count) reminder(s) from the band")
            bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderDeleteCommand(ids: stale))
        }

        // The band assigns each reminder's id and returns it via schedule.ackId. Collect those acks
        // so we know what to delete next time.
        var ackedIDs: [Int] = []
        bandManager?.onScheduleAck = { id in ackedIDs.append(Int(id)) }
        defer { bandManager?.onScheduleAck = nil }

        for reminder in upcoming {
            let details = XiaomiProto.reminderDetails(date: reminder.fires, title: reminder.title)
            bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderCreateCommand(details))
        }

        let deadline = ContinuousClock.now + .seconds(5)
        while ackedIDs.count < upcoming.count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        UserDefaults.standard.set(ackedIDs, forKey: createdReminderIDsKey)
        // Unacked creates leave the signature unset, so the next sync redoes the push.
        if ackedIDs.count == upcoming.count {
            UserDefaults.standard.set(sig, forKey: lastRemindersKey)
        }
        log.info("Pushed \(upcoming.count) reminder(s), \(ackedIDs.count) acked")
    }

    /// The ids of every reminder on the band, or nil if it didn't answer in time.
    private func fetchBandReminderIDs() async -> [UInt32]? {
        guard let bandManager else { return nil }
        var ids: [UInt32]?
        bandManager.onReminderList = { ids = $0.reminder.map(\.id) }
        defer { bandManager.onReminderList = nil }
        bandManager.sendEncryptedCommand(protoBytes: XiaomiProto.remindersGetCommand())
        let deadline = ContinuousClock.now + .seconds(3)
        while ids == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return ids
    }

    // MARK: - Fire times

    /// When the band should buzz: the reminder's earliest alert, else its due time, else 09:00 on
    /// a date-only due day (the iOS Reminders default for all-day reminders).
    static func fireDate(due: DateComponents?, alarms: [EKAlarm], calendar: Calendar = .current) -> Date? {
        var dueDate: Date?
        if var comps = due, comps.year != nil, comps.month != nil, comps.day != nil {
            if comps.hour == nil { comps.hour = 9; comps.minute = 0 }
            dueDate = calendar.date(from: comps)
        }
        let alerts = alarms.compactMap { $0.absoluteDate ?? dueDate?.addingTimeInterval($0.relativeOffset) }
        return alerts.min() ?? dueDate
    }

    static func fireDate(of reminder: EKReminder) -> Date? {
        fireDate(due: reminder.dueDateComponents, alarms: reminder.alarms ?? [])
    }

    /// Minutes before `start` of the earliest alert. Nil for an alert at or after the start (an
    /// all-day event's "9:00 on the day"), which the band's unsigned field cannot express.
    static func notifyMinutesBefore(start: Date, alarms: [EKAlarm]) -> UInt32? {
        guard let first = alarms.map({ $0.absoluteDate ?? start.addingTimeInterval($0.relativeOffset) }).min(),
              first < start else { return nil }
        return UInt32(start.timeIntervalSince(first) / 60)
    }

    private func fetchDueReminders() async -> [EKReminder] {
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: nil
        )
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                let withDue = (reminders ?? [])
                    .filter { $0.dueDateComponents != nil }
                cont.resume(returning: withDue)
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
