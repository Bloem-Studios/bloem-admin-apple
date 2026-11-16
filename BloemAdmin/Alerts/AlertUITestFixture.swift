#if DEBUG
import Foundation
import UIKit

/// UI-test seam for the "Server alerts" section: `--ui-testing-notifications=undetermined` (the person
/// grants the prompt), `=undetermined-refuse` (refuses it), `=granted` or `=denied`. The section then runs
/// on a fake permission, a throwaway settings store and no background scheduler, so a UI test never meets
/// a real system prompt. Nothing here is compiled into release builds.
struct AlertUITestFixture {
    static let argumentPrefix = "--ui-testing-notifications="

    let permission: NotificationPermission
    let answer: Bool

    static var isRequested: Bool { current != nil }

    static var current: AlertUITestFixture? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let value = arguments.first(where: { $0.hasPrefix(argumentPrefix) })?
            .dropFirst(argumentPrefix.count) else { return nil }
        switch value {
        case "undetermined": return AlertUITestFixture(permission: .notDetermined, answer: true)
        case "undetermined-refuse": return AlertUITestFixture(permission: .notDetermined, answer: false)
        case "granted": return AlertUITestFixture(permission: .allowed, answer: true)
        case "denied": return AlertUITestFixture(permission: .denied, answer: false)
        default: return nil
        }
    }

    /// One throwaway settings domain per launch.
    nonisolated(unsafe) private static let defaults: UserDefaults = {
        let suite = "com.bloemstudios.admin.ui-testing-alerts"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    @MainActor
    func makeModel(servers: [AdminServer]) -> AlertSettingsModel {
        AlertSettingsModel(
            preferences: AlertPreferences(defaults: Self.defaults),
            authorizer: UITestAuthorizer.shared(permission: permission, answer: answer),
            notifier: SilentNotifier(),
            planner: BackgroundCheckPlanner(scheduler: SilentScheduler(), now: { Date() }),
            servers: servers,
            openSystemSettings: {}
        )
    }
}

extension AlertUITestFixture {
    /// One throwaway push-settings domain per launch.
    nonisolated(unsafe) private static let pushDefaults: UserDefaults = {
        let suite = "com.bloemstudios.admin.ui-testing-push"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }()

    /// Settings → Notifications on the same fake permission: the first saved server is a Bloem server that
    /// pushes (registered once the permission is granted, waiting for it otherwise), every other one is a plain
    /// Silo server. No registrar, no network, no system prompt.
    @MainActor
    func makePushModel(servers: [AdminServer], alerts: AlertSettingsModel) -> PushSettingsModel {
        let preferences = PushPreferences(defaults: Self.pushDefaults)
        let authorizer = UITestAuthorizer.shared(permission: permission, answer: answer)
        let seed: @MainActor () async -> Void = {
            let allowed = await authorizer.status() == .allowed
            for (index, server) in servers.enumerated() {
                preferences.setStatus(index == 0 ? (allowed ? .registered : .needsPermission) : .plainSilo, serverID: server.id)
            }
        }
        return PushSettingsModel(
            servers: servers, preferences: preferences, alerts: alerts, authorizer: authorizer,
            sendKind: { kind, enabled, server in preferences.setKind(kind, enabled: enabled, serverID: server.id) },
            refresh: seed,
            openSystemSettings: {}
        )
    }
}

/// One permission per launch, so a prompt answered once stays answered when the screen reopens.
private final class UITestAuthorizer: NotificationAuthorizing, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var instance: UITestAuthorizer?

    static func shared(permission: NotificationPermission, answer: Bool) -> UITestAuthorizer {
        lock.withLock {
            if let instance { return instance }
            let created = UITestAuthorizer(permission: permission, answer: answer)
            instance = created
            return created
        }
    }

    private let stateLock = NSLock()
    private var current: NotificationPermission
    private let answer: Bool

    private init(permission: NotificationPermission, answer: Bool) {
        current = permission
        self.answer = answer
    }

    func status() async -> NotificationPermission { stateLock.withLock { current } }

    func requestPermission() async -> Bool {
        stateLock.withLock {
            current = answer ? .allowed : .denied
            return answer
        }
    }
}

private struct SilentNotifier: AlertNotifying {
    func post(_ content: AlertNotificationContent) async {}
    func removeDelivered(identifiers: [String]) async {}
}

private struct SilentScheduler: BackgroundTaskSubmitting {
    func submit(identifier: String, earliestBeginDate: Date) throws {}
    func cancel(identifier: String) {}
}
#endif
