import SwiftUI
import SwiftData

@main
struct My_BandApp: App {

    // static: garantia de única inicialização por processo.
    // App structs do SwiftUI podem ser recriadas durante setup de cena,
    // o que faria um `var` recriar o container (e o store SQLite) a cada vez.
    static let sharedModelContainer: ModelContainer = {
        let schema = Schema([
            BandDevice.self,
            SleepSession.self,
            ActivityDay.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            // Store corrompido (ex: watchdog kill durante gravação).
            // Em dev: apaga e recria. Em prod isso perderia dados — trocar por migração adequada.
            let storeURL = config.url
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-shm"))
            try? FileManager.default.removeItem(at: storeURL.deletingPathExtension().appendingPathExtension("store-wal"))
            do {
                return try ModelContainer(for: schema, configurations: [config])
            } catch let secondError {
                fatalError("Could not create ModelContainer even after store reset: \(secondError)")
            }
        }
    }()

    @State private var bandManager = BandManager()
    @State private var bandSyncer  = BandSyncer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(bandManager)
                .environment(bandSyncer)
                .onAppear {
                    bandSyncer.setup(
                        manager: bandManager,
                        context: Self.sharedModelContainer.mainContext
                    )
                    bandSyncer.loadStoredDevice()
                    // ── TEMPORÁRIO — remover antes da UI ──────────────────────
                    // Force-overwrite: seedIfNeeded() skips if any key exists, which
                    // would leave the old placeholder (eed4d315...) in the Keychain.
                    try? AuthKeyStore.saveHex("***REMOVED***")
                    bandManager.startScan()
                    // ─────────────────────────────────────────────────────────
                }
        }
        .modelContainer(Self.sharedModelContainer)
    }
}
