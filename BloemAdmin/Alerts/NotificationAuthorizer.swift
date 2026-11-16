import Foundation
import UserNotifications

enum NotificationPermission: Equatable, Sendable {
    case notDetermined
    case allowed
    case denied
}

protocol NotificationAuthorizing: Sendable {
    func status() async -> NotificationPermission
    /// Shows the system prompt: the settings models call it at the moment the admin turns alerts on or taps
    /// Allow notifications, and the push registrar calls it once, right after a sign-in to a server that can push.
    /// It asks for the badge too, because iOS asks only once for the three together.
    func requestPermission() async -> Bool
}

struct SystemNotificationAuthorizer: NotificationAuthorizing {
    func status() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorized, .provisional, .ephemeral: return .allowed
        case .denied: return .denied
        @unknown default: return .denied
        }
    }

    func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
}

protocol AlertNotifying: Sendable {
    func post(_ content: AlertNotificationContent) async
    func removeDelivered(identifiers: [String]) async
}

enum AlertCategory {
    static let server = "bloem.admin.alert.server"

    /// With "Show Previews" set to When Unlocked, iOS shows this in place of the body.
    static func notificationCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: server,
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "Server alert"),
            options: []
        )
    }
}

struct SystemAlertNotifier: AlertNotifying {
    func post(_ content: AlertNotificationContent) async {
        let message = UNMutableNotificationContent()
        message.title = content.title
        message.body = content.body
        message.sound = content.playsSound ? .default : nil
        message.threadIdentifier = content.threadIdentifier
        message.categoryIdentifier = AlertCategory.server
        message.userInfo = content.userInfo
        message.interruptionLevel = content.playsSound ? .active : .passive
        let request = UNNotificationRequest(identifier: content.identifier, content: message, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }

    func removeDelivered(identifiers: [String]) async {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}
