import CryptoKit
import Foundation

/// What the registrar needs from the saved servers' sign-ins. `StorePushGateway` is the real one.
@MainActor
protocol PushServerGateway: AnyObject {
    func isSignedIn(_ server: AdminServer) -> Bool
    /// The account the server's current sign-in belongs to, or "" when it cannot be told.
    func accountKey(_ server: AdminServer) -> String
    /// The server's Bloem capabilities, or nil for a plain Silo server. Normally the answer the app already
    /// has for this session (a plain Silo server is asked once, as the rest of the app does); `fresh` asks the
    /// server again, so a server that gained push is noticed. Throws when the server could not be asked.
    func capabilities(_ server: AdminServer, fresh: Bool) async throws -> BloemCapabilities?
    func register(_ server: AdminServer, _ request: PushRegisterRequest) async throws -> PushRegistered
    func setKinds(_ server: AdminServer, deviceID: String, kinds: [String: Bool]) async throws
    /// Tells the server which widgets are placed; answers what it now holds.
    func setWidgets(_ server: AdminServer, deviceID: String, report: WidgetReport) async throws -> WidgetReport
}

/// Keeps each saved Bloem server's registration for this phone in step with the choices made here.
///
/// - A plain Silo server is asked one question (its capabilities) and never sent a registration: its push
///   service cannot reach this app, so the app keeps its own local server-down checks and says so.
/// - A Bloem server that does not offer push yet (it lacks `admin_push_v1`, or answers the registration 404)
///   is shown as not available yet, with no error. It is asked again at the next sign-in, and at a foreground
///   once ten minutes have passed since it was last asked, so a deploy is noticed without restarting the app.
/// - Registering replaces the display token the server issued before, so it is done only when needed: no
///   registration yet, the APNs token changed, another account signed in, the last one is a week old, or a
///   sign-in just happened.
/// - Widget wakes: the phone reports which widgets are placed (`WidgetCenter`, read at launch and at every
///   foreground) in the registration, and again whenever the answer changes, so the server sends silent wakes
///   to a phone that has a widget and to no other. A server whose answer has no widget fields does not send
///   wakes, and is not told.
/// - Notification permission is asked at one moment: once the app's first page has loaded its data
///   (`Reason.firstPageLoaded`), and only when a signed-in server can push. Never straight after a sign-in,
///   never at launch, never on foreground, and never twice.
@MainActor
final class PushRegistrar {
    enum Reason: Equatable, Sendable {
        case launch, foreground, changed, token
        /// A successful sign-in to this server (it was just added, or the person signed in again).
        case signedIn(serverID: String)
        /// The first page the app shows has just loaded its data. This is the one moment iOS may be asked for
        /// permission: the person has seen the app work before it asks for anything.
        case firstPageLoaded
    }

    /// Signing out or removing a server never waits longer than this on a server that does not answer.
    static let unregisterBudget: Duration = .seconds(5)
    static let refreshAfter: TimeInterval = 7 * 24 * 60 * 60
    /// How long a Bloem server without push is left alone before a foreground asks it again.
    static let reprobeAfter: TimeInterval = 10 * 60
    /// A registration the server never confirmed stopping is dropped after this many tries.
    static let maxRetireAttempts = 5

    private let servers: () -> [AdminServer]
    private let gateway: any PushServerGateway
    private let registrations: any PushRegistrationStoring
    private let preferences: PushPreferences
    private let authorizer: any NotificationAuthorizing
    private let api: any PushDisplayAPI
    private let apnsEnvironment: String
    private let registerForRemoteNotifications: () -> Void
    private let now: () -> Date
    private let unregisterBudget: Duration
    /// The widgets placed now; nil when WidgetKit could not say, which leaves what the server holds alone.
    private let widgetReport: () async -> WidgetReport?

    /// Called after a pass changed what Settings shows.
    var statusDidChange: () -> Void = {}

    private var forced: Set<String> = []
    private var lastProbe: [String: Date] = [:]
    private var askForPermission = false
    private var isRunning = false
    private var runAgain = false

