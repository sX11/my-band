import AppIntents
import Foundation
import UserNotifications

// MARK: - CheckBandBatteryIntent
//
// "Avisar se a bateria da pulseira estiver baixa" — feito para uma Automação Pessoal do Atalhos
// ("quando eu conectar o iPhone ao carregador"): se a pulseira estiver abaixo do limite, dispara
// uma notificação local lembrando de colocá-la para carregar; acima do limite, o atalho termina
// em silêncio (sem diálogo, sem notificação), para não virar ruído toda vez que a automação roda.
//
// O nível de bateria só é conhecido com o link ativo — a pulseira reporta bateria no init
// pós-auth. Por isso o intent roda um sync best-effort primeiro (que conecta, se necessário) e
// depois pede a bateria explicitamente, caso o link já estivesse aberto há tempo e o valor em
// memória esteja velho.

struct CheckBandBatteryIntent: AppIntent {

    static var title: LocalizedStringResource = "Verificar bateria da pulseira"
    static var description = IntentDescription(
        "Verifica a bateria da Mi Band 10 e notifica apenas se estiver abaixo da porcentagem informada."
    )

    static var openAppWhenRun = false

    @Parameter(
        title: "Notificar abaixo de",
        description: "Porcentagem mínima. Acima dela o atalho não produz nenhuma saída.",
        default: 30,
        inclusiveRange: (1, 100)
    )
    var threshold: Int

    /// Tempo dado à pulseira para responder ao pedido de bateria depois do sync.
    private static let batteryRefreshWait: Duration = .seconds(3)

    private static let notificationID = "com.myband.lowbattery"

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int?> {
        // Best-effort: se a pulseira estiver fora de alcance, ainda respondemos com o último nível
        // conhecido em vez de falhar o atalho (e, portanto, a automação inteira).
        _ = try? await BackgroundSyncManager.shared.syncNow()

        let band = AppServices.shared.bandManager
        if band.connectionState.isConnected {
            band.sendEncryptedCommand(
                protoBytes: XiaomiProto.systemCommand(subtype: XiaomiSystemCmd.battery)
            )
            try? await Task.sleep(for: Self.batteryRefreshWait)
        }

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
        content.title = "Bateria da pulseira baixa"
        content.body  = "A pulseira está com \(level)%. Coloque para carregar."
        content.sound = .default

        let request = UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil)
        try? await center.add(request)
    }
}
