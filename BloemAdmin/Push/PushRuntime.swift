import Foundation
import UIKit
import UserNotifications

extension Notification.Name {
    /// Posted when a pass changed what Settings → Notifications shows.
    static let pushStatusDidChange = Notification.Name("bloem.admin.push.statusDidChange")
}

/// Puts the push pieces together for the running app. The signed-in root attaches its store and session
/// (`attach`); until then a token iOS hands over is only kept. Nothing here asks for permission by itself: the
/// registrar asks once, after a successful sign-in, and Settings asks when the person taps its button.
@MainActor
final class PushRuntime: PushLifecycle {
    static let shared = PushRuntime()

    /// The build's APNs environment: Debug builds are sandbox, Release builds production (`aps-environment`).
    static var apnsEnvironment: String {
        let value = Bundle.main.object(forInfoDictionaryKey: "BloemAPSEnvironment") as? String
        return value == "development" ? "sandbox" : "production"
    }

    private(set) var registrar: PushRegistrar?
    private(set) var store: ServerStore?
    let preferences = PushPreferences()
    private let registrations: any PushRegistrationStoring = KeychainPushRegistrationStore()
    private var pendingReason: PushRegistrar.Reason?

    init() {}

    /// Called once from the app delegate's launch, after the notification categories are set. iOS wants the
    /// registration repeated at every launch, because the token can change; registering needs the permission
    /// to already be granted, so a phone that never allowed notifications is not touched.
    func launch() {
        Task {
            if await SystemNotificationAuthorizer().status() == .allowed {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        PushSettingsMirror.sync(showsDetails: AlertRuntime.preferences().showsDetails)
        // Returning to the app asks every server again, which is what retries a server that had no push yet.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await PushRuntime.shared.reconcile(.foreground) }
        }
    }

    /// The model behind Settings → Notifications, for the saved servers `servers`.
    @MainActor
    static func settingsModel(servers: [AdminServer], alerts: AlertSettingsModel) -> PushSettingsModel {
        #if DEBUG
        if let fixture = AlertUITestFixture.current {
            return fixture.makePushModel(servers: servers, alerts: alerts)
        }
        #endif
        return PushSettingsModel(
            servers: servers,
            preferences: shared.preferences,
            alerts: alerts,
            authorizer: SystemNotificationAuthorizer(),
            sendKind: { kind, enabled, server in await PushRuntime.shared.setKind(kind, enabled: enabled, server: server) },
            refresh: { await PushRuntime.shared.reconcile(.changed) },
            openSystemSettings: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        )
    }

    /// The signed-in root hands over the store and session the registrar signs in with.
    func attach(store: ServerStore, sessionState: AdminSessionState) {
        #if DEBUG
        // A UI test with a fake permission has no registrations to make.
        if AlertUITestFixture.isRequested { return }
        #endif
        guard self.store !== store else { return }
        self.store = store
        let registrar = PushRegistrar(
            servers: { [weak store] in store?.servers ?? [] },
            gateway: StorePushGateway(store: store, sessionState: sessionState),
            registrations: registrations,
            preferences: preferences,
            authorizer: SystemNotificationAuthorizer(),
            api: URLSessionPushDisplayAPI(),
            apnsEnvironment: Self.apnsEnvironment,
            registerForRemoteNotifications: { UIApplication.shared.registerForRemoteNotifications() },
            widgetReport: { await SystemWidgetPlacements().report() }
        )
        registrar.statusDidChange = {
            NotificationCenter.default.post(name: .pushStatusDidChange, object: nil)
        }
        self.registrar = registrar
        if let pending = pendingReason {
            pendingReason = nil
            Task { await registrar.reconcile(pending) }
        }
    }

    /// Reads every saved server again: at launch, on return to the foreground and when the saved servers or
    /// their sign-ins change. Before `attach` the pass waits.
    func reconcile(_ reason: PushRegistrar.Reason) async {
        guard let registrar else {
            pendingReason = reason
            return
        }
        await registrar.reconcile(reason)
    }

    /// The first page has just shown data read from a server: the one moment iOS is asked for notification
    /// permission, if a signed-in server can push and the person was never asked. Called once per launch.
    func firstPageLoaded() {
        guard !didReportFirstPage else { return }
        didReportFirstPage = true
        Task { await reconcile(.firstPageLoaded) }
    }

    private var didReportFirstPage = false

    /// A successful sign-in (a server was added, or the person signed in again): the registration is made
    /// again for this account. It does not ask for permission; `firstPageLoaded` does.
    func serverSignedIn(_ server: AdminServer) {
        Task { await reconcile(.signedIn(serverID: server.id)) }
    }

    /// Signed out, or the server was removed. The server is told in the background and never waits longer
    /// than five seconds; the extension stops using the registration at once.
    func serverSignedOut(_ server: AdminServer) {
        Task { await unregister(serverID: server.id) }
    }

    /// iOS gave (or changed) this phone's APNs token.
    func tokenReceived(_ deviceToken: Data) {
        preferences.apnsToken = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await reconcile(.token) }
    }

    /// Stops pushes for a server about to be signed out of or removed. Waits at most five seconds.
    func unregister(serverID: String) async {
        if let registrar {
            await registrar.unregister(serverID: serverID)
        } else if let registration = registrations.registration(serverID: serverID) {
            // Not attached (a UI test host): drop the record, there is no registrar to tell the server.
            registrations.remove(serverID: registration.serverID)
        }
        NotificationCenter.default.post(name: .pushStatusDidChange, object: nil)
    }

    func setKind(_ kind: PushKind, enabled: Bool, server: AdminServer) async {
        if let registrar {
            await registrar.setKind(kind, enabled: enabled, server: server)
        } else {
            preferences.setKind(kind, enabled: enabled, serverID: server.id)
        }
    }

    // MARK: Widgets

    /// A push that reached the app in the background: a widget wake, or the background half of an alert push.
    /// Reloads the affected widgets and shows nothing.
    func handleBackgroundPush(_ wire: PushWire?) -> PushBackgroundHandler.Outcome {
        PushBackgroundHandler(registrations: registrations, reloader: SystemWidgetKindReloader()).handle(wire)
    }

    // MARK: Answering a notification

    /// A tap or a button on a notification. A tap waits in `DeepLinkCenter` for the app lock; a button runs
    /// at once and needs the phone unlocked (the action says so).
    func respond(_ response: PushResponse, notificationIdentifier: String) async {
        switch response {
        case .open(let route):
            DeepLinkCenter.shared.submit(route)
        case .decide(let serverID, let requestID, let approve):
            let runner = PushActionRunner(
                decider: WidgetRequestDecider(fetcher: WidgetFetcher.live(), servers: { AlertRuntime.savedServers() }),
                notifier: SystemPushNotifier(),
                afterAnswer: { WidgetReload.requests() }
            )
            await runner.run(serverID: serverID, requestID: requestID, approve: approve, notificationIdentifier: notificationIdentifier)
        case .ignore:
            break
        }
    }
}
