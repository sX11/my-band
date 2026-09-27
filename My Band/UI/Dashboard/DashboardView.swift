import SwiftUI

// MARK: - DashboardView
//
// Live band status, battery, last Apple Health sync and the sync action, the band's alarms and
// settings, today's activity read live from the band (ADR 0005), and the latest health readings
// from the last sync (ADR 0006).

struct DashboardView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSyncer.self) private var syncer
    @Environment(AlarmService.self) private var alarms
    @Environment(BandSettingsService.self) private var settings
    @Environment(TodayActivityService.self) private var today
    @Environment(LatestMetricsStore.self) private var latest
    @Environment(HealthSyncLog.self) private var syncLog
    @Environment(\.scenePhase) private var scenePhase
    var onForget: () -> Void

    @State private var syncing = false
    @State private var resultText: String?
    @State private var resultIsError = false
    @State private var showCustomize = false
    @State private var showProfile = false
    @State private var showAlarms = false
    @State private var showSettings = false
    @State private var showMetrics = false
    @State private var showHealthSync = false

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
            .refreshable {
                guard connected else { return }
                await performSync()
                today.refresh()
            }
        }
        .sheet(isPresented: $showCustomize) { CustomizeView() }
        .sheet(isPresented: $showProfile) { ProfileView() }
        .sheet(isPresented: $showAlarms) { AlarmsView() }
        .sheet(isPresented: $showSettings) { BandSettingsView() }
        .sheet(isPresented: $showMetrics) { LatestMetricsView(deviceID: syncer.currentDevice?.id) }
        .sheet(isPresented: $showHealthSync) { HealthSyncView() }
        .task(id: connected) {
            guard connected else { return }
            alarms.requestList()
            settings.requestAll()
        }
        .task(id: connected && scenePhase == .active) {
            // SwiftUI keeps .task running in the background; each reading makes the band measure
            // heart rate, so it only polls while the app is in front.
            guard connected, scenePhase == .active else {
                today.finish()
                return
            }
            while !Task.isCancelled {
                today.refresh()
                try? await Task.sleep(for: .seconds(5 * 60))
            }
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
            // Tiles stretch to the taller one in each row (a foot line is optional) instead of each
            // hugging its content.
            VStack(spacing: MB.Space.x3) {
                HStack(spacing: MB.Space.x3) {
                    batteryTile(now: context.date)
                    settingsTile
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: MB.Space.x3) {
                    alarmTile(now: context.date)
                    todayTile(now: context.date)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: MB.Space.x3) {
                    healthSyncTile(now: context.date)
                    metricsTile(now: context.date)
                }
                .fixedSize(horizontal: false, vertical: true)
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

    private func todayTile(now: Date) -> some View {
        MBMetricTile(
            icon: "figure.walk", tint: MB.steps, tintSoft: MB.stepsSoft,
            label: "Today",
            value: todaySteps(now: now).map(MBFormat.number) ?? "—",
            unit: todaySteps(now: now) != nil ? "steps" : nil,
            foot: todayFoot(now: now)
        )
    }

    /// A reading from an earlier day is not today's, whatever the tile's label says.
    private func todaySteps(now: Date) -> Int? {
        guard let at = today.updatedAt, Calendar.current.isDate(at, inSameDayAs: now) else { return nil }
        return today.steps
    }

    private func todayFoot(now: Date) -> String {
        guard todaySteps(now: now) != nil else {
            if !connected { return "Connect the band to see today" }
            return today.reading ? "Reading…" : "Pull to refresh"
        }
        var lines: [String] = []
        var totals: [String] = []
        if let kcal = today.calories { totals.append("\(kcal) kcal") }
        if let hours = stoodToday(now: now) { totals.append("stood \(hours) h") }
        if !totals.isEmpty { lines.append(totals.joined(separator: " · ")) }
        if let bpm = today.heartRate {
            lines.append("HR \(bpm) bpm")
        } else if today.reading {
            lines.append("Measuring HR…")
        }
        if let at = today.updatedAt, now.timeIntervalSince(at) > 10 * 60 {
            lines.append("as of \(at.formatted(date: .omitted, time: .shortened))")
        }
        return lines.joined(separator: "\n")
    }

    /// From the last synced daily summary: the realtime stream's own stand field reads 0 on a Band 10.
    private func stoodToday(now: Date) -> Int? {
        guard let day = latest.metrics.summaryDay, Calendar.current.isDate(day, inSameDayAs: now) else { return nil }
        return latest.metrics.standingHours
    }

    private func metricsTile(now: Date) -> some View {
        let m = latest.metrics
        return Button { showMetrics = true } label: {
            MBMetricTile(
                icon: "waveform.path.ecg", tint: MB.hr, tintSoft: MB.hrSoft,
                label: "Latest metrics",
                value: m.heartRate.map { String(Int($0.value)) } ?? "—",
                unit: m.heartRate != nil ? "bpm" : nil,
                foot: metricsFoot(m, now: now)
            )
        }
        .buttonStyle(.plain)
    }

    private func metricsFoot(_ m: LatestMetrics, now: Date) -> String {
        guard !m.isEmpty else { return "Sync to see readings" }
        var lines: [String] = []
        if let r = m.spo2 { lines.append("SpO₂ \(Int(r.value))%") }
        if let r = m.stress { lines.append("Stress \(Int(r.value))") }
        if let v = m.restingHR { lines.append("Resting \(v) bpm") }
        if let at = m.heartRate?.at { lines.append("HR \(MBFormat.ago(at, now: now))") }
        return lines.joined(separator: "\n")
    }

    private var settingsTile: some View {
        Button { showSettings = true } label: {
            MBMetricTile(
                icon: "gearshape.fill", tint: MB.accent, tintSoft: MB.accentSoft,
                label: "Settings",
                value: settings.heartRate != nil ? BandSettingsView.intervalLabel(settings.heartRateInterval, compact: true) : "—",
                unit: settings.heartRate != nil ? "HR" : nil,
                foot: settingsFoot
            )
        }
        .buttonStyle(.plain)
    }

    private var settingsFoot: String {
        guard settings.loaded else { return connected ? "Loading…" : "Band offline" }
        var on: [String] = []
        if settings.spo2 != nil, settings.spo2AllDay { on.append("SpO₂") }
        if let stress = settings.stress, stress.allDayTracking { on.append("Stress") }
        if let r = settings.standingReminder, r.enabled { on.append("Stand-up") }
        guard on.isEmpty else { return on.joined(separator: " · ") }
        // Only claim "off" when the band reported both configs; a missing one is unknown, not off.
        return settings.spo2 != nil && settings.stress != nil ? "All-day tracking off" : "Tap to change"
    }

    private func healthSyncFoot(_ r: HealthSyncReport) -> String {
        let sent = "\(MBFormat.number(r.total)) samples sent"
        return r.failed ? "\(sent) · sync failed" : sent
    }

    private func healthSyncTile(now: Date) -> some View {
        Button { showHealthSync = true } label: {
            MBMetricTile(
                icon: "heart.fill", tint: MB.hr, tintSoft: MB.hrSoft,
                label: "Apple Health",
                value: lastSyncText(now: now),
                foot: syncLog.last.map(healthSyncFoot) ?? "last sync"
            )
        }
        .buttonStyle(.plain)
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

    private func batteryTile(now: Date) -> some View {
        MBMetricTile(
            icon: batteryIcon, tint: batteryTint, tintSoft: batteryTintSoft,
            label: "Battery",
            value: band.batteryLevel.map(String.init) ?? "—",
            unit: band.batteryLevel != nil ? "%" : nil,
            foot: band.batteryCharging ? "Charging" : lastChargeText(now: now)
        )
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
        return MBFormat.ago(date, now: now, justNow: "Just now")
    }

    private func lastChargeText(now: Date) -> String? {
        guard let date = band.batteryLastCharged else { return nil }
        return "Charged \(MBFormat.ago(date, now: now))"
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
