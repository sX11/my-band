import SwiftUI

// MARK: - MBCard
//
// Port of base.css .mb-card — surface with hairline border, continuous corners.

struct MBCard<Content: View>: View {
    var padding: CGFloat = MB.Space.x5
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MB.surfaceCard)
            .overlay(
                RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous)
                    .strokeBorder(MB.hairline, lineWidth: 1)
            )
            .mbCornerRadius(MB.Radius.lg)
    }
}

// MARK: - MBMetricTile
//
// Port of base.css .mb-metric — tinted icon tile, label, oversized tabular value, footnote.

struct MBMetricTile: View {
    let icon: String           // SF Symbol
    let tint: Color
    let tintSoft: Color
    let label: String
    let value: String
    var unit: String? = nil
    var foot: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: MB.Space.x2) {
                RoundedRectangle(cornerRadius: MB.Radius.sm, style: .continuous)
                    .fill(tintSoft)
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint))
                Text(label).font(.mbSubheadEmph).foregroundStyle(MB.textSecondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.mbDataMD)
                    .tracking(-0.02 * 28)
                    .monospacedDigit()
                    .foregroundStyle(MB.textPrimary)
                if let unit {
                    Text(unit).font(.mbCallout).foregroundStyle(MB.textTertiary)
                }
            }
            if let foot {
                Text(foot).font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.init(top: 14, leading: 16, bottom: 16, trailing: 16))
        .background(MB.surfaceCard)
        .overlay(
            RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous)
                .strokeBorder(MB.hairline, lineWidth: 1)
        )
        .mbCornerRadius(MB.Radius.lg)
    }
}
