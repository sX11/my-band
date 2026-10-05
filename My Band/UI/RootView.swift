import SwiftUI
import SwiftData

// MARK: - RootView
//
// Top-level router for the Setup + Connection phase.
//   • No AuthKey stored  → SetupView (intro → key)
//   • AuthKey stored      → auto-connect → ConnectingView
//   • Connected           → ConnectedView (placeholder for the upcoming Dashboard)

struct RootView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSyncer.self) private var syncer
    @Environment(AlarmService.self) private var alarms
    @Environment(BandSettingsService.self) private var settings
    @Environment(TodayActivityService.self) private var today
    @Environment(\.scenePhase) private var scenePhase

    // Sourced from the model container directly so it's available at bootstrap regardless of
    // onAppear ordering relative to BandSyncer.loadStoredDevice().
    @Query(sort: \BandDevice.addedDate, order: .reverse) private var knownDevices: [BandDevice]

    private enum Phase { case setup, connecting, ready }
    @State private var phase: Phase = .setup
    @State private var page = 1

    var body: some View {
        Group {
            switch phase {
            case .setup:
                SetupView(onConnect: connect)
                    .transition(.opacity)
            case .connecting:
                ConnectingView(onConnected: { phase = .ready },
                               onRetry: { band.startScan() },
                               onReconfigure: forget)
                    .transition(.opacity)
            case .ready:
                // Sleep & trends left of the Dashboard (ADR 0010), Workouts right of it (ADR 0009).
                TabView(selection: $page) {
                    TrendsView(isActive: page == 0).tag(0)
                    DashboardView(onForget: forget).tag(1)
                    WorkoutsView(isActive: page == 2).tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .always))
                .background(MB.bgApp.ignoresSafeArea())
                .transition(.opacity)
                // Here rather than on the Dashboard page, which restarts its tasks on every swipe back.
                .task(id: band.connectionState.isConnected) {
                    guard band.connectionState.isConnected else { return }
                    alarms.requestList()
                    settings.requestAll()
                }
                .task(id: band.connectionState.isConnected && scenePhase == .active) {
                    // SwiftUI keeps .task running in the background; each reading makes the band measure
                    // heart rate, so it only polls while the app is in front.
                    guard band.connectionState.isConnected, scenePhase == .active else {
                        today.finish()
                        return
                    }
                    while !Task.isCancelled {
                        today.refresh()
                        try? await Task.sleep(for: .seconds(5 * 60))
                    }
                }
            }
        }
        .animation(.easeOut(duration: MB.Motion.durBase), value: phase)
        .preferredColorScheme(.dark)
        .onAppear(perform: bootstrap)
    }

    // MARK: - Actions

    private func bootstrap() {
        if band.connectionState == .connected {
            phase = .ready
        } else if AuthKeyStore.isStored {
            phase = .connecting
            // Reconnect directly to the known peripheral (no scan) when we have one on record;
            // otherwise fall back to scanning to find it.
            if let id = knownDevices.first?.peripheralIdentifier {
                band.reconnectToKnownDevice(identifier: id)
            } else {
                band.startScan()
            }
        } else {
            phase = .setup
        }
    }

    /// Validates + persists the AuthKey, then starts the BLE connection.
    /// Returns an inline error message, or nil on success.
    private func connect(_ hex: String) -> String? {
        do {
            try AuthKeyStore.saveHex(hex)
        } catch {
            return error.localizedDescription
        }
        band.startScan()
        phase = .connecting
        return nil
    }

    private func forget() {
        band.disconnect()
        AppServices.shared.alarms.reset()
        AppServices.shared.bandSettings.reset()
        AppServices.shared.todayActivity.reset()
        AppServices.shared.workoutLive.reset()
        AppServices.shared.latestMetrics.reset()
        AppServices.shared.syncLog.reset()
        CalendarSyncService.forgetBand()
        AuthKeyStore.delete()
        page = 1
        phase = .setup
    }
}
