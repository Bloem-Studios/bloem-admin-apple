import XCTest
@testable import BloemAdmin

/// The All servers dashboard: one model per server, each keeping its own values, sign-in and
/// failure state.
@MainActor
final class AggregateDashboardViewModelTests: XCTestCase {
    private let serverA = AdminServer(id: "aggdash-A", baseURL: URL(string: "https://aggdash-a.test")!, displayName: "Server A")
    private let serverB = AdminServer(id: "aggdash-B", baseURL: URL(string: "https://aggdash-b.test")!, displayName: "Server B")

    /// XCTest makes a fresh instance per test, so each test gets its own harness.
    nonisolated private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    /// The healthy routes of one host, with its own movie count.
    private func routes(host: String, movies: Int) -> [String: MockHTTPState.ResponseTuple] {
        var result: [String: MockHTTPState.ResponseTuple] = [:]
        for (path, response) in DashboardViewModelTests.healthyRoutes() {
            result["\(host)|\(path)"] = response
        }
        let stats = DashboardViewModelTests.statsJSON.replacingOccurrences(of: "\"total_movies\": 400", with: "\"total_movies\": \(movies)")
        result["\(host)|/api/v2/admin/stats"] = (Data(stats.utf8), 200)
        return result
    }

    private func environment(tokens: [String]) throws -> (ServerStore, AdminSessionState, ServerClientResolver) {
        let store = makeIsolatedServerStore()
        for id in tokens { try store.updateToken("tok-\(id)", forServerID: id) }
        let sessionState = AdminSessionState()
        let clients = store.authenticatedClients(for: [serverA, serverB], sessionState: sessionState, session: http.session)
        let resolve: ServerClientResolver = { server in
            clients[server.id] ?? store.client(for: server, sessionState: sessionState, session: self.http.session)
        }
        return (store, sessionState, resolve)
    }

    func testEachServerKeepsItsOwnValues() async throws {
        http.state.hostPathOverrides = routes(host: "aggdash-a.test", movies: 400).merging(routes(host: "aggdash-b.test", movies: 7)) { $1 }
        let (store, sessionState, resolve) = try environment(tokens: [serverA.id, serverB.id])
        let viewModel = AggregateDashboardViewModel()

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)

