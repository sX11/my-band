import SwiftUI

// MARK: - ConnectingView
//
// Port of the `Connecting` component in ui_kits/app/Setup.jsx, driven by the REAL
// BandManager.connectionState instead of a timed mock. Pulsing accent ring while
// connecting; settles to a mint check on success. Surfaces errors with a retry.

struct ConnectingView: View {

    @Environment(BandManager.self) private var band
    var onConnected: () -> Void
    var onRetry: () -> Void
    var onReconfigure: () -> Void

    @State private var ringAnimating = false

    private var done: Bool { band.connectionState == .connected }
    private var failed: Bool { band.connectionState.isError }

    var body: some View {
        VStack(spacing: MB.Space.x7) {
            Spacer()

            ZStack {
                if !done && !failed {
                    Circle()
                        .stroke(MB.accent, lineWidth: 2)
                        .frame(width: 132, height: 132)
                        .scaleEffect(ringAnimating ? 1.1 : 0.72)
                        .opacity(ringAnimating ? 0 : 0.9)
                }

                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(tileBackground)
                    .frame(width: 92, height: 92)
                    .overlay(
                        Image(systemName: tileIcon)
                            .font(.system(size: 38, weight: .semibold))
                            .foregroundStyle(tileForeground)
                    )
                    .shadow(color: glowColor, radius: 18)
            }
            .frame(width: 132, height: 132)

            VStack(spacing: 6) {
                Text(title)
                    .font(.mbTitle2)
                    .foregroundStyle(MB.textPrimary)
                Text(band.connectionState.handshakeStep)
                    .font(.mbMono)
                    .foregroundStyle(failed ? MB.danger : MB.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, MB.Space.x8)
            }

            Spacer()

            if failed {
                VStack(spacing: MB.Space.x3) {
                    MBButton(title: "Tentar novamente", variant: .primary, size: .lg,
                             icon: "arrow.clockwise", block: true, glow: true) {
                        onRetry()
                    }
                    MBButton(title: "Usar outra AuthKey", variant: .ghost, size: .lg,
                             icon: "key.fill", block: true) {
                        onReconfigure()
                    }
                }
                .padding(.horizontal, MB.Space.x7)
                .padding(.bottom, MB.Space.x10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MB.bgApp)
        .onAppear {
            startRing()
            // Already connected on entry (e.g. CoreBluetooth state restoration) — advance.
            if band.connectionState == .connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { onConnected() }
            }
        }
        .onChange(of: band.connectionState) { _, new in
            if new == .connected {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { onConnected() }
            }
        }
    }

    private func startRing() {
        guard !done && !failed else { return }
        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
            ringAnimating = true
        }
    }

    private var pairing: Bool { band.connectionState == .awaitingPairingConfirmation }

    private var title: String {
        if done { return "Pulseira conectada" }
        if failed { return "Não foi possível conectar" }
        if pairing { return "Confirme o pareamento" }
        return "Conectando…"
    }
    private var tileIcon: String {
        if done { return "checkmark" }
        if failed { return "exclamationmark.triangle.fill" }
        if pairing { return "hand.tap.fill" }
        return "dot.radiowaves.left.and.right"
    }
    private var tileBackground: Color { done ? MB.okSoft : (failed ? MB.dangerSoft : MB.accentSoft) }
    private var tileForeground: Color { done ? MB.ok : (failed ? MB.danger : MB.accent200) }
    private var glowColor: Color {
        if done { return MB.ok.opacity(0.45) }
        if failed { return .clear }
        return MB.accentGlow
    }
}
