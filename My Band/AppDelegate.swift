#if canImport(UIKit)
import UIKit

/// Minimal app delegate that sets up the background-capable services before the app finishes
/// launching. Two things MUST happen here, in the one moment iOS guarantees before the scene loads:
/// BGTaskScheduler.register (only allowed pre-launch), and creating + wiring the BLE/sync managers —
/// a CoreBluetooth state-restoration relaunch has no scene, so a SwiftUI .onAppear would never run.
/// didFinishLaunching is main-actor isolated (UIApplicationDelegate is @MainActor), so the
/// @MainActor managers can be touched directly.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundSyncManager.shared.register()
        AppServices.shared.bootstrap(container: My_BandApp.sharedModelContainer)
        return true
    }
}
#endif
