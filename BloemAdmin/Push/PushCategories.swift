import Foundation
import UserNotifications

/// The notification categories the app registers. A pushed notification names one by identifier: the
/// extension sets it, the app defines what it means. Approve and Decline need the phone unlocked
/// (`.authenticationRequired`), and neither is destructive.
enum PushCategories {
    static func request() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: PushCategoryID.request,
            actions: [
                UNNotificationAction(
                    identifier: PushActionID.approve, title: String(localized: "Approve"), options: [.authenticationRequired]
                ),
                UNNotificationAction(
                    identifier: PushActionID.decline, title: String(localized: "Decline"), options: [.authenticationRequired]
                ),
            ],
            intentIdentifiers: [],
            // With "Show Previews" set to When Unlocked, iOS shows this in place of the body.
            hiddenPreviewsBodyPlaceholder: String(localized: "Request update"),
            options: []
        )
    }

    static func general() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: PushCategoryID.general,
            actions: [],
            intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: String(localized: "Admin alert"),
            options: []
        )
    }

    /// Every category the app uses: the local server alert and the two pushed ones.
    static func all() -> Set<UNNotificationCategory> {
        [AlertCategory.notificationCategory(), request(), general()]
    }
}
