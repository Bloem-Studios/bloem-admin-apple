import SwiftUI
import Observation

@Observable
@MainActor
final class AdminGateViewModel {
    enum State {
        case checking
        case authorized
        case unauthorized
        /// The stored token was rejected as expired/invalid (401), distinct
        /// from `.unauthorized` (403, a valid-but-non-admin account) and from
        /// `.failed` (generic connectivity failure). The gate shows a
        /// re-login form instead of "Connection lost" in this state.
        case needsLogin
        case failed(String)
        /// Not a platform administrator, but administers these organizations: admitted to organization mode.
        /// `outcome` reads `.organizationOnly`, and `AdminGateView` shows the organization entry instead of the tabs.
        case organizationOnly([AdminContext])
    }

#if DEBUG
    static var forcesAuthorizedForUITests = false
#endif

    private(set) var state: State = .checking
    private(set) var outcome: AdminAccessOutcome = .checking
    private(set) var failure: ServerSectionFailure?
    private let session: URLSession
    private var accessInvocationID: UInt64 = 0

    private enum AuthenticationPrincipal: Equatable {
        case administrator
    }

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkAccess(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, isRetryAfterRefresh: Bool = false) async {
        let invocationID = beginAccessInvocation()
#if DEBUG
        // UI tests launch with servers that cannot be reached; this skips the probe so the signed-in
        // shell can be driven. Never set outside `--ui-testing-admin-gate=authorized`.
        if Self.forcesAuthorizedForUITests {
            outcome = .authorized
            failure = nil
            state = .authorized
            return
        }
#endif
        outcome = .checking
        failure = nil
        state = .checking
        store.seedAdministratorCredentialIfAbsent(in: sessionState, serverID: server.id)
        var canRefreshAdministrator = !isRetryAfterRefresh

        while true {
            guard isCurrentAccessInvocation(invocationID) else { return }
            let attemptCredential = sessionState.requestCredential(serverID: server.id)
            let client = APIClient(
                baseURL: server.baseURL,
                credentialProvider: { attemptCredential },
                session: session,
                bloemDetector: store.bloemDetector
            )
            do {
                _ = try await client.serverStatus()
                guard isCurrentAccessInvocation(invocationID) else { return }
                outcome = .authorized
                failure = nil
                state = .authorized
                return
            } catch let error as APIError where error.statusCode == 401 || error.statusCode == 403 {
                guard isCurrentAccessInvocation(invocationID) else { return }
                let failedPrincipal = currentAuthenticationPrincipal(
                    error,
                    serverID: server.id,
                    sessionState: sessionState
                )
                _ = sessionState.handleAuthenticationFailure(error)

                // Before giving up on a current administrator 401, try one
                // silent refresh. The loop bounds this retry without recursion.
                if error.statusCode == 401, failedPrincipal == .administrator, canRefreshAdministrator {
                    canRefreshAdministrator = false
                    if await attemptSilentRefresh(
                        server: server,
                        store: store,
                        sessionState: sessionState,
                        requiredAccessInvocationID: invocationID
                    ) {
                        guard isCurrentAccessInvocation(invocationID) else { return }
                        continue
                    }
                    guard isCurrentAccessInvocation(invocationID) else { return }
                }

                // A captured identity that is not the current one belongs to
                // an older session. It must not overwrite a newer check's UI.
                if error.requestIdentity != nil, failedPrincipal == nil {
                    return
                }

                // Refused as platform administrator: admitted when the account administers an organization.
                if error.statusCode == 403 {
                    await admitOrganizationAdministrator(
                        client: client, server: server, sessionState: sessionState,
                        refusal: error, invocationID: invocationID
                    )
                    return
                }

                recordFailure(ServerSectionFailure.classify(
                    error,
                    fallback: String(localized: "Could not verify administrator access.")
                ))
                return
            } catch let error as APIError {
                guard isCurrentAccessInvocation(invocationID) else { return }
                recordFailure(ServerSectionFailure.classify(
                    error,
                    fallback: String(localized: "Could not verify administrator access.")
                ))
                return
            } catch {
                guard isCurrentAccessInvocation(invocationID) else { return }
                recordFailure(ServerSectionFailure.classify(
                    error,
                    fallback: String(localized: "Could not reach \(server.displayName).")
                ))
                return
            }
        }
    }

