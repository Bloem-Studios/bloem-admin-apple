import UIKit
import UserNotifications

/// The few things SwiftUI's lifecycle cannot do: register the background task before launch finishes, and
/// answer notification taps and presentation. Everything it does is in `AlertRuntime` and `DeepLinkCenter`.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        AlertRuntime.launch(delegate: self)
        return true
    }

    /// A Home Screen quick action that launches the app arrives with the scene; one used while the app is
    /// running arrives at `QuickActionSceneDelegate`. Either way it only submits a link.
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if let item = options.shortcutItem { QuickActions.handle(item) }
        let configuration = UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }

    /// iOS gave (or changed) this phone's APNs token: the registrations with the saved servers follow it.
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushRuntime.shared.tokenReceived(deviceToken)
    }

    /// A silent push (the relay's `background_wake`), or the background half of an alert push. A widget wake names
    /// the widget channels that changed, and the app reloads the widgets that show them; an alert push reloads
    /// them all, which is what lets the server skip a wake right after one. Neither shows anything or reads
    /// anything else, and neither opens a socket. iOS may throttle these, and that is fine.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        if case .reloaded = PushRuntime.shared.handleBackgroundPush(PushWire(userInfo: userInfo)) {
            completionHandler(.newData)
        } else {
            completionHandler(.noData)
        }
    }

    /// Without a token no server can push. The next launch or foreground asks iOS again.
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// A notification that arrives while the app is open still shows, so a server going down is seen.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// Tapping a notification opens that server, and on a pushed one the page and item it names, after the app
    /// lock. Approve and Decline on a request notification run now, and the answer comes before iOS is told
    /// the response is handled, so the app is not suspended halfway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let request = response.notification.request
        let interpreted = PushResponse.interpret(
            actionIdentifier: response.actionIdentifier, info: PushTapInfo(userInfo: request.content.userInfo)
        )
        let identifier = request.identifier
        let done = HandlerBox(completionHandler)
        Task { @MainActor in
            await PushRuntime.shared.respond(interpreted, notificationIdentifier: identifier)
            done.call()
        }
    }
}

/// iOS's completion handler, which is called once and from whichever thread finishes the work.
private struct HandlerBox: @unchecked Sendable {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    func call() { handler() }
}

/// The Home Screen quick actions declared in `project.yml` (`UIApplicationShortcutItems`).
enum QuickActions {
    @MainActor
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard let route = DeepLinkRoute(quickActionType: item.type) else { return false }
        DeepLinkCenter.shared.submit(route)
        return true
    }
}

@MainActor
final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(QuickActions.handle(shortcutItem))
    }
}
