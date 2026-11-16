import XCTest
@testable import BloemAdmin

/// The app works with every Silo server. What Bloem adds switches on only for a server that answers
/// `GET /api/bloem/v2/capabilities`; on a plain Silo server the extras are not there and nothing under `/api/bloem/`
/// is asked beyond that one check.
@MainActor
final class PlainSiloGatingTests: XCTestCase {
    typealias F = PlatformFixtures

    nonisolated private let http = MockHTTPHarness()
    private let capabilities = "/api/bloem/v2/capabilities"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func bloemPaths() -> [String] {
        http.state.requestLog.compactMap { $0.url?.path }.filter { $0.hasPrefix("/api/bloem/") }
    }

    // MARK: The All servers menu

    func testTheAllServersMenuHasNoPlatformGroupWhenNoServerIsABloemServer() {
        let menu = AdminDestination.allServers(organizationsVisible: false)

        XCTAssertFalse(menu.contains { $0.id == AdminDestination.organizations.id })
        XCTAssertNil(AdminDestination.grouped(menu).first { $0.group == .platform }, "no empty Platform group")
        XCTAssertEqual(AdminDestination.grouped(menu).first?.pages.first?.id, AdminDestination.dashboard.id)
        XCTAssertEqual(AdminDestination.effective(selectedID: AdminDestination.organizations.id, in: menu)?.id, AdminDestination.startID,
                       "a remembered Organizations page falls back to the start page")
    }

    func testTheAllServersMenuLeadsWithOrganizationsWhenAServerIsABloemServer() {
        let menu = AdminDestination.allServers(organizationsVisible: true)

        XCTAssertEqual(menu.first?.id, AdminDestination.organizations.id)
        XCTAssertEqual(menu.dropFirst().map(\.id), AdminDestination.allServers(organizationsVisible: false).map(\.id),
                       "every other page is the same with or without Bloem")
    }

    func testAMenuOfOnlyPlainSiloServersKeepsEverySiloPage() {
        let ids = Set(AdminDestination.allServers(organizationsVisible: false).map(\.id))
        for page in [AdminDestination.dashboard, .nowPlaying, .libraries, .requests, .users, .playbackHistory, .nodes,
                     .settings, .scheduledTasks, .backups, .plugins, .audit] {
            XCTAssertTrue(ids.contains(page.id), "\(page.id) is a Silo page")
        }
    }

    // MARK: One server

    func testASingleServerMenuHasNoBloemPagesForAPlainSiloServer() {
        let ids = AdminDestination.singleServer(tenantsVisible: false, supportAccessVisible: false).map(\.id)
        XCTAssertFalse(ids.contains(AdminDestination.organizations.id))
        XCTAssertFalse(ids.contains(AdminDestination.supportAccess.id))
    }

    func testAPlainSiloServerGetsNeitherBloemPageAndIsAskedOnce() async {
        http.state.stubPlainSilo()
        let store = makeIsolatedServerStore()
        let client = store.client(for: .fixture, session: http.session)

        let organizations = await PlatformOrganizationsEligibility.check(client: client)
        let support = await SupportAccessEligibility.check(client: client)

        XCTAssertFalse(organizations)
        XCTAssertFalse(support)
        XCTAssertEqual(bloemPaths(), [capabilities], "one check, then nothing")
        XCTAssertTrue(http.state.requests(path: "/api/v2/account/me").isEmpty, "no Owner lookup for a page that cannot exist")
    }

