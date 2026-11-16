import Foundation

/// What step one learned about a server: enough to show its sign-in options and to sign in.
struct ServerDiscovery: Sendable, Equatable {
    let baseURL: URL
    let displayName: String
    /// `GET /api/v2/system/identity`; empty for a re-login that fell back to the password alone.
    let serverID: String
    let providers: AuthProviderCollection
}

/// Tokens from a finished sign-in. `providerID` is the provider to remember, nil for a password.
struct SignedIn: Sendable, Equatable {
    let accessToken: String
    let refreshToken: String
    let providerID: String?

    var credentials: ServerCredentials {
        ServerCredentials(version: ServerCredentials.currentVersion, accessToken: accessToken, refreshToken: refreshToken)
    }
}

/// Why discovery or a sign-in stopped. `message(providerName:)` is the only text anyone shows: raw
/// reasons from a redirect are never rendered.
enum SignInFailure: Error, Equatable, Sendable {
    case invalidAddress(ServerEndpointValidationError)
    case incompatibleServer
    case notAServer
    case clientUpgradeRequired
    case administratorRequired
    case api(APIError)
    case unreachable
    /// The person closed the browser: shows nothing.
    case cancelled
    /// The redirect or the redemption failed; the reason is a server reason code or `login_failed`.
    case oauthFailed(String)
    /// The redirect did not come from this server and sign-in.
    case oauthUntrusted
    case noBrowser
    case noSupportedSignIn

    func message(providerName: String?) -> String? {
        let provider = providerName ?? ""
        switch self {
        case .invalidAddress(let error): return error.localizedDescription
        case .incompatibleServer: return String(localized: "This server is not compatible with Bloem Admin.")
        case .notAServer: return String(localized: "That address isn't a Silo server. Check it and try again.")
        case .clientUpgradeRequired: return String(localized: "This server needs a newer version of Bloem Admin.")
        case .administratorRequired: return String(localized: "This account needs administrator access.")
        case .api(let error): return error.message
        case .unreachable: return String(localized: "Could not reach that server. Check the address, and that it uses https.")
        case .cancelled: return nil
        case .oauthUntrusted: return String(localized: "The sign-in response didn't come from this server. Try again.")
        case .noBrowser: return String(localized: "Install or turn on a web browser to sign in with \(provider).")
        case .noSupportedSignIn: return String(localized: "This server's sign-in options aren't available in this app.")
        case .oauthFailed(let reason):
            switch reason {
            case "not_permitted": return String(localized: "This account isn't allowed to sign in to this server.")
            case "account_required": return String(localized: "No account on this server uses that sign-in. Ask the server's owner for an invitation.")
            case "email_in_use": return String(localized: "An account with that email already exists. Sign in with its password instead.")
            case "identity_linked_elsewhere": return String(localized: "That sign-in is linked to a different account.")
            case "account_disabled": return String(localized: "This account is disabled.")
            case "provider_unavailable": return String(localized: "\(provider) isn't available right now. Try again later.")
            case "state_invalid", "session_expired": return String(localized: "The sign-in took too long or was interrupted. Try again.")
            default: return String(localized: "Sign-in didn't finish. Try again.")
            }
        }
    }

    /// Maps what a call threw. Cancellation stays a silent cancel.
    static func classify(_ error: Error) -> SignInFailure {
        if error is CancellationError { return .cancelled }
        if let failure = error as? SignInFailure { return failure }
        if let apiError = error as? APIError {
            if apiError.isClientUpgradeRequired { return .clientUpgradeRequired }
            return .api(apiError)
        }
        if error is DecodingError { return .notAServer }
        if (error as? URLError)?.code == .cancelled { return .cancelled }
        return .unreachable
    }
}

