import Foundation
import Observation

/// Presentation state for a collection whose initial empty value is only a
/// placeholder until its first request resolves.
enum CollectionPresentation: Equatable {
    case loading
    case content
    case empty
    case failure

    static func resolve(hasLoaded: Bool, itemCount: Int, errorMessage: String?) -> Self {
        guard hasLoaded else { return .loading }
        if itemCount > 0 { return .content }
        if errorMessage != nil { return .failure }
        return .empty
    }
}

/// Backs the "Sessions" and "Devices" sections of `UserDetailView`: the user's login sessions
/// (each can be revoked, or all at once) and devices (listed only; the API cannot revoke one).
/// Kept as its own small view model (rather than folded into
/// `UsersViewModel`) because it owns TWO independently-loaded lists scoped
/// to a single user being viewed.
@Observable
@MainActor
final class UserSessionsViewModel {
    private(set) var sessions: [AuthSession] = []
    private(set) var devices: [UserDevice] = []
    /// Each endpoint resolves independently so one failure cannot classify
    /// or discard the other endpoint's successful collection.
    private(set) var sessionsErrorMessage: String?
    private(set) var devicesErrorMessage: String?
    var errorMessage: String? {
        sessionsErrorMessage ?? devicesErrorMessage
    }
    /// Set by the revoke* actions on failure, surfaced inline next to the
    /// Sessions section without blanking it the way a genuine load failure does.
    private(set) var actionErrorMessage: String?
    /// How many sessions the last "revoke all" ended, as the server reported it.
    private(set) var revokedCount: Int?
    private(set) var hasLoadedSessions = false
    private(set) var hasLoadedDevices = false
    /// Set in All Servers mode so an action error shown on the user's own screen names its server.
    var serverName: String?

    var sessionsPresentation: CollectionPresentation {
        .resolve(hasLoaded: hasLoadedSessions, itemCount: sessions.count, errorMessage: sessionsErrorMessage)
    }

    var devicesPresentation: CollectionPresentation {
        .resolve(hasLoaded: hasLoadedDevices, itemCount: devices.count, errorMessage: devicesErrorMessage)
    }

    /// Loads sessions and devices concurrently; each request applies its own result as soon as it
    /// resolves, while `errorMessage` remains a summary for the shared retry UI.
    ///
    /// `includeSessions` and `includeDevices` are false when the server says it has no such list
    /// (its capabilities); the skipped list reads as empty rather than as a failure.
    func load(
        userID: String, client: APIClient, sessionState: ServerScopedSession? = nil,
        includeSessions: Bool = true, includeDevices: Bool = true
    ) async {
        sessions = []
        devices = []
        sessionsErrorMessage = nil
        devicesErrorMessage = nil
        hasLoadedSessions = false
        hasLoadedDevices = false

        async let sessionsLoad: Void = loadSessions(userID: userID, client: client, sessionState: sessionState, include: includeSessions)
        async let devicesLoad: Void = loadDevices(userID: userID, client: client, sessionState: sessionState, include: includeDevices)
        _ = await (sessionsLoad, devicesLoad)
    }

    private func loadSessions(userID: String, client: APIClient, sessionState: ServerScopedSession?, include: Bool = true) async {
        guard include else {
            hasLoadedSessions = true
            return
        }
        do {
            sessions = try await client.loginSessions(userID: userID)
            sessionsErrorMessage = nil
        } catch {
            sessionsErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "Sign-ins couldn't be loaded. Try again."), serverName: serverName)
        }
        hasLoadedSessions = true
    }

    private func loadDevices(userID: String, client: APIClient, sessionState: ServerScopedSession?, include: Bool = true) async {
        guard include else {
            hasLoadedDevices = true
            return
        }
        do {
            devices = try await client.userDevices(userID: userID)
            devicesErrorMessage = nil
        } catch {
            devicesErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "Devices couldn't be loaded. Try again."), serverName: serverName)
        }
        hasLoadedDevices = true
    }

    /// Deliberately does NOT reload itself, matching every other action
    /// method in the app — the caller (`UserDetailView`) reloads only when
    /// `actionErrorMessage == nil` after this returns.
    func revokeSession(_ session: AuthSession, userID: String, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        revokedCount = nil
        do {
            try await client.revokeLoginSession(userID: userID, sessionID: session.id)
            actionErrorMessage = nil
        } catch {
            setActionError(for: error, sessionState: sessionState, fallback: String(localized: "That sign-in couldn't be ended. Try again."))
        }
    }

    func revokeAllSessions(userID: String, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        revokedCount = nil
        do {
            revokedCount = try await client.revokeAllLoginSessions(userID: userID)
            actionErrorMessage = nil
        } catch {
            setActionError(for: error, sessionState: sessionState, fallback: String(localized: "The sign-ins couldn't be ended. Try again."))
        }
    }

    private func setActionError(for error: Error, sessionState: ServerScopedSession?, fallback: String) {
        actionErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
    }
}
