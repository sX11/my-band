import AppIntents
import Foundation
import OSLog
import UserNotifications

// MARK: - CheckBandBatteryIntent
//
// "Avisar se a bateria da pulseira estiver baixa" — feito para uma Automação Pessoal do Atalhos
// ("quando eu conectar o iPhone ao carregador"): se a pulseira estiver abaixo do limite, dispara
// uma notificação local lembrando de colocá-la para carregar; acima do limite, o atalho termina
// em silêncio (sem diálogo, sem notificação), para não virar ruído toda vez que a automação roda.
//
// O nível de bateria só é conhecido com o link ativo. A fonte preferida é a característica GATT
// padrão Battery Level (0x2A19) — a mesma que o iOS lê para o widget Baterias, então atalho e
// widget mostram o mesmo número; sem ela, vale o CMD_BATTERY do protocolo Xiaomi. O intent roda
// um sync best-effort primeiro (que conecta, se necessário) e depois pede uma leitura fresca,
// caso o link já estivesse aberto há tempo e o valor em memória esteja velho.

struct CheckBandBatteryIntent: AppIntent {

    static var title: LocalizedStringResource = "Check band battery"
    static var description = IntentDescription(
        "Checks the Mi Band 10 battery and notifies you only if it's below the given percentage."
    )

    static var openAppWhenRun = false

    @Parameter(
        title: "Notify below",
        description: "Minimum percentage. Above it, the shortcut produces no output.",
        default: 30,
        inclusiveRange: (1, 100)
    )
    var threshold: Int

    /// Teto de espera pelas leituras de bateria depois do sync (2A19 + CMD_BATTERY). Não é um
    /// sleep: o intent segue assim que as duas respostas chegam.
    private static let batteryRefreshWait: Duration = .seconds(3)

    private static let notificationID = "com.myband.lowbattery"

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.myband", category: "BatteryIntent"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int?> {
        let band = AppServices.shared.bandManager
        let hadLiveLink = band.connectionState.isConnected

        // O link precisa sobreviver ao sync: o pedido de bateria abaixo depende dele. Com o padrão
        // (`disconnectWhenDone: nil`) o sync derrubava a conexão que ele mesmo abriu antes do
        // CMD_BATTERY, então o intent respondia com o nível velho em memória (ou nil) e o link
        // caía no meio dos ACKs finais do sync — que a pulseira então re-oferecia na conexão
        // seguinte. Só soltamos o rádio no fim, e só se fomos nós que o abrimos.
        defer { if !hadLiveLink { band.disconnect(userInitiated: false) } }

        // Best-effort: se a pulseira estiver fora de alcance, ainda respondemos com o último nível
        // conhecido em vez de falhar o atalho (e, portanto, a automação inteira).
        do {
            _ = try await BackgroundSyncManager.shared.syncNow(disconnectWhenDone: false)
        } catch {
            Self.log.error("Sync do intent de bateria falhou: \(error.localizedDescription)")
        }

        await band.refreshBattery(timeout: Self.batteryRefreshWait)

        guard let level = band.batteryLevel else { return .result(value: nil) }

        // Já está no carregador: o lembrete não teria propósito.
        if level < threshold && !band.batteryCharging {
            await notifyLowBattery(level: level)
        }
        return .result(value: level)
    }

    private func notifyLowBattery(level: Int) async {
        let center = UNUserNotificationCenter.current()
        _ = try? await center.requestAuthorization(options: [.alert, .sound])

        let content = UNMutableNotificationContent()
        content.title = "Band battery low"
        content.body  = "The band is at \(level)%. Put it on the charger."
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        try? await center.add(request)
    }
}