    /// Attempts a single silent token refresh using this server's stored
    /// refresh token: on success, rewrites BOTH the access and (rotated)
    /// refresh token in the Keychain via `store.updateToken` and returns
    /// true; on any failure (no stored refresh token, or the refresh call
    /// itself failing/401-ing — `session_revoked` and `invalid_token` are
    /// handled identically here) returns false and touches nothing, leaving
    /// the caller to fall through to its existing re-login flow exactly as
    /// before this feature existed.
    func attemptSilentRefresh(
        server: AdminServer,
        store: ServerStore,
        sessionState: AdminSessionState,
        requiredAccessInvocationID: UInt64? = nil
    ) async -> Bool {
        let refreshSession = session
        let operationGeneration = sessionState.generation(for: server.id)
        let response = await sessionState.performSingleFlightRefresh(serverID: server.id) {
            // A widget may spend the same single-use refresh token: take the lock the widget takes, and first
            // adopt whatever it rotated.
            let held = await CredentialRefreshLock.appGroup().acquire()
            defer { held.release() }
            store.adoptWidgetRotation(for: server.id)
            guard let refreshToken = store.refreshToken(for: server.id) else { return nil }
            do {
                return try await AuthAPI.refresh(
                    baseURL: server.baseURL,
                    refreshToken: refreshToken,
                    session: refreshSession
                )
            } catch {
                return nil
            }
        }
        guard let response,
              !Task.isCancelled,
              requiredAccessInvocationID.map(isCurrentAccessInvocation) ?? true else { return false }

        if store.accessToken(for: server.id) == response.accessToken,
           store.refreshToken(for: server.id) == response.refreshToken,
           sessionState.requestCredential(serverID: server.id)?.accessToken == response.accessToken {
            return true
        }
        guard sessionState.generation(for: server.id) == operationGeneration else { return false }
        do {
            try store.updateToken(
                response.accessToken,
                refreshToken: response.refreshToken,
                forServerID: server.id
            )
            sessionState.setAdministratorToken(response.accessToken, serverID: server.id)
        } catch {
            return false
        }
        return true
    }

    /// Re-login from the `.needsLogin` state: logs in via the shared
    /// `AuthAPI.login` helper, rewrites the Keychain token for this
    /// server on success, then re-runs `checkAccess` so `state` reflects the
    /// fresh token. Kept on the view model (rather than inside ReLoginView)
    /// so it's directly testable, matching every other screen's
    /// view-stays-dumb / networking-lives-in-the-view-model split.
    /// Returns the APIError message on failure so the view can show it
    /// inline without re-deriving it from `state` (which doesn't carry a
    /// distinct "re-login failed" case).
    @discardableResult
    func reLogin(username: String, password: String, server: AdminServer, store: ServerStore, sessionState: AdminSessionState) async -> String? {
        let operationGeneration = sessionState.generation(for: server.id)
        do {
            let response = try await AuthAPI.login(baseURL: server.baseURL, username: username, password: password, session: session)
            return try await finishReLogin(
                SignedIn(accessToken: response.accessToken, refreshToken: response.refreshToken, providerID: nil),
                operationGeneration: operationGeneration,
                server: server,
                store: store,
                sessionState: sessionState
            )
        } catch is CancellationError {
            return String(localized: "Sign in was cancelled.")
        } catch let error as APIError {
            return error.message
        } catch {
            return String(localized: "Could not reach \(server.displayName).")
        }
    }

    enum ReLoginOutcome: Equatable {
        case signedIn
        /// The person closed the browser: nothing changed and nothing is shown.
        case cancelled
        case failed(String)
    }

    /// Re-login through a provider's browser sign-in. Tokens are stored exactly as a password re-login
    /// stores them and the provider is remembered; the admin check is the gate's own `checkAccess`
    /// that follows, so no extra probe runs here.
    func reLogin(
        provider: AuthProvider,
        discovery: ServerDiscovery,
        browser: any OAuthBrowserSession,
        server: AdminServer,
        store: ServerStore,
        sessionState: AdminSessionState,
        now: @Sendable () -> Date = { Date() }
    ) async -> ReLoginOutcome {
        let operationGeneration = sessionState.generation(for: server.id)
        let result = await AdminLogin.signInWithProvider(
            discovery: discovery,
            provider: provider,
            browser: browser,
            probeAdmin: false,
            now: now,
            session: session
        )
        switch result {
        case .failure(let failure):
            guard let message = failure.message(providerName: provider.displayName) else { return .cancelled }
            return .failed(message)
        case .success(let signedIn):
            do {
                if let message = try await finishReLogin(
                    signedIn,
                    operationGeneration: operationGeneration,
                    server: server,
                    store: store,
                    sessionState: sessionState
                ) {
                    return .failed(message)
                }
                return .signedIn
            } catch {
                return .failed(String(localized: "Could not reach \(server.displayName)."))
            }
        }
    }

