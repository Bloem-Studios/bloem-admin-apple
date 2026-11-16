import Foundation
import Observation

extension PushKind: Identifiable {
    var id: String { rawValue }
}

/// The logic of Settings → Notifications: a switch per kind, per saved server. A switch is kept on this phone
/// first and then sent to the server, which stops sending that kind. Two of the kinds come from this app's own
/// checks and never leave the phone: "Server can't be reached" is the "Servers to watch" switch of Server
/// alerts, and "Server is back" is its own switch.
///
/// A plain Silo server cannot push to this app, so for it Settings says so plainly and offers only those two.
/// Permission is asked after the first successful sign-in (`PushRegistrar`), never when this screen opens; the
/// screen has a button for it, and when iOS has refused it says how to allow it.
@MainActor
@Observable
final class PushSettingsModel {
    /// The servers listed: those the app can reach over HTTPS.
    let servers: [AdminServer]
    private(set) var permission: NotificationPermission = .notDetermined
    /// Bumped whenever something this screen reads outside the model changed.
    private(set) var revision = 0

    @ObservationIgnored private let preferences: PushPreferences
    @ObservationIgnored private let authorizer: any NotificationAuthorizing
    @ObservationIgnored private let alerts: AlertSettingsModel?
    @ObservationIgnored private let sendKind: @MainActor (PushKind, Bool, AdminServer) async -> Void
    @ObservationIgnored private let refresh: @MainActor () async -> Void
    @ObservationIgnored private let openSettings: @MainActor () -> Void

    init(
        servers: [AdminServer],
        preferences: PushPreferences,
        alerts: AlertSettingsModel?,
        authorizer: any NotificationAuthorizing,
        sendKind: @escaping @MainActor (PushKind, Bool, AdminServer) async -> Void,
        refresh: @escaping @MainActor () async -> Void,
        openSystemSettings: @escaping @MainActor () -> Void
    ) {
        self.servers = servers.filter { !$0.usesInsecureAddress }
        self.preferences = preferences
        self.alerts = alerts
        self.authorizer = authorizer
        self.sendKind = sendKind
        self.refresh = refresh
        self.openSettings = openSystemSettings
    }

    // MARK: What the screen shows

    func status(_ server: AdminServer) -> PushStatus {
        _ = revision
        return preferences.status(serverID: server.id)
    }

    /// The kinds a server's section lists: all seven where it can push, the two local ones everywhere else.
    func kinds(for server: AdminServer) -> [PushKind] {
        status(server).offersRemoteKinds ? PushKind.allCases : PushKind.allCases.filter(\.isLocal)
    }

    func isOn(_ kind: PushKind, server: AdminServer) -> Bool {
        _ = revision
        if kind == .serverDown {
            guard let alerts else { return false }
            return alerts.isOn && alerts.isServerOn(server.id)
        }
        return preferences.isEnabled(kind, serverID: server.id)
    }

    /// iOS has the app's notifications off, and a server is waiting for them.
    var showsPermissionHelp: Bool {
        permission == .denied && servers.contains { status($0) == .needsPermission }
    }

    /// iOS has not been asked, and a server is waiting for it.
    var offersPermissionButton: Bool {
        permission == .notDetermined && servers.contains { status($0) == .needsPermission }
    }

    nonisolated static func text(for status: PushStatus) -> String {
        switch status {
        case .unknown: String(localized: "Checking whether this server can send notifications")
        case .plainSilo: String(localized: "Push isn't available on this server. Only the server-down checks apply")
        case .notAvailableYet: String(localized: "Push isn't available on this server yet. Only the server-down checks apply")
        case .needsAdminAccount: String(localized: "Push needs an administrator account on this server")
        case .signedOut: String(localized: "Sign in to this server to receive notifications")
        case .needsPermission: String(localized: "Allow notifications to receive these")
        case .waitingForToken: String(localized: "Setting up notifications")
        case .registered: String(localized: "This server sends you notifications")
        case .failed: String(localized: "Couldn't set up notifications with this server. The app will try again")
        }
    }

    // MARK: Actions

    /// Reads iOS's answer without asking, and asks every server again.
    func load() async {
        permission = await authorizer.status()
        await refresh()
        permission = await authorizer.status()
        reload()
    }

    /// Something outside the model changed (a registration pass ended).
    func reload() {
        revision += 1
    }

    func set(_ kind: PushKind, on: Bool, server: AdminServer) async {
        if kind == .serverDown {
            await setServerDown(on, server: server)
        } else {
            await sendKind(kind, on, server)
        }
        reload()
    }

    private func setServerDown(_ on: Bool, server: AdminServer) async {
        guard let alerts else { return }
        if on {
            // The same switch as "Servers to watch". Turning it on turns Server alerts on, which is the one
            // moment that screen asks iOS for permission.
            if !alerts.isOn { await alerts.setEnabled(true) }
            if alerts.isOn { alerts.setServer(server.id, enabled: true) }
        } else {
            alerts.setServer(server.id, enabled: false)
        }
    }

    /// The button shown while iOS has not been asked. It is the person's own tap, so asking is fine.
    func allowNotifications() async {
        preferences.permissionAsked = true
        let granted = await authorizer.requestPermission()
        permission = granted ? .allowed : .denied
        await refresh()
        reload()
    }

    func openSystemSettings() {
        openSettings()
    }
}
