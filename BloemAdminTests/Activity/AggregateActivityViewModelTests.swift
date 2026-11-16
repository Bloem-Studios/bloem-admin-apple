import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateActivityViewModelTests: XCTestCase {
    private let serverAID = "aggact-srv-A"
    private let serverBID = "aggact-srv-B"

    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://aggact-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://aggact-b.test")!, displayName: "Server B")

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

    private func entriesJSON(sessionID: String, username: String) -> Data {
        ActivityFixtures.page([ActivityFixtures.entry(sessionID, username: username)], hasMore: false)
    }

    /// A page with `has_more` true and cursor "\(prefix)-next", so Load more is available.
    private func fullPageJSON(prefix: String, username: String) -> Data {
        ActivityFixtures.page(ActivityFixtures.ids(prefix, 3, username: username), hasMore: true, cursor: "\(prefix)-next")
    }

    func testLoadAllSectionsEntriesByServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggact-a.test": (entriesJSON(sessionID: "s1", username: "alice"), 200),
            "aggact-b.test": (entriesJSON(sessionID: "s2", username: "bob"), 200),
        ]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(filters: [:], servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).entries.first?.username, "alice")
        XCTAssertEqual(viewModel.viewModel(for: serverB).entries.first?.username, "bob")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertNil(viewModel.viewModel(for: serverB).errorMessage)
    }

    func testLoadAllFailingServerProducesErrorSectionWithoutAffectingOthers() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggact-a.test": (entriesJSON(sessionID: "s1", username: "alice"), 200),
            "aggact-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(filters: [:], servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).entries.first?.username, "alice")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertTrue(viewModel.viewModel(for: serverB).entries.isEmpty)
        XCTAssertEqual(viewModel.viewModel(for: serverB).errorMessage, "Token expired")
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testLoadAllPrunesFailuresForServersNoLongerIncluded() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggact-a.test": (entriesJSON(sessionID: "s1", username: "alice"), 200),
            "aggact-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveBoth) = makeResolveClient(
            servers: [serverA, serverB],
            store: store,
            sessionState: sessionState,
            session: makeSession()
        )

        await viewModel.loadAll(
            filters: [:],
            servers: [serverA, serverB],
            store: store,
            sessionState: sessionState,
            resolveClient: resolveBoth
        )
        XCTAssertNotNil(viewModel.failure(for: serverB))

        let (_, resolveA) = makeResolveClient(
            servers: [serverA],
            store: store,
            sessionState: sessionState,
            session: makeSession()
        )
        await viewModel.loadAll(
            filters: [:],
            servers: [serverA],
            store: store,
            sessionState: sessionState,
            resolveClient: resolveA
        )

        XCTAssertNil(viewModel.failure(for: serverB))
    }

    /// `loadMore` on server A's section (independent per-section pagination
    /// — never a merged cross-server feed) must not touch server B's
    /// section in any way.
    func testLoadMoreOnOneServersSectionDoesNotTouchAnotherServersSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggact-a.test": (fullPageJSON(prefix: "a", username: "alice"), 200),
            "aggact-b.test": (entriesJSON(sessionID: "s2", username: "bob"), 200),
        ]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: session)
        await viewModel.loadAll(filters: [:], servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        let sectionA = viewModel.viewModel(for: serverA)
        let sectionB = viewModel.viewModel(for: serverB)
        XCTAssertTrue(sectionA.hasMore)

        http.state.hostOverrides["aggact-a.test"] = (entriesJSON(sessionID: "s3", username: "carol"), 200)

        await sectionA.loadMore(client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))

        XCTAssertNil(sectionA.loadMoreErrorMessage)
        XCTAssertEqual(sectionA.entries.count, 4)
        XCTAssertEqual(sectionB.entries.count, 1)
        XCTAssertEqual(sectionB.entries.first?.username, "bob")
        XCTAssertNil(sectionB.errorMessage)
        XCTAssertNil(sectionB.loadMoreErrorMessage)
    }

    func testLoadMore401PreservesContentAndOffersSignIn() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggact-a.test": (fullPageJSON(prefix: "a", username: "alice"), 200)]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(filters: [:], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)

        http.state.hostOverrides["aggact-a.test"] = (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401)
        await viewModel.loadMore(server: serverA, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).entries.count, 3)
        XCTAssertTrue(viewModel.viewModel(for: serverA).hasMore)
        XCTAssertEqual(viewModel.paginationFailure(for: serverA)?.kind, .signedOut)
        XCTAssertEqual(viewModel.paginationFailure(for: serverA)?.recoveryAction, .signIn)
    }

    func testPaginationReauthenticationResumesFailedPageWithoutResettingAccumulatedEntries() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggact-a.test": (fullPageJSON(prefix: "a", username: "alice"), 200)]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(filters: [serverAID: HistoryFilter(userID: "42")], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)

        http.state.hostOverrides["aggact-a.test"] = (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401)
        await viewModel.loadMore(server: serverA, sessionState: sessionState, resolveClient: resolveClient)
        viewModel.beginReauthentication(for: serverA, origin: .pagination)
        viewModel.beginReauthentication(for: serverB, origin: .initialLoad)

        sessionState.setAdministratorToken("fresh-token", serverID: serverAID)
        http.state.requestLog = []
        http.state.hostOverrides["aggact-a.test"] = (entriesJSON(sessionID: "a-next", username: "alice"), 200)
        await viewModel.resumeAfterReauthentication(
            server: serverA,
            filter: HistoryFilter(userID: "999"),
            store: store,
            sessionState: sessionState,
            resolveClient: resolveClient
        )

        let section = viewModel.viewModel(for: serverA)
        XCTAssertEqual(section.entries.count, 4)
        XCTAssertEqual(section.entries.first?.sessionID, "a-0")
        XCTAssertEqual(section.entries.last?.sessionID, "a-next")
        XCTAssertTrue(section.hasLoadedBeyondFirstPage)
        XCTAssertNil(viewModel.paginationFailure(for: serverA))
        XCTAssertNil(viewModel.reauthenticationOrigin(for: serverA))
        XCTAssertEqual(viewModel.reauthenticationOrigin(for: serverB), .initialLoad)
        let resumedRequest = try XCTUnwrap(http.state.requestLog.last)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(resumedRequest.url), resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["cursor"], "a-next")
        XCTAssertNil(query["offset"])
        XCTAssertEqual(query["user_id"], "42")
    }

    func testStalePollDoesNotClobberFresherActionTriggeredReload() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggact-a.test": (entriesJSON(sessionID: "fresh", username: "fresh"), 200)]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let sectionViewModel = viewModel.viewModel(for: serverA)
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)

        let staleToken = sectionViewModel.beginLoad(filter: HistoryFilter(userID: ""))

        await viewModel.reload(server: serverA, filter: HistoryFilter(userID: ""), store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertEqual(sectionViewModel.entries.first?.username, "fresh")

        let stale = ActivityFixtures.decoded("stale", username: "stale")
        sectionViewModel.apply(filter: HistoryFilter(userID: ""), .success(APICollection(items: [stale], page: nil)), token: staleToken, sessionState: nil)

        XCTAssertEqual(sectionViewModel.entries.first?.username, "fresh")
    }

    /// I1 regression test: `loadAll`'s poll must respect EACH server's own
    /// active filter rather than forcing every section through one shared,
    /// unfiltered query. Two servers with DIFFERENT filters must each see
    /// their own `user_id` on the wire.
    func testLoadAllRespectsEachServersOwnFilter() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggact-a.test": (entriesJSON(sessionID: "s1", username: "alice"), 200),
            "aggact-b.test": (entriesJSON(sessionID: "s2", username: "bob"), 200),
        ]
        // `requestLog` is an additive, never-auto-cleared static (see
        // ServerConfigViewModelTests's identical reset) — without this,
        // `.first` below could pick up a request from an EARLIER test in
        // this same suite that happened to hit the same "aggact-a.test"
        // host, rather than this test's own request.
        http.state.requestLog = []
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(filters: [serverAID: HistoryFilter(userID: "7"), serverBID: HistoryFilter(userID: "9")], servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        let requestsByHost = Dictionary(grouping: http.state.requestLog, by: { $0.url?.host ?? "" })
        XCTAssertEqual(requestsByHost["aggact-a.test"]?.first?.url?.query?.contains("user_id=7"), true)
        XCTAssertEqual(requestsByHost["aggact-b.test"]?.first?.url?.query?.contains("user_id=9"), true)
    }

    /// I2 regression test: `apply` (the aggregate `loadAll`/`reload` write
    /// path) must no-op while a genuine `loadMore` is in flight for the
    /// SAME section — otherwise a poll tick or a "Filter" tap landing
    /// mid-`loadMore` could rewrite `entries`/`offset`/`hasMore`, producing
    /// a mixed-filter page or duplicate `Identifiable` ids.
    func testApplyNoOpsWhileLoadMoreInFlight() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggact-a.test": (fullPageJSON(prefix: "a", username: "alice"), 200)]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)
        await viewModel.loadAll(filters: [:], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)
        let sectionViewModel = viewModel.viewModel(for: serverA)
        XCTAssertTrue(sectionViewModel.hasMore)

        // Slow down server A's NEXT response (the loadMore's) so it's
        // still in flight (isLoadingMore == true) when `apply` races it.
        http.state.delayedHosts["aggact-a.test"] = 0.3
        http.state.hostOverrides["aggact-a.test"] = (entriesJSON(sessionID: "loadmore-page", username: "loadmore"), 200)

        let loadMoreTask = Task {
            await sectionViewModel.loadMore(client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))
        }
        // Give loadMore's `isLoadingMore = true` a moment to actually take
        // effect before racing `apply` against it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sectionViewModel.isLoadingMore)

        let staleToken = sectionViewModel.beginLoad(filter: HistoryFilter(userID: ""))
        let concurrentEntry = ActivityFixtures.decoded("should-not-apply", username: "poll")
        sectionViewModel.apply(filter: HistoryFilter(userID: ""), .success(APICollection(items: [concurrentEntry], page: nil)), token: staleToken, sessionState: nil)

        // `apply` must have no-op'd entirely — the concurrent poll's entry
        // must never appear, and the original full page must be untouched.
        XCTAssertFalse(sectionViewModel.entries.contains { $0.username == "poll" })
        XCTAssertEqual(sectionViewModel.entries.count, 3)

        await loadMoreTask.value
        http.state.delayedHosts = [:]
        XCTAssertEqual(sectionViewModel.entries.count, 4)
    }

    func testIgnoredReloadFailureDoesNotHidePaginatedContentWhileLoadMoreIsInFlight() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggact-a.test": (fullPageJSON(prefix: "a", username: "alice"), 200)]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (clients, resolveClient) = makeResolveClient(
            servers: [serverA],
            store: store,
            sessionState: sessionState,
            session: makeSession()
        )
        await viewModel.loadAll(
            filters: [:],
            servers: [serverA],
            store: store,
            sessionState: sessionState,
            resolveClient: resolveClient
        )

        let sectionViewModel = viewModel.viewModel(for: serverA)
        http.state.delayedHosts["aggact-a.test"] = 0.3
        http.state.hostOverrides["aggact-a.test"] = (entriesJSON(sessionID: "loadmore-page", username: "loadmore"), 200)
        let loadMoreTask = Task {
            await sectionViewModel.loadMore(
                client: clients[serverAID]!,
                sessionState: sessionState.scoped(to: serverAID)
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(sectionViewModel.isLoadingMore)

        let retryHTTP = MockHTTPHarness()
        defer { retryHTTP.invalidate() }
        retryHTTP.state.stub(
            host: "aggact-a.test",
            data: Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8),
            status: 401
        )
        let retryClient = store.client(
            for: serverA,
            sessionState: sessionState,
            session: retryHTTP.session
        )
        await viewModel.reload(
            server: serverA,
            filter: HistoryFilter(userID: ""),
            store: store,
            sessionState: sessionState,
            resolveClient: { _ in retryClient }
        )

        XCTAssertNil(viewModel.failure(for: serverA))
        XCTAssertEqual(sectionViewModel.entries.count, 3)

        await loadMoreTask.value
        XCTAssertEqual(sectionViewModel.entries.count, 4)
    }

    /// The poll (`merging`) lands while this section's Load more is in flight: the appended
    /// page and its cursor survive, and the poll's differing first page is merged in.
    func testMergingPollDuringLoadMoreKeepsAppendedPageAndCursor() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggact-a.test": (fullPageJSON(prefix: "a", username: "alice"), 200)]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(filters: [:], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)
        let section = viewModel.viewModel(for: serverA)

        http.state.delayedHosts["aggact-a.test"] = 0.3
        http.state.hostOverrides["aggact-a.test"] = (ActivityFixtures.page(ActivityFixtures.ids("b", 2), hasMore: true, cursor: "b-next"), 200)
        let loadMoreTask = Task { await section.loadMore(client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(section.isLoadingMore)

        http.state.delayedHosts = [:]
        http.state.hostOverrides["aggact-a.test"] = (ActivityFixtures.page(ActivityFixtures.ids("p", 2), hasMore: true, cursor: "poll-next"), 200)
        await viewModel.loadAll(filters: [:], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient, merging: true)
        await loadMoreTask.value

        XCTAssertEqual(section.entries.count, 7)
        XCTAssertTrue(section.entries.contains { $0.sessionID == "a-2" })
        http.state.requestLog = []
        http.state.hostOverrides["aggact-a.test"] = (ActivityFixtures.page([], hasMore: false), 200)
        await viewModel.loadMore(server: serverA, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertTrue(http.state.requestLog.last?.url?.query?.contains("cursor=b-next") == true)
    }

    func testFilterChangeFailureClearsRowsAndLoadMoreForThatSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggact-a.test": (fullPageJSON(prefix: "a", username: "alice"), 200)]
        let viewModel = AggregateActivityViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(filters: [serverAID: HistoryFilter(userID: "1")], servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertTrue(viewModel.viewModel(for: serverA).hasMore)

        http.state.hostOverrides["aggact-a.test"] = (Data(#"{"error":"server_error","message":"boom"}"#.utf8), 500)
        await viewModel.reload(server: serverA, filter: HistoryFilter(userID: "2"), store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertTrue(viewModel.viewModel(for: serverA).entries.isEmpty)
        XCTAssertFalse(viewModel.viewModel(for: serverA).hasMore)
        XCTAssertNotNil(viewModel.failure(for: serverA))
    }
}