        XCTAssertEqual(viewModel.orderedServers.map(\.id), [serverA.id, serverB.id])
        XCTAssertEqual(viewModel.model(for: serverA)?.stats?.totalMovies, 400)
        XCTAssertEqual(viewModel.model(for: serverB)?.stats?.totalMovies, 7)
        XCTAssertNil(viewModel.model(for: serverA)?.serverFailure)
        XCTAssertNil(viewModel.model(for: serverB)?.serverFailure)
        // Every section loads per server: the same sections the single-server screen has.
        XCTAssertEqual(viewModel.model(for: serverA)?.insights.top.value?.titles.first?.title, "Dune")
        XCTAssertEqual(http.state.requests(host: "aggdash-b.test", path: "/api/v2/admin/stats/top-activity").count, 1)
    }

    func testAServerWithNoSignInIsNotAskedAndOffersSignInWhileTheOtherLoads() async throws {
        http.state.hostPathOverrides = routes(host: "aggdash-a.test", movies: 400).merging(routes(host: "aggdash-b.test", movies: 7)) { $1 }
        let (store, sessionState, resolve) = try environment(tokens: [serverA.id])
        let viewModel = AggregateDashboardViewModel()

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)

        XCTAssertEqual(viewModel.model(for: serverA)?.stats?.totalMovies, 400)
        XCTAssertEqual(viewModel.model(for: serverB)?.authFailure?.kind, .signedOut)
        XCTAssertEqual(viewModel.model(for: serverB)?.serverFailure?.recoveryAction, .signIn)
        XCTAssertTrue(http.state.requests(host: "aggdash-b.test").isEmpty, "a signed-out server is not asked")
    }

    func testAnExpiredServerIsFlaggedByItsOwnRejectionAndNotAskedAgain() async throws {
        var overrides = routes(host: "aggdash-a.test", movies: 400)
        for (path, _) in DashboardViewModelTests.healthyRoutes() {
            overrides["aggdash-b.test|\(path)"] = (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401)
        }
        http.state.hostPathOverrides = overrides
        let (store, sessionState, resolve) = try environment(tokens: [serverA.id, serverB.id])
        sessionState.setAdministratorToken("tok-\(serverA.id)", serverID: serverA.id)
        sessionState.setAdministratorToken("tok-\(serverB.id)", serverID: serverB.id)
        let viewModel = AggregateDashboardViewModel()

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)

        XCTAssertFalse(sessionState.isTokenExpired(for: serverA.id))
        XCTAssertTrue(sessionState.isTokenExpired(for: serverB.id))
        XCTAssertEqual(viewModel.model(for: serverB)?.authFailure?.kind, .signedOut)
        XCTAssertEqual(viewModel.model(for: serverA)?.stats?.totalMovies, 400)
        XCTAssertNil(viewModel.model(for: serverA)?.serverFailure)

        let before = http.state.requests(host: "aggdash-b.test").count
        await viewModel.load(server: serverB, store: store, sessionState: sessionState, resolveClient: resolve)
        XCTAssertEqual(http.state.requests(host: "aggdash-b.test").count, before, "an expired server waits for Sign In")
    }

    func testAFailingServerShowsItsOwnFailureAndNeverTouchesTheOther() async throws {
        var overrides = routes(host: "aggdash-a.test", movies: 400)
        for (path, _) in DashboardViewModelTests.healthyRoutes() {
            overrides["aggdash-b.test|\(path)"] = (Data(#"{"error":"boom","message":"Server B is down"}"#.utf8), 500)
        }
        http.state.hostPathOverrides = overrides
        let (store, sessionState, resolve) = try environment(tokens: [serverA.id, serverB.id])
        let viewModel = AggregateDashboardViewModel()

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)

        let b = try XCTUnwrap(viewModel.model(for: serverB))
        XCTAssertEqual(b.errorMessage, "Server B is down")
        XCTAssertEqual(b.serverFailure?.kind, .serverFailure)
        XCTAssertEqual(b.serverFailure?.recoveryAction, .retry)
        XCTAssertFalse(b.hasAnyValue)
        XCTAssertEqual(viewModel.model(for: serverA)?.stats?.totalMovies, 400)
        XCTAssertNil(viewModel.model(for: serverA)?.errorMessage)
    }

    func testAFailingServerKeepsItsLastGoodValuesBesideTheFailure() async throws {
        http.state.hostPathOverrides = routes(host: "aggdash-a.test", movies: 400)
        let (store, sessionState, resolve) = try environment(tokens: [serverA.id])
        let viewModel = AggregateDashboardViewModel()
        await viewModel.loadAll(servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolve)

        var overrides = routes(host: "aggdash-a.test", movies: 400)
        overrides["aggdash-a.test|/api/v2/admin/stats"] = (Data(#"{"error":"boom","message":"Stats are down"}"#.utf8), 500)
        http.state.hostPathOverrides = overrides
        await viewModel.load(server: serverA, store: store, sessionState: sessionState, resolveClient: resolve, forceRefresh: true)

        let a = try XCTUnwrap(viewModel.model(for: serverA))
        XCTAssertEqual(a.stats?.totalMovies, 400)
        XCTAssertEqual(a.errorMessage, "Stats are down")
        XCTAssertEqual(a.serverFailure?.kind, .serverFailure)
        XCTAssertTrue(a.hasAnyValue)
    }

    func testChartWindowsAreChosenPerServer() async throws {
        http.state.hostPathOverrides = routes(host: "aggdash-a.test", movies: 400).merging(routes(host: "aggdash-b.test", movies: 7)) { $1 }
        let (store, sessionState, resolve) = try environment(tokens: [serverA.id, serverB.id])
        let viewModel = AggregateDashboardViewModel()
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)

        viewModel.model(for: serverA)?.selectRange(.week)
        await viewModel.loadCharts(server: serverA, sessionState: sessionState, resolveClient: resolve)

        XCTAssertEqual(viewModel.model(for: serverA)?.ranges.egress, .week)
        XCTAssertEqual(viewModel.model(for: serverB)?.ranges.egress, .day)
        XCTAssertNotNil(viewModel.model(for: serverA)?.insights.series(for: .week).value)
        let weekReadsB = http.state.requests(host: "aggdash-b.test", path: "/api/v2/admin/stats/timeseries").filter { $0.url?.query == "hours=168" }
        XCTAssertTrue(weekReadsB.isEmpty, "choosing a window on one server never reads another")
    }

    func testReconcileKeepsExistingModelsAndDropsRemovedServers() {
        let viewModel = AggregateDashboardViewModel()
        viewModel.reconcile(servers: [serverA, serverB])
        let first = viewModel.model(for: serverA)
        viewModel.model(for: serverA)?.selectRange(.month)

        viewModel.reconcile(servers: [serverA])

        XCTAssertTrue(viewModel.model(for: serverA) === first)
        XCTAssertEqual(viewModel.model(for: serverA)?.ranges.streams, .month, "a server keeps its window choice")
        XCTAssertNil(viewModel.model(for: serverB))
        XCTAssertEqual(viewModel.orderedServers.map(\.id), [serverA.id])
    }
}
