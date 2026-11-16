import XCTest
@testable import BloemAdmin

/// Covers Feature 2 (runtime branding via GET /api/v1/health): success sets
/// a display name from `server_name`, failure/absence falls back to nil so
/// the caller (AddServerView.connect) can fall back to the URL host itself.
final class AdminLoginTests: XCTestCase {
    static var statusFixture: [String: Any] { [
            "started_at": "2026-01-01T00:00:00Z",
            "restart_required": false,
            "restart_mark_count": 0,
            "restart_requested": false,
            "health": [
                "postgres": ["configured": true, "ok": true],
                "redis": ["configured": true, "ok": true],
                "errors_24h": 0,
                "warnings_24h": 0,
            ],
            "artwork_storage": ["locked": false, "status_known": true, "private_locked": false],
        ] }

    func testLoginDecodesTokenPairAndSendsCredentialsWithoutAuthorization() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/auth/login", json: Self.loginFixture)

        let pair = try await AuthAPI.login(
            baseURL: URL(string: "https://example.test")!,
            username: "admin",
            password: "secret",
            session: http.session
        )

        XCTAssertEqual(pair.accessToken, "access")
        XCTAssertEqual(pair.refreshToken, "refresh")
        XCTAssertEqual(pair.expiresIn, 3600)
        XCTAssertEqual(pair.user.id, "1")
        XCTAssertFalse(pair.user.passwordChangeRequired)
        let request = http.state.requests(path: "/api/v2/auth/login").first
        XCTAssertEqual(request?.httpMethod, "POST")
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        let sent = try JSONSerialization.jsonObject(with: http.state.body(path: "/api/v2/auth/login", requestIndex: 0) ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["username"] as? String, "admin")
        XCTAssertEqual(sent?["password"] as? String, "secret")
    }

    func testHealthAndStatusUseTheirPaths() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v1/health", json: ["status": "ok", "server_name": "N", "server_id": "id"])
        http.state.stub(path: "/api/v2/admin/server/status", json: Self.statusFixture)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)

        let health = try await client.health()
        let status = try await client.serverStatus()

        XCTAssertEqual(health.serverID, "id")
        XCTAssertEqual(status.startedAt, "2026-01-01T00:00:00Z")
        XCTAssertFalse(status.restartRequired)
    }

    static var loginFixture: [String: Any] { [
        "access_token": "access",
        "refresh_token": "refresh",
        "expires_in": 3600,
        "user": [
            "id": "1",
            "username": "admin",
            "email": "admin@example.test",
            "role": "admin",
            "permissions": [String](),
            "download_allowed": true,
            "password_change_required": false,
        ] as [String: Any],
    ] }

    func testLoginAndRefreshNeverSendIdempotencyKeys() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.pathOverrides = [
            "/api/v2/auth/login": (
                Data(#"{"access_token":"access","refresh_token":"refresh","expires_in":3600,"user":{"id":"1","username":"admin","email":"admin@example.test","role":"admin","permissions":[],"download_allowed":true,"password_change_required":false}}"#.utf8),
                200
            ),
            "/api/v2/auth/refresh": (
                Data(#"{"access_token":"next-access","refresh_token":"next-refresh","expires_in":3600}"#.utf8),
                200
            ),
        ]
        let baseURL = URL(string: "https://example.test")!

        _ = try await AuthAPI.login(
            baseURL: baseURL,
            username: "admin",
            password: "secret",
            session: http.session
        )
        _ = try await AuthAPI.refresh(
            baseURL: baseURL,
            refreshToken: "refresh",
            session: http.session
        )

        XCTAssertNil(http.state.requests(path: "/api/v2/auth/login").first?.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNil(http.state.requests(path: "/api/v2/auth/refresh").first?.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testFetchServerNameReturnsNameOnSuccess() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"status":"ok","server_name":"Home-Server","server_id":"b2d9e6c9-abc"}"#.utf8)
        http.state.responseStatus = 200

        let name = await AdminLogin.fetchServerName(baseURL: URL(string: "https://example.test")!, session: session)

        XCTAssertEqual(name, "Home-Server")
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v1/health")
        // The health endpoint is public — no Authorization header should be sent.
        XCTAssertNil(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testFetchServerNameReturnsNilWhenFieldAbsent() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"status":"ok"}"#.utf8)
        http.state.responseStatus = 200

        let name = await AdminLogin.fetchServerName(baseURL: URL(string: "https://example.test")!, session: session)

        XCTAssertNil(name)
    }

    /// Whitespace-only names (e.g. a single space) must not pass as a real
    /// display name — the field is technically present and non-empty by
    /// `String.isEmpty`, but has nothing meaningful to show.
    func testFetchServerNameReturnsNilWhenWhitespaceOnly() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"status":"ok","server_name":"   "}"#.utf8)
        http.state.responseStatus = 200

        let name = await AdminLogin.fetchServerName(baseURL: URL(string: "https://example.test")!, session: session)

        XCTAssertNil(name)
    }

    func testFetchServerNameReturnsNilOnFailure() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"not_found","message":"no such route"}"#.utf8)
        http.state.responseStatus = 404

        let name = await AdminLogin.fetchServerName(baseURL: URL(string: "https://example.test")!, session: session)

        XCTAssertNil(name)
    }

    // MARK: - refresh (Refresh-token support)

    /// Covers the refresh call's request/response shape: the outgoing body
    /// is `{"refresh_token": "..."}` (snake_case), unauthenticated (no
    /// Authorization header — refresh IS the credential), and a successful
    /// response decodes the new (rotated) access + refresh tokens.
    func testRefreshSendsRefreshTokenAndDecodesRotatedTokens() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
        http.state.responseStatus = 200

        let response = try await AuthAPI.refresh(baseURL: URL(string: "https://example.test")!, refreshToken: "old-refresh", session: session)

        XCTAssertEqual(response.accessToken, "new-access")
        XCTAssertEqual(response.refreshToken, "new-refresh")
        XCTAssertEqual(response.expiresIn, 3600)
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/auth/refresh")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
        XCTAssertNil(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"))

        let sentBody = try JSONSerialization.jsonObject(with: http.state.capturedBody ?? Data()) as? [String: Any]
        XCTAssertEqual(sentBody?["refresh_token"] as? String, "old-refresh")
    }

    /// Both documented failure shapes (`session_revoked`, `invalid_token`)
    /// are functionally identical for this app — refresh failed, the caller
    /// falls through to re-login — so this just confirms both surface as a
    /// thrown `APIError` with the 401 status intact.
    func testRefreshThrowsAPIErrorOnSessionRevoked() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"session_revoked","message":"Session was revoked"}"#.utf8)
        http.state.responseStatus = 401

        do {
            _ = try await AuthAPI.refresh(baseURL: URL(string: "https://example.test")!, refreshToken: "old-refresh", session: session)
            XCTFail("expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testRefreshProblemJSONUnauthorizedSurfacesAs401() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/api/v2/auth/refresh",
            json: ["type": "https://api.bloem.test/problems/invalid-token", "title": "Unauthorized", "status": 401, "detail": "Token expired"],
            status: 401
        )
        do {
            _ = try await AuthAPI.refresh(baseURL: URL(string: "https://example.test")!, refreshToken: "old", session: http.session)
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testRefreshThrowsAPIErrorOnInvalidToken() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired or malformed"}"#.utf8)
        http.state.responseStatus = 401

        do {
            _ = try await AuthAPI.refresh(baseURL: URL(string: "https://example.test")!, refreshToken: "old-refresh", session: session)
            XCTFail("expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }
}

// MARK: - OAuth/OIDC sign-in

/// A browser that answers from a closure: a callback URL, a cancel or an error.
@MainActor
final class FakeOAuthBrowser: OAuthBrowserSession {
    private(set) var startURLs: [URL] = []
    private(set) var cancelCount = 0
    var respond: (URL) -> OAuthBrowserOutcome

    init(respond: @escaping (URL) -> OAuthBrowserOutcome) {
        self.respond = respond
    }

    func authenticate(startURL: URL, callbackScheme: String) async -> OAuthBrowserOutcome {
        XCTAssertEqual(callbackScheme, "org.siloserver.silo")
        startURLs.append(startURL)
        return respond(startURL)
    }

    func cancel() { cancelCount += 1 }

    /// A redirect the way the server sends it for `startURL`'s `app_state`.
    static func redirect(
        for startURL: URL,
        code: String? = "auth-code",
        state: String? = nil,
        server: String? = "srv-1",
        iss: String? = "https://example.test",
        error: String? = nil
    ) -> OAuthBrowserOutcome {
        let appState = URLComponents(url: startURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "app_state" }?.value
        var items: [URLQueryItem] = []
        if let code { items.append(URLQueryItem(name: "code", value: code)) }
        if let error { items.append(URLQueryItem(name: "error", value: error)) }
        if let value = state ?? appState { items.append(URLQueryItem(name: "state", value: value)) }
        if let server { items.append(URLQueryItem(name: "server", value: server)) }
        if let iss { items.append(URLQueryItem(name: "iss", value: iss)) }
        var components = URLComponents()
        components.scheme = "org.siloserver.silo"
        components.path = "/auth/callback"
        components.queryItems = items
        return .callback(components.url!)
    }
}

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { current = start }

    func now() -> Date { lock.withLock { current } }
    func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@MainActor
final class AdminLoginOAuthTests: XCTestCase {
    private let baseURL = URL(string: "https://example.test")!

    static let providersFixture: [String: Any] = [
        "password_login": true,
        "items": [
            ["id": "local", "display_name": "Silo account", "mode": "credentials", "default": true] as [String: Any],
            [
                "id": "26", "display_name": "Corp SSO", "mode": "oauth", "default": false,
                "installation_id": "3", "icon_url": "https://plugins.example.test/icon.svg",
                "native_start_path": "/api/v2/auth/oauth/3/native/start",
            ] as [String: Any],
            [
                "id": "27", "display_name": "Home Server Portal Login", "mode": "oauth", "default": false,
                "installation_id": "4", "native_start_path": "/api/v2/auth/oauth/4/native/start",
            ] as [String: Any],
            ["id": "28", "display_name": "No native", "mode": "oauth", "default": false, "installation_id": "5"] as [String: Any],
            [
                "id": "net", "display_name": "Home network", "mode": "network", "default": false,
                "network_sign_in_path": "/api/v2/auth/network/5/sign-in",
                "network_identity": ["display_name": "Alex", "username": "alex"] as [String: Any],
            ] as [String: Any],
        ] as [Any],
        "page": ["has_more": false] as [String: Any],
    ]

    private static var completionFixture: [String: Any] { [
        "access_token": "oauth-access",
        "refresh_token": "oauth-refresh",
        "expires_in": 3600,
        "next": "/",
        "user": AdminLoginTests.loginFixture["user"] as Any,
    ] }

    private func upgradeProblem() -> [String: Any] {
        ["error": "client_upgrade_required", "message": "Upgrade", "code": "client_upgrade_required"]
    }

    private func makeHarness(
        providers: [String: Any] = AdminLoginOAuthTests.providersFixture,
        identity: String = "srv-1"
    ) -> MockHTTPHarness {
        let http = MockHTTPHarness()
        http.state.stub(path: "/api/v1/health", json: ["status": "ok", "server_name": "Home Server"])
        http.state.stub(path: "/api/v2/system/identity", json: ["server_id": identity])
        http.state.stub(path: "/api/v2/auth/providers", json: providers)
        http.state.stub(path: "/api/v2/auth/oauth/complete", json: Self.completionFixture)
        http.state.stub(path: "/api/v2/auth/login", json: AdminLoginTests.loginFixture)
        http.state.stub(path: "/api/v2/admin/server/status", json: AdminLoginTests.statusFixture)
        return http
    }

    private func discovery(
        serverID: String = "srv-1",
        providers: [String: Any] = AdminLoginOAuthTests.providersFixture
    ) throws -> ServerDiscovery {
        let data = try JSONSerialization.data(withJSONObject: providers)
        return ServerDiscovery(
            baseURL: baseURL,
            displayName: "Home Server",
            serverID: serverID,
            providers: try JSONDecoder().decode(AuthProviderCollection.self, from: data)
        )
    }

    private func provider(_ id: String = "26") throws -> AuthProvider {
        try XCTUnwrap(try discovery().providers.items.first { $0.id == id })
    }

    private func signIn(
        _ http: MockHTTPHarness,
        provider id: String = "26",
        probeAdmin: Bool = true,
        clock: TestClock = TestClock(),
        browser: FakeOAuthBrowser
    ) async throws -> Result<SignedIn, SignInFailure> {
        await AdminLogin.signInWithProvider(
            discovery: try discovery(),
            provider: try provider(id),
            browser: browser,
            probeAdmin: probeAdmin,
            now: { clock.now() },
            session: http.session
        )
    }

    // MARK: Decoding and ordering

    func testProvidersDecodeEveryContractFieldAndOnlyNativeOAuthIsOffered() throws {
        let value = try discovery()
        XCTAssertTrue(value.providers.passwordLogin)
        XCTAssertEqual(value.providers.items.count, 5)
        let sso = try provider("26")
        XCTAssertEqual(sso.installationID, "3")
        XCTAssertEqual(sso.nativeStartPath, "/api/v2/auth/oauth/3/native/start")
        XCTAssertEqual(value.providers.nativeOAuth.map(\.id), ["26", "27"])
    }

    func testDefaultOAuthProviderComesFirstAndRememberedOneBeatsIt() throws {
        var fixture = Self.providersFixture
        var items = fixture["items"] as! [[String: Any]]
        items[2]["default"] = true
        fixture["items"] = items
        let value = try discovery(providers: fixture)
        XCTAssertEqual(value.providers.nativeOAuth.map(\.id), ["27", "26"])
        XCTAssertEqual(value.providers.nativeOAuth(remembered: "26").map(\.id), ["26", "27"])
        XCTAssertEqual(value.providers.nativeOAuth(remembered: "gone").map(\.id), ["27", "26"])
        XCTAssertEqual(value.providers.nativeOAuth(remembered: nil).map(\.id), ["27", "26"])
        XCTAssertEqual(value.providers.nativeOAuth(remembered: "local").map(\.id), ["27", "26"])
    }

    /// Maintainer, 2026-11-16: Authentik first in every app, whether or not the server marks it as its default.
    func testAuthentikComesFirstWhateverTheServerSendsAndEvenARememberedOtherProviderFollowsIt() throws {
        var fixture = Self.providersFixture
        var items = fixture["items"] as! [[String: Any]]
        items[2]["default"] = true  // "Home Server Portal Login" is the server's default...
        items.append([
            "id": "29", "display_name": "Authentik", "mode": "oauth", "default": false,
            "installation_id": "6", "native_start_path": "/api/v2/auth/oauth/6/native/start",
        ])  // ...and Authentik is last, and not the default.
        fixture["items"] = items
        let value = try discovery(providers: fixture)

        XCTAssertEqual(value.providers.nativeOAuth.map(\.id), ["29", "27", "26"], "Authentik, then the default, then the rest")
        XCTAssertTrue(try XCTUnwrap(value.providers.items.first { $0.id == "29" }).isAuthentik)
        XCTAssertFalse(try provider("26").isAuthentik)
        XCTAssertEqual(value.providers.nativeOAuth(remembered: "26").map(\.id), ["29", "26", "27"], "Authentik leads, then the one used last")
        XCTAssertEqual(value.providers.nativeOAuth(remembered: "29").map(\.id), ["29", "27", "26"], "Authentik used last is still first")
        XCTAssertEqual(value.providers.nativeOAuth(remembered: nil).map(\.id), ["29", "27", "26"])
    }

    func testAnAuthentikProviderIsRecognisedByItsIdOrItsNameInAnyCase() throws {
        var fixture = Self.providersFixture
        var items = fixture["items"] as! [[String: Any]]
        items[1]["display_name"] = "Staff sign-in"
        items[1]["id"] = "Authentik-prod"
        items[2]["display_name"] = "AUTHENTIK partners"
        fixture["items"] = items
        let value = try discovery(providers: fixture)

        XCTAssertEqual(value.providers.nativeOAuth.map(\.id), ["Authentik-prod", "27"], "both count; the server's order holds between them")
        XCTAssertTrue(value.providers.nativeOAuth.allSatisfy(\.isAuthentik))
    }

    func testIdentityAndCompletionDecodeTheirSchemas() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let identity = try await AuthAPI.serverIdentity(baseURL: baseURL, session: http.session)
        XCTAssertEqual(identity.serverID, "srv-1")
        let completion = try await AuthAPI.completeOAuthLogin(baseURL: baseURL, code: "c", verifier: "v", session: http.session)
        XCTAssertEqual(completion.accessToken, "oauth-access")
        XCTAssertEqual(completion.refreshToken, "oauth-refresh")
        XCTAssertEqual(completion.next, "/")
        XCTAssertEqual(completion.user.username, "admin")
        let sent = try JSONSerialization.jsonObject(with: try XCTUnwrap(http.state.body(path: "/api/v2/auth/oauth/complete", requestIndex: 0))) as? [String: Any]
        XCTAssertEqual(sent?["code"] as? String, "c")
        XCTAssertEqual(sent?["code_verifier"] as? String, "v")
        for path in ["/api/v2/system/identity", "/api/v2/auth/oauth/complete"] {
            XCTAssertNil(http.state.requests(path: path).first?.value(forHTTPHeaderField: "Authorization"))
        }
    }

    // MARK: Discovery

    func testDiscoverReadsHealthIdentityAndProvidersWithoutAToken() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let result = await AdminLogin.discover(address: "https://Example.test/", session: http.session)
        let found = try result.get()
        XCTAssertEqual(found.baseURL, baseURL)
        XCTAssertEqual(found.displayName, "Home Server")
        XCTAssertEqual(found.serverID, "srv-1")
        XCTAssertEqual(found.providers.nativeOAuth.map(\.id), ["26", "27"])
        XCTAssertEqual(
            http.state.requestLog.compactMap(\.url?.path),
            ["/api/v1/health", "/api/v2/system/identity", "/api/v2/auth/providers"]
        )
        XCTAssertTrue(http.state.requestLog.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
    }

    func testDiscoverAssumesHTTPSForATypedHostWithoutAScheme() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let found = try await AdminLogin.discover(address: "example.test", session: http.session).get()
        XCTAssertEqual(found.baseURL.absoluteString, "https://example.test")
    }

    func testDiscoverFallsBackToTheHostWhenTheServerHasNoName() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v1/health", json: ["status": "ok", "server_name": "  "])
        let found = try await AdminLogin.discover(address: "https://example.test", session: http.session).get()
        XCTAssertEqual(found.displayName, "example.test")
    }

    func testDiscoverRejectsAnUnsafeAddressBeforeAnyRequest() async {
        let http = makeHarness()
        defer { http.invalidate() }
        for address in ["", "http://example.test", "https://example.test/path", "https://user@example.test"] {
            let result = await AdminLogin.discover(address: address, session: http.session)
            guard case .failure(.invalidAddress) = result else { return XCTFail("\(address) -> \(result)") }
        }
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testDiscoverMapsMissingRoutesUpgradeAndNonServers() async {
        let http = makeHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/system/identity", json: ["type": "https://api.bloem.test/problems/not-found", "title": "Not Found", "status": 404, "detail": "no route"], status: 404)
        var result = await AdminLogin.discover(address: "https://example.test", session: http.session)
        XCTAssertEqual(result.failureValue, .incompatibleServer)

        http.state.stub(path: "/api/v2/system/identity", json: ["server_id": "srv-1"])
        http.state.stub(path: "/api/v2/auth/providers", json: upgradeProblem(), status: 410)
        result = await AdminLogin.discover(address: "https://example.test", session: http.session)
        XCTAssertEqual(result.failureValue, .clientUpgradeRequired)

        http.state.stub(path: "/api/v2/auth/providers", json: ["unexpected": true])
        result = await AdminLogin.discover(address: "https://example.test", session: http.session)
        XCTAssertEqual(result.failureValue, .notAServer)

        http.state.stub(path: "/api/v2/auth/providers", json: Self.providersFixture)
        http.state.stub(path: "/api/v2/system/identity", json: ["server_id": "   "])
        result = await AdminLogin.discover(address: "https://example.test", session: http.session)
        XCTAssertEqual(result.failureValue, .incompatibleServer)
    }

    func testReLoginDiscoveryReadsIdentityAndProvidersOnlyAndKeepsTheSavedName() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let server = AdminServer(id: "s", baseURL: baseURL, displayName: "Saved name")
        let found = try await AdminLogin.discoverForReLogin(server: server, session: http.session).get()
        XCTAssertEqual(found.displayName, "Saved name")
        XCTAssertEqual(found.serverID, "srv-1")
        XCTAssertEqual(http.state.requestLog.compactMap(\.url?.path), ["/api/v2/system/identity", "/api/v2/auth/providers"])
    }

    func testReLoginDiscoveryReportsUpgradeRequiredFromIdentityOrProviders() async {
        let server = AdminServer(id: "s", baseURL: baseURL, displayName: "Saved name")
        for path in ["/api/v2/system/identity", "/api/v2/auth/providers"] {
            let http = makeHarness()
            defer { http.invalidate() }
            http.state.stub(path: path, json: upgradeProblem(), status: 410)
            let result = await AdminLogin.discoverForReLogin(server: server, session: http.session)
            XCTAssertEqual(result.failureValue, .clientUpgradeRequired, path)
        }
    }

    func testReLoginDiscoveryDegradesToPasswordOnlyOnAnyOtherFailure() async throws {
        let server = AdminServer(id: "s", baseURL: baseURL, displayName: "Saved name")
        for path in ["/api/v2/system/identity", "/api/v2/auth/providers"] {
            for status in [404, 500, 401] {
                let http = makeHarness()
                defer { http.invalidate() }
                http.state.stub(path: path, json: ["error": "nope", "message": "No"], status: status)
                let found = try await AdminLogin.discoverForReLogin(server: server, session: http.session).get()
                XCTAssertTrue(found.providers.passwordLogin, "\(path) \(status)")
                XCTAssertTrue(found.providers.items.isEmpty)
                XCTAssertEqual(found.displayName, "Saved name")
            }
        }
        let http = makeHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/auth/providers", json: ["unexpected": true])
        let decoded = try await AdminLogin.discoverForReLogin(server: server, session: http.session).get()
        XCTAssertTrue(decoded.providers.items.isEmpty)
    }

    // MARK: Password

    func testPasswordSignInProbesAdministratorStatusAndLeavesTheProviderEmpty() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let signedIn = try await AdminLogin.signInWithPassword(
            discovery: discovery(), username: "admin", password: "secret", session: http.session
        ).get()
        XCTAssertEqual(signedIn.accessToken, "access")
        XCTAssertEqual(signedIn.refreshToken, "refresh")
        XCTAssertNil(signedIn.providerID)
        XCTAssertEqual(http.state.requestLog.compactMap(\.url?.path), ["/api/v2/auth/login", "/api/v2/admin/server/status"])
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/server/status").first?.value(forHTTPHeaderField: "Authorization"), "Bearer access")
    }

    func testPasswordSignInSkipsTheProbeForReLogin() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        _ = try await AdminLogin.signInWithPassword(
            discovery: discovery(), username: "admin", password: "secret", probeAdmin: false, session: http.session
        ).get()
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/server/status").isEmpty)
    }

    func testPasswordSignInFailuresKeepTheirMapping() async throws {
        let problem: (Int, String) -> [String: Any] = { ["type": "https://api.bloem.test/problems/x", "title": "T", "status": $0, "detail": $1] }
        let http = makeHarness()
        defer { http.invalidate() }
        let value = try discovery()

        http.state.stub(path: "/api/v2/auth/login", json: problem(401, "Invalid username or password"), status: 401)
        var result = await AdminLogin.signInWithPassword(discovery: value, username: "a", password: "b", session: http.session)
        XCTAssertEqual(result.failureValue, .api(APIError(statusCode: 401, code: "x", message: "Invalid username or password")))

        http.state.stub(path: "/api/v2/auth/login", json: problem(404, "no route"), status: 404)
        result = await AdminLogin.signInWithPassword(discovery: value, username: "a", password: "b", session: http.session)
        XCTAssertEqual(result.failureValue, .incompatibleServer)

        http.state.stub(path: "/api/v2/auth/login", json: AdminLoginTests.loginFixture)
        http.state.stub(path: "/api/v2/admin/server/status", json: problem(403, "Administrator access required"), status: 403)
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", json: problem(404, "no route"), status: 404)
        result = await AdminLogin.signInWithPassword(discovery: value, username: "a", password: "b", session: http.session)
        XCTAssertEqual(result.failureValue, .administratorRequired)

        http.state.stub(path: "/api/v2/admin/server/status", json: problem(404, "no route"), status: 404)
        result = await AdminLogin.signInWithPassword(discovery: value, username: "a", password: "b", session: http.session)
        XCTAssertEqual(result.failureValue, .incompatibleServer)

        http.state.stub(path: "/api/v2/admin/server/status", json: problem(500, "boom"), status: 500)
        result = await AdminLogin.signInWithPassword(discovery: value, username: "a", password: "b", session: http.session)
        guard case .api(let error)? = result.failureValue else { return XCTFail("\(result)") }
        XCTAssertEqual(error.statusCode, 500)
    }

    // MARK: Provider

    func testProviderSignInSendsTheVerifierForTheChallengeAndRecordsTheProvider() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }

        let signedIn = try await signIn(http, browser: browser).get()

        XCTAssertEqual(signedIn.accessToken, "oauth-access")
        XCTAssertEqual(signedIn.refreshToken, "oauth-refresh")
        XCTAssertEqual(signedIn.providerID, "26")
        let start = try XCTUnwrap(browser.startURLs.first)
        let components = try XCTUnwrap(URLComponents(url: start, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "example.test")
        XCTAssertEqual(components.path, "/api/v2/auth/oauth/3/native/start")
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(Set(query.keys), ["code_challenge", "code_challenge_method", "app_state"])
        XCTAssertEqual(query["code_challenge_method"], "S256")

        let body = try XCTUnwrap(http.state.body(path: "/api/v2/auth/oauth/complete", requestIndex: 0))
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(sent["code"] as? String, "auth-code")
        let verifier = try XCTUnwrap(sent["code_verifier"] as? String)
        XCTAssertEqual(Pkce.challenge(for: verifier), query["code_challenge"])
        XCTAssertNotEqual(verifier, query["code_challenge"])
        XCTAssertNotEqual(verifier, query["app_state"])
        XCTAssertNil(http.state.requests(path: "/api/v2/auth/oauth/complete").first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(
            http.state.requests(path: "/api/v2/admin/server/status").first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer oauth-access"
        )
    }

    func testProviderSignInForReLoginSkipsTheAdminProbe() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }
        _ = try await signIn(http, probeAdmin: false, browser: browser).get()
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/server/status").isEmpty)
        XCTAssertEqual(http.state.requests(path: "/api/v2/auth/oauth/complete").count, 1)
    }

    func testUntrustedRedirectsAreNeverRedeemed() async throws {
        let redirects: [String: (URL) -> OAuthBrowserOutcome] = [
            "state": { FakeOAuthBrowser.redirect(for: $0, state: "other") },
            "server": { FakeOAuthBrowser.redirect(for: $0, server: "srv-2") },
            "missing server": { FakeOAuthBrowser.redirect(for: $0, server: nil) },
            "iss": { FakeOAuthBrowser.redirect(for: $0, iss: "https://evil.test") },
            "scheme": { _ in .callback(URL(string: "https://example.test/auth/callback?code=x")!) },
            "path": { _ in .callback(URL(string: "org.siloserver.silo:/other?code=x")!) },
        ]
        for (name, respond) in redirects {
            let http = makeHarness()
            defer { http.invalidate() }
            let browser = FakeOAuthBrowser(respond: respond)
            let result = try await signIn(http, browser: browser)
            XCTAssertEqual(result.failureValue, .oauthUntrusted, name)
            XCTAssertTrue(http.state.requests(path: "/api/v2/auth/oauth/complete").isEmpty, name)
            XCTAssertTrue(http.state.requests(path: "/api/v2/admin/server/status").isEmpty, name)
        }
    }

    func testRedirectErrorIsReportedWithItsReasonAndNothingIsRedeemed() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0, code: nil, error: "account_required") }
        let result = try await signIn(http, browser: browser)
        XCTAssertEqual(result.failureValue, .oauthFailed("account_required"))
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testCancelSendsNothing() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = FakeOAuthBrowser { _ in .cancelled }
        let result = try await signIn(http, browser: browser)
        XCTAssertEqual(result.failureValue, .cancelled)
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testABrowserThatCannotOpenOrFailsSendsNothing() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        var result = try await signIn(http, browser: FakeOAuthBrowser { _ in .unavailable })
        XCTAssertEqual(result.failureValue, .noBrowser)
        result = try await signIn(http, browser: FakeOAuthBrowser { _ in .failed })
        XCTAssertEqual(result.failureValue, .oauthFailed("login_failed"))
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testAProviderWithoutAPlainNativeStartPathNeverOpensTheBrowser() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }
        for id in ["local", "28", "net"] {
            let result = try await signIn(http, provider: id, browser: browser)
            XCTAssertEqual(result.failureValue, .noSupportedSignIn, id)
        }
        let bad = ["//evil.test/x", "https://evil.test/x", "/a?b=1", "/a#b", "/a b", "/a\\b", "x"]
        for path in bad {
            var fixture = Self.providersFixture
            var items = fixture["items"] as! [[String: Any]]
            items[1]["native_start_path"] = path
            fixture["items"] = items
            let value = try discovery(providers: fixture)
            let result = await AdminLogin.signInWithProvider(
                discovery: value, provider: value.providers.items[1], browser: browser,
                probeAdmin: true, now: { Date() }, session: http.session
            )
            XCTAssertEqual(result.failureValue, .noSupportedSignIn, path)
        }
        XCTAssertTrue(browser.startURLs.isEmpty)
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testAProviderSignInWithoutAServerIdentityIsNotOffered() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }
        let value = try discovery(serverID: "")
        let result = await AdminLogin.signInWithProvider(
            discovery: value, provider: value.providers.items[1], browser: browser,
            probeAdmin: true, now: { Date() }, session: http.session
        )
        XCTAssertEqual(result.failureValue, .noSupportedSignIn)
        XCTAssertTrue(browser.startURLs.isEmpty)
    }

    func testAdminProbe403AfterOAuthIsAdministratorRequired() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/api/v2/admin/server/status",
            json: ["type": "https://api.bloem.test/problems/forbidden", "title": "Forbidden", "status": 403, "detail": "Administrator access required"],
            status: 403
        )
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", json: ["error": "not_found", "message": "Not found"], status: 404)
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }
        let result = try await signIn(http, browser: browser)
        XCTAssertEqual(result.failureValue, .administratorRequired)
        XCTAssertEqual(http.state.requests(path: "/api/v2/auth/oauth/complete").count, 1)
    }

    // MARK: Organization-only administrators

    private static func membership(role: String, id: String = "org-1") -> [String: Any] {
        [
            "id": id, "slug": "acme", "name": "Acme", "default": false, "membership_id": "m-\(id)",
            "membership_role": role, "policy_revision": 1, "security_revision": 1,
        ]
    }

    private func refuseStatus(_ http: MockHTTPHarness) {
        http.state.stub(
            path: "/api/v2/admin/server/status",
            json: ["type": "https://api.bloem.test/problems/forbidden", "title": "Forbidden", "status": 403, "detail": "Administrator access required"],
            status: 403
        )
    }

    func testAnOrganizationAdministratorIsAdmittedAtPasswordSignIn() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        refuseStatus(http)
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", json: ["organizations": [Self.membership(role: "admin")]])

        let result = await AdminLogin.signInWithPassword(discovery: try discovery(), username: "a", password: "b", session: http.session)

        XCTAssertEqual(try result.get().accessToken, "access")
        let lookup = http.state.requests(path: "/api/bloem/v2/organizations")
        XCTAssertEqual(lookup.count, 1)
        XCTAssertEqual(lookup.first?.value(forHTTPHeaderField: "Authorization"), "Bearer access")
    }

    func testAPlainSiloServerRefusesAnOrdinaryAccountWithoutAskingForOrganizations() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        refuseStatus(http)
        http.state.stubPlainSilo()

        let result = await AdminLogin.signInWithPassword(discovery: try discovery(), username: "a", password: "b", session: http.session)

        XCTAssertEqual(result.failureValue, .administratorRequired)
        XCTAssertEqual(http.state.requests(path: "/api/bloem/v2/capabilities").count, 1)
        XCTAssertTrue(http.state.requests(path: "/api/bloem/v2/organizations").isEmpty, "a plain Silo server is never asked for organizations")
    }

    func testAPlainSiloServerBehindAProxyThatAnswersHTMLStillSaysAdministratorRequired() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        refuseStatus(http)
        http.state.stub(path: "/api/bloem/v2/capabilities", data: Data("<html>welcome</html>".utf8))

        let result = await AdminLogin.signInWithPassword(discovery: try discovery(), username: "a", password: "b", session: http.session)

        XCTAssertEqual(result.failureValue, .administratorRequired, "not the \"not a server\" message")
        XCTAssertTrue(http.state.requests(path: "/api/bloem/v2/organizations").isEmpty)
    }

    func testAnOrganizationAdministratorIsAdmittedAfterProviderSignIn() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        refuseStatus(http)
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", json: ["organizations": [Self.membership(role: "admin")]])
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }

        let result = try await signIn(http, browser: browser)

        XCTAssertEqual(try result.get().accessToken, "oauth-access")
    }

    func testAMemberWhoAdministersNothingIsStillRefused() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        refuseStatus(http)
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", json: ["organizations": [Self.membership(role: "user")]])

        let result = await AdminLogin.signInWithPassword(discovery: try discovery(), username: "a", password: "b", session: http.session)

        XCTAssertEqual(result.failureValue, .administratorRequired)
    }

    func testAnAccountWithNoOrganizationsIsStillRefused() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        refuseStatus(http)
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", json: ["organizations": [Any]()])

        let result = await AdminLogin.signInWithPassword(discovery: try discovery(), username: "a", password: "b", session: http.session)

        XCTAssertEqual(result.failureValue, .administratorRequired)
    }

    func testAFailedOrganizationLookupIsReportedNotTakenAsARefusal() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        refuseStatus(http)
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", json: ["error": "boom", "message": "Down"], status: 500)

        let result = await AdminLogin.signInWithPassword(discovery: try discovery(), username: "a", password: "b", session: http.session)

        guard case .api(let error)? = result.failureValue else { return XCTFail("\(result)") }
        XCTAssertEqual(error.statusCode, 500)
    }

    func testAPlatformAdministratorNeverTriggersTheOrganizationLookup() async throws {
        let http = makeHarness()
        defer { http.invalidate() }

        let result = await AdminLogin.signInWithPassword(discovery: try discovery(), username: "a", password: "b", session: http.session)

        XCTAssertNoThrow(try result.get())
        XCTAssertTrue(http.state.requests(path: "/api/bloem/v2/organizations").isEmpty)
    }

    func testRejectedCompletionIsLoginFailedAndUpgradeIsReported() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }
        for status in [400, 401] {
            http.state.stub(path: "/api/v2/auth/oauth/complete", json: ["error": "invalid_grant", "message": "Code expired"], status: status)
            let result = try await signIn(http, browser: browser)
            XCTAssertEqual(result.failureValue, .oauthFailed("login_failed"), "\(status)")
        }
        http.state.stub(path: "/api/v2/auth/oauth/complete", json: upgradeProblem(), status: 410)
        let upgrade = try await signIn(http, browser: browser)
        XCTAssertEqual(upgrade.failureValue, .clientUpgradeRequired)
    }

    func testARedirectTakenAfterTenMinutesIsExpiredAndNotRedeemed() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let clock = TestClock()
        let browser = FakeOAuthBrowser { start in
            clock.advance(by: 10 * 60 + 1)
            return FakeOAuthBrowser.redirect(for: start)
        }
        let result = try await signIn(http, clock: clock, browser: browser)
        XCTAssertEqual(result.failureValue, .oauthFailed("session_expired"))
        XCTAssertTrue(http.state.requests(path: "/api/v2/auth/oauth/complete").isEmpty)
    }

    func testARedirectJustInsideTenMinutesIsRedeemed() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let clock = TestClock()
        let browser = FakeOAuthBrowser { start in
            clock.advance(by: 10 * 60)
            return FakeOAuthBrowser.redirect(for: start)
        }
        _ = try await signIn(http, clock: clock, browser: browser).get()
        XCTAssertEqual(http.state.requests(path: "/api/v2/auth/oauth/complete").count, 1)
    }

    // MARK: Copy

    func testFailureCopyFollowsTheSpecAndNeverShowsRawReasons() {
        let message = { (failure: SignInFailure) in failure.message(providerName: "Corp SSO") }
        XCTAssertEqual(message(.oauthFailed("not_permitted")), "This account isn't allowed to sign in to this server.")
        XCTAssertEqual(message(.oauthFailed("account_required")), "No account on this server uses that sign-in. Ask the server's owner for an invitation.")
        XCTAssertEqual(message(.oauthFailed("email_in_use")), "An account with that email already exists. Sign in with its password instead.")
        XCTAssertEqual(message(.oauthFailed("identity_linked_elsewhere")), "That sign-in is linked to a different account.")
        XCTAssertEqual(message(.oauthFailed("account_disabled")), "This account is disabled.")
        XCTAssertEqual(message(.oauthFailed("provider_unavailable")), "Corp SSO isn't available right now. Try again later.")
        XCTAssertEqual(message(.oauthFailed("state_invalid")), "The sign-in took too long or was interrupted. Try again.")
        XCTAssertEqual(message(.oauthFailed("session_expired")), "The sign-in took too long or was interrupted. Try again.")
        for reason in ["login_failed", "already_linked", "something_new", "<b>raw</b>"] {
            XCTAssertEqual(message(.oauthFailed(reason)), "Sign-in didn't finish. Try again.", reason)
        }
        XCTAssertEqual(message(.oauthUntrusted), "The sign-in response didn't come from this server. Try again.")
        XCTAssertEqual(message(.noBrowser), "Install or turn on a web browser to sign in with Corp SSO.")
        XCTAssertEqual(message(.noSupportedSignIn), "This server's sign-in options aren't available in this app.")
        XCTAssertEqual(message(.clientUpgradeRequired), "This server needs a newer version of Bloem Admin.")
        XCTAssertEqual(message(.administratorRequired), "This account needs administrator access.")
        XCTAssertEqual(message(.incompatibleServer), "This server is not compatible with Bloem Admin.")
        XCTAssertNil(SignInFailure.cancelled.message(providerName: "Corp SSO"))
    }

    // MARK: One sign-in at a time

    func testStartingASecondSignInCancelsTheFirstAndTheLastOneOwnsTheState() async throws {
        final class HangingBrowser: OAuthBrowserSession {
            var calls = 0
            var events: [String] = []
            func authenticate(startURL: URL, callbackScheme: String) async -> OAuthBrowserOutcome {
                calls += 1
                guard calls == 1 else { return .cancelled }
                while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
                events.append("first cancelled")
                return .cancelled
            }
            func cancel() {}
        }
        let browser = HangingBrowser()
        let controller = ProviderSignInController(browser: browser)
        let first = try provider("26")
        let second = try provider("27")

        controller.start(provider: first, work: {
            _ = await browser.authenticate(startURL: URL(string: "https://example.test")!, callbackScheme: "x")
        })
        XCTAssertTrue(controller.isConnecting)
        XCTAssertEqual(controller.providerID, "26")
        while browser.calls < 1 { try await Task.sleep(for: .milliseconds(5)) }

        var secondRan = false
        controller.start(provider: second, work: {
            browser.events.append("second started")
            secondRan = true
        })
        XCTAssertEqual(controller.providerID, "27")
        while controller.isConnecting { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertTrue(secondRan)
        XCTAssertEqual(browser.events, ["first cancelled", "second started"])
        XCTAssertNil(controller.providerID)
    }

    /// Waits for a redirect that never comes until `cancel()` (or task cancellation), like a browser left open.
    @MainActor
    final class WaitingBrowser: OAuthBrowserSession {
        private(set) var cancelCount = 0
        private(set) var started = 0
        func authenticate(startURL: URL, callbackScheme: String) async -> OAuthBrowserOutcome {
            started += 1
            let mark = cancelCount
            while cancelCount == mark && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return .cancelled
        }
        func cancel() { cancelCount += 1 }
    }

    func testStartingASignInDoesNotCancelItsOwnBrowser() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = WaitingBrowser()
        let controller = ProviderSignInController(browser: browser)
        let value = try discovery()
        let sso = try provider()
        controller.start(provider: sso, work: {
            await AdminLogin.signInWithProvider(discovery: value, provider: sso, browser: browser, session: http.session)
        })
        while browser.started < 1 { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(browser.cancelCount, 0)
        XCTAssertTrue(controller.isConnecting)
        controller.cancel()
    }

    func testExplicitCancelClosesTheBrowserAndRedeemsNothing() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let browser = WaitingBrowser()
        let controller = ProviderSignInController(browser: browser)
        let value = try discovery()
        let sso = try provider()
        var reported: Result<SignedIn, SignInFailure>?
        controller.start(provider: sso, work: {
            await AdminLogin.signInWithProvider(discovery: value, provider: sso, browser: browser, session: http.session)
        }, onResult: { reported = $0 })
        while browser.started < 1 { try await Task.sleep(for: .milliseconds(5)) }
        controller.cancel()
        XCTAssertGreaterThanOrEqual(browser.cancelCount, 1)
        XCTAssertFalse(controller.isConnecting)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(reported, "a cancelled sign-in reports nothing")
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testReleasingTheControllerCancelsAWaitingBrowser() async throws {
        let browser = WaitingBrowser()
        weak var weakController: ProviderSignInController?
        do {
            let controller = ProviderSignInController(browser: browser)
            weakController = controller
            let sso = try provider()
            controller.start(provider: sso, work: {
                _ = await browser.authenticate(startURL: URL(string: "https://example.test")!, callbackScheme: "x")
            })
            while browser.started < 1 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(browser.cancelCount, 0)
        }
        for _ in 0..<200 where browser.cancelCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNil(weakController)
        XCTAssertGreaterThanOrEqual(browser.cancelCount, 1)
    }

    // MARK: Re-login (view model)

    private func gateFixture(providerID: String? = nil) throws -> (AdminServer, ServerStore, MockHTTPHarness, AdminGateViewModel) {
        let http = makeHarness()
        let store = makeIsolatedServerStore()
        var server = AdminServer(id: "srv-local", baseURL: baseURL, displayName: "Home Server")
        server.signInProviderID = providerID
        try store.addServer(server, accessToken: "stale", refreshToken: "stale-refresh")
        return (server, store, http, AdminGateViewModel(session: http.session))
    }

    func testProviderReLoginStoresTokensRecordsTheProviderAndProbesOnce() async throws {
        let (server, store, http, viewModel) = try gateFixture()
        defer { http.invalidate() }
        let sessionState = AdminSessionState()
        let browser = FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0) }

        let outcome = await viewModel.reLogin(
            provider: try provider(), discovery: try discovery(), browser: browser,
            server: server, store: store, sessionState: sessionState
        )

        XCTAssertEqual(outcome, .signedIn)
        let credentials = try XCTUnwrap(try store.credentials(for: server.id))
        XCTAssertEqual(credentials.accessToken, "oauth-access")
        XCTAssertEqual(credentials.refreshToken, "oauth-refresh")
        XCTAssertEqual(store.servers.first?.signInProviderID, "26")
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.accessToken, "oauth-access")
        // Today's post-re-login behavior: the gate's own access check is the one admin probe.
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/server/status").count, 1)
        XCTAssertEqual(http.state.requestLog.last?.value(forHTTPHeaderField: "Authorization"), "Bearer oauth-access")
        if case .authorized = viewModel.state {} else { XCTFail("expected .authorized, got \(viewModel.state)") }
    }

    func testProviderReLoginCancelAndFailureChangeNothing() async throws {
        let (server, store, http, viewModel) = try gateFixture(providerID: "27")
        defer { http.invalidate() }

        var outcome = await viewModel.reLogin(
            provider: try provider(), discovery: try discovery(), browser: FakeOAuthBrowser { _ in .cancelled },
            server: server, store: store, sessionState: AdminSessionState()
        )
        XCTAssertEqual(outcome, .cancelled)

        outcome = await viewModel.reLogin(
            provider: try provider(), discovery: try discovery(),
            browser: FakeOAuthBrowser { FakeOAuthBrowser.redirect(for: $0, code: nil, error: "provider_unavailable") },
            server: server, store: store, sessionState: AdminSessionState()
        )
        XCTAssertEqual(outcome, .failed("Corp SSO isn't available right now. Try again later."))

        XCTAssertEqual(store.accessToken(for: server.id), "stale")
        XCTAssertEqual(store.servers.first?.signInProviderID, "27")
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testPasswordReLoginClearsTheRememberedProvider() async throws {
        let (server, store, http, viewModel) = try gateFixture(providerID: "26")
        defer { http.invalidate() }

        let message = await viewModel.reLogin(
            username: "admin", password: "secret", server: server, store: store, sessionState: AdminSessionState()
        )

        XCTAssertNil(message)
        XCTAssertNil(store.servers.first?.signInProviderID)
        XCTAssertEqual(store.accessToken(for: server.id), "access")
    }

    // MARK: Remembered provider

    func testRememberedProviderPersistsAndOldRecordsDecode() throws {
        let metadata = InMemoryServerMetadataStore()
        let store = ServerStore(metadataStore: metadata, credentialStore: InMemoryCredentialStore())
        try store.addServer(AdminServer(id: "a", baseURL: baseURL, displayName: "A"), accessToken: "t")
        XCTAssertNil(store.servers.first?.signInProviderID)
        try store.setSignInProvider("26", forServerID: "a")
        XCTAssertEqual(try metadata.loadServers().first?.signInProviderID, "26")
        try store.setSignInProvider(nil, forServerID: "a")
        XCTAssertNil(try metadata.loadServers().first?.signInProviderID)

        let legacy = Data(#"[{"id":"a","baseURL":"https://example.test","displayName":"A"}]"#.utf8)
        let decoded = try JSONDecoder().decode([AdminServer].self, from: legacy)
        XCTAssertNil(decoded.first?.signInProviderID)
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