    /// Stores the replacement tokens, publishes them to the runtime session, records (or clears) the
    /// provider and re-runs the access check. Returns an error message, or nil on success.
    private func finishReLogin(
        _ signedIn: SignedIn,
        operationGeneration: UInt64,
        server: AdminServer,
        store: ServerStore,
        sessionState: AdminSessionState
    ) async throws -> String? {
        guard !Task.isCancelled else { return String(localized: "Sign in was cancelled.") }
        guard sessionState.generation(for: server.id) == operationGeneration else {
            return String(localized: "Session changed before sign in completed.")
        }
        try store.updateToken(signedIn.accessToken, refreshToken: signedIn.refreshToken, forServerID: server.id)
        // Push registers again for whoever just signed in.
        store.noteInteractiveSignIn(serverID: server.id)
        // Not a secret and not needed to sign in: a failed write only costs the list order next time.
        try? store.setSignInProvider(signedIn.providerID, forServerID: server.id)
        sessionState.setAdministratorToken(signedIn.accessToken, serverID: server.id)
        await checkAccess(server: server, store: store, sessionState: sessionState)
        return nil
    }

    /// Shared re-login entry point used by the single-server and aggregate
    /// forms. `reLogin` persists the replacement credential and publishes
    /// it to the runtime session before rechecking access.
    @discardableResult
    func reLoginAndResetSession(username: String, password: String, server: AdminServer, store: ServerStore, sessionState: AdminSessionState) async -> String? {
        await reLogin(
            username: username,
            password: password,
            server: server,
            store: store,
            sessionState: sessionState
        )
    }

    /// The 403 on the platform probe is not the end: an account that administers at least one organization is
    /// admitted into organization mode (the web does the same: Platform only for a platform administrator,
    /// otherwise each organization whose membership role is `admin`). An account that administers nothing, or on a
    /// server that has no organizations (404), keeps today's "No Admin Access". An expired sign-in found on the way
    /// goes to re-login, and an unreachable or unreadable lookup is a failure to show, not a refusal (as on Android).
    private func admitOrganizationAdministrator(
        client: APIClient,
        server: AdminServer,
        sessionState: AdminSessionState,
        refusal: APIError,
        invocationID: UInt64
    ) async {
        do {
            let contexts = try await client.listAdminContexts(platformAdmin: false)
            guard isCurrentAccessInvocation(invocationID) else { return }
            if contexts.isEmpty {
                recordFailure(ServerSectionFailure.classify(
                    refusal, fallback: String(localized: "Could not verify administrator access.")
                ))
            } else {
                outcome = .organizationOnly
                failure = nil
                state = .organizationOnly(contexts)
            }
        } catch {
            guard isCurrentAccessInvocation(invocationID) else { return }
            if let apiError = error as? APIError, apiError.statusCode == 401 || apiError.statusCode == 403 {
                _ = sessionState.handleAuthenticationFailure(apiError)
            }
            recordFailure(ServerSectionFailure.classify(
                error, fallback: String(localized: "Could not reach \(server.displayName).")
            ))
        }
    }

    /// The gate checks access each time it appears, except once an organization has been admitted: the organization's
    /// pages push onto the server list's stack and cover the gate, and checking again when one is closed would throw
    /// the open organization away. Leaving to the server list and coming back builds a new gate, which checks.
    var shouldCheckAccessOnAppear: Bool {
        if case .organizationOnly = state { return false }
        return true
    }

    private func isCurrentAdministratorFailure(
        _ error: APIError,
        serverID: String,
        sessionState: AdminSessionState
    ) -> Bool {
        guard let identity = error.requestIdentity,
              identity.serverID == serverID,
              identity.generation == sessionState.generation(for: serverID),
              case .administrator = identity.principal else { return false }
        return sessionState.requestCredential(serverID: serverID)?.identity == identity
    }

    private func currentAuthenticationPrincipal(
        _ error: APIError,
        serverID: String,
        sessionState: AdminSessionState
    ) -> AuthenticationPrincipal? {
        guard error.statusCode == 401 || error.statusCode == 403 else { return nil }
        if isCurrentAdministratorFailure(error, serverID: serverID, sessionState: sessionState) {
            return .administrator
        }
        return nil
    }

    private func beginAccessInvocation() -> UInt64 {
        precondition(accessInvocationID < UInt64.max, "Admin Gate access invocation exhausted")
        accessInvocationID += 1
        return accessInvocationID
    }

    private func isCurrentAccessInvocation(_ invocationID: UInt64) -> Bool {
        accessInvocationID == invocationID
    }

