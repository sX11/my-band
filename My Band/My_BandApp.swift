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
    @State private var customization = CustomizationManager()
    @State private var scaleManager = ScaleManager()

    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(bandManager)
                .environment(bandSyncer)
                .environment(customization)
                .environment(scaleManager)
                .onAppear {
                    bandSyncer.setup(
                        manager: bandManager,
                        context: Self.sharedModelContainer.mainContext
                    )
                    customization.setup(manager: bandManager)
                    bandSyncer.loadStoredDevice()
                    BackgroundSyncManager.shared.configure(manager: bandManager, syncer: bandSyncer)
                    // O scan/conexão da pulseira agora é disparado pela UI (RootView/SetupView).
                    // A balança é broadcast-only: escutar o anúncio (foreground) basta.
                    scaleManager.start()
                }
                .onOpenURL { url in
                    // Shared file ("Abrir com → My Band") for a .bin/.rpk. Installs against the
                    // live connection; progress/result surface in CustomizeView.
                    Task { await customization.installFromFile(url) }
                }
        }
        .modelContainer(Self.sharedModelContainer)
        .onChange(of: scenePhase) { _, phase in
            // Ao ir para segundo plano, garante que há um pedido de sync agendado.
            if phase == .background { BackgroundSyncManager.shared.scheduleNext() }
        }
    }
}
