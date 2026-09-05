import AppIntents

// MARK: - BandShortcuts
//
// Exposes the app's intents to Siri and the Shortcuts app with predefined phrases. Each phrase
// must reference \(.applicationName) so the system can disambiguate which app to invoke.

struct BandShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SyncBandIntent(),
            phrases: [
                "Sincronizar \(.applicationName)",
                "Sincronizar minha pulseira no \(.applicationName)",
                "Sincronizar a pulseira com o \(.applicationName)",
                "Sincronizar minha Mi Band no \(.applicationName)",
                "Atualizar minha pulseira no \(.applicationName)",
                "Sincronizar dados da pulseira no \(.applicationName)",
                "Puxar dados da Mi Band no \(.applicationName)",
                "Sincronizar pulseira com o Apple Health no \(.applicationName)",
            ],
            shortTitle: "Sincronizar pulseira",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: GetSleepStateIntent(),
            phrases: [
                "Estou dormindo no \(.applicationName)",
                "Eu estou dormindo no \(.applicationName)",
                "Ver se estou dormindo no \(.applicationName)",
                "Verificar meu sono no \(.applicationName)",
            ],
            shortTitle: "Ver se estou dormindo",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: CheckBandBatteryIntent(),
            phrases: [
                "Verificar bateria da pulseira no \(.applicationName)",
                "Ver a bateria da pulseira no \(.applicationName)",
                "Quanto tem de bateria na pulseira no \(.applicationName)",
                "Checar bateria da Mi Band no \(.applicationName)",
            ],
            shortTitle: "Verificar bateria",
            systemImageName: "battery.25"
        )
    }
}
