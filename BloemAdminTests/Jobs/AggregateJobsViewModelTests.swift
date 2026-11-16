import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateJobsViewModelTests: XCTestCase {
    private let serverAID = "aggjobs-srv-A"
    private let serverBID = "aggjobs-srv-B"

    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://aggjobs-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://aggjobs-b.test")!, displayName: "Server B")

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

    /// See `AggregateStreamsViewModelTests.makeResolveClient`'s doc comment
    /// — same shared, per-server client map `AllServersView` owns in
    /// production.
    private func makeResolveClient(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, session: URLSession) -> (clients: [String: APIClient], resolve: ServerClientResolver) {
        let clients = store.authenticatedClients(for: servers, sessionState: sessionState, session: session)
        return (clients, { server in clients[server.id] ?? store.client(for: server, sessionState: sessionState, session: session) })
    }

    private func taskJSON(key: String, name: String) -> Data {
        Data(#"{"items":[{"key":"\#(key)","name":"\#(name)","description":"d","category":"system","state":"idle","progress":0,"manual_only":false,"triggers":[],"execution_scope":"process"}]}"#.utf8)
    }

    func testLoadAllSectionsTasksByServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggjobs-a.test": (taskJSON(key: "task-a", name: "Task A"), 200),
            "aggjobs-b.test": (taskJSON(key: "task-b", name: "Task B"), 200),
        ]
        let viewModel = AggregateJobsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).tasks.first?.key, "task-a")
        XCTAssertEqual(viewModel.viewModel(for: serverB).tasks.first?.key, "task-b")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertNil(viewModel.viewModel(for: serverB).errorMessage)
    }

    func testLoadAllFailingServerProducesErrorSectionWithoutAffectingOthers() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggjobs-a.test": (taskJSON(key: "task-a", name: "Task A"), 200),
            "aggjobs-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateJobsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).tasks.first?.key, "task-a")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertTrue(viewModel.viewModel(for: serverB).tasks.isEmpty)
        XCTAssertEqual(viewModel.viewModel(for: serverB).errorMessage, "Token expired")
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testDetailRefreshFailurePublishesTypedRecovery() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggjobs-a.test": (Data(#"{"error":"temporary","message":"Unavailable"}"#.utf8), 503)]
        let viewModel = AggregateJobsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.refreshAfterDetailMutation(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.failure(for: serverA)?.kind, .serverFailure)
        XCTAssertEqual(viewModel.failure(for: serverA)?.recoveryAction, .retry)
    }

    /// Running a task on server A's section must not touch server B's
    /// section in any way.
    func testActionOnOneServersSectionDoesNotTouchAnotherServersSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggjobs-a.test": (taskJSON(key: "task-a", name: "Task A"), 200),
            "aggjobs-b.test": (taskJSON(key: "task-b", name: "Task B"), 200),
        ]
        let viewModel = AggregateJobsViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: session)
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        let sectionA = viewModel.viewModel(for: serverA)
        let sectionB = viewModel.viewModel(for: serverB)
        let target = sectionA.tasks[0]

        http.state.hostOverrides = [:]
        http.state.responseData = Data()
        http.state.responseStatus = 200

        await sectionA.run(target, client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))

        XCTAssertNil(sectionA.actionErrorMessage)
        XCTAssertNil(sectionB.actionErrorMessage)
        XCTAssertEqual(sectionB.tasks.first?.key, "task-b")
        XCTAssertNil(sectionB.errorMessage)
    }

    /// A stale, slower `loadAll` fetch that started BEFORE a fresh
    /// per-section `reload` (e.g. right after a Run/Cancel action) must not
    /// clobber that fresher reload's result when it resolves later — proves
    /// the `beginLoad`/`apply` token guard actually works.
    func testStalePollDoesNotClobberFresherActionTriggeredReload() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggjobs-a.test": (taskJSON(key: "stale-task", name: "Stale"), 200)]
        let viewModel = AggregateJobsViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let sectionViewModel = viewModel.viewModel(for: serverA)
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)

        // Simulate a stale in-flight poll: mint a token as if a load had
        // started, but don't apply its result yet.
        let staleToken = sectionViewModel.beginLoad()

        // A fresher action-triggered reload happens next and completes.
        await viewModel.reload(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertEqual(sectionViewModel.tasks.first?.key, "stale-task")

        // The stale fetch (from before the reload) now resolves and tries
        // to apply its (older) result — it must be dropped since a newer
        // token has since been minted.
        sectionViewModel.apply(.success([AdminTask(key: "should-not-appear", name: "Old", description: "", category: "c", state: "idle", progress: 0, progressMessage: nil, manualOnly: false, triggers: [])]), token: staleToken, sessionState: nil)

        XCTAssertEqual(sectionViewModel.tasks.first?.key, "stale-task")
    }
}