/// Server discovery and sign-in, shared by Add Server (first sign-in) and the re-login forms (after
/// a 401). Each function is a namespace-level static so the flows are directly testable.
enum AdminLogin {
    /// Step one: validates the address, then reads the server's name, identity and providers.
    static func discover(address: String, session: URLSession? = nil) async -> Result<ServerDiscovery, SignInFailure> {
        let baseURL: URL
        do {
            baseURL = try ServerEndpointValidator.validateTyped(address)
        } catch let error as ServerEndpointValidationError {
            return .failure(.invalidAddress(error))
        } catch {
            return .failure(.invalidAddress(.invalidURL))
        }
        do {
            let health = try await APIClient(baseURL: baseURL, accessToken: nil, session: session).health()
            let identity = try await readIdentityAndProviders(baseURL: baseURL, session: session)
            let name = health.serverName?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .success(ServerDiscovery(
                baseURL: baseURL,
                displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? (baseURL.host ?? address),
                serverID: identity.serverID,
                providers: identity.providers
            ))
        } catch {
            return .failure(SignInFailure.classify(error))
        }
    }

    /// Step one for re-login: reads the saved server's identity and providers. The saved name is kept
    /// and no health check is made. Upgrade-required is reported; any other failure of either call
    /// degrades to the password alone (no provider can start without an identity), as re-login
    /// always did.
    static func discoverForReLogin(server: AdminServer, session: URLSession? = nil) async -> Result<ServerDiscovery, SignInFailure> {
        do {
            let found = try await readIdentityAndProviders(baseURL: server.baseURL, session: session)
            return .success(ServerDiscovery(
                baseURL: server.baseURL,
                displayName: server.displayName,
                serverID: found.serverID,
                providers: found.providers
            ))
        } catch SignInFailure.clientUpgradeRequired {
            return .failure(.clientUpgradeRequired)
        } catch {
            return .success(passwordOnly(server))
        }
    }

    private static func passwordOnly(_ server: AdminServer) -> ServerDiscovery {
        ServerDiscovery(
            baseURL: server.baseURL,
            displayName: server.displayName,
            serverID: "",
            providers: AuthProviderCollection(passwordLogin: true, items: [])
        )
    }

    private static func readIdentityAndProviders(
        baseURL: URL,
        session: URLSession?
    ) async throws -> (serverID: String, providers: AuthProviderCollection) {
        do {
            let identity = try await AuthAPI.serverIdentity(baseURL: baseURL, session: session)
            let providers = try await AuthAPI.authProviders(baseURL: baseURL, session: session)
            let serverID = identity.serverID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !serverID.isEmpty else { throw SignInFailure.incompatibleServer }
            return (serverID, providers)
        } catch let error as APIError where error.isClientUpgradeRequired {
            throw SignInFailure.clientUpgradeRequired
        } catch let error as APIError where error.statusCode == 404 {
            throw SignInFailure.incompatibleServer
        }
    }

    /// Password sign-in. `probeAdmin` is false for re-login, which leaves the administrator check to
    /// the access gate as it always did.
    static func signInWithPassword(
        discovery: ServerDiscovery,
        username: String,
        password: String,
        probeAdmin: Bool = true,
        session: URLSession? = nil
    ) async -> Result<SignedIn, SignInFailure> {
        do {
            let response: TokenPair
            do {
                response = try await AuthAPI.login(baseURL: discovery.baseURL, username: username, password: password, session: session)
            } catch let error as APIError where error.statusCode == 404 {
                throw SignInFailure.incompatibleServer
            }
            if probeAdmin {
                try await probeAdministrator(baseURL: discovery.baseURL, accessToken: response.accessToken, session: session)
            }
            return .success(SignedIn(accessToken: response.accessToken, refreshToken: response.refreshToken, providerID: nil))
        } catch {
            return .failure(SignInFailure.classify(error))
        }
    }

