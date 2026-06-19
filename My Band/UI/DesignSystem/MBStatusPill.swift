import SwiftUI

// MARK: - MBStatusPill
//
// Port of components/core/StatusPill.jsx + base.css (.mb-pill).
// Status is communicated with color + a dot/icon — never color alone (a11y).

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
        .background(bg)
        .clipShape(Capsule())
        .onAppear {
            guard pulse else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        }
    }
}
