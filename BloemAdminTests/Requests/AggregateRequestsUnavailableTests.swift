import XCTest
@testable import BloemAdmin

/// All servers: a server with no request administration says so in its own section, without a Retry, and is
/// left alone by the poll; pulling down asks it again.
@MainActor
final class AggregateRequestsUnavailableTests: XCTestCase {
    private let serverA = AdminServer(id: "unavail-A", baseURL: URL(string: "https://unavail-a.test")!, displayName: "Server A")
    private let serverB = AdminServer(id: "unavail-B", baseURL: URL(string: "https://unavail-b.test")!, displayName: "Server B")
    nonisolated private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private let unavailable = Data(#"{"type":"https://unavail-a.test/problems/dependency_unavailable","title":"Dependency unavailable","status":503,"detail":"The request administration service is not available on this server."}"#.utf8)

    private func rows(_ id: String) -> Data {
        Data(#"{"items":[\#(RequestsViewModelTests.mediaRequestJSON(id: id, title: "Movie \(id)"))]}"#.utf8)
    }

    private func environment() throws -> (store: ServerStore, state: AdminSessionState, resolve: ServerClientResolver) {
        let store = makeIsolatedServerStore()
        try store.updateToken("tok-a", forServerID: serverA.id)
        try store.updateToken("tok-b", forServerID: serverB.id)
        let state = AdminSessionState()
        let clients = store.authenticatedClients(for: [serverA, serverB], sessionState: state, session: http.session)
        return (store, state, { server in clients[server.id] ?? store.client(for: server, sessionState: state, session: self.http.session) })
    }

    func testAServerWithoutRequestAdministrationIsUnavailableNotFailed() async throws {
        http.state.hostOverrides = ["unavail-a.test": (unavailable, 503), "unavail-b.test": (rows("r2"), 200)]
        let (store, state, resolve) = try environment()
        let model = AggregateRequestsViewModel()

        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: state, resolveClient: resolve)

        XCTAssertTrue(model.isUnavailable(serverA))
        XCTAssertNil(model.failure(for: serverA), "nothing to retry")
        XCTAssertTrue(model.viewModel(for: serverA).requests.isEmpty)
        XCTAssertFalse(model.isUnavailable(serverB))
        XCTAssertEqual(model.viewModel(for: serverB).requests.map(\.id), ["r2"])
    }

    func testThePollSkipsAnUnavailableServer() async throws {
        http.state.hostOverrides = ["unavail-a.test": (unavailable, 503), "unavail-b.test": (rows("r2"), 200)]
        let (store, state, resolve) = try environment()
        let model = AggregateRequestsViewModel()
        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: state, resolveClient: resolve)
        let askedA = http.state.requests(host: "unavail-a.test").count

        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: state, resolveClient: resolve)

        XCTAssertEqual(http.state.requests(host: "unavail-a.test").count, askedA, "polling stopped for that server")
        XCTAssertGreaterThan(http.state.requests(host: "unavail-b.test").count, 1, "the others keep being read")
    }

    func testPullingToRefreshAsksAgainAndTheServerRecovers() async throws {
        http.state.hostOverrides = ["unavail-a.test": (unavailable, 503), "unavail-b.test": (rows("r2"), 200)]
        let (store, state, resolve) = try environment()
        let model = AggregateRequestsViewModel()
        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: state, resolveClient: resolve)

        http.state.hostOverrides = ["unavail-a.test": (rows("r1"), 200), "unavail-b.test": (rows("r2"), 200)]
        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: state, resolveClient: resolve, includeUnavailable: true)

        XCTAssertFalse(model.isUnavailable(serverA))
        XCTAssertEqual(model.viewModel(for: serverA).requests.map(\.id), ["r1"])
    }

    func testReloadingOneServerAfterItAnswersAgainClearsTheMark() async throws {
        http.state.hostOverrides = ["unavail-a.test": (unavailable, 503), "unavail-b.test": (rows("r2"), 200)]
        let (store, state, resolve) = try environment()
        let model = AggregateRequestsViewModel()
        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: state, resolveClient: resolve)

        http.state.hostOverrides = ["unavail-a.test": (rows("r1"), 200), "unavail-b.test": (rows("r2"), 200)]
        await model.reload(server: serverA, store: store, sessionState: state, resolveClient: resolve)

        XCTAssertFalse(model.isUnavailable(serverA))
        XCTAssertEqual(model.viewModel(for: serverA).requests.map(\.id), ["r1"])
    }

    func testAnotherFailureStillShowsAsAFailureWithRetry() async throws {
        http.state.hostOverrides = ["unavail-a.test": (Data(), 500), "unavail-b.test": (rows("r2"), 200)]
        let (store, state, resolve) = try environment()
        let model = AggregateRequestsViewModel()

        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: state, resolveClient: resolve)

        XCTAssertFalse(model.isUnavailable(serverA))
        XCTAssertNotNil(model.failure(for: serverA))
    }
}
