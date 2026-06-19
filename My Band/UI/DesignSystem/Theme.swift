import SwiftUI

// MARK: - My Band Design System — tokens
//
// SwiftUI port of the Claude Design handoff (`My Band — Design System`).
// Dark-mode-first, OLED midnight palette, single Aurora-indigo accent.
// Values mirror tokens/colors.css, tokens/typography.css, tokens/spacing.css.

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Color tokens

enum MB {

    // Base neutral ramp (cool midnight)
    static let night1000 = Color(hex: 0x050609)
    static let night950  = Color(hex: 0x0A0B10)   // app background
    static let night900  = Color(hex: 0x0F1117)   // grouped background
    static let night850  = Color(hex: 0x14161F)   // card surface
    static let night800  = Color(hex: 0x1A1D27)   // elevated surface
    static let night750  = Color(hex: 0x222632)   // control fill
    static let night700  = Color(hex: 0x2C313F)   // strong fill
    static let night600  = Color(hex: 0x3A4050)

    // Text
    static let textPrimary   = Color(hex: 0xF3F4F9)
    static let textSecondary = Color(hex: 0x9AA0B0)
    static let textTertiary  = Color(hex: 0x6B7180)
    static let textDisabled  = Color(hex: 0x4A4F5D)
    static let textOnAccent  = Color(hex: 0x0B0B16)

    // Hairlines
    static let hairline       = Color.white.opacity(0.07)
    static let hairlineStrong = Color.white.opacity(0.12)
    static let hairlineFaint  = Color.white.opacity(0.04)
    static let scrim          = Color(hex: 0x050609, alpha: 0.64)

    // Brand accent — Aurora indigo
    static let accent50  = Color(hex: 0xECECFF)
    static let accent200 = Color(hex: 0xC2C3FF)
    static let accent400 = Color(hex: 0x9A9CFF)
    static let accent    = Color(hex: 0x7C7FFF)
    static let accent600 = Color(hex: 0x6A6CEB)
    static let accent700 = Color(hex: 0x5557CC)
    static let accentSoft   = Color(hex: 0x7C7FFF, alpha: 0.16)
    static let accentSofter = Color(hex: 0x7C7FFF, alpha: 0.10)
    static let accentGlow   = Color(hex: 0x7C7FFF, alpha: 0.40)

    // Health data
    static let hr        = Color(hex: 0xFF5C7A)
    static let hrSoft    = Color(hex: 0xFF5C7A, alpha: 0.16)
    static let steps     = Color(hex: 0x46E0A0)
    static let stepsSoft = Color(hex: 0x46E0A0, alpha: 0.16)
    static let spo2      = Color(hex: 0x5BC0F8)
    static let spo2Soft  = Color(hex: 0x5BC0F8, alpha: 0.16)
    static let energy    = Color(hex: 0xFF9A4C)
    static let energySoft = Color(hex: 0xFF9A4C, alpha: 0.16)

    // Sleep phases (dusk → deep night)
    static let sleepAwake = Color(hex: 0xF6A052)
    static let sleepREM   = Color(hex: 0x5BC0F8)
    static let sleepLight = Color(hex: 0x8A8CFF)
    static let sleepDeep  = Color(hex: 0x4B45C7)

    // Status
    static let ok        = Color(hex: 0x46E0A0)
    static let okSoft    = Color(hex: 0x46E0A0, alpha: 0.16)
    static let warn      = Color(hex: 0xF6C552)
    static let warnSoft  = Color(hex: 0xF6C552, alpha: 0.16)
    static let danger    = Color(hex: 0xFF5C6C)
    static let dangerSoft = Color(hex: 0xFF5C6C, alpha: 0.16)

    // Semantic aliases
    static let bgApp         = night950
    static let bgGrouped     = night900
    static let surfaceCard   = night850
    static let surfaceRaised = night800
    static let surfaceControl = night750
    static let surfaceFill   = night700

    // MARK: - Spacing (4-pt grid)

    enum Space {
        static let x1: CGFloat = 4
        static let x2: CGFloat = 8
        static let x3: CGFloat = 12
        static let x4: CGFloat = 16
        static let x5: CGFloat = 20
        static let x6: CGFloat = 24
        static let x7: CGFloat = 28
        static let x8: CGFloat = 32
        static let x10: CGFloat = 40
        static let screenPad: CGFloat = 20
        static let rowMinHeight: CGFloat = 44
    }

    // MARK: - Radii (continuous corners)

    enum Radius {
        static let xs: CGFloat = 6
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        static let full: CGFloat = 999
    }

    // MARK: - Motion

    enum Motion {
        static let durFast: Double = 0.12
        static let durBase: Double = 0.20
        static let durSlow: Double = 0.32
    }
}

// MARK: - Typography
//
// On-device the live app uses SF Pro (system). Data numerals are tabular.

extension Font {
    static let mbLargeTitle = Font.system(size: 34, weight: .bold)
    static let mbTitle1     = Font.system(size: 28, weight: .bold)
    static let mbTitle2     = Font.system(size: 22, weight: .semibold)
    static let mbTitle3     = Font.system(size: 20, weight: .semibold)
    static let mbHeadline    = Font.system(size: 17, weight: .semibold)
    static let mbBody        = Font.system(size: 17, weight: .regular)
    static let mbCallout     = Font.system(size: 16, weight: .regular)
    static let mbSubhead      = Font.system(size: 15, weight: .regular)
    static let mbSubheadEmph  = Font.system(size: 15, weight: .semibold)
    static let mbFootnote     = Font.system(size: 13, weight: .regular)
    static let mbCaption      = Font.system(size: 12, weight: .regular)

    static let mbDataMD = Font.system(size: 28, weight: .semibold)

    static let mbMono   = Font.system(size: 14, weight: .medium, design: .monospaced)
    static let mbMonoSm = Font.system(size: 12, weight: .medium, design: .monospaced)
}

// MARK: - Continuous-corner helper

extension View {
    /// Rounded rect with iOS-style continuous corners.
    func mbCornerRadius(_ radius: CGFloat) -> some View {
        clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
