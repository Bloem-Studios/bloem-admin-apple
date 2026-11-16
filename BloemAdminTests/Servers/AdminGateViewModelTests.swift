import XCTest
import Observation
@testable import BloemAdmin

@MainActor
final class AdminGateViewModelTests: XCTestCase {
    func testCheckAccessSeedsStoredAdministratorBeforeFirstStatusRequest() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.pathOverrides = [
            "/api/v2/admin/server/status": (Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8), 200),
        ]
        let store = makeIsolatedServerStore()
        try store.updateToken("stored-admin", forServerID: "srv-1")
        let state = AdminSessionState()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: state)

        XCTAssertEqual(
            http.state.requests(path: "/api/v2/admin/server/status").first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer stored-admin"
        )
        XCTAssertEqual(state.requestCredential(serverID: "srv-1")?.accessToken, "stored-admin")
    }

    /// The Tenants tab is hidden until the platform pass exists, so the gate asks for nothing but status.
    func testCheckAccessRequestsOnlyTheStatusRoute() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/api/v2/admin/server/status",
            data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
            status: 200
        )
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertEqual(viewModel.outcome, .authorized)
        XCTAssertEqual(http.state.requestLog.compactMap { $0.url?.path }, ["/api/v2/admin/server/status"])
    }

    func testCheckAccessGrantsAuthorizedOn200() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8)
        http.state.responseStatus = 200

        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        if case .authorized = viewModel.state {} else {
            XCTFail("expected .authorized, got \(viewModel.state)")
        }
    }

    func testCheckAccessReportsUnauthorizedOn403() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"forbidden","message":"Admin access required"}"#.utf8)
        http.state.responseStatus = 403

        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        if case .unauthorized = viewModel.state {} else {
            XCTFail("expected .unauthorized, got \(viewModel.state)")
        }
    }

    func testCheckAccessTransitionsToNeedsLoginOn401() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401

        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        if case .needsLogin = viewModel.state {} else {
            XCTFail("expected .needsLogin, got \(viewModel.state)")
        }
    }

    func testCheckAccessClassifies401AsSignedOutAndOnlyItRequestsCredentials() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertEqual(viewModel.outcome, .signedOut)
        XCTAssertTrue(viewModel.outcome.requestsCredentials)
        XCTAssertFalse(viewModel.outcome.canRetry)
    }

    func testCheckAccessClassifies403AsForbiddenWithoutCredentialPrompt() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"forbidden","message":"Admin access required"}"#.utf8)
        http.state.responseStatus = 403
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertEqual(viewModel.outcome, .forbidden)
        XCTAssertFalse(viewModel.outcome.requestsCredentials)
        XCTAssertFalse(viewModel.outcome.canRetry)
    }

    func testEveryGatePageThatCannotMoveOnOffersRetryButSignedOutAndAuthorizedDoNot() {
        XCTAssertTrue(AdminAccessOutcome.forbidden.gateOffersRetry)
        XCTAssertTrue(AdminAccessOutcome.connectivity.gateOffersRetry)
        XCTAssertTrue(AdminAccessOutcome.incompatibleResponse.gateOffersRetry)
        XCTAssertTrue(AdminAccessOutcome.serverFailure.gateOffersRetry)
        XCTAssertFalse(AdminAccessOutcome.signedOut.gateOffersRetry)
        XCTAssertFalse(AdminAccessOutcome.authorized.gateOffersRetry)
        XCTAssertFalse(AdminAccessOutcome.checking.gateOffersRetry)
    }

    /// Retry on No access runs the same check again: an account whose role was restored is admitted.
    func testCheckingAgainAfterNoAccessAdmitsAnAccountThatNowHasAccess() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let status = #"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#
        http.state.stubSequence(path: "/api/v2/admin/server/status", responses: [
            MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Admin access required"}"#.utf8), status: 403),
            MockHTTPResponse(data: Data(status.utf8), status: 200),
        ])
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", data: Data(#"{"error":"not_found","message":"Not found"}"#.utf8), status: 404)
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())
        XCTAssertEqual(viewModel.outcome, .forbidden)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())
        XCTAssertEqual(viewModel.outcome, .authorized)
    }

    func testCheckAccessClassifiesOfflineTransportAsRetryableConnectivityFailure() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/admin/server/status", response: MockHTTPResponse(transportError: .notConnectedToInternet))
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertEqual(viewModel.outcome, .connectivity)
        XCTAssertFalse(viewModel.outcome.requestsCredentials)
        XCTAssertTrue(viewModel.outcome.canRetry)
    }

    func testCheckAccessClassifiesDecodeFailureAsRetryableIncompatibleResponse() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"unexpected":true}"#.utf8)
        http.state.responseStatus = 200
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertEqual(viewModel.outcome, .incompatibleResponse)
        XCTAssertFalse(viewModel.outcome.requestsCredentials)
        XCTAssertTrue(viewModel.outcome.canRetry)
    }

    func testCheckAccessClassifies5xxAsRetryableServerFailure() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"temporary","message":"Temporarily unavailable"}"#.utf8)
        http.state.responseStatus = 503
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertEqual(viewModel.outcome, .serverFailure)
        XCTAssertFalse(viewModel.outcome.requestsCredentials)
        XCTAssertTrue(viewModel.outcome.canRetry)
    }

    /// Exercises `AdminGateViewModel.reLogin` itself (the method ReLoginView
    /// calls) end to end: a successful login rewrites the Keychain token via
    /// ServerStore.updateToken, and the internal re-check of checkAccess
    /// lands the view model in .authorized with that fresh token attached to
    /// the outgoing request. Routes the login POST and the status-probe GET
    /// to distinct canned responses via pathOverrides, since reLogin fires
    /// both against the same mock session.
    func testReLoginRewritesTokenAndReEvaluatesAsAuthorized() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
            http.state.pathOverrides = [:]
        }
        try store.updateToken("stale-token", forServerID: "srv-1")

        http.state.pathOverrides = [
            "/api/v2/auth/login": (Data(#"{"access_token":"fresh-token","refresh_token":"r","expires_in":3600,"user":{"id":"1","username":"alex","email":"alex@example.test","role":"admin","permissions":[],"download_allowed":true,"password_change_required":false}}"#.utf8), 200),
            "/api/v2/admin/server/status": (Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8), 200),
        ]

        let viewModel = AdminGateViewModel(session: session)
        let sessionState = AdminSessionState()
        let errorMessage = await viewModel.reLogin(username: "alex", password: "secret", server: server, store: store, sessionState: sessionState)

        XCTAssertNil(errorMessage)
        XCTAssertEqual(store.accessToken(for: "srv-1"), "fresh-token")
        if case .authorized = viewModel.state {} else {
            XCTFail("expected .authorized after re-login, got \(viewModel.state)")
        }
        // The re-check (checkAccess) must have used the freshly-written token.
        XCTAssertEqual(http.state.requestLog.last?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-token")
    }

    func testReLoginSavesThenPublishesReplacementBeforeAccessRecheck() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("stale-token", refreshToken: "stale-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("stale-token", serverID: server.id)
        let oldGeneration = sessionState.requestCredential(serverID: server.id)!.identity.generation
        http.state.pathOverrides = [
            "/api/v2/auth/login": (Data(#"{"access_token":"fresh-token","refresh_token":"fresh-refresh","expires_in":3600,"user":{"id":"1","username":"alex","email":"alex@example.test","role":"admin","permissions":[],"download_allowed":true,"password_change_required":false}}"#.utf8), 200),
            "/api/v2/admin/server/status": (Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8), 200),
        ]
        let viewModel = AdminGateViewModel(session: http.session)

        let errorMessage = await viewModel.reLoginAndResetSession(
            username: "alex",
            password: "secret",
            server: server,
            store: store,
            sessionState: sessionState
        )

        XCTAssertNil(errorMessage)
        XCTAssertEqual(try store.credentials(for: server.id)?.accessToken, "fresh-token")
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.accessToken, "fresh-token")
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.identity.generation, oldGeneration + 1)
        XCTAssertEqual(
            http.state.requests(path: "/api/v2/admin/server/status").first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fresh-token"
        )
    }

    /// A rejected re-login must surface its message via reLogin's return
    /// value and must NOT rewrite the stored token or change `state`.
    func testReLoginFailureSurfacesErrorMessageAndLeavesStateUnchanged() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
        }
        try store.updateToken("stale-token", forServerID: "srv-1")

        http.state.responseData = Data(#"{"error":"invalid_credentials","message":"Invalid username or password"}"#.utf8)
        http.state.responseStatus = 401

        let viewModel = AdminGateViewModel(session: session)
        let errorMessage = await viewModel.reLogin(username: "alex", password: "wrong", server: server, store: store, sessionState: AdminSessionState())

        XCTAssertEqual(errorMessage, "Invalid username or password")
        XCTAssertEqual(store.accessToken(for: "srv-1"), "stale-token")
        if case .checking = viewModel.state {} else {
            XCTFail("expected state to remain .checking (never reached checkAccess), got \(viewModel.state)")
        }
    }

    // MARK: - reLoginAndResetSession (review finding I3: the shared
    // post-re-login cleanup both ReLoginView and the aggregate mode's
    // SectionReLoginView call, so this cleanup can never again be
    // forgotten by one of the two call sites)

    /// A successful re-login must clear this server's mid-session-401 flag,
    /// exercised through the actual call site view code uses instead of
    /// calling `resetAfterReLogin` directly.
    func testReLoginAndResetSessionClearsTokenExpiredOnSuccess() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
            http.state.pathOverrides = [:]
        }
        try store.updateToken("stale-token", forServerID: "srv-1")
        http.state.pathOverrides = [
            "/api/v2/auth/login": (Data(#"{"access_token":"fresh-token","refresh_token":"r","expires_in":3600,"user":{"id":"1","username":"alex","email":"alex@example.test","role":"admin","permissions":[],"download_allowed":true,"password_change_required":false}}"#.utf8), 200),
            "/api/v2/admin/server/status": (Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8), 200),
        ]

        let viewModel = AdminGateViewModel(session: session)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("stale-token", serverID: "srv-1")

        let errorMessage = await viewModel.reLoginAndResetSession(username: "alex", password: "secret", server: server, store: store, sessionState: sessionState)

        XCTAssertNil(errorMessage)
        XCTAssertFalse(sessionState.isTokenExpired(for: "srv-1"))
    }

    /// A rejected re-login must NOT touch the session state at all — a
    /// failed sign-in attempt shouldn't silently clear a flag
    /// that's still accurate.
    func testReLoginAndResetSessionLeavesSessionStateUntouchedOnFailure() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
        }
        try store.updateToken("stale-token", forServerID: "srv-1")
        http.state.responseData = Data(#"{"error":"invalid_credentials","message":"Invalid username or password"}"#.utf8)
        http.state.responseStatus = 401

        let viewModel = AdminGateViewModel(session: session)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("stale-token", serverID: "srv-1")

        let errorMessage = await viewModel.reLoginAndResetSession(username: "alex", password: "wrong", server: server, store: store, sessionState: sessionState)

        XCTAssertEqual(errorMessage, "Invalid username or password")
        XCTAssertFalse(sessionState.isTokenExpired(for: "srv-1"))
    }

    // MARK: - attemptSilentRefresh + checkAccess integration (Refresh-token support)

    /// A stored refresh token that the server accepts must rewrite BOTH the
    /// access and (rotated) refresh token in the Keychain and return true.
    func testAttemptSilentRefreshUpdatesBothTokensOnSuccess() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
        }
        try store.updateToken("stale-access", refreshToken: "stale-refresh", forServerID: "srv-1")
        http.state.responseData = Data(#"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600}"#.utf8)
        http.state.responseStatus = 200

        let viewModel = AdminGateViewModel(session: session)
        let didRefresh = await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(store.accessToken(for: "srv-1"), "fresh-access")
        XCTAssertEqual(store.refreshToken(for: "srv-1"), "fresh-refresh")
    }

    func testConcurrentSilentRefreshesShareOneRotatingTokenRequestAndResult() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("stale-access", refreshToken: "one-use-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("stale-access", serverID: server.id)
        http.state.stub(
            path: "/api/v2/auth/refresh",
            response: MockHTTPResponse(
                data: Data(#"{"access_token":"fresh-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8),
                status: 200
            ),
            delayUntilReleased: true
        )
        let firstViewModel = AdminGateViewModel(session: http.session)
        let secondViewModel = AdminGateViewModel(session: http.session)

        let first = Task {
            await firstViewModel.attemptSilentRefresh(server: server, store: store, sessionState: sessionState)
        }
        await http.state.waitForRequest(path: "/api/v2/auth/refresh")
        let secondStarted = expectation(description: "second refresh joined")
        let second = Task {
            secondStarted.fulfill()
            return await secondViewModel.attemptSilentRefresh(server: server, store: store, sessionState: sessionState)
        }
        await fulfillment(of: [secondStarted], timeout: 0.5)

        XCTAssertEqual(http.state.requests(path: "/api/v2/auth/refresh").count, 1)
        http.state.releaseResponses(matching: "/api/v2/auth/refresh")
        let results = await (first.value, second.value)

        XCTAssertEqual(results.0, true)
        XCTAssertEqual(results.1, true)
        XCTAssertEqual(http.state.requests(path: "/api/v2/auth/refresh").count, 1)
        XCTAssertEqual(try store.credentials(for: server.id)?.accessToken, "fresh-access")
        XCTAssertEqual(try store.credentials(for: server.id)?.refreshToken, "rotated-refresh")
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.accessToken, "fresh-access")
    }

    func testSilentRefreshSavesThenPublishesReplacementBeforeNextRequest() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("stale-access", refreshToken: "stale-refresh", forServerID: server.id)
        let state = AdminSessionState()
        state.setAdministratorToken("stale-access", serverID: server.id)
        let oldGeneration = state.requestCredential(serverID: server.id)!.identity.generation
        http.state.pathOverrides = [
            "/api/v2/auth/refresh": (Data(#"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600}"#.utf8), 200),
            "/action": (Data(), 204),
        ]
        let viewModel = AdminGateViewModel(session: http.session)

        let didRefresh = await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: state)
        let client = APIClient(
            baseURL: server.baseURL,
            credentialProvider: state.credentialProvider(serverID: server.id),
            session: http.session
        )
        try await client.post("/action")

        XCTAssertTrue(didRefresh)
        XCTAssertEqual(try store.credentials(for: server.id)?.accessToken, "fresh-access")
        XCTAssertEqual(state.requestCredential(serverID: server.id)?.accessToken, "fresh-access")
        XCTAssertEqual(state.requestCredential(serverID: server.id)?.identity.generation, oldGeneration + 1)
        XCTAssertEqual(
            http.state.requests(path: "/action").first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer fresh-access"
        )
    }

    func testSilentRefreshPersistenceFailureDoesNotPublishCandidateToken() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let credentials = InMemoryCredentialStore(
            credentialsByServerID: [
                "srv-1": ServerCredentials(
                    version: ServerCredentials.currentVersion,
                    accessToken: "stale-access",
                    refreshToken: "stale-refresh"
                ),
            ],
            saveError: TestError.expected
        )
        let store = ServerStore(metadataStore: InMemoryServerMetadataStore(), credentialStore: credentials)
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let state = AdminSessionState()
        state.setAdministratorToken("stale-access", serverID: server.id)
        let oldIdentity = state.requestCredential(serverID: server.id)!.identity
        http.state.stub(
            path: "/api/v2/auth/refresh",
            data: Data(#"{"access_token":"candidate-access","refresh_token":"candidate-refresh","expires_in":3600}"#.utf8),
            status: 200
        )
        let viewModel = AdminGateViewModel(session: http.session)

        let didRefresh = await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: state)

        XCTAssertFalse(didRefresh)
        XCTAssertEqual(state.requestCredential(serverID: server.id)?.accessToken, "stale-access")
        XCTAssertEqual(state.requestCredential(serverID: server.id)?.identity, oldIdentity)
    }

    /// No stored refresh token at all (e.g. a server added before this
    /// feature existed) must fail closed, not crash — the caller then falls
    /// through to the existing re-login flow.
    func testAttemptSilentRefreshFailsWhenNoRefreshTokenStored() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
        }
        try store.updateToken("stale-access", forServerID: "srv-1")

        let viewModel = AdminGateViewModel(session: session)
        let didRefresh = await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertFalse(didRefresh)
        XCTAssertEqual(store.accessToken(for: "srv-1"), "stale-access")
    }

    /// A `session_revoked`/`invalid_token` 401 from the refresh call itself
    /// must also fail closed and leave the stored tokens untouched.
    func testAttemptSilentRefreshFailsWhenServerRejectsRefreshToken() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
        }
        try store.updateToken("stale-access", refreshToken: "dead-refresh", forServerID: "srv-1")
        http.state.responseData = Data(#"{"error":"session_revoked","message":"Session was revoked"}"#.utf8)
        http.state.responseStatus = 401

        let viewModel = AdminGateViewModel(session: session)
        let didRefresh = await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: AdminSessionState())

        XCTAssertFalse(didRefresh)
        XCTAssertEqual(store.accessToken(for: "srv-1"), "stale-access")
        XCTAssertEqual(store.refreshToken(for: "srv-1"), "dead-refresh")
    }

    /// End-to-end silent-refresh-then-retry: `checkAccess` hits a 401 on the
    /// status probe, silently refreshes, and re-runs the probe with the
    /// fresh token — landing in `.authorized` WITHOUT ever surfacing
    /// `.needsLogin`, so the admin never sees a re-login prompt.
    func testCheckAccessSilentlyRefreshesAndRetriesToAuthorizedOn401() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
            http.state.hostPathSequences = [:]
            http.state.hostPathOverrides = [:]
        }
        try store.updateToken("stale-access", refreshToken: "stale-refresh", forServerID: "srv-1")

        // The status probe 401s on the FIRST call (stale token), then 200s
        // on the retry after the silent refresh rewrites it — proving the
        // retry actually happens with the fresh token, not just that
        // refresh itself succeeded.
        http.state.hostPathSequences = [
            "example.test|/api/v2/admin/server/status": [
                (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
                (Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8), 200),
            ],
        ]
        http.state.hostPathOverrides = [
            "example.test|/api/v2/auth/refresh": (Data(#"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":3600}"#.utf8), 200),
        ]

        let viewModel = AdminGateViewModel(session: session)
        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        if case .authorized = viewModel.state {} else {
            XCTFail("expected .authorized after silent-refresh-then-retry, got \(viewModel.state)")
        }
        XCTAssertEqual(store.accessToken(for: "srv-1"), "fresh-access")
        XCTAssertEqual(store.refreshToken(for: "srv-1"), "fresh-refresh")
        // The retried status probe must have carried the FRESH token.
        XCTAssertEqual(http.state.requestLog.last(where: { $0.url?.path == "/api/v2/admin/server/status" })?.value(forHTTPHeaderField: "Authorization"), "Bearer fresh-access")
    }

    /// The safety net: when silent refresh itself fails (no usable refresh
    /// token), `checkAccess` must fall through to `.needsLogin` exactly as
    /// it did before this feature existed.
    func testCheckAccessFallsThroughToNeedsLoginWhenSilentRefreshFails() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        defer {
            try? store.removeServer("srv-1")
        }
        try store.updateToken("stale-access", forServerID: "srv-1")
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401

        let viewModel = AdminGateViewModel(session: session)
        await viewModel.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        if case .needsLogin = viewModel.state {} else {
            XCTFail("expected .needsLogin, got \(viewModel.state)")
        }
    }

    // MARK: - Request identity review regressions

    func testOldSilentRefreshCannotOverwriteNewerManualLogin() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("old-access", refreshToken: "old-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("old-access", serverID: server.id)
        http.state.stub(
            path: "/api/v2/auth/refresh",
            response: MockHTTPResponse(
                data: Data(#"{"access_token":"refresh-candidate","refresh_token":"refresh-candidate-r","expires_in":3600}"#.utf8),
                status: 200
            ),
            delayUntilReleased: true
        )
        http.state.stub(
            path: "/api/v2/auth/login",
            data: Data(#"{"access_token":"manual-access","refresh_token":"manual-refresh","expires_in":3600,"user":{"id":"1","username":"alex","email":"alex@example.test","role":"admin","permissions":[],"download_allowed":true,"password_change_required":false}}"#.utf8),
            status: 200
        )
        http.state.stub(
            path: "/api/v2/admin/server/status",
            data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
            status: 200
        )
        http.state.stub(path: "/action", data: Data(), status: 204)
        let viewModel = AdminGateViewModel(session: http.session)

        let refreshTask = Task {
            await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: sessionState)
        }
        await http.state.waitForRequest(path: "/api/v2/auth/refresh")

        let loginError = await viewModel.reLogin(
            username: "alex",
            password: "secret",
            server: server,
            store: store,
            sessionState: sessionState
        )
        let manualIdentity = try XCTUnwrap(sessionState.requestCredential(serverID: server.id)?.identity)
        http.state.releaseResponses(matching: "/api/v2/auth/refresh")
        let didRefresh = await refreshTask.value

        let client = APIClient(
            baseURL: server.baseURL,
            credentialProvider: sessionState.credentialProvider(serverID: server.id),
            session: http.session
        )
        try await client.post("/action")

        XCTAssertNil(loginError)
        XCTAssertFalse(didRefresh)
        XCTAssertEqual(try store.credentials(for: server.id)?.accessToken, "manual-access")
        XCTAssertEqual(try store.credentials(for: server.id)?.refreshToken, "manual-refresh")
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.accessToken, "manual-access")
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.identity, manualIdentity)
        XCTAssertEqual(
            http.state.requests(path: "/action").first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer manual-access"
        )
    }

    func testSilentRefreshCompletingAfterSignOutCannotResurrectSession() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("old-access", refreshToken: "old-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        let startingGeneration = sessionState.generation(for: server.id)
        http.state.stub(
            path: "/api/v2/auth/refresh",
            response: MockHTTPResponse(
                data: Data(#"{"access_token":"refresh-candidate","refresh_token":"refresh-candidate-r","expires_in":3600}"#.utf8),
                status: 200
            ),
            delayUntilReleased: true
        )
        http.state.stub(path: "/action", data: Data(), status: 204)
        let viewModel = AdminGateViewModel(session: http.session)

        let refreshTask = Task {
            await viewModel.attemptSilentRefresh(server: server, store: store, sessionState: sessionState)
        }
        await http.state.waitForRequest(path: "/api/v2/auth/refresh")
        try store.signOut(server.id, sessionState: sessionState)
        let signedOutGeneration = sessionState.generation(for: server.id)
        http.state.releaseResponses(matching: "/api/v2/auth/refresh")
        let didRefresh = await refreshTask.value

        let client = APIClient(
            baseURL: server.baseURL,
            credentialProvider: sessionState.credentialProvider(serverID: server.id),
            session: http.session
        )
        try await client.post("/action")

        XCTAssertEqual(signedOutGeneration, startingGeneration + 1)
        XCTAssertFalse(didRefresh)
        XCTAssertNil(try store.credentials(for: server.id))
        XCTAssertNil(sessionState.requestCredential(serverID: server.id))
        XCTAssertEqual(sessionState.generation(for: server.id), signedOutGeneration)
        XCTAssertNil(http.state.requests(path: "/action").first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testManualLoginCompletingAfterRemovalCannotResurrectSession() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.addServer(server, accessToken: "old-access", refreshToken: "old-refresh")
        let sessionState = AdminSessionState()
        let startingGeneration = sessionState.generation(for: server.id)
        http.state.stub(
            path: "/api/v2/auth/login",
            response: MockHTTPResponse(
                data: Data(#"{"access_token":"login-candidate","refresh_token":"login-candidate-r","expires_in":3600,"user":{"id":"1","username":"alex","email":"alex@example.test","role":"admin","permissions":[],"download_allowed":true,"password_change_required":false}}"#.utf8),
                status: 200
            ),
            delayUntilReleased: true
        )
        http.state.stub(
            path: "/api/v2/admin/server/status",
            data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
            status: 200
        )
        http.state.stub(path: "/action", data: Data(), status: 204)
        let viewModel = AdminGateViewModel(session: http.session)

        let loginTask = Task {
            await viewModel.reLogin(
                username: "alex",
                password: "secret",
                server: server,
                store: store,
                sessionState: sessionState
            )
        }
        await http.state.waitForRequest(path: "/api/v2/auth/login")
        try store.removeServer(server.id, sessionState: sessionState)
        let removedGeneration = sessionState.generation(for: server.id)
        http.state.releaseResponses(matching: "/api/v2/auth/login")
        let loginError = await loginTask.value

        let client = APIClient(
            baseURL: server.baseURL,
            credentialProvider: sessionState.credentialProvider(serverID: server.id),
            session: http.session
        )
        try await client.post("/action")

        XCTAssertEqual(removedGeneration, startingGeneration + 1)
        XCTAssertNotNil(loginError)
        XCTAssertFalse(store.servers.contains(where: { $0.id == server.id }))
        XCTAssertNil(try store.credentials(for: server.id))
        XCTAssertNil(sessionState.requestCredential(serverID: server.id))
        XCTAssertEqual(sessionState.generation(for: server.id), removedGeneration)
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/server/status").isEmpty)
        XCTAssertNil(http.state.requests(path: "/action").first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testAdministratorStatus403RetainsCredentialAndShowsUnauthorized() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("admin-access", refreshToken: "admin-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("admin-access", serverID: server.id)
        let identity = try XCTUnwrap(sessionState.requestCredential(serverID: server.id)?.identity)
        http.state.stub(
            path: "/api/v2/admin/server/status",
            data: Data(#"{"error":"forbidden","message":"Admin access required"}"#.utf8),
            status: 403
        )
        // A server without organizations: the 403 is final.
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", data: Data(#"{"error":"not_found","message":"Not found"}"#.utf8), status: 404)
        let viewModel = AdminGateViewModel(session: http.session)

        await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)

        if case .unauthorized = viewModel.state {} else {
            XCTFail("expected .unauthorized, got \(viewModel.state)")
        }
        XCTAssertFalse(sessionState.isTokenExpired(for: server.id))
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.accessToken, "admin-access")
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.identity, identity)
        XCTAssertEqual(try store.credentials(for: server.id)?.accessToken, "admin-access")
    }

    func testUnrelatedStaleStatusFailureCannotOverwriteNewerAuthorizedPrincipal() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("old-admin", refreshToken: "old-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("old-admin", serverID: server.id)
        http.state.stub(
            path: "/api/v2/admin/server/status",
            response: MockHTTPResponse(
                data: Data(#"{"error":"invalid_token","message":"Old token expired"}"#.utf8),
                status: 401
            ),
            delayUntilReleased: true
        )
        http.state.stub(path: "/action", data: Data(), status: 204)
        let viewModel = AdminGateViewModel(session: http.session)

        let staleAccessTask = Task {
            await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        }
        await http.state.waitForRequest(path: "/api/v2/admin/server/status")

        try store.updateToken("new-admin", refreshToken: "new-refresh", forServerID: server.id)
        sessionState.setAdministratorToken("new-admin", serverID: server.id)
        let newerIdentity = try XCTUnwrap(sessionState.requestCredential(serverID: server.id)?.identity)
        http.state.stub(
            path: "/api/v2/admin/server/status",
            response: MockHTTPResponse(
                data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
                status: 200
            )
        )
        await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        if case .authorized = viewModel.state {} else {
            XCTFail("expected newer administrator check to authorize, got \(viewModel.state)")
        }

        http.state.releaseResponses(matching: "/api/v2/admin/server/status")
        await staleAccessTask.value

        let client = APIClient(
            baseURL: server.baseURL,
            credentialProvider: sessionState.credentialProvider(serverID: server.id),
            session: http.session
        )
        try await client.post("/action")

        if case .authorized = viewModel.state {} else {
            XCTFail("stale status must not overwrite the newer authorized state, got \(viewModel.state)")
        }
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.identity, newerIdentity)
        XCTAssertEqual(sessionState.requestCredential(serverID: server.id)?.accessToken, "new-admin")
        XCTAssertEqual(try store.credentials(for: server.id)?.accessToken, "new-admin")
        XCTAssertTrue(http.state.requests(path: "/api/v2/auth/refresh").isEmpty)
        XCTAssertEqual(
            http.state.requests(path: "/api/v2/admin/server/status").map { $0.value(forHTTPHeaderField: "Authorization") },
            ["Bearer old-admin", "Bearer new-admin"]
        )
        XCTAssertEqual(
            http.state.requests(path: "/action").first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer new-admin"
        )
    }

    func testStaleGenericFailureCannotOverwriteNewerAuthorizedCheck() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("admin-access", refreshToken: "admin-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("admin-access", serverID: server.id)
        http.state.stub(
            path: "/api/v2/admin/server/status",
            response: MockHTTPResponse(
                data: Data(#"{"error":"server_error","message":"Old failure"}"#.utf8),
                status: 500
            ),
            delayUntilReleased: true
        )
        let viewModel = AdminGateViewModel(session: http.session)

        let staleAccessTask = Task {
            await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        }
        await http.state.waitForRequest(path: "/api/v2/admin/server/status")

        http.state.stub(
            path: "/api/v2/admin/server/status",
            response: MockHTTPResponse(
                data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
                status: 200
            )
        )
        await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        if case .authorized = viewModel.state {} else {
            XCTFail("expected newer check to authorize, got \(viewModel.state)")
        }

        http.state.releaseResponses(matching: "/api/v2/admin/server/status")
        await staleAccessTask.value

        if case .authorized = viewModel.state {} else {
            XCTFail("stale generic failure must not overwrite newer authorization, got \(viewModel.state)")
        }
    }

    func testStaleSuccessCannotOverwriteNewerUnauthorizedCheck() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("admin-access", refreshToken: "admin-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("admin-access", serverID: server.id)
        let viewModel = AdminGateViewModel(session: http.session)

        http.state.stub(
            path: "/api/v2/admin/server/status",
            data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
            status: 200
        )
        await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)

        http.state.stub(
            path: "/api/v2/admin/server/status",
            response: MockHTTPResponse(
                data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
                status: 200
            ),
            delayUntilReleased: true
        )
        let staleAccessTask = Task {
            await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        }
        await http.state.waitForRequest(path: "/api/v2/admin/server/status", count: 2)

        http.state.stub(
            path: "/api/v2/admin/server/status",
            response: MockHTTPResponse(
                data: Data(#"{"error":"forbidden","message":"Admin access required"}"#.utf8),
                status: 403
            )
        )
        // A server without organizations: the 403 is final.
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", data: Data(#"{"error":"not_found","message":"Not found"}"#.utf8), status: 404)
        await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        if case .unauthorized = viewModel.state {} else {
            XCTFail("expected newer check to remain unauthorized, got \(viewModel.state)")
        }

        http.state.releaseResponses(matching: "/api/v2/admin/server/status")
        await staleAccessTask.value

        if case .unauthorized = viewModel.state {} else {
            XCTFail("stale success must not overwrite newer unauthorized state, got \(viewModel.state)")
        }
    }

    func testStaleCheckRefreshCannotPersistAfterNewerAuthorizedCheck() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        try store.updateToken("old-admin", refreshToken: "old-refresh", forServerID: server.id)
        let sessionState = AdminSessionState()
        sessionState.setAdministratorToken("old-admin", serverID: server.id)
        let administratorGeneration = sessionState.generation(for: server.id)
        http.state.stubSequence(
            path: "/api/v2/admin/server/status",
            responses: [
                MockHTTPResponse(
                    data: Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8),
                    status: 401
                ),
                MockHTTPResponse(
                    data: Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8),
                    status: 200
                ),
            ]
        )
        http.state.stub(
            path: "/api/v2/auth/refresh",
            response: MockHTTPResponse(
                data: Data(#"{"access_token":"stale-refreshed-admin","refresh_token":"stale-refreshed-refresh","expires_in":3600}"#.utf8),
                status: 200
            ),
            delayUntilReleased: true
        )
        http.state.stub(path: "/action", data: Data(), status: 204)
        let viewModel = AdminGateViewModel(session: http.session)

        let staleAccessTask = Task {
            await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        }
        await http.state.waitForRequest(path: "/api/v2/auth/refresh")

        await viewModel.checkAccess(server: server, store: store, sessionState: sessionState)
        if case .authorized = viewModel.state {} else {
            XCTFail("expected newer check to authorize, got \(viewModel.state)")
        }
        XCTAssertTrue(sessionState.isTokenExpired(for: server.id))

        http.state.releaseResponses(matching: "/api/v2/auth/refresh")
        await staleAccessTask.value

        let client = APIClient(
            baseURL: server.baseURL,
            credentialProvider: sessionState.credentialProvider(serverID: server.id),
            session: http.session
        )
        try await client.post("/action")

        if case .authorized = viewModel.state {} else {
            XCTFail("stale refresh must not overwrite newer authorized UI, got \(viewModel.state)")
        }
        XCTAssertTrue(sessionState.isTokenExpired(for: server.id))
        XCTAssertNil(sessionState.requestCredential(serverID: server.id))
        XCTAssertEqual(sessionState.generation(for: server.id), administratorGeneration + 1)
        XCTAssertEqual(try store.credentials(for: server.id)?.accessToken, "old-admin")
        XCTAssertEqual(try store.credentials(for: server.id)?.refreshToken, "old-refresh")
        XCTAssertEqual(http.state.requests(path: "/api/v2/auth/refresh").count, 1)
        XCTAssertNil(http.state.requests(path: "/action").first?.value(forHTTPHeaderField: "Authorization"))
    }

    private func waitForGenerationChange(
        _ sessionState: AdminSessionState,
        serverID: String,
        from generation: UInt64
    ) async {
        guard sessionState.generation(for: serverID) == generation else { return }
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = sessionState.generation(for: serverID)
            } onChange: {
                continuation.resume()
            }
        }
    }

}
