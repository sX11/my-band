import SwiftUI

// MARK: - RemindersView
//
// The page right of Workouts: the band's reminders. Swipe left to delete, add a new one with a
// title, a date and time, and a repeat; "Every day" takes several times. Every change goes
// straight to the band and the list is re-read from it (see ReminderService). Reminders pushed
// from the iPhone's Reminders app show here too; deleting one only lasts until the next sync
// pushes it again.

struct RemindersView: View {

    /// Reads the band's list only while this is the selected page.
    var isActive: Bool

    @Environment(BandManager.self) private var band
    @Environment(ReminderService.self) private var reminders

    private struct TimeSlot: Identifiable {
        let id = UUID()
        var time: Date
    }

    /// Daily reminders sharing a title show as one row, as they were added; deleting it deletes all.
    private struct ReminderGroup: Identifiable {
        let items: [ReminderService.Reminder]
        var id: UInt32 { items[0].id }
        var first: ReminderService.Reminder { items[0] }
    }

    @State private var newTitle = ""
    @State private var newDate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var newRepeat: ReminderService.Repeat = .once
    @State private var newTimes: [TimeSlot] = [TimeSlot(time: Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now)]
    @State private var adding = false
    @State private var resultText: String?

    private var connected: Bool { band.connectionState.isConnected }
    private var titleIsValid: Bool { !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var newDates: [Date] { newRepeat == .daily ? Self.nextOccurrences(newTimes.map(\.time)) : [newDate] }
    private var fits: Bool { reminders.canAdd(newDates.count) }
    private var atCapacity: Bool { reminders.loaded && !fits }

    var body: some View {
        NavigationStack {
            List {
                if !connected {
                    Section {
                        Text("Connect the band to change reminders.")
                            .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    }
                    .listRowBackground(MB.surfaceCard)
                }
                remindersSection
                newReminderSection
            }
            .scrollContentBackground(.hidden)
            .background(MB.bgApp.ignoresSafeArea())
            .refreshable { if connected { reminders.requestList() } }
            .navigationTitle("Reminders")
        }
        .preferredColorScheme(.dark)
        .task(id: connected && isActive) { if connected && isActive { reminders.requestList() } }
    }

    // MARK: - List

    private var remindersSection: some View {
        Section {
            if reminders.reminders.isEmpty {
                Text(reminders.loaded ? "No reminders on the band" : "Loading…")
                    .font(.mbSubhead).foregroundStyle(MB.textTertiary)
            }
            ForEach(Self.grouped(reminders.reminders)) { group in
                row(group)
                    .swipeActions {
                        Button("Delete", role: .destructive) { reminders.delete(group.items) }
                            .disabled(!connected)
                    }
            }
        } header: {
            Text(capacityText)
        } footer: {
            if reminders.reminders.contains(where: { !$0.addedHere }) {
                Text("Reminders from the iPhone's Reminders app come back on the next sync if deleted here.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
        }
        .listRowBackground(MB.surfaceCard)
    }

    private var capacityText: String {
        guard reminders.loaded else { return "On the band" }
        guard let max = reminders.maxReminders else { return "On the band · \(reminders.reminders.count)" }
        return "On the band · \(reminders.reminders.count) of \(max)"
    }

    private func row(_ group: ReminderGroup) -> some View {
        let r = group.first
        let when = group.items.count > 1
            ? group.items.map { Self.time($0.date) }.joined(separator: ", ")
            : Self.when(r.date)
        return VStack(alignment: .leading, spacing: 2) {
            Text(r.title.isEmpty ? "Reminder" : r.title)
                .font(.mbSubhead).foregroundStyle(MB.textPrimary)
            Text([when, r.repeatRule == .once ? nil : r.repeatRule.title, r.addedHere ? nil : "from Reminders"]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.mbFootnote).foregroundStyle(MB.textTertiary)
        }
    }

    // MARK: - New reminder

    private var newReminderSection: some View {
        Section("New reminder") {
            HStack {
                TextField("Title", text: $newTitle)
                    .font(.mbSubhead)
                    .onChange(of: newTitle) { _, value in
                        if value.count > ReminderService.maxTitleLength {
                            newTitle = String(value.prefix(ReminderService.maxTitleLength))
                        }
                    }
                Text("\(newTitle.count)/\(ReminderService.maxTitleLength)")
                    .font(.mbFootnote).monospacedDigit().foregroundStyle(MB.textTertiary)
            }
            Picker("Repeat", selection: $newRepeat) {
                ForEach(ReminderService.Repeat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .font(.mbSubhead)
            if newRepeat == .daily {
                timesRows
            } else {
                DatePicker("When", selection: $newDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    .font(.mbSubhead)
            }
            if atCapacity {
                Text(capacityHint)
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
            if let resultText {
                Text(resultText)
                    .font(.mbFootnote).foregroundStyle(MB.warn)
            }
            MBButton(title: atCapacity ? "Band is full" : addTitle, variant: .primary, size: .lg,
                     icon: "plus", block: true, disabled: !connected || !fits || !titleIsValid || adding) {
                add()
            }
        }
        .listRowBackground(MB.surfaceCard)
        .tint(MB.accent)
    }

    @ViewBuilder
    private var timesRows: some View {
        ForEach($newTimes) { $slot in
            DatePicker(newTimes.count > 1 ? "At" : "Time", selection: $slot.time, displayedComponents: .hourAndMinute)
                .font(.mbSubhead)
                .deleteDisabled(newTimes.count == 1)
        }
        .onDelete { newTimes.remove(atOffsets: $0) }
        Button {
            let last = newTimes.last?.time ?? .now
            newTimes.append(TimeSlot(time: Calendar.current.date(byAdding: .hour, value: 3, to: last) ?? last))
        } label: {
            Label("Add time", systemImage: "plus.circle")
                .font(.mbSubhead)
        }
    }

    private var addTitle: String {
        newDates.count > 1 ? "Add \(newDates.count) reminders" : "Add reminder"
    }

    private var capacityHint: String {
        let max = reminders.maxReminders ?? 0
        guard newDates.count > 1, let free = reminders.freeSlots else {
            return "The band holds \(max) reminders. Delete one to add another."
        }
        return "Each time takes one of the band's \(max) slots: \(newDates.count) needed, \(free) free."
    }

    private func add() {
        let dates = newDates
        let title = newTitle
        let repeatRule = newRepeat
        adding = true
        resultText = nil
        Task {
            let acked = await reminders.add(title: title, dates: dates, repeatRule: repeatRule)
            adding = false
            if acked < dates.count {
                resultText = "The band confirmed \(acked) of \(dates.count). Check the list before adding again."
            } else {
                newTitle = ""
            }
        }
    }

    // MARK: - Grouping

    private static func grouped(_ items: [ReminderService.Reminder]) -> [ReminderGroup] {
        var groups: [ReminderGroup] = []
        var dailyIndex: [String: Int] = [:]
        for r in items {
            guard r.repeatRule == .daily else {
                groups.append(ReminderGroup(items: [r]))
                continue
            }
            let key = "\(r.title)|\(r.addedHere)"
            if let i = dailyIndex[key] {
                groups[i] = ReminderGroup(items: (groups[i].items + [r]).sorted { time(of: $0.date) < time(of: $1.date) })
            } else {
                dailyIndex[key] = groups.count
                groups.append(ReminderGroup(items: [r]))
            }
        }
        return groups
    }

    private static func time(of date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// The next occurrence of each distinct time of day, so a daily reminder starts today if the
    /// time is still ahead and tomorrow otherwise.
    private static func nextOccurrences(_ times: [Date]) -> [Date] {
        let cal = Calendar.current
        var seen = Set<Int>()
        return times.compactMap { t in
            guard seen.insert(time(of: t)).inserted else { return nil }
            let c = cal.dateComponents([.hour, .minute], from: t)
            return cal.nextDate(after: .now, matching: DateComponents(hour: c.hour, minute: c.minute, second: 0),
                                matchingPolicy: .nextTime)
        }
        .sorted()
    }

    // MARK: - Copy

    private static func time(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute().locale(MBFormat.locale))
    }

    private static func when(_ date: Date) -> String {
        let time = time(date)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(MBFormat.locale)) + " \(time)"
    }
}