    func testABloemServerStillGetsOrganizationsAndSupportAccess() async {
        http.state.stubBloemServer(featureTokens: ["organization_support_v1"])
        http.state.stub(path: "/api/v2/account/me", data: F.data(#"{"id":"1"}"#))
        http.state.stub(path: "/api/v2/admin/users/1", json: UserFixtures.user(id: "1", username: "root", overrides: ["role": "admin", "is_owner": true]))
        let store = makeIsolatedServerStore()
        let client = store.client(for: .fixture, session: http.session)

        let organizations = await PlatformOrganizationsEligibility.check(client: client)
        let support = await SupportAccessEligibility.check(client: client)

        XCTAssertTrue(organizations)
        XCTAssertTrue(support)
        XCTAssertEqual(http.state.requests(path: capabilities).count, 1, "both pages share one answer")
    }

    // MARK: The organization lookup

    func testAPlainSiloServerIsNeverAskedForItsOrganizations() async throws {
        http.state.stubPlainSilo()
        let store = makeIsolatedServerStore()
        let client = store.client(for: .fixture, session: http.session)

        for _ in 0..<3 {
            let contexts = try await client.discoverAdminContexts()
            XCTAssertTrue(contexts.isEmpty)
        }
        let listed = try await client.listAdminContexts(platformAdmin: true)

        XCTAssertTrue(listed.isEmpty)
        XCTAssertEqual(bloemPaths(), [capabilities], "asked once for the whole session")
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/server/status").isEmpty, "no platform probe either")
    }

    func testABloemServerStillListsItsOrganizations() async throws {
        http.state.stubBloemServer()
        http.state.stub(path: "/api/v2/admin/server/status", data: F.data(PlatformFixtures.error("forbidden")), status: 403)
        http.state.stub(path: "/api/bloem/v2/organizations", data: F.data(OrganizationFixtures.memberships(OrganizationFixtures.membership())))
        let store = makeIsolatedServerStore()
        let client = store.client(for: .fixture, session: http.session)

        let contexts = try await client.discoverAdminContexts()

        XCTAssertEqual(contexts.map(\.name), ["Acme Media"])
        XCTAssertEqual(http.state.requests(path: "/api/bloem/v2/organizations").count, 1)
    }

    func testAServerThatCannotBeAskedIsNotTakenForPlainSiloAndIsAskedAgain() async throws {
        http.state.stubSequence(path: capabilities, responses: [
            MockHTTPResponse(transportError: .timedOut),
            MockHTTPResponse(data: Data(#"{"api":"bloem/v2","feature_tokens":[]}"#.utf8)),
        ])
        http.state.stub(path: "/api/v2/admin/server/status", data: F.data(PlatformFixtures.error("forbidden")), status: 403)
        http.state.stub(path: "/api/bloem/v2/organizations", data: F.data(OrganizationFixtures.memberships(OrganizationFixtures.membership())))
        let store = makeIsolatedServerStore()
        let client = store.client(for: .fixture, session: http.session)

        do {
            _ = try await client.discoverAdminContexts()
            XCTFail("the failure reaches the caller, which keeps the dropdown as it was")
        } catch {}
        let contexts = try await client.discoverAdminContexts()

        XCTAssertEqual(contexts.map(\.name), ["Acme Media"])
    }

    // MARK: All servers › Organizations

    private let hostA = "gating-a.test"
    private let hostB = "gating-b.test"
    private lazy var serverA = AdminServer(id: "gating-A", baseURL: URL(string: "https://\(hostA)")!, displayName: "Server A")
    private lazy var serverB = AdminServer(id: "gating-B", baseURL: URL(string: "https://\(hostB)")!, displayName: "Server B")

    private func loadAggregate(_ store: ServerStore) async -> AggregatePlatformOrganizationsModel {
        try? store.updateToken("tok-a", forServerID: serverA.id)
        try? store.updateToken("tok-b", forServerID: serverB.id)
        let sessionState = AdminSessionState()
        let clients = store.authenticatedClients(for: [serverA, serverB], sessionState: sessionState, session: http.session)
        let model = AggregatePlatformOrganizationsModel()
        await model.loadAll(
            servers: [serverA, serverB], store: store, sessionState: sessionState,
            resolveClient: { clients[$0.id]! }, session: http.session
        )
        return model
    }

    func testTheAggregatePageAsksOnlyForTheCapabilitiesOfPlainSiloServers() async {
        for host in [hostA, hostB] {
            http.state.stub(host: host, path: capabilities, data: Data("404 page not found".utf8), status: 404)
        }
        let store = makeIsolatedServerStore()

        let model = await loadAggregate(store)

        XCTAssertEqual(model.state(for: serverA), .unavailable)
        XCTAssertEqual(model.state(for: serverB), .unavailable)
        XCTAssertEqual(bloemPaths(), [capabilities, capabilities], "one capabilities check per server and nothing else")
        XCTAssertFalse(store.bloemDetector.anyKnownBloem(in: [serverA.baseURL, serverB.baseURL]), "so the menu has no Organizations")
    }

    func testOneBloemServerAmongPlainSiloServersKeepsOrganizationsInTheMenu() async {
        http.state.stub(host: hostA, path: capabilities, data: F.data(#"{"api":"bloem/v2","identity_schema":2,"features":{},"media_types":[],"feature_tokens":[]}"#))
        http.state.stub(host: hostA, path: F.mint, data: F.data(F.platformPass("pass-a")))
        http.state.stub(host: hostA, path: F.base, data: F.data(F.page(F.organization())))
        http.state.stub(host: hostB, path: capabilities, data: Data("404 page not found".utf8), status: 404)
        let store = makeIsolatedServerStore()

        let model = await loadAggregate(store)

        if case .loaded(let organizations, _) = model.state(for: serverA) {
            XCTAssertEqual(organizations.map(\.name), ["Riverside Club"])
        } else {
            XCTFail("the Bloem server lists its organizations: \(model.state(for: serverA))")
        }
        XCTAssertEqual(model.state(for: serverB), .unavailable)
        XCTAssertTrue(store.bloemDetector.anyKnownBloem(in: [serverA.baseURL, serverB.baseURL]))
        XCTAssertTrue(http.state.requests(host: hostB).allSatisfy { $0.url?.path == capabilities }, "the plain Silo server is asked nothing else")
    }

    // MARK: A removed server

    func testARemovedServerIsForgotten() async throws {
        http.state.stubBloemServer()
        let store = makeIsolatedServerStore()
        try store.addServer(.fixture, accessToken: "t")
        let client = store.client(for: .fixture, session: http.session)
        _ = await client.isBloemServer()
        XCTAssertTrue(store.bloemDetector.anyKnownBloem(in: [AdminServer.fixture.baseURL]))

        try store.removeServer(AdminServer.fixture.id)

        XCTAssertFalse(store.bloemDetector.anyKnownBloem(in: [AdminServer.fixture.baseURL]))
    }
}
