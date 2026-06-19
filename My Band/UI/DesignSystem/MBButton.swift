import SwiftUI

// MARK: - MBButton
//
// Port of components/core/Button.jsx + base.css (.mb-btn).
// Variants map to iOS button roles; press scales to 0.97 (the tactile iOS tap).

struct MBButton: View {

    enum Variant { case primary, secondary, tinted, ghost, destructive }
    enum Size { case sm, md, lg }

    let title: String
    var variant: Variant = .secondary
    var size: Size = .md
    var icon: String? = nil          // SF Symbol, leading
    var iconRight: String? = nil     // SF Symbol, trailing
    var block: Bool = false
    var glow: Bool = false
    var loading: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    private var height: CGFloat {
        switch size { case .sm: 34; case .md: 44; case .lg: 52 }
    }
    private var hPad: CGFloat {
        switch size { case .sm: 14; case .md: 18; case .lg: 22 }
    }
    private var fontSize: CGFloat {
        switch size { case .sm: 15; case .md: 16; case .lg: 17 }
    }
    private var radius: CGFloat {
        switch size { case .sm: MB.Radius.sm; case .md: MB.Radius.md; case .lg: MB.Radius.lg }
    }

    private var fg: Color {
        switch variant {
        case .primary:     MB.textOnAccent
        case .secondary:   MB.textPrimary
        case .tinted:      MB.accent200
        case .ghost:       MB.accent200
        case .destructive: MB.danger
        }
    }
    private var bg: Color {
        switch variant {
        case .primary:     MB.accent
        case .secondary:   MB.surfaceControl
        case .tinted:      MB.accentSoft
        case .ghost:       .clear
        case .destructive: MB.dangerSoft
        }
    }

    @State private var pressed = false
    private var isDisabled: Bool { disabled || loading }

    var body: some View {
        Button(action: action) {
            HStack(spacing: MB.Space.x2) {
                if loading {
                    ProgressView().controlSize(.small).tint(fg)
                } else if let icon {
                    Image(systemName: icon).font(.system(size: fontSize, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: fontSize, weight: .semibold))
                    .tracking(-0.01 * fontSize)
                if let iconRight, !loading {
                    Image(systemName: iconRight).font(.system(size: fontSize, weight: .semibold))
                }
            }
            .foregroundStyle(fg)
            .frame(maxWidth: block ? .infinity : nil)
            .frame(height: height)
            .padding(.horizontal, hPad)
            .background(bg)
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(variant == .secondary ? MB.hairlineStrong : .clear, lineWidth: 1)
            )
            .mbCornerRadius(radius)
            .shadow(color: glow && variant == .primary ? MB.accentGlow : .clear,
                    radius: 12, y: 0)
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.97 : 1)
        .opacity(isDisabled ? 0.45 : 1)
        .disabled(isDisabled)
        .animation(.easeOut(duration: MB.Motion.durFast), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !isDisabled { pressed = true } }
                .onEnded { _ in pressed = false }
        )
    }
}
