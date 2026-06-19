import SwiftUI

// MARK: - RootView
//
// Top-level router for the Setup + Connection phase.
//   • No AuthKey stored  → SetupView (intro → key)
//   • AuthKey stored      → auto-connect → ConnectingView
//   • Connected           → ConnectedView (placeholder for the upcoming Dashboard)

struct RootView: View {

    @Environment(BandManager.self) private var band
    @Environment(BandSyncer.self) private var syncer

    private enum Phase { case setup, connecting, ready }
    @State private var phase: Phase = .setup

    var body: some View {
        Group {
            switch phase {
            case .setup:
                SetupView(onConnect: connect)
                    .transition(.opacity)
            case .connecting:
                ConnectingView(onConnected: { phase = .ready },
                               onRetry: { band.startScan() })
                    .transition(.opacity)
            case .ready:
                DashboardView(onForget: forget)
                    .transition(.opacity)
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
            band.startScan()
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
        AuthKeyStore.delete()
        phase = .setup
    }
}
