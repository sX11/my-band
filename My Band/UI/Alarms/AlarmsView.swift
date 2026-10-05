import SwiftUI

// MARK: - AlarmsView
//
// The band's alarms: switch one on or off, swipe left to delete, swipe right to switch smart
// wake-up, add a new one. Every change goes
// straight to the band and the list is re-read from it (see AlarmService).

struct AlarmsView: View {

    @Environment(BandManager.self) private var band
    @Environment(AlarmService.self) private var alarms
    @Environment(\.dismiss) private var dismiss

    @State private var newTime = Calendar.current.date(bySettingHour: 7, minute: 0, second: 0, of: .now) ?? .now
    @State private var newDays: UInt32 = 0
    @State private var newSmart = false

    private var connected: Bool { band.connectionState.isConnected }
    private var atCapacity: Bool { alarms.loaded && !alarms.canAdd }

    /// Mon … Sun, matching the band's bit order (Mon = 1 … Sun = 64).
    private static let dayLetters = ["M", "T", "W", "T", "F", "S", "S"]

    var body: some View {
        NavigationStack {
            List {
                if !connected {
                    Section {
                        Text("Connect the band to change alarms.")
                            .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    }
                    .listRowBackground(MB.surfaceCard)
                }
                alarmsSection
                newAlarmSection
            }
            .scrollContentBackground(.hidden)
            .background(MB.bgApp.ignoresSafeArea())
            .navigationTitle("Alarms")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { if connected { alarms.requestList() } }
    }

    // MARK: - List

    private var alarmsSection: some View {
        Section {
            if alarms.alarms.isEmpty {
                Text(alarms.loaded ? "No alarms on the band" : "Loading…")
                    .font(.mbSubhead).foregroundStyle(MB.textTertiary)
            }
            ForEach(alarms.alarms) { alarm in
                row(alarm)
                    .swipeActions {
                        Button("Delete", role: .destructive) { alarms.delete(alarm) }
                            .disabled(!connected)
                    }
                    .swipeActions(edge: .leading) {
                        Button(alarm.smart ? "Normal" : "Smart") { alarms.setSmart(alarm, !alarm.smart) }
                            .tint(MB.accent)
                            .disabled(!connected)
                    }
            }
        } header: {
            Text(capacityText)
        }
        .listRowBackground(MB.surfaceCard)
    }

    private var capacityText: String {
        guard alarms.loaded else { return "On the band" }
        return "On the band · \(alarms.alarms.count) of \(alarms.capacity)"
    }

    private func row(_ alarm: AlarmService.Alarm) -> some View {
        Toggle(isOn: Binding(get: { alarm.enabled }, set: { alarms.setEnabled(alarm, $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "%02d:%02d", alarm.hour, alarm.minute))
                    .font(.mbDataMD).monospacedDigit()
                    .foregroundStyle(alarm.enabled ? MB.textPrimary : MB.textTertiary)
                Text(Self.repeatSummary(alarm.repeatDays) + (alarm.smart ? " · smart" : ""))
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
        }
        .tint(MB.accent)
        .disabled(!connected)
    }

    // MARK: - New alarm

    private var newAlarmSection: some View {
        Section("New alarm") {
            DatePicker("Time", selection: $newTime, displayedComponents: .hourAndMinute)
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            HStack(spacing: MB.Space.x2) {
                ForEach(0 ..< 7, id: \.self) { i in dayChip(i) }
            }
            .frame(maxWidth: .infinity)
            Text(Self.repeatSummary(newDays))
                .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            Toggle(isOn: $newSmart) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smart wake-up").font(.mbSubhead).foregroundStyle(MB.textPrimary)
                    Text("Wakes you in light sleep shortly before the set time")
                        .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                }
            }
            .tint(MB.accent)
            if atCapacity {
                Text("The band holds \(alarms.capacity) alarms. Delete one to add another.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
            MBButton(title: atCapacity ? "Band is full" : "Add alarm", variant: .primary, size: .lg,
                     icon: "plus", block: true, disabled: !connected || !alarms.canAdd) {
                let c = Calendar.current.dateComponents([.hour, .minute], from: newTime)
                alarms.add(hour: c.hour ?? 7, minute: c.minute ?? 0, repeatDays: newDays, smart: newSmart)
            }
        }
        .listRowBackground(MB.surfaceCard)
    }

    private func dayChip(_ i: Int) -> some View {
        let bit: UInt32 = 1 << UInt32(i)
        let on = newDays & bit != 0
        return Button { newDays ^= bit } label: {
            Text(Self.dayLetters[i])
                .font(.mbSubheadEmph)
                .frame(width: 36, height: 36)
                .foregroundStyle(on ? MB.textOnAccent : MB.textSecondary)
                .background(on ? MB.accent : MB.surfaceControl, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Calendar.current.weekdaySymbols[(i + 1) % 7])
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: - Copy

    static func repeatSummary(_ days: UInt32) -> String {
        switch days {
        case 0: return "Once"
        case AlarmService.everyDay: return "Every day"
        case 0x1F: return "Weekdays"
        case 0x60: return "Weekends"
        default:
            let names = Calendar.current.shortWeekdaySymbols   // Sun … Sat
            return (0 ..< 7).filter { days & (1 << UInt32($0)) != 0 }
                .map { names[($0 + 1) % 7] }
                .joined(separator: ", ")
        }
    }
}