    init(
        servers: @escaping () -> [AdminServer],
        gateway: any PushServerGateway,
        registrations: any PushRegistrationStoring,
        preferences: PushPreferences,
        authorizer: any NotificationAuthorizing,
        api: any PushDisplayAPI,
        apnsEnvironment: String,
        registerForRemoteNotifications: @escaping () -> Void,
        unregisterBudget: Duration = PushRegistrar.unregisterBudget,
        now: @escaping () -> Date = { Date() },
        widgetReport: @escaping () async -> WidgetReport? = { nil }
    ) {
        self.servers = servers
        self.gateway = gateway
        self.registrations = registrations
        self.preferences = preferences
        self.authorizer = authorizer
        self.api = api
        self.apnsEnvironment = apnsEnvironment
        self.registerForRemoteNotifications = registerForRemoteNotifications
        self.unregisterBudget = unregisterBudget
        self.now = now
        self.widgetReport = widgetReport
    }

    // MARK: Reconcile

    /// Brings every saved server's registration in step with this phone. Passes never overlap: one that is
    /// asked for while another runs is run once more when that one ends.
    func reconcile(_ reason: Reason) async {
        if case .signedIn(let serverID) = reason {
            forced.insert(serverID)
        }
        if reason == .firstPageLoaded { askForPermission = true }
        guard !isRunning else {
            // The pass that is running may have read the servers before this change: run it once more.
            runAgain = true
            return
        }
        isRunning = true
        defer { isRunning = false }
        var passReason = reason
        repeat {
            runAgain = false
            await pass(passReason)
            passReason = .changed
        } while runAgain
        statusDidChange()
    }

    private enum Capability {
        case plainSilo, notYet, canPush, unreachable
    }

    private func pass(_ reason: Reason) async {
        let saved = servers()
        let savedIDs = Set(saved.map(\.id))
        preferences.retain(serverIDs: savedIDs)
        let signedIn = saved.filter { gateway.isSignedIn($0) }
        let signedInIDs = Set(signedIn.map(\.id))
        for server in saved where !signedInIDs.contains(server.id) {
            preferences.setStatus(.signedOut, serverID: server.id)
        }
        // A registration the server has not yet been told to stop (the server was removed, or the person
        // signed out, and the server did not answer then): its own record has the address to stop it at.
        if case .found(let all) = registrations.load() {
            for leftover in all where !signedInIDs.contains(leftover.serverID) && (leftover.isRetiring || !savedIDs.contains(leftover.serverID)) {
                _ = await retire(leftover)
            }
        }
        var capabilities: [String: Capability] = [:]
        for server in signedIn {
            capabilities[server.id] = await capability(of: server, reason: reason)
        }

        var permission = await authorizer.status()
        let anyCanPush = capabilities.values.contains(.canPush)
        if askForPermission {
            if anyCanPush, permission == .notDetermined, !preferences.permissionAsked {
                // The one moment iOS is asked: after the first page's first successful load, with a server that can push.
                preferences.permissionAsked = true
                permission = await authorizer.requestPermission() ? .allowed : .denied
            }
            // Keep waiting only while a server could not be asked; a later pass in this session may still be
            // the first to see it can push (a pass for a sign-in never asks: only `firstPageLoaded` sets the flag).
            if !capabilities.values.contains(.unreachable) || permission != .notDetermined {
                askForPermission = false
            }
        }
        // Asked for only while there is no token: iOS answers every ask with the token callback, which runs
        // another pass, so asking each time would never end. The launch asks again for a changed token.
        if permission == .allowed, preferences.apnsToken == nil { registerForRemoteNotifications() }

        // Read once a pass, and only when some server could use it: a phone with no server that can push has
        // nothing to report.
        let widgets: WidgetReport? = anyCanPush ? await widgetReport() : nil
        for server in signedIn {
            switch capabilities[server.id] ?? .unreachable {
            case .unreachable:
                break
            case .plainSilo:
                await forget(server, status: .plainSilo)
            case .notYet:
                await forget(server, status: .notAvailableYet)
            case .canPush:
                await apply(permission: permission, to: server, widgets: widgets)
            }
        }
    }