    private func recordFailure(_ failure: ServerSectionFailure) {
        self.failure = failure
        outcome = failure.outcome
        switch failure.kind {
        case .signedOut:
            state = .needsLogin
        case .forbidden:
            state = .unauthorized
        case .connectivity, .incompatibleResponse, .serverFailure:
            state = .failed(failure.message)
        }
    }

}

/// Checks that the signed-in account may administer `server` before showing its pages. While it checks, and
/// when it cannot let the person in (signed out, no admin access, unreachable), it shows a screen with the
/// shell's top bar (title and context dropdown, no menu). Once access is confirmed it shows `authorized`.
struct AdminGateView<Authorized: View>: View {
    let server: AdminServer
    let store: ServerStore
    let sessionState: AdminSessionState
    @ViewBuilder let authorized: () -> Authorized
    @State private var viewModel = AdminGateViewModel()

    init(
        server: AdminServer,
        store: ServerStore,
        sessionState: AdminSessionState,
        @ViewBuilder authorized: @escaping () -> Authorized
    ) {
        self.server = server
        self.store = store
        self.sessionState = sessionState
        self.authorized = authorized
        store.seedAdministratorCredentialIfAbsent(in: sessionState, serverID: server.id)
    }

    private var retryButton: some View {
        Button("Try again") {
            Task { await viewModel.checkAccess(server: server, store: store, sessionState: sessionState) }
        }
        .buttonStyle(.bloemProminent)
    }

    var body: some View {
        Group {
            // A current-generation administrator 401 from any page routes to
            // the same re-login form as the initial gate check. This is
            // checked ahead of `state`, which remains `.authorized` while a
            // mid-session request invalidates the credential.
            if sessionState.isTokenExpired(for: server.id) {
                PreNavigationScreen(title: String(localized: "Sign in")) {
                    ReLoginView(server: server, store: store, viewModel: viewModel, sessionState: sessionState)
                }
                // Try one silent refresh before requiring credentials.
                // Success persists and publishes a replacement token,
                // clearing the expired state in the same main-actor turn.
                .task(id: server.id) {
                    _ = await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: sessionState)
                }
            } else {
                switch viewModel.outcome {
                case .checking:
                    PreNavigationScreen(title: String(localized: "Checking access")) {
                        ProgressView("Checking access…")
                    }
                case .authorized:
                    authorized()
                case .organizationOnly:
                    if case .organizationOnly(let contexts) = viewModel.state {
                        // The shell's bar and context dropdown over the organization's own menu; its pages
                        // push onto this stack (`usesEnclosingNavigationStack`), the layout its UI test pins.
                        PreNavigationScreen(title: server.displayName) {
                            OrganizationAdmissionView(
                                server: server, store: store, sessionState: sessionState, contexts: contexts
                            )
                        }
                    }
                case .forbidden:
                    PreNavigationScreen(title: String(localized: "No access")) {
                        VStack(spacing: 16) {
                            BloemEmptyState(
                                "No Admin Access",
                                icon: .lock,
                                description: Text("This account doesn't have admin access on \(server.displayName).")
                            )
                            retryButton
                        }
                    }
                case .signedOut:
                    PreNavigationScreen(title: String(localized: "Sign in")) {
                        ReLoginView(server: server, store: store, viewModel: viewModel, sessionState: sessionState)
                    }
                case .connectivity, .incompatibleResponse, .serverFailure:
                    PreNavigationScreen(title: String(localized: "Can't reach server")) {
                        VStack(spacing: 16) {
                            BloemEmptyState(
                                viewModel.outcome == .incompatibleResponse ? "Incompatible Server Response" : "Connection lost",
                                icon: viewModel.outcome == .incompatibleResponse ? .unplug : .wifiOff,
                                description: Text(viewModel.failure?.message ?? String(localized: "Could not verify administrator access."))
                            )
                            retryButton
                        }
                    }
                }
            }
        }
        .task {
            guard viewModel.shouldCheckAccessOnAppear else { return }
            await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        }
    }
}


/// Re-login form shown when AdminGateViewModel lands in `.needsLogin` (a 401
/// on the status probe, i.e. an expired/invalid token). The networking
/// (login + token rewrite + re-check) lives on `AdminGateViewModel.reLogin`,
/// and the sign-in options in `ReLoginSections` — this view only frames them.
private struct ReLoginView: View {
    let server: AdminServer
    let store: ServerStore
    let viewModel: AdminGateViewModel
    let sessionState: AdminSessionState

    var body: some View {
        Form {
            Section {
                Text("Your session on \(server.displayName) has expired. Sign in again to continue.")
                    .foregroundStyle(.bloemMuted)
            }
            ReLoginSections(server: server, store: store, viewModel: viewModel, sessionState: sessionState)
        }
    }
}