    /// Signs in through `provider`'s browser flow. The verifier, the state, the code and the redirect
    /// never leave this function. A redirect that fails any check is never redeemed.
    @MainActor
    static func signInWithProvider(
        discovery: ServerDiscovery,
        provider: AuthProvider,
        browser: any OAuthBrowserSession,
        probeAdmin: Bool = true,
        now: @Sendable () -> Date = { Date() },
        session: URLSession? = nil
    ) async -> Result<SignedIn, SignInFailure> {
        guard provider.mode == "oauth", let nativeStartPath = provider.nativeStartPath, !discovery.serverID.isEmpty else {
            return .failure(.noSupportedSignIn)
        }
        let pkce: Pkce
        let appState: String
        let startURL: URL
        do {
            pkce = try Pkce.generate()
            appState = try OAuthRandom.appState()
            startURL = try OAuthStart.url(baseURL: discovery.baseURL, nativeStartPath: nativeStartPath, pkce: pkce, appState: appState)
        } catch {
            return .failure(.noSupportedSignIn)
        }
        let pending = PendingOAuth(
            issuer: OAuthIssuer.form(of: discovery.baseURL),
            serverID: discovery.serverID,
            providerID: provider.id,
            providerName: provider.displayName,
            pkce: pkce,
            appState: appState,
            startedAt: now()
        )

        let callback: URL
        switch await browser.authenticate(startURL: startURL, callbackScheme: OAuthRedirectSpec.scheme) {
        case .callback(let url): callback = url
        case .cancelled: return .failure(.cancelled)
        case .unavailable: return .failure(.noBrowser)
        case .failed: return .failure(.oauthFailed("login_failed"))
        }
        if Task.isCancelled { return .failure(.cancelled) }

        let code: String
        switch parseOAuthRedirect(callback.absoluteString, pending: pending) {
        case .untrusted: return .failure(.oauthUntrusted)
        case .failed(let reason):
            if now().timeIntervalSince(pending.startedAt) > PendingOAuth.lifetime { return .failure(.oauthFailed("session_expired")) }
            return .failure(.oauthFailed(reason))
        case .code(let value):
            if now().timeIntervalSince(pending.startedAt) > PendingOAuth.lifetime { return .failure(.oauthFailed("session_expired")) }
            code = value
        }

        do {
            let completion: OAuthCompletion
            do {
                completion = try await AuthAPI.completeOAuthLogin(
                    baseURL: discovery.baseURL, code: code, verifier: pkce.verifier, session: session
                )
            } catch let error as APIError where error.statusCode == 400 || error.statusCode == 401 {
                if Task.isCancelled { return .failure(.cancelled) }
                return .failure(.oauthFailed("login_failed"))
            } catch let error as APIError where error.statusCode == 404 {
                throw SignInFailure.incompatibleServer
            }
            if probeAdmin {
                try await probeAdministrator(baseURL: discovery.baseURL, accessToken: completion.accessToken, session: session)
            }
            return .success(SignedIn(accessToken: completion.accessToken, refreshToken: completion.refreshToken, providerID: provider.id))
        } catch {
            if Task.isCancelled { return .failure(.cancelled) }
            return .failure(SignInFailure.classify(error))
        }
    }

    /// A platform administrator passes on the admin status route (200). A 403 is not the end: an account
    /// that administers at least one organization (`GET /api/bloem/v2/organizations`, the same lookup
    /// `discoverAdminContexts` and the access gate use) may be added too, and the gate opens organization
    /// mode for it. Only an account with no admin context at all is refused. A failed lookup is reported
    /// as the failure it is, not taken as a refusal.
    private static func probeAdministrator(baseURL: URL, accessToken: String, session: URLSession?) async throws {
        let adminClient = APIClient(baseURL: baseURL, accessToken: accessToken, session: session)
        do {
            _ = try await adminClient.serverStatus()
        } catch let error as APIError where error.statusCode == 403 {
            guard try await adminClient.listAdminContexts(platformAdmin: false).isEmpty == false else {
                throw SignInFailure.administratorRequired
            }
        } catch let error as APIError where error.statusCode == 404 {
            throw SignInFailure.incompatibleServer
        }
    }

    /// Calls the unauthenticated `GET /api/v1/health` endpoint and returns a
    /// non-empty `server_name` if present. Returns nil on any failure
    /// (network error, non-2xx, absent/empty field) so callers can fall back
    /// to their existing URL-host display name without blocking on this.
    static func fetchServerName(baseURL: URL, session: URLSession? = nil) async -> String? {
        let client = APIClient(baseURL: baseURL, accessToken: nil, session: session)
        guard let health = try? await client.health() else { return nil }
        guard let name = health.serverName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return name
    }
}
