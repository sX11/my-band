import SwiftUI

// MARK: - MBIconButton
//
// Port of components/core/IconButton.jsx + base.css (.mb-iconbtn).

struct MBIconButton: View {

    enum Variant { case standard, plain, accent }
    enum Size { case sm, md, lg }

    let icon: String              // SF Symbol
    var variant: Variant = .standard
    var size: Size = .md
    var accessibilityLabelText: String = ""
    let action: () -> Void

    private var side: CGFloat {
        switch size { case .sm: 32; case .md: 40; case .lg: 48 }
    }
    private var radius: CGFloat {
        switch size { case .sm: MB.Radius.sm; case .md: MB.Radius.md; case .lg: MB.Radius.lg }
    }
    private var bg: Color {
        switch variant { case .standard: MB.surfaceControl; case .plain: .clear; case .accent: MB.accent }
    }
    private var fg: Color {
        switch variant { case .standard: MB.textSecondary; case .plain: MB.textSecondary; case .accent: MB.textOnAccent }
    }

    @State private var pressed = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: side * 0.45, weight: .semibold))
                .foregroundStyle(fg)
                .frame(width: side, height: side)
                .background(bg)
                .overlay(
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(variant == .standard ? MB.hairline : .clear, lineWidth: 1)
                )
                .mbCornerRadius(radius)
        }
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.93 : 1)
        .animation(.easeOut(duration: MB.Motion.durFast), value: pressed)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
        .accessibilityLabel(accessibilityLabelText)
    }
}
