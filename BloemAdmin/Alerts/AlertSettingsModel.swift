import Foundation
import Observation

/// The App settings section's logic. Permission is asked for at one moment only: when the admin turns the
/// master switch on and iOS has not been asked yet. Opening the screen, launching the app and running a
/// background check never ask.
@MainActor
@Observable
final class AlertSettingsModel {
    private(set) var isEnabled: Bool
    private(set) var permission: NotificationPermission
    private(set) var enabledServerIDs: Set<String>
    private(set) var showsDetails: Bool
    let servers: [AdminServer]

    @ObservationIgnored private let preferences: AlertPreferences
    @ObservationIgnored private let authorizer: any NotificationAuthorizing
    @ObservationIgnored private let notifier: any AlertNotifying
    @ObservationIgnored private let planner: BackgroundCheckPlanner
    @ObservationIgnored private let openSettings: @MainActor () -> Void

    init(
        preferences: AlertPreferences,
        authorizer: any NotificationAuthorizing,
        notifier: any AlertNotifying,
        planner: BackgroundCheckPlanner,
        servers: [AdminServer],
        openSystemSettings: @escaping @MainActor () -> Void
    ) {
        self.preferences = preferences
        self.authorizer = authorizer
        self.notifier = notifier
        self.planner = planner
        self.servers = servers
        self.openSettings = openSystemSettings
        isEnabled = preferences.isEnabled
        // Until `load()` has read iOS's answer, a switch that was on stays shown as on.
        permission = preferences.isEnabled ? .allowed : .notDetermined
        enabledServerIDs = preferences.enabledServerIDs
        showsDetails = preferences.showsDetails
    }

    /// On means alerts are switched on here and iOS lets the app notify. A permission taken back in iOS
    /// Settings shows the switch off.
    var isOn: Bool { isEnabled && permission == .allowed }

    func isServerOn(_ id: String) -> Bool { enabledServerIDs.contains(id) }

    /// Reads iOS's answer without asking.
    func load() async {
        isEnabled = preferences.isEnabled
        enabledServerIDs = preferences.enabledServerIDs
        permission = await authorizer.status()
    }

    func setEnabled(_ on: Bool) async {
        if on {
            var status = await authorizer.status()
            if status == .notDetermined {
                status = await authorizer.requestPermission() ? .allowed : .denied
            }
            permission = status
            preferences.isEnabled = status == .allowed
        } else {
            preferences.isEnabled = false
            preferences.clearStates()
            await notifier.removeDelivered(identifiers: servers.flatMap { AlertNotificationContent.identifiers(forServer: $0.id) })
        }
        isEnabled = preferences.isEnabled
        reschedule()
    }

    func setServer(_ id: String, enabled: Bool) {
        preferences.setServer(id, enabled: enabled)
        enabledServerIDs = preferences.enabledServerIDs
        reschedule()
    }

    func setShowsDetails(_ on: Bool) {
        preferences.showsDetails = on
        showsDetails = on
    }

    func openSystemSettings() {
        openSettings()
    }

    private func reschedule() {
        planner.reschedule(preferences: preferences, savedServerIDs: Set(servers.map(\.id)))
    }
}
