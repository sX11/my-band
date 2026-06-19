import SwiftUI

// MARK: - SetupView
//
// Port of ui_kits/app/Setup.jsx (intro + key steps). The connecting step is owned
// by RootView (ConnectingView) so it can be reused by the auto-reconnect path.
//
// `onConnect` receives the typed AuthKey; it returns an error message to show inline,
// or nil on success (RootView then advances to the connecting screen).

struct SetupView: View {

    let onConnect: (String) -> String?

    private enum Step { case intro, key }
    @State private var step: Step = .intro
    @State private var key = ""
    @State private var fieldError: String?

    private var keyValid: Bool {
        let cleaned = key.replacingOccurrences(of: " ", with: "")
        return cleaned.count == 32 && cleaned.allSatisfy(\.isHexDigit)
    }

    var body: some View {
        ZStack {
            MB.bgApp.ignoresSafeArea()
            switch step {
            case .intro: intro
            case .key:   keyEntry
            }
        }
        .animation(.easeOut(duration: MB.Motion.durBase), value: step)
    }

    // MARK: Intro

    private var intro: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 20) {
                    brandMark
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Conecte sua\nMi Band 10")
                            .font(.mbTitle1)
                            .tracking(-0.02 * 28)
                            .foregroundStyle(MB.textPrimary)
                        Text("Sem o app da Xiaomi. Seus dados vão direto para onde você quiser.")
                            .font(.mbBody)
                            .foregroundStyle(MB.textSecondary)
                            .frame(maxWidth: 280, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 18) {
                    feature(icon: "heart.fill", bg: MB.hrSoft, fg: MB.hr,
                            title: "Apple Health", sub: "Sono, FC, passos e SpO₂")
                    feature(icon: "house.fill", bg: MB.accentSoft, fg: MB.accent,
                            title: "Home Assistant", sub: "Automações ao dormir e acordar")
                    feature(icon: "mic.fill", bg: MB.spo2Soft, fg: MB.spo2,
                            title: "Atalhos e Siri", sub: "“Como foi meu sono?”")
                }
            }
            Spacer()
            MBButton(title: "Começar", variant: .primary, size: .lg,
                     iconRight: "arrow.right", block: true, glow: true) {
                step = .key
            }
        }
        .padding(.horizontal, MB.Space.x7)
        .padding(.top, 70)
        .padding(.bottom, MB.Space.x10)
    }

    private var brandMark: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(colors: [MB.accent, MB.accent700],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .frame(width: 76, height: 76)
            .overlay(
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .shadow(color: MB.accentGlow, radius: 20)
    }

    private func feature(icon: String, bg: Color, fg: Color, title: String, sub: String) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(bg)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: icon).font(.system(size: 19)).foregroundStyle(fg))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.mbHeadline).foregroundStyle(MB.textPrimary)
                Text(sub).font(.mbFootnote).foregroundStyle(MB.textTertiary)
            }
        }
    }

    // MARK: Key entry

    private var keyEntry: some View {
        VStack(alignment: .leading, spacing: 0) {
            MBIconButton(icon: "arrow.left", variant: .plain,
                         accessibilityLabelText: "Voltar") {
                step = .intro
            }
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Inserir AuthKey")
                        .font(.mbTitle1)
                        .tracking(-0.02 * 28)
                        .foregroundStyle(MB.textPrimary)
                    Text("A chave de 32 caracteres da sua pulseira. Fica guardada apenas no Keychain.")
                        .font(.mbBody)
                        .foregroundStyle(MB.textSecondary)
                }

                MBTextField(
                    label: "AuthKey",
                    text: $key,
                    icon: "key.fill",
                    placeholder: "32 caracteres hex",
                    mono: true,
                    secure: true,
                    hint: "Obtenha via GadgetBridge, huami-token ou Xiaomi Cloud.",
                    errorText: fieldError
                )
                .onChange(of: key) { _, _ in fieldError = nil }
            }

            Spacer()

            MBButton(title: "Conectar pulseira", variant: .primary, size: .lg,
                     icon: "dot.radiowaves.left.and.right", block: true, glow: true,
                     disabled: !keyValid) {
                fieldError = onConnect(key)
            }
        }
        .padding(.horizontal, MB.Space.x7)
        .padding(.top, 70)
        .padding(.bottom, MB.Space.x10)
    }
}
