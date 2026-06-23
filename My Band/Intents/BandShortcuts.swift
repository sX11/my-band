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
                "Sincronizar minha pulseira no \(.applicationName)",
                "Sincronizar a pulseira com o \(.applicationName)",
                "Sincronizar \(.applicationName)",
            ],
            shortTitle: "Sincronizar pulseira",
            systemImageName: "arrow.triangle.2.circlepath"
        )
    }
}
