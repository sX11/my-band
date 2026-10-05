import SwiftUI

// MARK: - RemindersView
//
// The band's reminders: swipe left to delete, add a new one with a title, a date and time, and a
// repeat. Every change goes straight to the band and the list is re-read from it (see
// ReminderService). Reminders pushed from the iPhone's Reminders app show here too; deleting one
// only lasts until the next sync pushes it again.

struct RemindersView: View {

    @Environment(BandManager.self) private var band
    @Environment(ReminderService.self) private var reminders
    @Environment(\.dismiss) private var dismiss

    @State private var newTitle = ""
    @State private var newDate = Calendar.current.date(byAdding: .hour, value: 1, to: .now) ?? .now
    @State private var newRepeat: ReminderService.Repeat = .once

    private var connected: Bool { band.connectionState.isConnected }
    private var atCapacity: Bool { reminders.loaded && !reminders.canAdd }
    private var titleIsValid: Bool { !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

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
            .navigationTitle("Reminders")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: connected) { if connected { reminders.requestList() } }
    }

    // MARK: - List

    private var remindersSection: some View {
        Section {
            if reminders.reminders.isEmpty {
                Text(reminders.loaded ? "No reminders on the band" : "Loading…")
                    .font(.mbSubhead).foregroundStyle(MB.textTertiary)
            }
            ForEach(reminders.reminders) { reminder in
                row(reminder)
                    .swipeActions {
                        Button("Delete", role: .destructive) { reminders.delete(reminder) }
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

    private func row(_ reminder: ReminderService.Reminder) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reminder.title.isEmpty ? "Reminder" : reminder.title)
                .font(.mbSubhead).foregroundStyle(MB.textPrimary)
            Text([Self.when(reminder.date), reminder.repeatRule == .once ? nil : reminder.repeatRule.title,
                  reminder.addedHere ? nil : "from Reminders"]
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
            DatePicker("When", selection: $newDate, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                .font(.mbSubhead)
            Picker("Repeat", selection: $newRepeat) {
                ForEach(ReminderService.Repeat.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .font(.mbSubhead)
            if atCapacity {
                Text("The band holds \(reminders.maxReminders ?? 0) reminders. Delete one to add another.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
            MBButton(title: atCapacity ? "Band is full" : "Add reminder", variant: .primary, size: .lg,
                     icon: "plus", block: true, disabled: !connected || !reminders.canAdd || !titleIsValid) {
                reminders.add(title: newTitle, date: newDate, repeatRule: newRepeat)
                newTitle = ""
            }
        }
        .listRowBackground(MB.surfaceCard)
        .tint(MB.accent)
    }

    // MARK: - Copy

    private static func when(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour().minute().locale(MBFormat.locale))
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(MBFormat.locale)) + " \(time)"
    }
}
