import SwiftUI

// MARK: - MBStatusPill
//
// Port of components/core/StatusPill.jsx + base.css (.mb-pill).
// Status is communicated with color + a dot/icon — never color alone (a11y).
//
// Liquid Glass chrome: a status pill is exactly the "system chrome" half of the app's post-redesign
// split (glass for chrome/status, opaque dark for content) — the app no longer shows health-metric
// content at all, so this and other status/navigation elements are the only surfaces glass applies
// to. `tone`'s color becomes a `Glass` tint instead of a flat fill.

struct MBStatusPill: View {

    enum Tone { case ok, warn, danger, accent, neutral }

    let text: String
    var tone: Tone = .neutral
    var icon: String? = nil      // SF Symbol; if nil, a filled dot is shown
    var pulse: Bool = false

    @State private var pulsing = false

    private var fg: Color {
        switch tone {
        case .ok: MB.ok; case .warn: MB.warn; case .danger: MB.danger
        case .accent: MB.accent200; case .neutral: MB.textSecondary
        }
    }
    private var bg: Color {
        switch tone {
        case .ok: MB.okSoft; case .warn: MB.warnSoft; case .danger: MB.dangerSoft
        case .accent: MB.accentSoft; case .neutral: MB.surfaceControl
        }
    }

    var body: some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
            } else {
                Circle()
                    .fill(fg)
                    .frame(width: 7, height: 7)
                    .opacity(pulse && pulsing ? 0.35 : 1)
                    .scaleEffect(pulse && pulsing ? 0.7 : 1)
            }
            Text(text).font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(fg)
        .padding(.init(top: 6, leading: 10, bottom: 6, trailing: 11))
        .glassEffect(.regular.tint(bg), in: .capsule)
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}
