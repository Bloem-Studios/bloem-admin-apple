import XCTest
@testable import BloemAdmin

@MainActor
final class AggregateRequestsViewModelTests: XCTestCase {
    private let serverAID = "aggreq-srv-A"
    private let serverBID = "aggreq-srv-B"

    private lazy var serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://aggreq-a.test")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://aggreq-b.test")!, displayName: "Server B")

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

    private func requestsJSON(id: String, title: String) -> Data {
        Data(#"{"items":[\#(RequestsViewModelTests.mediaRequestJSON(id: id, title: title))]}"#.utf8)
    }

    func testLoadAllSectionsRequestsByServer() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggreq-a.test": (requestsJSON(id: "r1", title: "Movie A"), 200),
            "aggreq-b.test": (requestsJSON(id: "r2", title: "Movie B"), 200),
        ]
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).requests.first?.title, "Movie A")
        XCTAssertEqual(viewModel.viewModel(for: serverB).requests.first?.title, "Movie B")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertNil(viewModel.viewModel(for: serverB).errorMessage)
    }

    func testLoadAllFailingServerProducesErrorSectionWithoutAffectingOthers() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggreq-a.test": (requestsJSON(id: "r1", title: "Movie A"), 200),
            "aggreq-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.viewModel(for: serverA).requests.first?.title, "Movie A")
        XCTAssertNil(viewModel.viewModel(for: serverA).errorMessage)
        XCTAssertTrue(viewModel.viewModel(for: serverB).requests.isEmpty)
        XCTAssertEqual(viewModel.viewModel(for: serverB).errorMessage, "Token expired")
        XCTAssertEqual(viewModel.failure(for: serverB)?.kind, .signedOut)
        XCTAssertEqual(viewModel.failure(for: serverB)?.recoveryAction, .signIn)
        XCTAssertTrue(sessionState.isTokenExpired(for: serverBID))
        XCTAssertFalse(sessionState.isTokenExpired(for: serverAID))
    }

    func testDetailRefreshFailurePublishesTypedRecovery() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggreq-a.test": (Data(#"{"error":"temporary","message":"Unavailable"}"#.utf8), 503)]
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: makeSession())

        await viewModel.refreshAfterDetailMutation(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertEqual(viewModel.failure(for: serverA)?.kind, .serverFailure)
        XCTAssertEqual(viewModel.failure(for: serverA)?.recoveryAction, .retry)
    }

    func testActionOnOneServersSectionDoesNotTouchAnotherServersSection() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = [
            "aggreq-a.test": (requestsJSON(id: "r1", title: "Movie A"), 200),
            "aggreq-b.test": (requestsJSON(id: "r2", title: "Movie B"), 200),
        ]
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let (clients, resolveClient) = makeResolveClient(servers: [serverA, serverB], store: store, sessionState: sessionState, session: session)
        await viewModel.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolveClient)

        let sectionA = viewModel.viewModel(for: serverA)
        let sectionB = viewModel.viewModel(for: serverB)
        let target = sectionA.requests[0]

        http.state.hostOverrides = [:]
        http.state.responseData = Data()
        http.state.responseStatus = 200

        await sectionA.approve(target, client: clients[serverAID]!, sessionState: sessionState.scoped(to: serverAID))

        XCTAssertNil(sectionA.actionErrorMessage)
        XCTAssertNil(sectionB.actionErrorMessage)
        XCTAssertEqual(sectionB.requests.first?.title, "Movie B")
        XCTAssertNil(sectionB.errorMessage)
    }

    func testStalePollDoesNotClobberFresherActionTriggeredReload() async throws {
        let store = try makeStoreWithTokens()
        http.state.hostOverrides = ["aggreq-a.test": (requestsJSON(id: "fresh", title: "Fresh"), 200)]
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let session = makeSession()
        let sectionViewModel = viewModel.viewModel(for: serverA)
        let (_, resolveClient) = makeResolveClient(servers: [serverA], store: store, sessionState: sessionState, session: session)

        let staleToken = sectionViewModel.beginLoad()

        await viewModel.reload(server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertEqual(sectionViewModel.requests.first?.title, "Fresh")

        let stale = MediaRequest(id: "stale", provider: "p", mediaType: "movie", title: "Stale", status: "pending", outcome: "none", requestedByUserID: "1", lastError: nil)
        sectionViewModel.apply(.success([stale]), token: staleToken, sessionState: nil)

        XCTAssertEqual(sectionViewModel.requests.first?.title, "Fresh")
    }

    // MARK: Requester names

    private func usersJSON(_ accounts: [(id: String, name: String)]) -> Data {
        let items = accounts.map { #"{"id":"\#($0.id)","username":"\#($0.name)","email":"x@example.test","role":"user","enabled":true}"# }
        return Data(#"{"items":[\#(items.joined(separator: ","))]}"#.utf8)
    }

    private func stubServers(
        usersA: Data = Data(), statusA: Int = 200,
        usersB: Data = Data(), statusB: Int = 200
    ) {
        http.state.stub(host: "aggreq-a.test", path: "/api/v2/admin/requests", data: requestsJSON(id: "r1", title: "Movie A"))
        http.state.stub(host: "aggreq-b.test", path: "/api/v2/admin/requests", data: requestsJSON(id: "r2", title: "Movie B"))
        http.state.stub(host: "aggreq-a.test", path: "/api/v2/admin/users", data: usersA, status: statusA)
        http.state.stub(host: "aggreq-b.test", path: "/api/v2/admin/users", data: usersB, status: statusB)
    }

    func testRequestersAreNamedFromEachServersOwnAccountList() async throws {
        let store = try makeStoreWithTokens()
        stubServers(usersA: usersJSON([("68", "alex")]), usersB: usersJSON([("68", "bella")]))
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let servers = [serverA, serverB]
        let (_, resolveClient) = makeResolveClient(servers: servers, store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)

        await viewModel.loadNames(servers: servers, resolveClient: resolveClient)

        let a = try XCTUnwrap(viewModel.viewModel(for: serverA).requests.first)
        let b = try XCTUnwrap(viewModel.viewModel(for: serverB).requests.first)
        XCTAssertEqual(viewModel.requester(for: a, on: serverA), "alex")
        XCTAssertEqual(viewModel.requester(for: b, on: serverB), "bella")
    }

    func testARequesterWhoseServerHasNoAccountListStaysUserID() async throws {
        let store = try makeStoreWithTokens()
        stubServers(usersA: usersJSON([("68", "alex")]), usersB: Data(#"{"error":"boom","message":"Down"}"#.utf8), statusB: 500)
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let servers = [serverA, serverB]
        let (_, resolveClient) = makeResolveClient(servers: servers, store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)

        await viewModel.loadNames(servers: servers, resolveClient: resolveClient)

        let a = try XCTUnwrap(viewModel.viewModel(for: serverA).requests.first)
        let b = try XCTUnwrap(viewModel.viewModel(for: serverB).requests.first)
        XCTAssertEqual(viewModel.requester(for: a, on: serverA), "alex")
        XCTAssertEqual(viewModel.requester(for: b, on: serverB), "User 68")
    }

    func testNamesAreReadOncePerServerAndRetriedOnlyWhereTheReadFailed() async throws {
        let store = try makeStoreWithTokens()
        stubServers(usersA: usersJSON([("68", "alex")]), usersB: Data(#"{"error":"boom","message":"Down"}"#.utf8), statusB: 500)
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let servers = [serverA, serverB]
        let (_, resolveClient) = makeResolveClient(servers: servers, store: store, sessionState: sessionState, session: makeSession())

        await viewModel.loadNames(servers: servers, resolveClient: resolveClient)
        await viewModel.loadNames(servers: servers, resolveClient: resolveClient)

        XCTAssertEqual(http.state.requests(host: "aggreq-a.test", path: "/api/v2/admin/users").count, 1)
        XCTAssertEqual(http.state.requests(host: "aggreq-b.test", path: "/api/v2/admin/users").count, 2)
    }

    // MARK: Busy rows

    func testARowRefusesASecondActionWhileTheFirstIsInFlight() async throws {
        let store = try makeStoreWithTokens()
        stubServers()
        let approvePath = "/api/v2/admin/requests/r1/approve"
        http.state.stub(path: approvePath, response: MockHTTPResponse(), delayUntilReleased: true)
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let servers = [serverA, serverB]
        let (_, resolveClient) = makeResolveClient(servers: servers, store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
        let request = try XCTUnwrap(viewModel.viewModel(for: serverA).requests.first)

        let first = Task {
            await viewModel.perform(.approve, on: request, reason: nil, server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)
        }
        await http.state.waitForRequest(path: approvePath)

        XCTAssertTrue(viewModel.isBusy(request, on: serverA))
        XCTAssertFalse(viewModel.isBusy(request, on: serverB))
        let second = await viewModel.perform(.approve, on: request, reason: nil, server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)
        XCTAssertFalse(second)

        http.state.releaseResponses(matching: approvePath)
        let accepted = await first.value
        XCTAssertTrue(accepted)
        XCTAssertFalse(viewModel.isBusy(request, on: serverA))
        XCTAssertEqual(http.state.requests(path: approvePath).count, 1)
    }

    func testARefusedActionClearsTheBusyMarkAndKeepsTheServersMessage() async throws {
        let store = try makeStoreWithTokens()
        stubServers()
        let declinePath = "/api/v2/admin/requests/r1/decline"
        http.state.stub(path: declinePath, data: Data(#"{"error":"conflict","message":"Already closed"}"#.utf8), status: 409)
        let viewModel = AggregateRequestsViewModel()
        let sessionState = AdminSessionState()
        let servers = [serverA, serverB]
        let (_, resolveClient) = makeResolveClient(servers: servers, store: store, sessionState: sessionState, session: makeSession())
        await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
        let request = try XCTUnwrap(viewModel.viewModel(for: serverA).requests.first)

        let accepted = await viewModel.perform(.decline, on: request, reason: "no", server: serverA, store: store, sessionState: sessionState, resolveClient: resolveClient)

        XCTAssertFalse(accepted)
        XCTAssertFalse(viewModel.isBusy(request, on: serverA))
        XCTAssertEqual(viewModel.viewModel(for: serverA).actionErrorMessage, "Server A: Already closed")
        XCTAssertNil(viewModel.viewModel(for: serverB).actionErrorMessage)
    }
}
