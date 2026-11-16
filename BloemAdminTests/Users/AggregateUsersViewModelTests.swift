import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateUsersViewModelTests: XCTestCase {
    private let serverAID = "aggusers-srv-A"
    private let serverBID = "aggusers-srv-B"

    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://aggusers-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://aggusers-b.test")!, displayName: "Server B")

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

    private func usersJSON(id: Int, username: String) -> Data {
        let page = UserFixtures.page([UserFixtures.user(id: String(id), username: username)])
        return (try? JSONSerialization.data(withJSONObject: page)) ?? Data()
    }

    func testLoadAllSectionsUsersByServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggusers-a.test": (usersJSON(id: 1, username: "alice"), 200),
            "aggusers-b.test": (usersJSON(id: 2, username: "bob"), 200),
        ]
        let viewModel = AggregateUsersViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).users.first?.username, "alice")
        XCTAssertEqual(viewModel.viewModel(for: serverB).users.first?.username, "bob")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertNil(viewModel.viewModel(for: serverB).errorMessage)
    }

    func testLoadAllFailingServerProducesErrorSectionWithoutAffectingOthers() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggusers-a.test": (usersJSON(id: 1, username: "alice"), 200),
            "aggusers-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateUsersViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).users.first?.username, "alice")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertTrue(viewModel.viewModel(for: serverB).users.isEmpty)
        XCTAssertEqual(viewModel.viewModel(for: serverB).errorMessage, "Token expired")
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testDetailRefreshFailurePublishesTypedRecovery() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggusers-a.test": (Data(#"{"error":"temporary","message":"Unavailable"}"#.utf8), 503)]
        let viewModel = AggregateUsersViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.refreshAfterDetailMutation(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.failure(for: serverA)?.kind, .serverFailure)
        XCTAssertEqual(viewModel.failure(for: serverA)?.recoveryAction, .retry)
    }

    func testActionOnOneServersSectionDoesNotTouchAnotherServersSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggusers-a.test": (usersJSON(id: 1, username: "alice"), 200),
            "aggusers-b.test": (usersJSON(id: 2, username: "bob"), 200),
        ]
        let viewModel = AggregateUsersViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: session)
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        let sectionA = viewModel.viewModel(for: serverA)
        let sectionB = viewModel.viewModel(for: serverB)
        let target = sectionA.users[0]

        http.state.hostOverrides = [:]
        http.state.stubSequence(path: "/api/v2/admin/users/1", responses: [
            UserFixtures.response(UserFixtures.user(id: "1", username: "alice"), etag: "\"u1\""),
            MockHTTPResponse(status: 204),
        ], host: "aggusers-a.test")

        await sectionA.setEnabled(false, for: target, client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))

        XCTAssertNil(sectionA.actionErrorMessage)
        XCTAssertNil(sectionB.actionErrorMessage)
        XCTAssertEqual(sectionB.users.first?.username, "bob")
        XCTAssertNil(sectionB.errorMessage)
    }

    func testActionErrorOnOneServersSectionNamesThatServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggusers-a.test": (usersJSON(id: 1, username: "alice"), 200)]
        let viewModel = AggregateUsersViewModel()
        let sessionState = AdminSessionState()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: [serverA], store: store, sessionState: sessionState, resolveClient: resolveClient)
        let sectionA = viewModel.viewModel(for: serverA)
        http.state.hostOverrides = [:]
        http.state.stubSequence(path: "/api/v2/admin/users/1", responses: [
            MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8), status: 500),
        ], host: "aggusers-a.test")

        await sectionA.delete(sectionA.users[0], client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))

        XCTAssertEqual(sectionA.actionErrorMessage, "Server A: Not allowed")
    }

    func testStalePollDoesNotClobberFresherActionTriggeredReload() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggusers-a.test": (usersJSON(id: 3, username: "fresh"), 200)]
        let viewModel = AggregateUsersViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let sectionViewModel = viewModel.viewModel(for: serverA)
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)

        let staleToken = sectionViewModel.beginLoad()

        await viewModel.reload(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertEqual(sectionViewModel.users.first?.username, "fresh")

        let stale = AdminUser(id: "99", username: "stale", email: "stale@test.com", role: "user", enabled: true, maxStreams: nil, maxTranscodes: nil)
        sectionViewModel.apply(.success([stale]), token: staleToken, sessionState: nil)

        XCTAssertEqual(sectionViewModel.users.first?.username, "fresh")
    }

}
