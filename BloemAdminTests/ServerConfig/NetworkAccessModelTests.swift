import XCTest
@testable import BloemAdmin

/// Network access (server:internal/apiv2/network_access.go): `GET /network-access/capabilities` lists the
/// providers, `GET /admin/network-access/{provider}/status` the hosts, and connect and disconnect
/// answer 202 with the state each host reached.
@MainActor
final class NetworkAccessModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func host(_ id: String, role: String = "api", name: String = "Main", state: String, extra: [String: Any] = [:]) -> [String: Any] {
        var json: [String: Any] = ["host": ["id": id, "role": role, "name": name], "state": state, "addresses": [String]()]
        json.merge(extra) { _, new in new }
        return json
    }

    private func stubProvider(hosts: [[String: Any]]) {
        http.state.stub(path: "/api/v2/network-access/capabilities", json: [
            "state": "available", "providers": [["provider": "tailscale", "display_name": "Tailscale", "installation_id": "9"]],
        ])
        http.state.stub(path: "/api/v2/admin/network-access/tailscale/status", json: ["provider": "tailscale", "hosts": hosts])
    }

    func testLoadListsProvidersWithTheirHosts() async {
        stubProvider(hosts: [
            host("api", state: "connected", extra: ["origin": "https://main.example.test", "hostname": "main.example.test"]),
            host("node:2", role: "proxy", name: "Edge", state: "awaiting_authorization", extra: ["auth_url": "https://login.tailscale.com/a/abc"]),
        ])
        let model = NetworkAccessModel()

        await model.load(client: client)

        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.entries.map(\.provider.displayName), ["Tailscale"])
        let hosts = model.entries.first?.hosts ?? []
        XCTAssertEqual(hosts.map(\.id), ["api", "node:2"])
        XCTAssertEqual(hosts.map(\.stateLabel), ["Connected", "Waiting for authorization"])
        XCTAssertEqual(hosts.map(\.title), ["API server · Main", "Proxy node · Edge"])
        XCTAssertEqual(hosts.last?.authorizationURL?.host, "login.tailscale.com")
        XCTAssertEqual(hosts.first?.origin, "https://main.example.test")
    }

    func testNoProvidersInstalledIsAnEmptyListNotAnError() async {
        http.state.stub(path: "/api/v2/network-access/capabilities", json: ["state": "not_configured", "providers": [Any]()])
        let model = NetworkAccessModel()

        await model.load(client: client)

        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNil(model.loadFailure)
    }

    func testAProviderWhoseStatusCannotBeReadKeepsItsRowWithTheReason() async {
        http.state.stub(path: "/api/v2/network-access/capabilities", json: ["providers": [["provider": "tailscale", "display_name": "Tailscale", "installation_id": "9"]]])
        http.state.stub(path: "/api/v2/admin/network-access/tailscale/status", response: MockHTTPResponse(
            data: Data(#"{"error":"not_found","message":"Unknown provider"}"#.utf8), status: 404
        ))
        let model = NetworkAccessModel()

        await model.load(client: client)

        XCTAssertEqual(model.entries.first?.error, "Unknown provider")
        XCTAssertEqual(model.entries.first?.hosts.count, 0)
    }

    func testConnectNamesTheHostAndTakesTheStateItReached() async throws {
        stubProvider(hosts: [host("api", state: "disconnected")])
        let model = NetworkAccessModel()
        await model.load(client: client)
        http.state.stub(path: "/api/v2/admin/network-access/tailscale/connect", response: MockHTTPResponse(
            json: ["provider": "tailscale", "hosts": [host("api", state: "awaiting_authorization", extra: ["auth_url": "https://login.tailscale.com/a/x"])]], status: 202
        ))
        let entry = try XCTUnwrap(model.entries.first)
        let target = try XCTUnwrap(entry.hosts.first)

        await model.connect(provider: entry.provider, host: target, client: client)

        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(http.state.capturedBody)) as? [String: Any])
        XCTAssertEqual(body["hosts"] as? [String], ["api"])
        XCTAssertEqual(model.entries.first?.hosts.first?.state, "awaiting_authorization")
        XCTAssertTrue(model.busyHostIDs.isEmpty)
        XCTAssertNil(model.actionError)
    }

    func testDisconnectFailureKeepsTheStateAndSaysWhatToDo() async throws {
        stubProvider(hosts: [host("api", state: "connected")])
        let model = NetworkAccessModel(serverName: "Alpha")
        await model.load(client: client)
        http.state.stub(path: "/api/v2/admin/network-access/tailscale/disconnect", response: MockHTTPResponse(
            data: Data(#"{"error":"x","message":"The plugin is not running"}"#.utf8), status: 503
        ))
        let entry = try XCTUnwrap(model.entries.first)
        let target = try XCTUnwrap(entry.hosts.first)

        await model.disconnect(provider: entry.provider, host: target, client: client)

        XCTAssertEqual(model.entries.first?.hosts.first?.state, "connected")
        XCTAssertEqual(model.actionError, "Alpha: The plugin is not running")
    }

    func testAnAuthorizationAddressThatIsNotAWebAddressIsNotOffered() {
        XCTAssertNil(NetworkAccessHost(id: "api", state: "awaiting_authorization", authURL: "javascript:alert(1)").authorizationURL)
        XCTAssertNil(NetworkAccessHost(id: "api", state: "awaiting_authorization", authURL: "not a url").authorizationURL)
        XCTAssertNotNil(NetworkAccessHost(id: "api", state: "awaiting_authorization", authURL: "https://login.tailscale.com/a/1").authorizationURL)
    }

    func testStateLabelsUseTheWebsWords() {
        let labels = ["disconnected", "awaiting_authorization", "connecting", "connected", "error", "unavailable", "mystery"]
            .map { NetworkAccessHost(id: "api", state: $0).stateLabel }
        XCTAssertEqual(labels, ["Disconnected", "Waiting for authorization", "Connecting", "Connected", "Error", "Plugin not running", "Error"])
    }
}
