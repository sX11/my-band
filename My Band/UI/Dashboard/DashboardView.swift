import SwiftUI

// MARK: - DashboardView
//
// Minimal first dashboard: live band status, battery, last Apple Health sync, and a
// "Sincronizar com Apple Health" action. Sleep/activity detail comes in a later phase.

struct DashboardView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSyncer.self) private var syncer
    @Environment(AlarmService.self) private var alarms
    @Environment(BandSettingsService.self) private var settings
    var onForget: () -> Void

    @State private var syncing = false
    @State private var resultText: String?
    @State private var resultIsError = false
    @State private var showCustomize = false
    @State private var showProfile = false
    @State private var showAlarms = false
    @State private var showSettings = false

    private var connected: Bool { band.connectionState.isConnected }
    /// Mid-handshake (or scanning) — a reconnect is already under way, so the button waits.
    private var connecting: Bool {
        switch band.connectionState {
        case .connecting, .discoveringServices, .sessionConfig, .authenticating, .scanning,
             .awaitingPairingConfirmation: true
        default: false
        }
    }

    var body: some View {
        ZStack {
            MB.bgApp.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: MB.Space.x5) {
                    header
                    metrics
                    syncSection
                    MBButton(title: "Customize", variant: .secondary, size: .lg,
                             icon: "square.grid.2x2", block: true, disabled: !connected) {
                        showCustomize = true
                    }
                    MBButton(title: "Profile", variant: .secondary, size: .lg,
                             icon: "person.text.rectangle", block: true) {
                        showProfile = true
                    }
                    Spacer(minLength: MB.Space.x6)
                    MBButton(title: "Forget band", variant: .ghost, size: .md, block: true,
                             action: onForget)
                }
                .padding(.horizontal, MB.Space.screenPad)
                .padding(.top, MB.Space.x6)
                .padding(.bottom, MB.Space.x10)
            }
            .refreshable { if connected { await performSync() } }
        }
        .sheet(isPresented: $showCustomize) { CustomizeView() }
        .sheet(isPresented: $showProfile) { ProfileView() }
        .sheet(isPresented: $showAlarms) { AlarmsView() }
        .sheet(isPresented: $showSettings) { BandSettingsView() }
        .task(id: connected) {
            guard connected else { return }
            alarms.requestList()
            settings.requestAll()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(syncer.currentDevice?.name ?? "Mi Band 10")
                    .font(.mbTitle1).tracking(-0.02 * 28)
                    .foregroundStyle(MB.textPrimary)
                Text("Your band").font(.mbSubhead).foregroundStyle(MB.textTertiary)
            }
            Spacer()
            MBStatusPill(text: band.connectionState.pillLabel,
                         tone: band.connectionState.pillTone,
                         pulse: band.connectionState.pillPulses)
                .padding(.top, 6)
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        // The relative "last sync" text is computed at render time; without a clock nothing
        // re-renders it, so it froze at whatever it read when the view last changed.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: MB.Space.x3) {
                metricTiles(now: context.date)
                alarmTile(now: context.date)
                settingsTile
            }
        }
    }

    private func alarmTile(now: Date) -> some View {
        let next = alarms.nextAlarm(after: now)
        return Button { showAlarms = true } label: {
            MBMetricTile(
                icon: "alarm.fill", tint: MB.accent, tintSoft: MB.accentSoft,
                label: "Next alarm",
                value: next.map { String(format: "%02d:%02d", $0.alarm.hour, $0.alarm.minute) } ?? "—",
                foot: alarmFoot(next, now: now)
            )
        }
        .buttonStyle(.plain)
    }

    private var settingsTile: some View {
        Button { showSettings = true } label: {
            MBMetricTile(
                icon: "gearshape.fill", tint: MB.accent, tintSoft: MB.accentSoft,
                label: "Band settings",
                value: settings.heartRate != nil ? BandSettingsView.intervalLabel(settings.heartRateInterval) : "—",
                unit: settings.heartRate != nil ? "heart rate" : nil,
                foot: settingsFoot
            )
        }
        .buttonStyle(.plain)
    }

    private var settingsFoot: String {
        guard settings.loaded else { return connected ? "Loading…" : "Connect the band to see settings" }
        var parts: [String] = []
        if settings.spo2 != nil { parts.append(settings.spo2AllDay ? "SpO₂ all-day" : "SpO₂ off") }
        if let stress = settings.stress { parts.append(stress.allDayTracking ? "Stress on" : "Stress off") }
        if let r = settings.standingReminder, r.enabled { parts.append("Stand-up reminder") }
        return parts.joined(separator: " · ")
    }

    private func alarmFoot(_ next: (alarm: AlarmService.Alarm, fires: Date)?, now: Date) -> String {
        guard let next else {
            if !alarms.loaded { return connected ? "Loading…" : "Connect the band to see alarms" }
            return alarms.alarms.isEmpty ? "No alarms · tap to add" : "All alarms off"
        }
        let cal = Calendar.current
        let day = cal.isDate(next.fires, inSameDayAs: now) ? "Today"
            : cal.isDateInTomorrow(next.fires) ? "Tomorrow"
            : next.fires.formatted(.dateTime.weekday(.wide))
        return "\(day) · \(AlarmsView.repeatSummary(next.alarm.repeatDays))"
    }

    private func metricTiles(now: Date) -> some View {
        HStack(spacing: MB.Space.x3) {
            MBMetricTile(
                icon: batteryIcon, tint: batteryTint, tintSoft: batteryTintSoft,
                label: "Battery",
                value: band.batteryLevel.map(String.init) ?? "—",
                unit: band.batteryLevel != nil ? "%" : nil,
                foot: band.batteryCharging ? "Charging" : lastChargeText(now: now)
            )
            MBMetricTile(
                icon: "heart.fill", tint: MB.hr, tintSoft: MB.hrSoft,
                label: "Apple Health",
                value: lastSyncText(now: now),
                foot: "last sync"
            )
        }
        // Tiles stretch to the taller one (a foot line is optional) instead of each hugging its content.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Sync

    private var syncSection: some View {
        VStack(spacing: MB.Space.x3) {
            MBButton(title: syncing ? "Syncing…" : "Sync with Apple Health",
                     variant: .primary, size: .lg, icon: "arrow.triangle.2.circlepath",
                     block: true, glow: true, loading: syncing, disabled: !connected || syncing) {
                runSync()
            }
            if !connected {
                MBButton(title: connecting ? "Connecting…" : "Reconnect",
                         variant: .secondary, size: .lg,
                         icon: "antenna.radiowaves.left.and.right",
                         block: true, loading: connecting, disabled: connecting) {
                    reconnect()
                }
            }
            if let resultText {
                Text(resultText)
                    .font(.mbFootnote)
                    .foregroundStyle(resultIsError ? MB.danger : MB.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if !connected {
                Text("Connect the band to sync.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func reconnect() {
        if let id = syncer.currentDevice?.peripheralIdentifier {
            band.reconnectToKnownDevice(identifier: id)
        } else {
            band.startScan()
        }
    }

    private func runSync() {
        Task { await performSync() }
    }

    private func performSync() async {
        guard !syncing else { return }
        syncing = true
        resultText = nil
        do {
            // Funnel through the same coalesced entry point as the background/intent triggers,
            // so a manual tap can't race a sync already in flight.
            let outcome = try await BackgroundSyncManager.shared.syncNow()
            resultIsError = false
            resultText = "Synced · \(outcome.healthSamplesWritten) samples in Apple Health"
        } catch {
            resultIsError = true
            resultText = error.localizedDescription
        }
        syncing = false
    }

    // MARK: Derived

    private func lastSyncText(now: Date) -> String {
        guard let date = syncer.lastHealthSync else { return "Never" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .abbreviated
        // Under a minute reads "in 0 sec." / "0 sec. ago" from the formatter.
        if now.timeIntervalSince(date) < 60 { return "Just now" }
        return f.localizedString(for: date, relativeTo: now)
    }

    private func lastChargeText(now: Date) -> String? {
        guard let date = band.batteryLastCharged else { return nil }
        if now.timeIntervalSince(date) < 60 { return "Charged just now" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "en_US")
        f.unitsStyle = .abbreviated
        return "Charged \(f.localizedString(for: date, relativeTo: now))"
    }

    private var batteryIcon: String {
        guard let level = band.batteryLevel else { return "battery.0" }
        if band.batteryCharging { return "battery.100.bolt" }
        switch level {
        case ..<15: return "battery.25"
        case ..<55: return "battery.50"
        case ..<85: return "battery.75"
        default:    return "battery.100"
        }
    }
    private var batteryTint: Color {
        guard let level = band.batteryLevel else { return MB.textTertiary }
        if level < 15 { return MB.danger }
        if level < 30 { return MB.warn }
        return MB.steps
    }
    private var batteryTintSoft: Color {
        guard let level = band.batteryLevel else { return MB.surfaceFill }
        if level < 15 { return MB.dangerSoft }
        if level < 30 { return MB.warnSoft }
        return MB.stepsSoft
    }
}
