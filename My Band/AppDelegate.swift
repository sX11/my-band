#if canImport(UIKit)
import UIKit

/// Minimal app delegate whose sole job is to register the background-sync BGTask before the app
/// finishes launching — the one moment iOS allows BGTaskScheduler.register. Everything else stays
/// in SwiftUI. On a cold launch triggered by the task itself, this runs before the scene loads.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        BackgroundSyncManager.shared.register()
        return true
    }
}
#endif
