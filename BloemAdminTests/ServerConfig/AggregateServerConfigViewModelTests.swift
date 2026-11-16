import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateServerConfigViewModelTests: XCTestCase {
    private let serverAID = "aggcfg-srv-A"
    private let serverBID = "aggcfg-srv-B"

    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://aggcfg-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://aggcfg-b.test")!, displayName: "Server B")

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

    private func statusJSON(startedAt: String, restart: Bool = false, reasons: [String] = []) -> Data {
        let list = reasons.map { "\"\($0)\"" }.joined(separator: ",")
        return Data(#"{"started_at":"\#(startedAt)","restart_required":\#(restart),"restart_requested":false,"restart_required_reasons":[\#(list)],"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#.utf8)
    }

    private func makeResolveClient(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, session: URLSession) -> (clients: [String: APIClient], resolve: ServerClientResolver) {
        let clients = store.authenticatedClients(for: servers, sessionState: sessionState, session: session)
        return (clients, { server in clients[server.id] ?? store.client(for: server, sessionState: sessionState, session: session) })
    }

    private func setSuccess(host: String, startedAt: String, restart: Bool = false, reasons: [String] = []) {
        http.state.hostPathOverrides["\(host)|/api/v2/admin/server/status"] = (statusJSON(startedAt: startedAt, restart: restart, reasons: reasons), 200)
    }

    func testLoadAllReadsEachServersStatus() async throws {
        let store = try makeStoreWithTokens()
        setSuccess(host: "aggcfg-a.test", startedAt: "2026-01-01T00:00:00Z")
        setSuccess(host: "aggcfg-b.test", startedAt: "2026-02-02T00:00:00Z", restart: true, reasons: ["setting:server.public_url"])
        let viewModel = AggregateServerConfigViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.status(for: serverA)?.startedAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(viewModel.status(for: serverB)?.startedAt, "2026-02-02T00:00:00Z")
        XCTAssertEqual(viewModel.status(for: serverB).map(RestartStatus.reasonLabels), ["Public URL"])
        XCTAssertNil(viewModel.failure(for: serverA))
        XCTAssertNil(viewModel.failure(for: serverB))
    }

    func testLoadAllFailingServerProducesFailureWithoutAffectingOthers() async throws {
        let store = try makeStoreWithTokens()
        setSuccess(host: "aggcfg-a.test", startedAt: "2026-01-01T00:00:00Z")
        http.state.hostOverrides["aggcfg-b.test"] = (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401)
        let viewModel = AggregateServerConfigViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertNotNil(viewModel.status(for: serverA))
        XCTAssertNil(viewModel.failure(for: serverA))
        XCTAssertNil(viewModel.status(for: serverB))
        XCTAssertEqual(viewModel.failure(for: serverB)?.message, "Token expired")
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testReloadRefreshesOnlyThatServersRow() async throws {
        let store = try makeStoreWithTokens()
        setSuccess(host: "aggcfg-a.test", startedAt: "2026-01-01T00:00:00Z")
        setSuccess(host: "aggcfg-b.test", startedAt: "2026-02-02T00:00:00Z")
        let viewModel = AggregateServerConfigViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        setSuccess(host: "aggcfg-a.test", startedAt: "2026-03-03T00:00:00Z")
        setSuccess(host: "aggcfg-b.test", startedAt: "2026-04-04T00:00:00Z")
        await viewModel.reload(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.status(for: serverA)?.startedAt, "2026-03-03T00:00:00Z")
        XCTAssertEqual(viewModel.status(for: serverB)?.startedAt, "2026-02-02T00:00:00Z")
    }

    func testServersRemovedFromTheListLoseTheirStatus() async throws {
        let store = try makeStoreWithTokens()
        setSuccess(host: "aggcfg-a.test", startedAt: "2026-01-01T00:00:00Z")
        setSuccess(host: "aggcfg-b.test", startedAt: "2026-02-02T00:00:00Z")
        let viewModel = AggregateServerConfigViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        await viewModel.loadAll(servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertNotNil(viewModel.status(for: serverA))
        XCTAssertNil(viewModel.status(for: serverB))
    }
}
