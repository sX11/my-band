import SwiftUI

// MARK: - XiaomiLoginView
//
// Guided AuthKey extraction via Xiaomi Cloud QR login (XiaomiCloudAuth). The user scans
// the QR with the Xiaomi / Mi Home app (or opens the login URL on this device); once they
// confirm, we pull the band's beaconkey (= AuthKey) and hand it back through `onExtracted`,
// which feeds the same connect path as manual entry.

struct XiaomiLoginView: View {

    let onExtracted: (String) -> String?   // returns an inline error, or nil on success
    let onManual: () -> Void
    let onBack: () -> Void

    @State private var auth = XiaomiCloudAuth()
    @State private var selectionError: String?
    @State private var showLogin = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MBIconButton(icon: "arrow.left", variant: .plain, accessibilityLabelText: "Voltar") {
                auth.cancel()
                onBack()
            }
            .padding(.bottom, 18)

            content
        }
        .padding(.horizontal, MB.Space.x7)
        .padding(.top, 70)
        .padding(.bottom, MB.Space.x10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MB.bgApp)
        .onAppear { if auth.phase == .idle { auth.start() } }
        .onDisappear { auth.cancel() }
        .animation(.easeOut(duration: MB.Motion.durBase), value: auth.phase)
        .onChange(of: auth.phase) { _, new in
            // The poll detected the login (or it failed) — close the in-app login sheet.
            if new != .awaitingScan && new != .requestingCode { showLogin = false }
        }
        #if canImport(SafariServices) && !targetEnvironment(macCatalyst)
        .sheet(isPresented: $showLogin) {
            if let url = auth.loginURL { SafariView(url: url).ignoresSafeArea() }
        }
        #endif
    }

    @ViewBuilder
    private var content: some View {
        switch auth.phase {
        case .idle, .requestingCode:
            progress(title: "Gerando código", subtitle: "Preparando o login da Xiaomi…")
        case .awaitingScan:
            scanStep
        case .authenticating:
            progress(title: "Autenticando", subtitle: "Confirme a leitura no app da Xiaomi.")
        case .fetchingDevices:
            progress(title: "Buscando pulseira", subtitle: "Lendo a chave da sua conta…")
        case .done:
            deviceStep
        case .failed(let message):
            failure(message)
        }
    }

    // MARK: - Awaiting scan

    private var scanStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: "Entre na conta Xiaomi",
                   subtitle: "Toque em fazer login para entrar aqui mesmo, sem sair do app. Ou escaneie o QR com o app Xiaomi/Mi Home em outro aparelho.")

            HStack {
                Spacer()
                qrCode
                Spacer()
            }

            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(MB.accent)
                Text("Aguardando confirmação…")
                    .font(.mbFootnote)
                    .foregroundStyle(MB.textTertiary)
            }
            .frame(maxWidth: .infinity)

            Spacer()

            if let url = auth.loginURL {
                MBButton(title: "Fazer login da Xiaomi", variant: .primary, size: .lg,
                         icon: "person.crop.circle", block: true, glow: true) {
                    openLogin(url)
                }
            }
            manualLink
        }
    }

    private var qrCode: some View {
        ZStack {
            RoundedRectangle(cornerRadius: MB.Radius.xl, style: .continuous)
                .fill(Color.white)
                .frame(width: 232, height: 232)
            if let url = auth.qrImageURL {
                AsyncImage(url: url) { image in
                    image.resizable().interpolation(.none).scaledToFit()
                } placeholder: {
                    ProgressView().tint(MB.night950)
                }
                .frame(width: 196, height: 196)
            }
        }
    }

    // MARK: - Device selection

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: auth.bands.count == 1 ? "Pulseira encontrada" : "Escolha a pulseira",
                   subtitle: "A chave fica guardada apenas no Keychain deste aparelho.")

            VStack(spacing: 12) {
                ForEach(auth.bands) { band in
                    Button { select(band) } label: { bandRow(band) }
                        .buttonStyle(.plain)
                }
            }

            if let selectionError {
                Text(selectionError).font(.mbFootnote).foregroundStyle(MB.danger)
            }

            Spacer()
            manualLink
        }
    }

    private func bandRow(_ band: XiaomiCloudAuth.CloudBand) -> some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(MB.accentSoft)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 19)).foregroundStyle(MB.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text(band.name).font(.mbHeadline).foregroundStyle(MB.textPrimary)
                if !band.mac.isEmpty {
                    Text(band.mac).font(.mbMonoSm).foregroundStyle(MB.textTertiary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
                .foregroundStyle(MB.textTertiary)
        }
        .padding(14)
        .background(MB.surfaceCard)
        .overlay(RoundedRectangle(cornerRadius: MB.Radius.lg, style: .continuous)
            .strokeBorder(MB.hairline, lineWidth: 1))
        .mbCornerRadius(MB.Radius.lg)
    }

    // MARK: - Failure

    private func failure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            header(title: "Não foi possível extrair", subtitle: message)
            Spacer()
            MBButton(title: "Tentar novamente", variant: .primary, size: .lg,
                     icon: "arrow.clockwise", block: true, glow: true) {
                selectionError = nil
                auth.start()
            }
            manualLink
        }
    }

    // MARK: - Shared pieces

    private func progress(title: String, subtitle: String) -> some View {
        VStack(spacing: MB.Space.x6) {
            Spacer()
            ProgressView().controlSize(.large).tint(MB.accent)
            VStack(spacing: 6) {
                Text(title).font(.mbTitle3).foregroundStyle(MB.textPrimary)
                Text(subtitle).font(.mbFootnote).foregroundStyle(MB.textTertiary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            manualLink
        }
        .frame(maxWidth: .infinity)
    }

    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.mbTitle1)
                .tracking(-0.02 * 28)
                .foregroundStyle(MB.textPrimary)
            Text(subtitle)
                .font(.mbBody)
                .foregroundStyle(MB.textSecondary)
        }
    }

    private var manualLink: some View {
        Button { auth.cancel(); onManual() } label: {
            Text("Inserir AuthKey manualmente")
                .font(.mbSubheadEmph)
                .foregroundStyle(MB.accent200)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func select(_ band: XiaomiCloudAuth.CloudBand) {
        selectionError = onExtracted(band.beaconKey)
    }

    /// Present the Xiaomi login IN-APP so the long-poll keeps running. Opening it in an external
    /// browser would background the app and suspend the poll, so the confirmation is never observed.
    private func openLogin(_ url: URL) {
        #if canImport(SafariServices) && !targetEnvironment(macCatalyst)
        showLogin = true
        #else
        openURL(url)
        #endif
    }
}

#if canImport(SafariServices) && !targetEnvironment(macCatalyst)
import SafariServices

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
#endif
