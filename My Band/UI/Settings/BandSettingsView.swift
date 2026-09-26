import SwiftUI

// MARK: - BandSettingsView
//
// The band's own settings: heart-rate, SpO₂ and stress monitoring, activity reminders, and the
// screen on notifications. Every change goes straight to the band and is re-read from it (see
// BandSettingsService); a section appears once the band has reported it.

struct BandSettingsView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSettingsService.self) private var settings
    @Environment(\.dismiss) private var dismiss

    private var connected: Bool { band.connectionState.isConnected }

    var body: some View {
        NavigationStack {
            List {
                if !connected {
                    Section {
                        Text("Connect the band to change its settings.")
                            .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    }
                    .listRowBackground(MB.surfaceCard)
                } else if !settings.loaded {
                    Section {
                        Text("Loading…").font(.mbSubhead).foregroundStyle(MB.textTertiary)
                    }
                    .listRowBackground(MB.surfaceCard)
                }
                heartRateSection
                spo2Section
                stressSection
                activitySection
                displaySection
            }
            .scrollContentBackground(.hidden)
            .background(MB.bgApp.ignoresSafeArea())
            .navigationTitle("Band settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .disabled(!connected)
            .tint(MB.accent)
        }
        .preferredColorScheme(.dark)
        .onAppear { if connected { settings.requestAll() } }
    }

    // MARK: - Heart rate

    @ViewBuilder private var heartRateSection: some View {
        if let hr = settings.heartRate {
            Section("Heart rate") {
                Picker("Monitoring", selection: Binding(
                    get: { settings.heartRateInterval },
                    set: { settings.setHeartRateInterval($0) })) {
                    ForEach(BandSettingsService.heartRateIntervals, id: \.self) { value in
                        Text(Self.intervalLabel(value)).tag(value)
                    }
                }
                Picker("High alert", selection: Binding(
                    get: { hr.alarmHighEnabled ? hr.alarmHighThreshold : 0 },
                    set: { settings.setHeartRateHighAlert($0) })) {
                    ForEach(Self.withCurrent(BandSettingsService.heartRateHighThresholds,
                                             hr.alarmHighEnabled ? hr.alarmHighThreshold : 0), id: \.self) {
                        Text(Self.thresholdLabel($0, unit: "bpm")).tag($0)
                    }
                }
                Picker("Low alert", selection: Binding(
                    get: { hr.heartRateAlarmLow.alarmLowEnabled ? hr.heartRateAlarmLow.alarmLowThreshold : 0 },
                    set: { settings.setHeartRateLowAlert($0) })) {
                    ForEach(Self.withCurrent(BandSettingsService.heartRateLowThresholds,
                                             hr.heartRateAlarmLow.alarmLowEnabled ? hr.heartRateAlarmLow.alarmLowThreshold : 0),
                            id: \.self) {
                        Text(Self.thresholdLabel($0, unit: "bpm")).tag($0)
                    }
                }
                toggle("Sleep monitoring", detail: "Uses heart rate to detect sleep stages",
                       isOn: hr.advancedMonitoring.enabled, set: settings.setSleepMonitoring)
                // Mi Band 10 acks a breathingScore set but never stores or reports it.
                if hr.hasBreathingScore {
                    toggle("Breathing quality", detail: "Tracks breathing during sleep",
                           isOn: hr.breathingScore == 1, set: settings.setBreathingQuality)
                }
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    // MARK: - SpO₂

    @ViewBuilder private var spo2Section: some View {
        if settings.spo2 != nil {
            Section("Blood oxygen") {
                toggle("All-day SpO₂", detail: "Measures periodically through the day",
                       isOn: settings.spo2AllDay, set: settings.setSpo2AllDay)
                Picker("Low alert", selection: Binding(
                    get: { settings.spo2LowAlert },
                    set: { settings.setSpo2LowAlert($0) })) {
                    ForEach(Self.withCurrent(BandSettingsService.spo2LowThresholds, settings.spo2LowAlert),
                            id: \.self) {
                        Text(Self.thresholdLabel($0, unit: "%")).tag($0)
                    }
                }
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    // MARK: - Stress

    @ViewBuilder private var stressSection: some View {
        if let stress = settings.stress {
            Section("Stress") {
                toggle("All-day stress", isOn: stress.allDayTracking, set: settings.setStressAllDay)
                toggle("Relax reminder", detail: "Suggests a breathing exercise when stress is high",
                       isOn: stress.relaxReminder.enabled, set: settings.setRelaxReminder)
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    // MARK: - Activity

    @ViewBuilder private var activitySection: some View {
        if settings.standingReminder != nil || settings.goalNotification != nil {
            Section("Activity") {
                if let r = settings.standingReminder {
                    toggle("Stand-up reminder", detail: "Vibrates when you have been still too long",
                           isOn: r.enabled, set: settings.setStandingReminder)
                    if r.enabled {
                        DatePicker("From", selection: Binding(
                            get: { Self.date(r.start) },
                            set: { settings.setStandingReminderWindow(start: Self.hourMinute($0), end: r.end) }),
                                   displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: Binding(
                            get: { Self.date(r.end) },
                            set: { settings.setStandingReminderWindow(start: r.start, end: Self.hourMinute($0)) }),
                                   displayedComponents: .hourAndMinute)
                    }
                }
                if let g = settings.goalNotification {
                    toggle("Goal reached", detail: "Celebrates hitting a daily goal",
                           isOn: g.enabled, set: settings.setGoalNotification)
                }
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    // MARK: - Display

    @ViewBuilder private var displaySection: some View {
        if let screenOn = settings.screenOnNotifications {
            Section("Display") {
                toggle("Wake screen on notification", isOn: screenOn, set: settings.setScreenOnNotifications)
            }
            .listRowBackground(MB.surfaceCard)
        }
    }

    // MARK: - Pieces

    private func toggle(_ title: String, detail: String? = nil, isOn: Bool,
                        set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mbSubhead).foregroundStyle(MB.textPrimary)
                if let detail {
                    Text(detail).font(.mbFootnote).foregroundStyle(MB.textTertiary)
                }
            }
        }
    }

    // MARK: - Copy

    static func intervalLabel(_ minutes: UInt32?) -> String {
        switch minutes {
        case nil: "Off"
        case 0: "Smart"
        case 1: "Every minute"
        case let m?: "Every \(m) min"
        }
    }

    private static func thresholdLabel(_ value: UInt32, unit: String) -> String {
        value == 0 ? "Off" : "\(value) \(unit)"
    }

    /// A value the band holds that isn't among the offered choices still gets a row, so the picker
    /// shows it instead of an empty selection.
    private static func withCurrent(_ options: [UInt32], _ current: UInt32) -> [UInt32] {
        options.contains(current) ? options : (options + [current]).sorted()
    }

    private static func date(_ hm: Xiaomi_HourMinute) -> Date {
        Calendar.current.date(bySettingHour: Int(hm.hour), minute: Int(hm.minute), second: 0, of: .now) ?? .now
    }

    private static func hourMinute(_ date: Date) -> Xiaomi_HourMinute {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        var hm = Xiaomi_HourMinute()
        hm.hour = UInt32(c.hour ?? 0)
        hm.minute = UInt32(c.minute ?? 0)
        return hm
    }
}
