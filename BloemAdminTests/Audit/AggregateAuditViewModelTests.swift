import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateAuditViewModelTests: XCTestCase {
    private let serverAID = "aggaudit-srv-A"
    private let serverBID = "aggaudit-srv-B"

    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://aggaudit-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://aggaudit-b.test")!, displayName: "Server B")

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

    private func makeResolveClient(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, session: URLSession) -> (clients: [String: APIClient], resolve: ServerClientResolver) {
        let clients = store.authenticatedClients(for: servers, sessionState: sessionState, session: session)
        return (clients, { server in clients[server.id] ?? store.client(for: server, sessionState: sessionState, session: session) })
    }

    private func auditJSON(id: Int, path: String, nextCursor: String? = nil) -> Data {
        AuditFixtures.page(
            [AuditFixtures.entry("\(id)", path: path)],
            hasMore: nextCursor != nil,
            cursor: nextCursor
        )
    }

    func testLoadAllSectionsEntriesByServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggaudit-a.test": (auditJSON(id: 1, path: "/a"), 200),
            "aggaudit-b.test": (auditJSON(id: 2, path: "/b"), 200),
        ]
        let viewModel = AggregateAuditViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(filters: [:], servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).entries.first?.path, "/a")
        XCTAssertEqual(viewModel.viewModel(for: serverB).entries.first?.path, "/b")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertNil(viewModel.viewModel(for: serverB).errorMessage)
    }

    func testLoadAllFailingServerProducesErrorSectionWithoutAffectingOthers() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggaudit-a.test": (auditJSON(id: 1, path: "/a"), 200),
            "aggaudit-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateAuditViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(filters: [:], servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).entries.first?.path, "/a")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertTrue(viewModel.viewModel(for: serverB).entries.isEmpty)
        XCTAssertEqual(viewModel.viewModel(for: serverB).errorMessage, "Token expired")
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    /// `loadMore` on server A's section (cursor-based, independent per
    /// section — never a merged cross-server feed) must not touch server
    /// B's section in any way.
    func testLoadMoreOnOneServersSectionDoesNotTouchAnotherServersSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggaudit-a.test": (auditJSON(id: 1, path: "/a1", nextCursor: "cursor-a"), 200),
            "aggaudit-b.test": (auditJSON(id: 2, path: "/b1"), 200),
        ]
        let viewModel = AggregateAuditViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: session)
        await viewModel.loadAll(filters: [:], servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        let sectionA = viewModel.viewModel(for: serverA)
        let sectionB = viewModel.viewModel(for: serverB)
        XCTAssertTrue(sectionA.hasMore)
        XCTAssertFalse(sectionB.hasMore)

        http.state.hostOverrides["aggaudit-a.test"] = (auditJSON(id: 3, path: "/a2"), 200)

        await sectionA.loadMore(client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))

        XCTAssertNil(sectionA.loadMoreErrorMessage)
        XCTAssertEqual(sectionA.entries.count, 2)
        XCTAssertEqual(sectionB.entries.count, 1)
        XCTAssertEqual(sectionB.entries.first?.path, "/b1")
        XCTAssertNil(sectionB.errorMessage)
        XCTAssertNil(sectionB.loadMoreErrorMessage)
    }

    func testLoadMoreServerFailurePreservesContentAndOffersRetry() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggaudit-a.test": (auditJSON(id: 1, path: "/a1", nextCursor: "cursor-a"), 200)]
        let viewModel = AggregateAuditViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(filters: [:], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)

        http.state.hostOverrides["aggaudit-a.test"] = (Data(#"{"error":"temporary","message":"Unavailable"}"#.utf8), 503)
        await viewModel.loadMore(server: serverA, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).entries.map(\.path), ["/a1"])
        XCTAssertTrue(viewModel.viewModel(for: serverA).hasMore)
        XCTAssertEqual(viewModel.paginationFailure(for: serverA)?.kind, .serverFailure)
        XCTAssertEqual(viewModel.paginationFailure(for: serverA)?.recoveryAction, .retry)
    }

    func testPaginationReauthenticationResumesFailedPageWithoutResettingAccumulatedEntries() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggaudit-a.test": (auditJSON(id: 1, path: "/a1", nextCursor: "cursor-a"), 200)]
        let viewModel = AggregateAuditViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(filters: [serverAID: AuditFilter(userID: "42")], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)

        http.state.hostOverrides["aggaudit-a.test"] = (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401)
        await viewModel.loadMore(server: serverA, sessionState: sessionState, resolveClient: resolveClient)
        viewModel.beginReauthentication(for: serverA, origin: .pagination)
        viewModel.beginReauthentication(for: serverB, origin: .initialLoad)

        sessionState.setAdministratorToken("fresh-token", serverID: serverAID)
        http.state.requestLog = []
        http.state.hostOverrides["aggaudit-a.test"] = (auditJSON(id: 2, path: "/a2"), 200)
        await viewModel.resumeAfterReauthentication(
            server: serverA,
            filter: AuditFilter(userID: "999"),
            store: store,
            sessionState: sessionState,
            resolveClient: resolveClient
        )

        let section = viewModel.viewModel(for: serverA)
        XCTAssertEqual(section.entries.map(\.path), ["/a1", "/a2"])
        XCTAssertFalse(section.hasMore)
        XCTAssertNil(viewModel.paginationFailure(for: serverA))
        XCTAssertNil(viewModel.reauthenticationOrigin(for: serverA))
        XCTAssertEqual(viewModel.reauthenticationOrigin(for: serverB), .initialLoad)
        let resumedRequest = try XCTUnwrap(http.state.requestLog.last)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(resumedRequest.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["cursor"], "cursor-a")
        XCTAssertEqual(query["user_id"], "42")
    }

    func testStalePollDoesNotClobberFresherActionTriggeredReload() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggaudit-a.test": (auditJSON(id: 1, path: "/fresh"), 200)]
        let viewModel = AggregateAuditViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let sectionViewModel = viewModel.viewModel(for: serverA)
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)

        let staleToken = sectionViewModel.beginLoad(filter: AuditFilter(userID: ""))

        await viewModel.reload(server: serverA, filter: AuditFilter(userID: ""), store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertEqual(sectionViewModel.entries.first?.path, "/fresh")

        let staleResponse = APICollection<AuditLogEntry>(items: [], page: nil)
        sectionViewModel.apply(filter: AuditFilter(userID: ""), .success(staleResponse), token: staleToken, sessionState: nil)

        XCTAssertEqual(sectionViewModel.entries.first?.path, "/fresh")
    }

    /// I2 regression test: `apply` must no-op while a genuine `loadMore` is
    /// in flight for the SAME section — mirrors
    /// `AggregateActivityViewModelTests`'s identical fix, adapted to
    /// Audit's cursor-based pagination (a stale `apply` mid-`loadMore`
    /// could otherwise mint/apply a cursor from a completely different,
    /// concurrently-fetched page).
    func testApplyNoOpsWhileLoadMoreInFlight() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggaudit-a.test": (auditJSON(id: 1, path: "/a1", nextCursor: "cursor-a"), 200)]
        let viewModel = AggregateAuditViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)
        await viewModel.loadAll(filters: [:], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)
        let sectionViewModel = viewModel.viewModel(for: serverA)
        XCTAssertTrue(sectionViewModel.hasMore)

        http.state.delayedHosts["aggaudit-a.test"] = 0.3
        http.state.hostOverrides["aggaudit-a.test"] = (auditJSON(id: 2, path: "/a2"), 200)

        let loadMoreTask = Task {
            await sectionViewModel.loadMore(client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sectionViewModel.isLoadingMore)

        let staleToken = sectionViewModel.beginLoad(filter: AuditFilter(userID: ""))
        let concurrentResponse = APICollection<AuditLogEntry>(items: [], page: PageInfo(hasMore: true, nextCursor: "should-not-apply"))
        sectionViewModel.apply(filter: AuditFilter(userID: ""), .success(concurrentResponse), token: staleToken, sessionState: nil)

        // `apply` must have no-op'd entirely — the original entry/cursor
        // must be untouched by the concurrent poll's (empty) result.
        XCTAssertEqual(sectionViewModel.entries.first?.path, "/a1")

        await loadMoreTask.value
        http.state.delayedHosts = [:]
        XCTAssertEqual(sectionViewModel.entries.count, 2)
    }
}
