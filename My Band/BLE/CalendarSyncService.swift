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
// Reminders have no bulk-replace, so the reminders this push created are deleted before
// re-creating — this mirrors the iPhone's reminders without accumulating duplicates on the band.
// Ones added on the Reminders screen (ReminderService) are left alone.

@MainActor
final class CalendarSyncService {

    private weak var bandManager: BandManager?
    /// Owns the band's reminder list and create acks; reminders go through it.
    var reminders: ReminderService?
    private let store = EKEventStore()
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "CalSync")

    private let maxEvents = 50
    private let maxReminders = 20
    private static let createdReminderIDsKey = "myband.createdReminderIDs"
    private static let pushedRemindersKey = "myband.pushedReminders"
    private static let titleCleanupDoneKey = "myband.reminderTitleCleanupDone.2"
    static let pushCalendarKey = "myband.pushCalendar"
    static let pushRemindersKey = "myband.pushReminders"

    /// Off pushes an empty set, which clears the band's copies; on by default.
    private static func pushEnabled(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

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
        let enabled = Self.pushEnabled(Self.pushCalendarKey)
        if enabled, !(await requestEventsAccess()) {
            log.info("Calendar access not granted — skipping")
            return
        }
        let now = Date()
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = (enabled ? store.events(matching: predicate) : [])
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
        let enabled = Self.pushEnabled(Self.pushRemindersKey)
        if enabled, !(await requestRemindersAccess()) {
            log.info("Reminders access not granted — skipping")
            return
        }

        // Only reminders that will still fire: an overdue one is created on the band in the past.
        // The band holds one time per reminder, so each alert becomes its own.
        let now = Date()
        let upcoming = (enabled ? await fetchDueReminders() : [])
            .flatMap { r in
                Self.upcomingFires(of: r, after: now).map {
                    (title: ReminderService.truncated(r.title ?? "Reminder"), fires: $0.date, repeats: $0.repeats)
                }
            }
            .sorted { $0.fires < $1.fires }
            .prefix(maxReminders)

        // Skip the delete+recreate churn when the upcoming set hasn't changed since the last push.
        // The version prefix makes the first sync on this build push, so the title cleanup below runs.
        let sig = "3|" + signature(upcoming.map { "\($0.title)|\($0.fires.timeIntervalSince1970)|\($0.repeats.mode)" }
            .joined(separator: ";"))
        guard UserDefaults.standard.string(forKey: Self.lastRemindersKey) != sig else {
            log.debug("Reminders unchanged — skipping push")
            return
        }

        // Without the band's list there is nothing to reconcile against; the unsaved signature
        // makes the next sync try again.
        guard let reminders, let onBand = await reminders.fetchList() else {
            log.info("Band didn't list its reminders — skipping push")
            return
        }

        // Only this push's reminders are deleted: an id acked on a previous push, or one whose title
        // and time match what was pushed (its create-ack was missed, so its id was never known).
        // Once per install, any reminder titled like one the last push sent too: copies pushed before
        // repeating ones were keyed without their date are recognisable by nothing else, including
        // those of iPhone reminders since completed. Only once, because a title alone also matches
        // a reminder the band or another app created.
        // One added on the Reminders screen is never this push's, even with the same title and time.
        let previousIDs = Set((UserDefaults.standard.array(forKey: Self.createdReminderIDsKey) as? [Int] ?? []).map { UInt32($0) })
        let previousKeys = Set(UserDefaults.standard.stringArray(forKey: Self.pushedRemindersKey) ?? [])
        let titleCleanup = !UserDefaults.standard.bool(forKey: Self.titleCleanupDoneKey)
        let pushedTitles = titleCleanup ? Set(previousKeys.map(Self.title(ofKey:))) : []
        let protected = reminders.protectedIDs
        let stale = onBand.reminder
            .filter { !protected.contains($0.id) }
            .filter { previousIDs.contains($0.id) || previousKeys.contains(Self.reminderKey($0.reminderDetails))
                || pushedTitles.contains($0.reminderDetails.title) }
        if !stale.isEmpty {
            log.info("Deleting \(stale.count) reminder(s) from the band")
            reminders.delete(ids: stale.map(\.id))
        }

        // Creates still in flight (an add on the Reminders screen) aren't on the list yet.
        let slots = onBand.hasMaxReminders && onBand.maxReminders > 0
            ? Int(onBand.maxReminders) - (onBand.reminder.count - stale.count) - reminders.inFlight
            : maxReminders
        let toPush = upcoming.prefix(max(0, slots))
            .map { XiaomiProto.reminderDetails(date: $0.fires, title: $0.title, repeatMode: $0.repeats.mode) }

        // The band assigns each reminder's id and returns it in the create ack.
        let ackedIDs = await reminders.create(toPush)
        let owned = Self.owned(created: ackedIDs, pushed: toPush, deleting: stale,
                               listedAfter: await reminders.fetchList())
        UserDefaults.standard.set(owned.ids.map { Int($0) }, forKey: Self.createdReminderIDsKey)
        UserDefaults.standard.set(owned.keys, forKey: Self.pushedRemindersKey)
        UserDefaults.standard.set(true, forKey: Self.titleCleanupDoneKey)
        // A create left unconfirmed, or a delete the band didn't take, keeps the signature unsaved,
        // so the next sync tries again.
        if ackedIDs.count == toPush.count && owned.undeleted == 0 {
            UserDefaults.standard.set(sig, forKey: Self.lastRemindersKey)
        }
        log.info("Pushed \(toPush.count) of \(upcoming.count) reminder(s), \(ackedIDs.count) acked")
    }

    /// What the push owns on the band after it ran: its creates, plus every reminder it deleted that
    /// the band still lists (or all of them, with no list). A reminder stays the push's until the
    /// band stops listing it, so a lost delete is retried.
    static func owned(created: [UInt32], pushed: [Xiaomi_ReminderDetails], deleting: [Xiaomi_Reminder],
                      listedAfter: Xiaomi_Reminders?) -> (ids: [UInt32], keys: [String], undeleted: Int) {
        let listed = listedAfter.map { Set($0.reminder.map(\.id)) }
        let undeleted = deleting.filter { listed?.contains($0.id) ?? true }
        return (created + undeleted.map(\.id),
                pushed.map(reminderKey) + undeleted.map { reminderKey($0.reminderDetails) },
                undeleted.count)
    }

    /// The band's repeat for an iPhone recurrence, anchored on the next fire time. Only a plain,
    /// open-ended every-1 rule maps: the band has no interval and its weekly repeat holds one
    /// weekday, so anything else goes as its next occurrence and is re-pushed after it fires.
    static func repeatRule(_ rule: EKRecurrenceRule?, firing: Date, calendar: Calendar = .current) -> ReminderService.Repeat {
        // An empty list means the same as none; a rule synced from elsewhere may carry either.
        func set<T>(_ a: [T]?) -> [T]? { a?.isEmpty == false ? a : nil }
        guard let rule, rule.interval == 1, set(rule.setPositions) == nil,
              set(rule.weeksOfTheYear) == nil, set(rule.daysOfTheYear) == nil,
              // The band's repeat never ends, so a rule that does goes one occurrence at a time.
              rule.recurrenceEnd == nil else { return .once }
        let days = set(rule.daysOfTheWeek)
        let monthDays = set(rule.daysOfTheMonth)?.map(\.intValue)
        let months = set(rule.monthsOfTheYear)?.map(\.intValue)
        // A day or month the rule names is fine when it is the one the reminder fires on anyway.
        let firingDay = calendar.component(.day, from: firing)
        let firingMonth = calendar.component(.month, from: firing)
        let dayMatches = monthDays == nil || monthDays == [firingDay]
        let monthMatches = months == nil || months == [firingMonth]
        switch rule.frequency {
        case .daily:
            return days == nil && monthDays == nil && months == nil ? .daily : .once
        case .weekly:
            guard monthDays == nil, months == nil else { return .once }
            guard let days else { return .weekly }
            let weekday = calendar.component(.weekday, from: firing)
            return days.count == 1 && days[0].weekNumber == 0 && days[0].dayOfTheWeek.rawValue == weekday ? .weekly : .once
        case .monthly:
            return days == nil && months == nil && dayMatches ? .monthly : .once
        case .yearly:
            return days == nil && monthMatches && dayMatches ? .yearly : .once
        @unknown default:
            return .once
        }
    }

    /// How a reminder is recognised on the band's list; see `ReminderService.key`.
    static func reminderKey(_ d: Xiaomi_ReminderDetails) -> String { ReminderService.key(d) }

    /// The title a stored key starts with; the part after its last `|` never holds one.
    static func title(ofKey key: String) -> String {
        key.range(of: "|", options: .backwards).map { String(key[..<$0.lowerBound]) } ?? key
    }

    /// Makes the next sync push the iPhone's reminders even if they haven't changed: one was
    /// deleted on the Reminders screen.
    static func invalidateReminders() {
        UserDefaults.standard.removeObject(forKey: lastRemindersKey)
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
        alertDates(due: due, alarms: alarms, calendar: calendar).filter { $0 > now }.min()
    }

    static func fireDate(of reminder: EKReminder, after now: Date) -> Date? {
        fireDate(due: reminder.dueDateComponents, alarms: reminder.alarms ?? [], after: now)
    }

    /// Every alert of the reminder's current occurrence still to come, each with the band repeat it
    /// maps to. A repeating reminder's alert that already passed rolls forward to its next
    /// occurrence instead of dropping out until the iPhone moves the reminder on.
    static func upcomingFires(due: DateComponents?, alarms: [EKAlarm], rule: EKRecurrenceRule?,
                              after now: Date, calendar: Calendar = .current)
        -> [(date: Date, repeats: ReminderService.Repeat)] {
        Set(alertDates(due: due, alarms: alarms, calendar: calendar))
            .compactMap { alert -> (date: Date, repeats: ReminderService.Repeat)? in
                let repeats = repeatRule(rule, firing: alert, calendar: calendar)
                guard let next = rolledForward(alert, by: repeats, after: now, calendar: calendar) else { return nil }
                return (next, repeats)
            }
            .sorted { $0.date < $1.date }
    }

    static func upcomingFires(of reminder: EKReminder, after now: Date) -> [(date: Date, repeats: ReminderService.Repeat)] {
        upcomingFires(due: reminder.dueDateComponents, alarms: reminder.alarms ?? [],
                      rule: reminder.recurrenceRules?.first, after: now)
    }

    private static func rolledForward(_ date: Date, by repeats: ReminderService.Repeat, after now: Date,
                                      calendar: Calendar) -> Date? {
        let unit: Calendar.Component
        let size: Int
        switch repeats {
        case .once: return date > now ? date : nil
        case .daily: (unit, size) = (.day, 1)
        case .weekly: (unit, size) = (.day, 7)
        case .monthly: (unit, size) = (.month, 1)
        case .yearly: (unit, size) = (.year, 1)
        }
        // Each step counts from the original date: stepping from the previous result would carry a
        // clamped day on (Jan 31 → Feb 28 → Mar 28). Bounded so a years-overdue reminder can't spin.
        for n in 0..<800 {
            guard let next = calendar.date(byAdding: unit, value: n * size, to: date) else { return nil }
            if next > now { return next }
        }
        return nil
    }

    /// The times the iPhone would alert for the reminder's current occurrence, past ones included.
    private static func alertDates(due: DateComponents?, alarms: [EKAlarm], calendar: Calendar) -> [Date] {
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
        return alerts.isEmpty ? [dueDate].compactMap { $0 } : alerts
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
