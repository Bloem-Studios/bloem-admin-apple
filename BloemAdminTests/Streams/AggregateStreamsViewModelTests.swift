import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateStreamsViewModelTests: XCTestCase {
    private let serverAID = "aggstreams-srv-A"
    private let serverBID = "aggstreams-srv-B"

    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://aggstreams-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://aggstreams-b.test")!, displayName: "Server B")

    /// Every session this file hands to `loadAll`/`reload`, invalidated in
    /// `tearDown` — an un-invalidated ephemeral `URLSession` can starve the
    /// shared system queue custom-URLProtocol delivery runs through for
    /// whichever test runs next, which is what broke
    /// `ServerFanOutTests.testFanOutRunsServersConcurrently`'s barrier when
    /// this was first discovered (see that file's `makeInvalidatingSession`
    /// doc comment for the full root-cause writeup).
    nonisolated private let http = MockHTTPHarness()

    private func makeSession() -> URLSession {
        http.session
    }

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func makeStoreWithTokens() throws -> ServerStore {
        let store = makeIsolatedServerStore()
        try store.updateToken("tok-a", forServerID: serverAID)
        try store.updateToken("tok-b", forServerID: serverBID)
        return store
    }

    /// Builds the same kind of shared, per-server client map `AllServersView`
    /// owns in production — one `APIClient` per server, reused across every
    /// `loadAll`/`reload` call in a test, so a test can simulate
    /// `AllServersView`'s client-sync `.task(id:)` by mutating one of
    /// these clients' in-memory token directly before exercising `reload`.
    private func makeResolveClient(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, session: URLSession) -> (clients: [String: APIClient], resolve: ServerClientResolver) {
        let clients = store.authenticatedClients(for: servers, sessionState: sessionState, session: session)
        return (clients, { server in clients[server.id] ?? store.client(for: server, sessionState: sessionState, session: session) })
    }

    private func sessionJSON(id: String, username: String) -> Data {
        StreamsViewModelTests.sessionsData([StreamsViewModelTests.sessionObject(id: id, username: username)])
    }

    /// Two healthy servers must each get their OWN section, populated from
    /// their OWN response, not a merged or swapped list.
    func testLoadAllSectionsSessionsByServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200),
            "aggstreams-b.test": (sessionJSON(id: "b1", username: "bob"), 200),
        ]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.orderedServers.map(\.id), [serverAID, serverBID])
        XCTAssertEqual(viewModel.viewModel(for: serverA).sessions.first?.username, "alice")
        XCTAssertEqual(viewModel.viewModel(for: serverB).sessions.first?.username, "bob")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertNil(viewModel.viewModel(for: serverB).errorMessage)
    }

    /// A server that fails to load (expired/rejected token here) must
    /// produce an ERROR section — not a crash, and not silently blank —
    /// while its healthy sibling's section is unaffected.
    func testLoadAllFailingServerProducesErrorSectionWithoutAffectingOthers() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200),
            "aggstreams-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).sessions.first?.username, "alice")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)

        XCTAssertTrue(viewModel.viewModel(for: serverB).sessions.isEmpty)
        XCTAssertEqual(viewModel.viewModel(for: serverB).errorMessage, "Token expired")
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        // The 401 must also have flagged THAT server's slice of the shared
        // AdminSessionState, scoped correctly — server A's slice untouched.
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testLoadAllDropsStale401AfterAdministratorTokenRotates() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggstreams-a.test": (Data(#"{"error":"invalid_token","message":"Old token expired"}"#.utf8), 401),
        ]
        http.state.delayedHosts["aggstreams-a.test"] = 0.25
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(
            servers: [serverA],
            store: store,
            sessionState: sessionState,
            session: makeSession()
        )

        let load = Task {
            await viewModel.loadAll(
                servers: [serverA],
                store: store,
                sessionState: sessionState,
                resolveClient: resolveClient
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        sessionState.setAdministratorToken("rotated-token", serverID: serverAID)
        await load.value

        XCTAssertNil(viewModel.failure(for: serverA))
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testDetailRefreshFailurePublishesTypedRecovery() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggstreams-a.test": (Data(#"{"error":"temporary","message":"Unavailable"}"#.utf8), 503),
        ]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.refreshAfterDetailMutation(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.failure(for: serverA)?.kind, .serverFailure)
        XCTAssertEqual(viewModel.failure(for: serverA)?.recoveryAction, .retry)
    }

    /// A server with no stored token at all (never signed in / removed
    /// token) must also produce a clean error section, not a crash.
    func testLoadAllServerWithNoStoredTokenProducesErrorSectionNotSignedIn() async throws {
        let store = makeIsolatedServerStore()
        try store.updateToken("tok-a", forServerID: serverAID)
        http.state.hostOverrides = ["aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200)]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        // Only server A has a token; server B never got one.
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).sessions.first?.username, "alice")
        XCTAssertNotNil(viewModel.viewModel(for: serverB).errorMessage)
        XCTAssertTrue(viewModel.viewModel(for: serverB).sessions.isEmpty)
    }

    /// Stopping a session on server A's section must not touch server B's
    /// section in any way — separate `StreamsViewModel` instances per
    /// server section is the whole point of this design.
    func testActionOnOneServersSessionDoesNotTouchAnotherServersSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200),
            "aggstreams-b.test": (sessionJSON(id: "b1", username: "bob"), 200),
        ]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        let sectionA = viewModel.viewModel(for: serverA)
        let sectionB = viewModel.viewModel(for: serverB)
        let target = sectionA.sessions[0]

        // Isolate the action's own POST response from the hostOverrides
        // used for the GET load above (an empty 200 decodes cleanly as
        // APIClient's EmptyResponse).
        http.state.hostOverrides = [:]
        http.state.responseData = Data()
        http.state.responseStatus = 200

        await sectionA.stop(target, client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))

        XCTAssertNil(sectionA.actionErrorMessage)
        // Server B's section: no action was ever run against it, and its
        // sessions/errorMessage/actionErrorMessage must be exactly as
        // `loadAll` left them.
        XCTAssertNil(sectionB.actionErrorMessage)
        XCTAssertEqual(sectionB.sessions.first?.username, "bob")
        XCTAssertNil(sectionB.errorMessage)
    }

    /// `reload` must refresh only the named server's section, leaving a
    /// sibling section (and its already-loaded sessions) untouched — the
    /// path used after a per-section re-login.
    func testReloadRefreshesOnlyTheNamedServersSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200),
            "aggstreams-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertNotNil(viewModel.viewModel(for: serverB).errorMessage)

        // Simulate a successful re-login for server B: fresh token + a
        // server that now answers successfully.
        try store.updateToken("fresh-tok-b", forServerID: serverBID)
        http.state.hostOverrides["aggstreams-b.test"] = (sessionJSON(id: "b2", username: "bea"), 200)

        await viewModel.reload(server: serverB, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertNil(viewModel.viewModel(for: serverB).errorMessage)
        XCTAssertEqual(viewModel.viewModel(for: serverB).sessions.first?.username, "bea")
        // Server A's section was never asked to reload and stays as-is.
        XCTAssertEqual(viewModel.viewModel(for: serverA).sessions.first?.username, "alice")
    }

    /// Companion case: `reload` resolves the
    /// admin's own Keychain token fresh — proving the redesign didn't make
    /// `reload` invent a new identity, just consistently resolve the right
    /// one at its own call site instead of trusting a possibly-stale cache.
    func testReloadResolvesAdminTokenFresh() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200)]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.reload(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-a")
    }

    /// New Critical A / round-4 redesign regression test: a per-section
    /// re-login (writing a FRESH token to the Keychain via
    /// `store.updateToken`, exactly what `SectionReLoginView` →
    /// `AdminGateViewModel.reLoginAndResetSession` does) must result in the
    /// section's SUBSEQUENT REQUEST actually carrying the new token — not
    /// silently continuing to send whatever wrong/expired token the shared
    /// client held before. This starts the shared client on a deliberately
    /// WRONG token DIRECTLY (simulating what it would hold right after a
    /// mid-session 401 — a legitimate prior state to set up, not a
    /// hand-simulation of the fix itself), then calls the REAL `reload`
    /// with no separate sync step at all — the fix is that `reload` itself
    /// now overwrites that wrong token by resolving fresh from
    /// `sessionState`/`store`, with zero dependency on `AllServersView`'s
    /// `.task(id:)` having run.
    func testReloadAfterReLoginOverwritesAStaleClientTokenWithTheFreshKeychainOne() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200)]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)

        // The re-login itself: writes a brand-new token to the Keychain and
        // clears the mid-session-401 flag.
        try store.updateToken("tok-a-fresh-after-relogin", forServerID: serverAID)
        sessionState.setAdministratorToken("tok-a-fresh-after-relogin", serverID: serverAID)

        // The REAL production call — no manual sync step of any kind.
        await viewModel.reload(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-a-fresh-after-relogin")
        XCTAssertNotEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer wrong-expired-token")
    }

    // MARK: - C2 coverage: fanOut actually honors `resolveClient`.

    func testLoadAllUsesTheV2SessionsRoute() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200)]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertFalse(http.state.requests(host: "aggstreams-a.test", path: "/api/v2/admin/sessions").isEmpty)
    }

    /// The detail screen is outside the server's section, so its action errors name the server.
    func testActionErrorInAllServersNamesTheServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggstreams-a.test": (sessionJSON(id: "a1", username: "alice"), 200)]
        let viewModel = AggregateStreamsViewModel()
        let sessionState = AdminSessionState()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)
        let section = viewModel.viewModel(for: serverA)
        http.state.hostOverrides = [:]
        http.state.stub(path: "/api/v2/admin/sessions/a1/pause", response: MockHTTPResponse(
            data: Data(#"{"type":"https://x/problems/stale_sequence","title":"t","status":409,"detail":"stale"}"#.utf8),
            status: 409, headers: ["X-Silo-Latest-Sequence": "9000"]
        ))
        await section.pause(section.sessions[0], client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))
        XCTAssertEqual(section.actionErrorMessage, "Server A: Another command reached this stream first. Try again.")
    }
}
