import XCTest
@testable import BloemAdmin

/// All servers › Organizations: one section per saved server, each with that server's organizations, its own failure
/// or sign-in row, and nothing from one server leaking into another's section.
@MainActor
final class AggregatePlatformOrganizationsModelTests: XCTestCase {
    typealias F = PlatformFixtures

    private let hostA = "aggorgs-a.test"
    private let hostB = "aggorgs-b.test"
    private lazy var serverA = AdminServer(id: "aggorgs-A", baseURL: URL(string: "https://\(hostA)")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: "aggorgs-B", baseURL: URL(string: "https://\(hostB)")!, displayName: "Server B")

    nonisolated private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func store(tokens: Bool = true) throws -> ServerStore {
        let store = makeIsolatedServerStore()
        if tokens {
            try store.updateToken("tok-a", forServerID: serverA.id)
            try store.updateToken("tok-b", forServerID: serverB.id)
        }
        return store
    }

    private func resolver(_ store: ServerStore, _ sessionState: AdminSessionState) -> ServerClientResolver {
        let clients = store.authenticatedClients(for: [serverA, serverB], sessionState: sessionState, session: http.session)
        return { server in clients[server.id] ?? store.client(for: server, sessionState: sessionState, session: self.http.session) }
    }

    private func bloem(_ host: String, organizations: String) {
        http.state.stub(host: host, path: "/api/bloem/v2/capabilities", data: F.data(#"{"api":"bloem/v2","identity_schema":2,"features":{},"media_types":[],"feature_tokens":[]}"#))
        http.state.stub(host: host, path: F.mint, data: F.data(F.platformPass("pass-\(host)")))
        http.state.stub(host: host, path: F.base, data: F.data(organizations))
    }

    private func load(_ model: AggregatePlatformOrganizationsModel, store: ServerStore) async {
        let sessionState = AdminSessionState()
        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolver(store, sessionState), session: http.session)
    }

    private func names(_ state: AggregatePlatformOrganizationsModel.SectionState) -> [String]? {
        if case .loaded(let organizations, _) = state { return organizations.map(\.name) }
        return nil
    }

    func testEachServerGetsItsOwnSectionFromItsOwnPlatformPass() async throws {
        let store = try store()
        bloem(hostA, organizations: F.page(F.organization(name: "Riverside Club")))
        bloem(hostB, organizations: F.page(F.organization(id: F.otherOrgID, name: "Harbor Studio", status: "suspended")))
        let model = AggregatePlatformOrganizationsModel()

        await load(model, store: store)

        XCTAssertEqual(names(model.state(for: serverA)), ["Riverside Club"])
        XCTAssertEqual(names(model.state(for: serverB)), ["Harbor Studio"])
        let passes = [hostA, hostB].map { host in http.state.requests(host: host, path: F.base).first?.value(forHTTPHeaderField: "Authorization") }
        XCTAssertEqual(passes, ["Bearer pass-\(hostA)", "Bearer pass-\(hostB)"], "each list is read with its own server's pass")
    }

    func testAServerThatIsNotABloemServerSaysOrganizationsAreNotAvailableThere() async throws {
        let store = try store()
        bloem(hostA, organizations: F.page(F.organization()))
        http.state.stub(host: hostB, path: "/api/bloem/v2/capabilities", data: F.data(F.error("not_found")), status: 404)
        let model = AggregatePlatformOrganizationsModel()

        await load(model, store: store)

        XCTAssertEqual(model.state(for: serverB), .unavailable)
        XCTAssertEqual(names(model.state(for: serverA)), ["Riverside Club"])
        XCTAssertTrue(http.state.requests(host: hostB, path: F.base).isEmpty, "no platform call to a server that has none")
    }

    func testAServerThatRefusesTheSignInGetsASignInRowAndTheOtherIsUnaffected() async throws {
        let store = try store()
        bloem(hostA, organizations: F.page(F.organization()))
        http.state.stub(host: hostB, path: "/api/bloem/v2/capabilities", data: F.data(#"{"api":"bloem/v2","feature_tokens":[]}"#))
        http.state.stub(host: hostB, path: F.mint, data: F.data(F.error("invalid_token", message: "Token expired")), status: 401)
        let model = AggregatePlatformOrganizationsModel()
        let sessionState = AdminSessionState()

        await model.loadAll(servers: [serverA, serverB], store: store, sessionState: sessionState, resolveClient: resolver(store, sessionState), session: http.session)

        guard case .failed(let failure) = model.state(for: serverB) else { return XCTFail("expected a failure for B") }
        XCTAssertEqual(failure.kind, .signedOut)
        XCTAssertEqual(failure.recoveryAction, .signIn)
        XCTAssertEqual(names(model.state(for: serverA)), ["Riverside Club"])
    }

    func testAServerWithNoSavedSignInIsNotAskedAnything() async throws {
        let store = try store(tokens: false)
        let model = AggregatePlatformOrganizationsModel()

        await load(model, store: store)

        guard case .failed(let failure) = model.state(for: serverA) else { return XCTFail("expected a failure") }
        XCTAssertEqual(failure.kind, .signedOut)
        XCTAssertTrue(http.state.requests(host: hostA, path: "/api/bloem/v2/capabilities").isEmpty)
    }

    func testTheSearchAndTheStatusAreSentToEveryServer() async throws {
        let store = try store()
        bloem(hostA, organizations: F.page())
        bloem(hostB, organizations: F.page())
        let model = AggregatePlatformOrganizationsModel()
        model.query = " river "
        model.statusFilter = .suspended

        await load(model, store: store)

        for host in [hostA, hostB] {
            let url = try XCTUnwrap(http.state.requests(host: host, path: F.base).first?.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }), ["query": "river", "status": "suspended", "limit": "50"], host)
        }
    }

    func testASectionWithMoreThanOnePageSaysSo() async throws {
        let store = try store()
        bloem(hostA, organizations: F.page(F.organization(), next: "c2"))
        bloem(hostB, organizations: F.page(F.organization(id: F.otherOrgID, name: "Harbor Studio")))
        let model = AggregatePlatformOrganizationsModel()

        await load(model, store: store)

        guard case .loaded(_, let moreOnA) = model.state(for: serverA), case .loaded(_, let moreOnB) = model.state(for: serverB) else {
            return XCTFail("both load")
        }
        XCTAssertTrue(moreOnA)
        XCTAssertFalse(moreOnB)
    }

    func testReloadingOneServerLeavesTheOthersSectionAlone() async throws {
        let store = try store()
        bloem(hostA, organizations: F.page(F.organization(name: "Riverside Club")))
        bloem(hostB, organizations: F.page(F.organization(id: F.otherOrgID, name: "Harbor Studio")))
        let model = AggregatePlatformOrganizationsModel()
        await load(model, store: store)
        http.state.stub(host: hostB, path: F.base, data: F.data(F.page(F.organization(id: F.otherOrgID, name: "Harbor Studio 2"))))
        let before = http.state.requests(host: hostA, path: F.base).count
        let sessionState = AdminSessionState()

        await model.reload(server: serverB, store: store, sessionState: sessionState, resolveClient: resolver(store, sessionState), session: http.session)

        XCTAssertEqual(names(model.state(for: serverB)), ["Harbor Studio 2"])
        XCTAssertEqual(names(model.state(for: serverA)), ["Riverside Club"])
        XCTAssertEqual(http.state.requests(host: hostA, path: F.base).count, before, "A was not asked again")
    }
}
