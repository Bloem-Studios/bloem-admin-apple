import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateLibrariesViewModelTests: XCTestCase {
    private let serverAID = "agglib-srv-A"
    private let serverBID = "agglib-srv-B"
    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://agglib-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://agglib-b.test")!, displayName: "Server B")
    nonisolated private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    private func stubServer(host: String, libraryName: String, scans: [[String: Any]] = []) {
        http.state.stub(host: host, path: "/api/v2/libraries", data: json(["items": [["id": "1", "name": libraryName, "type": "movies", "paths": ["/m"], "enabled": true]]]))
        http.state.stub(host: host, path: "/api/v2/scan/capabilities", data: json(["revision": "r", "state": "available"]))
        http.state.stub(host: host, path: "/api/v2/admin/autoscan/scans", data: json(["items": scans, "page": ["has_more": false], "total": scans.count]))
        http.state.stub(host: host, path: "/api/v2/admin/jobs", data: json(["items": [Any]()]))
    }

    private func makeStoreWithTokens() throws -> ServerStore {
        let store = makeIsolatedServerStore()
        try store.updateToken("tok-a", forServerID: serverAID)
        try store.updateToken("tok-b", forServerID: serverBID)
        return store
    }

    private func makeResolveClient(store: ServerStore, sessionState: AdminSessionState) -> ServerClientResolver {
        let clients = store.authenticatedClients(for: [serverA, serverB], sessionState: sessionState, session: http.session)
        return { server in clients[server.id] ?? store.client(for: server, sessionState: sessionState, session: self.http.session) }
    }

    func testLoadAllSectionsLibrariesByServer() async throws {
        stubServer(host: "agglib-a.test", libraryName: "Movies A")
        stubServer(host: "agglib-b.test", libraryName: "Movies B")
        let store = try makeStoreWithTokens()
        let sessionState = AdminSessionState()
        let viewModel = AggregateLibrariesViewModel()

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: makeResolveClient(store: store, sessionState: sessionState))

        XCTAssertEqual(viewModel.viewModel(for: serverA).libraries.map(\.name), ["Movies A"])
        XCTAssertEqual(viewModel.viewModel(for: serverB).libraries.map(\.name), ["Movies B"])
        XCTAssertNil(viewModel.failure(for: serverA))
        XCTAssertNil(viewModel.failure(for: serverB))
    }

    func testAFailingServerGetsItsOwnFailureWithoutAffectingTheOthers() async throws {
        stubServer(host: "agglib-a.test", libraryName: "Movies A")
        http.state.stub(host: "agglib-b.test", data: json(["error": "invalid_token", "message": "Token expired"]), status: 401)
        let store = try makeStoreWithTokens()
        let sessionState = AdminSessionState()
        let viewModel = AggregateLibrariesViewModel()

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: makeResolveClient(store: store, sessionState: sessionState))

        XCTAssertEqual(viewModel.viewModel(for: serverA).libraries.map(\.name), ["Movies A"])
        XCTAssertNil(viewModel.failure(for: serverA))
        XCTAssertTrue(viewModel.viewModel(for: serverB).libraries.isEmpty)
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testAScanOnOneServersRowOnlyReachesThatServer() async throws {
        stubServer(host: "agglib-a.test", libraryName: "Movies A")
        stubServer(host: "agglib-b.test", libraryName: "Movies B")
        http.state.stub(host: "agglib-b.test", path: "/api/v2/scan", data: json(["status": "accepted", "mode": "library", "library_id": "1"]), status: 202)
        let store = try makeStoreWithTokens()
        let sessionState = AdminSessionState()
        let resolve = makeResolveClient(store: store, sessionState: sessionState)
        let viewModel = AggregateLibrariesViewModel()
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)

        let sectionB = viewModel.viewModel(for: serverB)
        await sectionB.scan(sectionB.libraries[0], client: resolve(serverB), sessionState: sessionState.scoped(to: serverBID))

        XCTAssertEqual(http.state.requests(host: "agglib-b.test", path: "/api/v2/scan").count, 1)
        XCTAssertTrue(http.state.requests(host: "agglib-a.test", path: "/api/v2/scan").isEmpty)
        XCTAssertEqual(sectionB.scanState(for: sectionB.libraries[0]), .queued(count: 1))
        XCTAssertEqual(viewModel.viewModel(for: serverA).scanState(for: viewModel.viewModel(for: serverA).libraries[0]), .idle)
    }

    func testActionErrorsInAllServersNameTheServer() async throws {
        stubServer(host: "agglib-a.test", libraryName: "Movies A")
        stubServer(host: "agglib-b.test", libraryName: "Movies B")
        http.state.stub(host: "agglib-a.test", path: "/api/v2/scan", data: json(["type": "about:blank", "title": "Conflict", "status": 409, "detail": "already queued"]), status: 409)
        let store = try makeStoreWithTokens()
        let sessionState = AdminSessionState()
        let resolve = makeResolveClient(store: store, sessionState: sessionState)
        let viewModel = AggregateLibrariesViewModel()
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)

        let sectionA = viewModel.viewModel(for: serverA)
        await sectionA.scan(sectionA.libraries[0], client: resolve(serverA), sessionState: sessionState.scoped(to: serverAID))

        XCTAssertTrue(sectionA.actionErrorMessage?.hasPrefix("Server A: ") == true, sectionA.actionErrorMessage ?? "nil")
        XCTAssertNil(viewModel.viewModel(for: serverB).actionErrorMessage)
    }

    func testReloadRefreshesOnlyTheNamedServer() async throws {
        stubServer(host: "agglib-a.test", libraryName: "Movies A")
        stubServer(host: "agglib-b.test", libraryName: "Movies B")
        let store = try makeStoreWithTokens()
        let sessionState = AdminSessionState()
        let resolve = makeResolveClient(store: store, sessionState: sessionState)
        let viewModel = AggregateLibrariesViewModel()
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolve)
        let before = http.state.requests(host: "agglib-a.test", path: "/api/v2/libraries").count

        await viewModel.reload(server: serverB, store: store, sessionState: sessionState, resolveClient: resolve)

        XCTAssertEqual(http.state.requests(host: "agglib-a.test", path: "/api/v2/libraries").count, before)
        XCTAssertEqual(http.state.requests(host: "agglib-b.test", path: "/api/v2/libraries").count, 2)
    }
}
