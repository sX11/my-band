import Foundation
import UserNotifications

// MARK: - NotificationRouter
//
// The notification centre's delegate, set before didFinishLaunching returns so the tap that
// cold-launched the app is delivered. Only the morning sleep summary is routed or shown in front;
// every other notification keeps the system default of no foreground banner.

final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let morning = notification.request.identifier.hasPrefix(MorningSleepNotifier.identifierPrefix)
        completionHandler(morning ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let key = response.notification.request.content.userInfo[MorningSleepNotifier.nightKey] as? String
        if let key, let day = NightRatings.day(fromKey: key) {
            Task { @MainActor in AppNavigation.shared.openNight = day }
        }
        completionHandler()
    }
}
