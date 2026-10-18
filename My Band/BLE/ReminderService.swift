import Foundation
import OSLog
import Observation

// MARK: - ReminderService
//
// The band's reminders (Schedule, type 17): list, create, delete. Owns the reminder list and the
// create acks for the whole app — CalendarSyncService pushes the iPhone's reminders through it —
// because BandManager has one callback slot for each, and two owners would steal each other's.
//
// Reminders added from this app are remembered by title and time, so the iPhone-reminders push
// never deletes them.

@Observable
@MainActor
final class ReminderService {

    enum Repeat: CaseIterable, Hashable {
        case once, daily, weekly, monthly, yearly

        /// GadgetBridge's `XiaomiScheduleService` REPETITION_* values.
        var mode: UInt32 {
            switch self {
            case .once: 0
            case .daily: 1
            case .weekly: XiaomiProto.weeklyRepeatMode
            case .monthly: 7
            case .yearly: 8
            }
        }

        init(mode: UInt32) {
            self = Self.allCases.first { $0.mode == mode } ?? .once
        }

        var title: String {
            switch self {
            case .once: "Once"
            case .daily: "Every day"
            case .weekly: "Every week"
            case .monthly: "Every month"
            case .yearly: "Every year"
            }
        }
    }

    struct Reminder: Identifiable, Equatable {
        let id: UInt32
        let title: String
        let date: Date
        let repeatRule: Repeat
        /// Added from this app's Reminders screen, not pushed from the iPhone's Reminders.
        let addedHere: Bool
    }

    /// GadgetBridge caps Xiaomi reminder text at 20 characters, itself unsure the band needs it.
    static let maxTitleLength = 20

    private(set) var reminders: [Reminder] = []
    /// Reported by the band with its list; nil until then, or if it never says.
    private(set) var maxReminders: Int?
    private(set) var loaded = false

    /// Creates waiting for their ack, oldest first. The band acks creates in order and the ack is
    /// the only place it says the new id, so each one is matched to the oldest waiting create.
    private var ackWaiters: [(UUID, (UInt32) -> Void)] = []
    /// Acked creates the list hasn't been re-read for yet, which the current list doesn't count.
    private var ackedCreates = 0
    @ObservationIgnored private var listWaiters: [(UUID, (Xiaomi_Reminders) -> Void)] = []

    /// Reminders added here, by `key`, and whether the band has listed each one yet. Kept by
    /// identity rather than by ack id, so a lost or misattributed ack can't move the protection to
    /// another reminder. An iPhone reminder with the same title and time is protected too.
    @ObservationIgnored private var addedHere: [String: Bool] = ReminderService.loadAddedHere()
    private static let addedHereKey = "myband.addedHereReminders"

    /// Creates sent but not yet on the band's list: waiting for an ack, or acked and not re-read.
    var inFlight: Int { ackWaiters.count + ackedCreates }

    var canAdd: Bool { canAdd(1) }

    /// Free slots on the band, nil until it reports a limit.
    var freeSlots: Int? { maxReminders.map { max(0, $0 - reminders.count - inFlight) } }

    /// Whether `count` new reminders fit once `freeing` are deleted; only freed ones still listed count.
    func canAdd(_ count: Int, freeing: [Reminder] = []) -> Bool {
        guard loaded, count > 0 else { return false }
        let listed = Set(reminders.map(\.id))
        let freed = freeing.filter { listed.contains($0.id) }.count
        return freeSlots.map { count <= $0 + freed } ?? true
    }

    /// The ids of reminders added here, which the iPhone-reminders push leaves alone.
    var protectedIDs: Set<UInt32> { Set(reminders.filter(\.addedHere).map(\.id)) }

