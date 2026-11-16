import Foundation
import UserNotifications

/// Replaces the relay's generic alert with the real title and body, read from the app's own server.
///
/// The relay sends `private_alert` with `mutable-content`: a generic line and a delivery id, and never any
/// text. iOS hands that push to this extension before it shows it. The extension finds the saved server the
/// delivery id belongs to, asks that server for the text with this device's display token, and shows it. It
/// adds names and titles only when "Show details on the lock screen" is on, and shows the generic text when
/// the server cannot be asked in time. Everything it decides is in `PushNotificationProcessor`.
///
/// The extension never holds a sign-in: it reads one keychain item (the display token) and one small
/// settings file from the App Group.
final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let lock = NSLock()
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var task: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            contentHandler(request.content)
            return
        }
        let wire = PushWire(userInfo: content.userInfo)
        // If time runs out before the server answers, what shows is the generic text, never the relay's.
        PushNotificationComposer.compose(registration: nil, display: nil, showsDetails: false).apply(to: content)
        lock.withLock {
            self.contentHandler = contentHandler
            bestAttempt = content
        }
        let processor = Self.makeProcessor()
        let work = Task { [self] in
            let plan = await processor.plan(for: wire)
            deliver(plan)
        }
        lock.withLock { task = work }
    }

    override func serviceExtensionTimeWillExpire() {
        lock.withLock { task }?.cancel()
        deliver(nil)
    }

    /// Hands the notification to iOS once: with the plan applied, or as the generic text it already carries.
    private func deliver(_ plan: PushNotificationPlan?) {
        let finished: (handler: (UNNotificationContent) -> Void, content: UNMutableNotificationContent)? = lock.withLock {
            guard let handler = contentHandler, let content = bestAttempt else { return nil }
            contentHandler = nil
            if let plan { plan.apply(to: content) }
            return (handler, content)
        }
        guard let (handler, content) = finished else { return }
        handler(content)
    }

    private static func makeProcessor() -> PushNotificationProcessor {
        PushNotificationProcessor(
            registrations: KeychainPushRegistrationStore(),
            settings: FilePushSharedSettingsStore.appGroup() ?? PrivatePushSettings(),
            api: URLSessionPushDisplayAPI()
        )
    }
}