    private func capability(of server: AdminServer, reason: Reason) async -> Capability {
        // Only a Bloem server already known not to offer push is asked again, and not on every foreground.
        var fresh = false
        if preferences.status(serverID: server.id) == .notAvailableYet {
            switch reason {
            case .signedIn(let id) where id == server.id:
                fresh = true
            case .foreground:
                fresh = now().timeIntervalSince(lastProbe[server.id] ?? now()) >= Self.reprobeAfter
            default:
                break
            }
        }
        do {
            let capabilities = try await gateway.capabilities(server, fresh: fresh)
            if fresh || lastProbe[server.id] == nil { lastProbe[server.id] = now() }
            guard let capabilities else { return .plainSilo }
            return capabilities.featureTokens.contains(adminPushFeatureToken) ? .canPush : .notYet
        } catch {
            return .unreachable
        }
    }

    /// A server that cannot push to this app: nothing to register, and a registration left from before is
    /// dropped (there is nothing on the server to stop).
    private func forget(_ server: AdminServer, status: PushStatus) async {
        registrations.remove(serverID: server.id)
        forced.remove(server.id)
        preferences.setStatus(status, serverID: server.id)
    }

    private func apply(permission: NotificationPermission, to server: AdminServer, widgets: WidgetReport?) async {
        guard permission == .allowed else {
            preferences.setStatus(.needsPermission, serverID: server.id)
            return
        }
        guard let apnsToken = preferences.apnsToken else {
            preferences.setStatus(.waitingForToken, serverID: server.id)
            return
        }
        await registerIfNeeded(server, apnsToken: apnsToken, widgets: widgets)
    }

    private func registerIfNeeded(_ server: AdminServer, apnsToken: String, widgets: WidgetReport?) async {
        let tokenHash = Self.hash(apnsToken)
        let account = gateway.accountKey(server)
        if var existing = registrations.registration(serverID: server.id),
           isCurrent(existing, for: server, tokenHash: tokenHash, account: account) {
            if existing.serverName != server.displayName {
                existing.serverName = server.displayName
                try? registrations.save(existing)
            }
            preferences.setStatus(.registered, serverID: server.id)
            await syncWidgets(of: server, to: widgets)
            return
        }
        var request = PushRegisterRequest(
            installationID: preferences.installationID, platform: "apple", token: apnsToken,
            apnsEnvironment: apnsEnvironment, apnsTopic: adminPushAPNsTopic,
            disabledKinds: preferences.disabledRemoteKinds(serverID: server.id)
        )
        if let widgets { request = request.reporting(widgets) }
        do {
            let registered = try await gateway.register(server, request)
            try registrations.save(PushRegistration(
                serverID: server.id, serverName: server.displayName, baseURL: server.baseURL,
                deviceID: registered.deviceID, displayToken: registered.displayToken, accountKey: account,
                tokenHash: tokenHash, registeredAt: now(), widgetReport: registered.widgets
            ))
            forced.remove(server.id)
            preferences.setStatus(.registered, serverID: server.id)
        } catch let error as APIError {
            let status = Self.status(for: error)
            if status != .failed { forced.remove(server.id) }
            preferences.setStatus(status, serverID: server.id)
        } catch {
            // The registration could not be saved, or the network failed: tried again at the next pass.
            preferences.setStatus(.failed, serverID: server.id)
        }
    }

    private func isCurrent(_ registration: PushRegistration, for server: AdminServer, tokenHash: String, account: String) -> Bool {
        guard !registration.isRetiring, !registration.needsResync, !forced.contains(server.id),
              registration.tokenHash == tokenHash, registration.baseURL == server.baseURL,
              now().timeIntervalSince(registration.registeredAt) < Self.refreshAfter else { return false }
        // Another account signed in: the server's device must move to it. When either side cannot say who it
        // is, the sign-in event above is what forces the move.
        return registration.accountKey.isEmpty || account.isEmpty || registration.accountKey == account
    }

