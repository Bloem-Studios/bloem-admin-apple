import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

/// Puts the alert pieces together for the running app: the background task, the foreground check and the
/// App settings model. Nothing here asks for permission.
enum AlertRuntime {
    /// Called once, from the app delegate's launch. Registers the background task (which must happen before
    /// launch ends), the notification delegate and category, and the foreground check. Debug builds started
    /// by a UI test with `--ui-testing-notifications` do none of it.
    @MainActor
    static func launch(delegate: UNUserNotificationCenterDelegate) {
        #if DEBUG
        if AlertUITestFixture.isRequested { return }
        #endif
        UNUserNotificationCenter.current().delegate = delegate
        UNUserNotificationCenter.current().setNotificationCategories(PushCategories.all())
        PushRuntime.shared.launch()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: BackgroundCheckPlanner.identifier, using: nil) { task in
            BackgroundCheckRun(task: task).start()
        }
        // iOS runs the task when it chooses, so the first request is made at launch as well.
        planner().reschedule(preferences: preferences(), savedServerIDs: savedServerIDs())
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { await makeRunner().run() }
        }
    }

    // MARK: Pieces

    static func preferences() -> AlertPreferences {
        AlertPreferences(defaults: .standard)
    }

    static func planner() -> BackgroundCheckPlanner {
        BackgroundCheckPlanner(scheduler: SystemBackgroundTaskScheduler(), now: { Date() })
    }

    /// Only the saved servers' metadata (name, address), never a stored sign-in.
    static func savedServers() -> [AdminServer] {
        (try? UserDefaultsServerMetadataStore(defaults: .standard).loadServers()) ?? []
    }

    static func savedServerIDs() -> Set<String> {
        Set(savedServers().map(\.id))
    }

    static func makeRunner() -> AlertRunner {
        AlertRunner(
            preferences: preferences(),
            loadServers: { savedServers() },
            probe: HealthProbe(),
            notifier: SystemAlertNotifier(),
            authorizer: SystemNotificationAuthorizer(),
            snapshots: SnapshotStores.shared,
            reloader: SystemWidgetReloader(),
            planner: planner(),
            now: { Date() },
            backNoticeAllowed: { PushPreferences().isEnabled(.serverUp, serverID: $0) }
        )
    }

    @MainActor
    static func settingsModel(servers: [AdminServer]) -> AlertSettingsModel {
        #if DEBUG
        if let fixture = AlertUITestFixture.current {
            return fixture.makeModel(servers: servers)
        }
        #endif
        return AlertSettingsModel(
            preferences: preferences(),
            authorizer: SystemNotificationAuthorizer(),
            notifier: SystemAlertNotifier(),
            planner: planner(),
            servers: servers,
            openSystemSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        )
    }
}

/// The snapshot store the app and its background task write: the App Group file when the group is
/// available, otherwise nothing is written (widgets then check reachability themselves).
enum SnapshotStores {
    static let shared: any SnapshotStoring = FileSnapshotStore.appGroup() ?? DiscardingSnapshotStore()
}

private struct DiscardingSnapshotStore: SnapshotStoring {
    func load() -> AdminSnapshot? { nil }
    func save(_ snapshot: AdminSnapshot) throws {}
}

/// One run of the background refresh task. iOS gives a short window; if it ends first the check is
/// cancelled and the task is reported unfinished. The next request is made before the check starts, so a
/// run that is cut short does not end the chain.
private final class BackgroundCheckRun: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var finished = false

    init(task: BGTask) { self.task = task }

    func start() {
        AlertRuntime.planner().reschedule(
            preferences: AlertRuntime.preferences(), savedServerIDs: AlertRuntime.savedServerIDs()
        )
        let work = Task {
            await AlertRuntime.makeRunner().run()
            finish(success: true)
        }
        task.expirationHandler = { [self] in
            work.cancel()
            finish(success: false)
        }
    }

    private func finish(success: Bool) {
        let first = lock.withLock { () -> Bool in
            defer { finished = true }
            return !finished
        }
        if first { task.setTaskCompleted(success: success) }
    }
}
