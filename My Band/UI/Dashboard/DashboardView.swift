import SwiftUI

// MARK: - DashboardView
//
// Minimal first dashboard: live band status, battery, last Apple Health sync, and a
// "Sincronizar com Apple Health" action. Sleep/activity detail comes in a later phase.

struct DashboardView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSyncer.self) private var syncer
    var onForget: () -> Void

    @State private var syncing = false
    @State private var resultText: String?
    @State private var resultIsError = false

    private var connected: Bool { band.connectionState.isConnected }

    var body: some View {
        ZStack {
            MB.bgApp.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: MB.Space.x5) {
                    header
                    metrics
                    syncSection
                    Spacer(minLength: MB.Space.x6)
                    MBButton(title: "Esquecer pulseira", variant: .ghost, size: .md, block: true,
                             action: onForget)
                }
                .padding(.horizontal, MB.Space.screenPad)
                .padding(.top, MB.Space.x6)
                .padding(.bottom, MB.Space.x10)
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
                Text("Sua pulseira").font(.mbSubhead).foregroundStyle(MB.textTertiary)
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
        HStack(spacing: MB.Space.x3) {
            MBMetricTile(
                icon: batteryIcon, tint: batteryTint, tintSoft: batteryTintSoft,
                label: "Bateria",
                value: band.batteryLevel.map(String.init) ?? "—",
                unit: band.batteryLevel != nil ? "%" : nil,
                foot: band.batteryCharging ? "Carregando" : nil
            )
            MBMetricTile(
                icon: "heart.fill", tint: MB.hr, tintSoft: MB.hrSoft,
                label: "Apple Health",
                value: lastSyncText,
                foot: "última sincronização"
            )
        }
    }

    // MARK: Sync

    private var syncSection: some View {
        VStack(spacing: MB.Space.x3) {
            MBButton(title: syncing ? "Sincronizando…" : "Sincronizar com Apple Health",
                     variant: .primary, size: .lg, icon: "arrow.triangle.2.circlepath",
                     block: true, glow: true, loading: syncing, disabled: !connected || syncing) {
                runSync()
            }
            if let resultText {
                Text(resultText)
                    .font(.mbFootnote)
                    .foregroundStyle(resultIsError ? MB.danger : MB.textTertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            } else if !connected {
                Text("Conecte a pulseira para sincronizar.")
                    .font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func runSync() {
        syncing = true
        resultText = nil
        Task {
            do {
                let outcome = try await syncer.syncToHealth()
                resultIsError = false
                resultText = "Sincronizado · \(outcome.healthSamplesWritten) amostras no Apple Health"
            } catch {
                resultIsError = true
                resultText = error.localizedDescription
            }
            syncing = false
        }
    }

    // MARK: Derived

    private var lastSyncText: String {
        guard let date = syncer.lastHealthSync else { return "Nunca" }
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
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