    /// How the server's refusal of a registration reads in Settings. A server without the routes (or with
    /// push delivery off) is "not available yet", not an error.
    static func status(for error: APIError) -> PushStatus {
        switch error.statusCode {
        case 404, 405, 501, 503: .notAvailableYet
        case 403: .needsAdminAccount
        default: .failed
        }
    }

    // MARK: Widgets

    /// Tells a registered server which widgets are placed, when that differs from what it holds. A widget added
    /// or removed since the last pass is noticed at the next launch or foreground. A server whose registration
    /// answer had no widget fields does not send wakes and is left alone; one that refuses the call as missing
    /// is treated the same from then on. Any other failure is tried again at the next pass.
    private func syncWidgets(of server: AdminServer, to report: WidgetReport?) async {
        guard let report, var registration = registrations.registration(serverID: server.id), !registration.isRetiring,
              let held = registration.widgetReport, held != report else { return }
        do {
            registration.widgetReport = try await gateway.setWidgets(server, deviceID: registration.deviceID, report: report)
            try? registrations.save(registration)
        } catch let error as APIError where [404, 405, 501].contains(error.statusCode) {
            registration.widgetReport = nil
            try? registrations.save(registration)
        } catch {
            // Offline or a server error: the record still says what the server holds, so the next pass asks again.
        }
    }

    // MARK: Switches

    /// Switches one kind for one saved server. The choice is kept here first. A server that pushes to this
    /// phone is told too; if it cannot be told now, the registration is marked so the next pass sends every
    /// switch again. A local kind never leaves the phone.
    func setKind(_ kind: PushKind, enabled: Bool, server: AdminServer) async {
        preferences.setKind(kind, enabled: enabled, serverID: server.id)
        guard !kind.isLocal, var registration = registrations.registration(serverID: server.id),
              !registration.isRetiring else { return }
        do {
            try await gateway.setKinds(server, deviceID: registration.deviceID, kinds: [kind.rawValue: enabled])
        } catch {
            registration.needsResync = true
            try? registrations.save(registration)
        }
    }

    // MARK: Sign-out and removal

    /// Stops pushes to this phone for a server about to be signed out of or removed. It uses the display token,
    /// so it works with no sign-in left, and waits at most `unregisterBudget`: signing out never hangs on a
    /// server that does not answer. The extension stops using the registration at once. If the server did not
    /// confirm, the record stays marked as being retired and the next pass tries again (`maxRetireAttempts`
    /// times), so a server that was offline for a moment still stops pushing.
    func unregister(serverID: String) async {
        forced.remove(serverID)
        guard let registration = registrations.registration(serverID: serverID) else { return }
        _ = await retire(registration)
    }

    /// True when the server confirmed (or no longer knows the device) and the record is gone.
    @discardableResult
    private func retire(_ registration: PushRegistration) async -> Bool {
        var marked = registration
        marked.isRetiring = true
        let retiring = marked
        let api = api
        let result = await PushBoundedWait.run(unregisterBudget) { () async -> PushRetireResult? in
            await api.retire(baseURL: retiring.baseURL, displayToken: retiring.displayToken, deviceID: retiring.deviceID)
        }
        switch result {
        case .retired?, .gone?:
            registrations.remove(serverID: registration.serverID)
            return true
        case .failed?, nil:
            marked.retireAttempts += 1
            if marked.retireAttempts >= Self.maxRetireAttempts {
                registrations.remove(serverID: registration.serverID)
            } else {
                try? registrations.save(marked)
            }
            return false
        }
    }

    nonisolated static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension PushRegisterRequest {
    /// This request with the widgets the phone has placed, as the server wants them: channels only when placed.
    func reporting(_ report: WidgetReport) -> PushRegisterRequest {
        var copy = self
        copy.widgetsPlaced = report.placed
        copy.widgetChannels = report.placed ? report.channelNames : nil
        return copy
    }
}