    private weak var bandManager: BandManager?
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "Reminders")

    func setup(manager: BandManager) {
        bandManager = manager
        manager.onReminderList = { [weak self] list in self?.handleList(list) }
        manager.onScheduleAck = { [weak self] id in self?.handleAck(id) }
    }

    /// Title and local wall time, the only fields the band echoes back that identify a reminder.
    static func key(_ d: Xiaomi_ReminderDetails) -> String {
        "\(d.title)|\(d.date.year)-\(d.date.month)-\(d.date.day) \(d.time.hour):\(d.time.minute)"
    }

    static func truncated(_ title: String) -> String {
        String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxTitleLength))
    }

    // MARK: - Actions

    /// Forget / re-pair: the list and what was added belonged to the old band.
    func reset() {
        reminders = []
        maxReminders = nil
        loaded = false
        ackWaiters = []
        ackedCreates = 0
        listWaiters = []
        addedHere = [:]
        saveAddedHere()
    }

    func requestList() {
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.remindersGetCommand())
    }

    /// One reminder per date, same title and repeat: the band holds a single time per reminder, so
    /// "every day at 10, 13 and 16" is three daily reminders. Returns how many the band acked; all
    /// or nothing is checked against the free slots, but a lost ack can still leave a partial set.
    @discardableResult
    func add(title: String, dates: [Date], repeatRule: Repeat) async -> Int {
        guard canAdd(dates.count) else {
            log.warning("Reminders not added: \(dates.count, privacy: .public) needed, \(self.freeSlots ?? -1, privacy: .public) free")
            return 0
        }
        let title = Self.truncated(title)
        var answered = 0
        var acked = 0
        for date in dates {
            let details = XiaomiProto.reminderDetails(date: date, title: title, repeatMode: repeatRule.mode)
            let key = Self.key(details)
            addedHere[key] = false
            create(details) { [weak self] id in
                answered += 1
                if id != nil { acked += 1 }
                // Unacked and never listed: the create most likely didn't land, so don't keep a key
                // that would protect a future reminder with the same title and time.
                guard let self, id == nil, self.addedHere[key] == false else { return }
                self.addedHere[key] = nil
                self.saveAddedHere()
            }
        }
        saveAddedHere()
        while answered < dates.count {
            try? await Task.sleep(for: .milliseconds(100))
        }
        requestList()
        return acked
    }

    /// Replaces `old` with a new set: nil if it doesn't fit, leaving `old` untouched; otherwise how
    /// many the band acked. A delete the band didn't take is sent once more, so an edit doesn't
    /// leave the old reminder next to the new one.
    func replace(_ old: [Reminder], title: String, dates: [Date], repeatRule: Repeat) async -> Int? {
        guard canAdd(dates.count, freeing: old) else {
            log.warning("Edit not saved: \(dates.count, privacy: .public) needed, \(self.freeSlots ?? -1, privacy: .public) free")
            return nil
        }
        delete(old)
        let acked = await add(title: title, dates: dates, repeatRule: repeatRule)
        let oldIDs = Set(old.map(\.id))
        if let list = await fetchList() {
            let left = list.reminder.map(\.id).filter { oldIDs.contains($0) }
            if !left.isEmpty {
                log.warning("Edit: band still lists \(left.count, privacy: .public) replaced reminder(s) — deleting again")
                delete(ids: left)
                requestList()
            }
        }
        return acked
    }

    func delete(_ group: [Reminder]) {
        let ids = Set(group.map(\.id))
        guard !ids.isEmpty else { return }
        reminders.removeAll { ids.contains($0.id) }
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderDeleteCommand(ids: Array(ids)))
        // The push skips an unchanged set, so without this a deleted iPhone reminder stays gone.
        if group.contains(where: { !$0.addedHere }) { CalendarSyncService.invalidateReminders() }
        requestList()
    }

    // MARK: - For the iPhone-reminders push

    /// The band's list as it answers now, or nil if it didn't within `timeout`.
    func fetchList(timeout: Duration = .seconds(3)) async -> Xiaomi_Reminders? {
        guard bandManager != nil else { return nil }
        let token = UUID()
        var list: Xiaomi_Reminders?
        listWaiters.append((token, { list = $0 }))
        defer { listWaiters.removeAll { $0.0 == token } }
        requestList()
        let deadline = ContinuousClock.now + timeout
        while list == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return list
    }

    /// Sends each create and returns the ids the band acked within `timeout`; fewer ids than
    /// creates means some went unconfirmed.
    func create(_ details: [Xiaomi_ReminderDetails], timeout: Duration = .seconds(5)) async -> [UInt32] {
        var acked: [UInt32] = []
        var answered = 0
        for d in details {
            create(d) { id in
                answered += 1
                if let id { acked.append(id) }
            }
        }
        let deadline = ContinuousClock.now + timeout
        while answered < details.count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return acked
    }

    func delete(ids: [UInt32]) {
        guard !ids.isEmpty else { return }
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderDeleteCommand(ids: ids))
    }

    // MARK: - Creates

    /// `done` gets the band-assigned id, or nil if no ack came within 10 s.
    private func create(_ details: Xiaomi_ReminderDetails, done: @escaping (UInt32?) -> Void) {
        let token = UUID()
        ackWaiters.append((token, { done($0) }))
        bandManager?.sendEncryptedCommand(protoBytes: XiaomiProto.reminderCreateCommand(details))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, let i = self.ackWaiters.firstIndex(where: { $0.0 == token }) else { return }
            self.ackWaiters.remove(at: i)
            self.log.warning("Reminder create got no ack")
            done(nil)
        }
    }

    // MARK: - Incoming

    private func handleList(_ list: Xiaomi_Reminders) {
        maxReminders = list.hasMaxReminders && list.maxReminders > 0 ? Int(list.maxReminders) : nil
        let onBand = Set(list.reminder.map { Self.key($0.reminderDetails) })
        // A reminder added here that the band listed and then dropped was deleted on the band;
        // one not listed yet may still be on its way.
        addedHere = addedHere.filter { key, seen in !seen || onBand.contains(key) }
        for key in addedHere.keys where onBand.contains(key) { addedHere[key] = true }
        saveAddedHere()
        reminders = list.reminder.map { r in
            let d = r.reminderDetails
            if d.repeatMode == XiaomiProto.weeklyRepeatMode {
                // Unconfirmed whether the band reads weekly flags as a weekday (GadgetBridge) or a bitmask.
                log.info("Weekly reminder id=\(r.id, privacy: .public) repeatFlags=\(d.repeatFlags, privacy: .public)")
            }
            return Reminder(id: r.id, title: d.title, date: Self.date(of: d),
                            repeatRule: Repeat(mode: d.repeatMode), addedHere: addedHere[Self.key(d)] != nil)
        }
        .sorted { $0.date < $1.date }
        ackedCreates = 0
        loaded = true
        log.info("Reminders: \(self.reminders.count, privacy: .public) of max \(self.maxReminders ?? -1, privacy: .public)")
        listWaiters.forEach { $0.1(list) }
    }

    private func handleAck(_ id: UInt32) {
        guard !ackWaiters.isEmpty else {
            log.debug("Reminder ack id=\(id, privacy: .public) with no create waiting")
            return
        }
        ackedCreates += 1
        ackWaiters.removeFirst().1(id)
    }

    private static func date(of d: Xiaomi_ReminderDetails) -> Date {
        Calendar.current.date(from: DateComponents(
            year: Int(d.date.year), month: Int(d.date.month), day: Int(d.date.day),
            hour: Int(d.time.hour), minute: Int(d.time.minute))) ?? .distantPast
    }

    // MARK: - Persistence

    private static func loadAddedHere() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: addedHereKey) as? [String: Bool] ?? [:]
    }

    private func saveAddedHere() {
        UserDefaults.standard.set(addedHere, forKey: Self.addedHereKey)
    }
}
