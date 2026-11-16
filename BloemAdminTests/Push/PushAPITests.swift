import XCTest
@testable import BloemAdmin

/// The admin push routes, as the Bloem server contract shapes them.
final class PushAPITests: XCTestCase {
    nonisolated private let http = MockHTTPHarness()
    private let base = URL(string: "https://home.example.test")!

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func api() -> URLSessionPushDisplayAPI { URLSessionPushDisplayAPI(session: http.session) }

    private func client() -> APIClient {
        APIClient(baseURL: base, accessToken: "access-1", session: http.session)
    }

    // MARK: Registration (the administrator's own sign-in)

    func testRegistrationSendsTheContractsBodyWithTheSignIn() async throws {
        http.state.stub(
            path: "/api/bloem/v2/admin/push/devices",
            json: ["device_id": "dev1", "display_token": "bad_abc", "kinds": [["kind": "admin.scan_failed", "enabled": true, "server_emitted": true]]]
        )
        let registered = try await client().registerPushDevice(PushRegisterRequest(
            installationID: "install-0001", platform: "apple", token: "ab12cd", apnsEnvironment: "sandbox",
            apnsTopic: "com.bloemstudios.admin", disabledKinds: ["admin.scan_failed"]
        ))

        XCTAssertEqual(registered.deviceID, "dev1")
        XCTAssertEqual(registered.displayToken, "bad_abc")
        XCTAssertEqual(registered.kinds, [PushKindState(kind: "admin.scan_failed", enabled: true, serverEmitted: true)])

        let request = try XCTUnwrap(http.state.requests(path: "/api/bloem/v2/admin/push/devices").first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        let body = try XCTUnwrap(http.state.body(path: "/api/bloem/v2/admin/push/devices", requestIndex: 0))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["installation_id"] as? String, "install-0001")
        XCTAssertEqual(json["platform"] as? String, "apple")
        XCTAssertEqual(json["token"] as? String, "ab12cd")
        XCTAssertEqual(json["apns_environment"] as? String, "sandbox")
        XCTAssertEqual(json["apns_topic"] as? String, "com.bloemstudios.admin")
        XCTAssertEqual(json["disabled_kinds"] as? [String], ["admin.scan_failed"])
        XCTAssertEqual(Set(json.keys), ["installation_id", "platform", "token", "apns_environment", "apns_topic", "disabled_kinds"])
    }

    func testTheFeatureTokenAndTopicAreTheServersNames() {
        XCTAssertEqual(adminPushFeatureToken, "admin_push_v1")
        XCTAssertEqual(adminPushAPNsTopic, "com.bloemstudios.admin")
    }

    func testARegistrationAnswerMayOmitItsKindList() throws {
        let registered = try JSONDecoder().decode(PushRegistered.self, from: Data(#"{"device_id":"d","display_token":"bad_x"}"#.utf8))
        XCTAssertEqual(registered.kinds, [])
    }

    func testRegistrationCarriesTheWidgetReportWhenKnownAndNothingWhenNot() async throws {
        http.state.stub(path: "/api/bloem/v2/admin/push/devices", json: ["device_id": "dev1", "display_token": "bad_abc"])
        let base = PushRegisterRequest(
            installationID: "install-0001", platform: "apple", token: "ab12cd", apnsEnvironment: "sandbox",
            apnsTopic: "com.bloemstudios.admin", disabledKinds: []
        )
        _ = try await client().registerPushDevice(base.reporting(WidgetReport(placed: true, channels: [.requests, .sessions])))
        _ = try await client().registerPushDevice(base.reporting(.nothingPlaced))
        _ = try await client().registerPushDevice(base)

        func json(_ index: Int) throws -> [String: Any] {
            let body = try XCTUnwrap(http.state.body(path: "/api/bloem/v2/admin/push/devices", requestIndex: index))
            return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        }
        let placed = try json(0)
        XCTAssertEqual(placed["widgets_placed"] as? Bool, true)
        XCTAssertEqual(placed["widget_channels"] as? [String], ["requests", "sessions"])
        let none = try json(1)
        XCTAssertEqual(none["widgets_placed"] as? Bool, false)
        XCTAssertNil(none["widget_channels"], "the server wants channels only when something is placed")
        let unknown = try json(2)
        XCTAssertNil(unknown["widgets_placed"], "omitted keeps what the server holds")
        XCTAssertNil(unknown["widget_channels"])
    }

    func testTheRegistrationAnswerCarriesWhatTheServerHoldsForWidgets() throws {
        let held = try JSONDecoder().decode(PushRegistered.self, from: Data(
            #"{"device_id":"d","display_token":"bad_x","widgets_placed":true,"widget_channels":["nodes","playlists","requests"]}"#.utf8
        ))
        XCTAssertEqual(held.widgets, WidgetReport(placed: true, channels: [.nodes, .requests]), "a channel this build lacks is dropped")
        let cleared = try JSONDecoder().decode(PushRegistered.self, from: Data(
            #"{"device_id":"d","display_token":"bad_x","widgets_placed":false,"widget_channels":[]}"#.utf8
        ))
        XCTAssertEqual(cleared.widgets, WidgetReport.nothingPlaced)
        let older = try JSONDecoder().decode(PushRegistered.self, from: Data(#"{"device_id":"d","display_token":"bad_x"}"#.utf8))
        XCTAssertNil(older.widgets, "a server that does not know widgets")
    }

    func testTheWidgetReportIsPutToTheDevicesWidgetsRoute() async throws {
        let path = "/api/bloem/v2/admin/push/devices/dev1/widgets"
        http.state.stub(path: path, json: ["widgets_placed": true, "channels": ["nodes", "requests"]])

        let answer = try await client().setPushWidgets(deviceID: "dev1", report: WidgetReport(placed: true, channels: [.requests, .nodes]))

        XCTAssertEqual(answer.report, WidgetReport(placed: true, channels: [.nodes, .requests]))
        let request = try XCTUnwrap(http.state.requests(path: path).first)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
        let body = try XCTUnwrap(http.state.body(path: path, requestIndex: 0))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["widgets_placed"] as? Bool, true)
        XCTAssertEqual(json["channels"] as? [String], ["nodes", "requests"])
        XCTAssertEqual(Set(json.keys), ["widgets_placed", "channels"])
    }

    func testRemovingTheLastWidgetPutsNotPlacedWithAnEmptyList() async throws {
        let path = "/api/bloem/v2/admin/push/devices/dev1/widgets"
        http.state.stub(path: path, json: ["widgets_placed": false, "channels": [String]()])
        let answer = try await client().setPushWidgets(deviceID: "dev1", report: .nothingPlaced)
        XCTAssertEqual(answer.report, WidgetReport.nothingPlaced)
        let body = try XCTUnwrap(http.state.body(path: path, requestIndex: 0))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["widgets_placed"] as? Bool, false)
        XCTAssertEqual(json["channels"] as? [String], [], "channels is a required field, sent empty")
        XCTAssertEqual(PushPaths.widgets(deviceID: "a/b"), "/api/bloem/v2/admin/push/devices/a%2Fb/widgets")
    }

    func testTheKindSwitchPatchesOneDevicesKinds() async throws {
        http.state.stub(path: "/api/bloem/v2/admin/push/devices/dev1/kinds", json: ["kinds": [["kind": "admin.scan_failed", "enabled": false, "server_emitted": true]]])
        let answer = try await client().setPushKinds(deviceID: "dev1", kinds: ["admin.scan_failed": false])

        XCTAssertEqual(answer.kinds.first?.enabled, false)
        let path = "/api/bloem/v2/admin/push/devices/dev1/kinds"
        XCTAssertEqual(http.state.requests(path: path).first?.httpMethod, "PATCH")
        let body = try XCTUnwrap(http.state.body(path: path, requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: [String: Bool]], ["kinds": ["admin.scan_failed": false]])
    }

    func testDeletingADeviceUsesTheSignIn() async throws {
        http.state.stub(path: "/api/bloem/v2/admin/push/devices/dev1", data: Data(), status: 204)
        try await client().deletePushDevice(deviceID: "dev1")
        let request = try XCTUnwrap(http.state.requests(path: "/api/bloem/v2/admin/push/devices/dev1").first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer access-1")
    }

    func testADeviceIdIsOnePathSegment() async throws {
        try await client().deletePushDevice(deviceID: "a/b")
        let sent = try XCTUnwrap(http.state.requestLog.last?.url?.absoluteString)
        XCTAssertTrue(sent.hasSuffix("/api/bloem/v2/admin/push/devices/a%2Fb"), sent)
        XCTAssertEqual(PushPaths.device("a/b"), "/api/bloem/v2/admin/push/devices/a%2Fb")
        XCTAssertEqual(PushPaths.content("dev1.abc-1"), "/api/bloem/v2/admin/push/content/dev1.abc-1")
        XCTAssertEqual(PushPaths.retire(deviceID: "dev1"), "/api/bloem/v2/admin/push/devices/dev1/retire")
    }

    // MARK: Reading a notification (the display token, never a sign-in)

    func testTheTextIsReadWithTheDisplayTokenAndTheIdAsPushed() async throws {
        http.state.stub(path: "/api/bloem/v2/admin/push/content/dev1.abc-1", data: Data(PushSamples.requestJSON.utf8))

        let result = await api().content(baseURL: base, displayToken: "bad_tok", contentID: "dev1.abc-1")

        guard case .content(let content) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(content.title, "Sam requested Dune")
        let request = try XCTUnwrap(http.state.requests(path: "/api/bloem/v2/admin/push/content/dev1.abc-1").first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bad_tok")
        XCTAssertEqual(request.httpBody, nil)
    }

    func testAnUnknownOrExpiredNotificationIsGone() async {
        for status in [401, 403, 404] {
            http.state.stub(path: "/api/bloem/v2/admin/push/content/dev1.abc-1", data: Data(#"{"error":"x"}"#.utf8), status: status)
            let result = await api().content(baseURL: base, displayToken: "bad_tok", contentID: "dev1.abc-1")
            XCTAssertEqual(result, .gone, "\(status)")
        }
    }

    func testAServerErrorOrNonsenseIsAFailure() async {
        http.state.stub(path: "/api/bloem/v2/admin/push/content/dev1.abc-1", data: Data(), status: 503)
        let unavailable = await api().content(baseURL: base, displayToken: "t", contentID: "dev1.abc-1")
        XCTAssertEqual(unavailable, .failed)

        http.state.stub(path: "/api/bloem/v2/admin/push/content/dev1.abc-1", data: Data("<html>hi</html>".utf8))
        let html = await api().content(baseURL: base, displayToken: "t", contentID: "dev1.abc-1")
        XCTAssertEqual(html, .failed)
    }

    func testNoConnectionIsAFailureNotACrash() async {
        http.state.stub(path: "/api/bloem/v2/admin/push/content/dev1.abc-1", response: MockHTTPResponse(transportError: .notConnectedToInternet))
        let result = await api().content(baseURL: base, displayToken: "t", contentID: "dev1.abc-1")
        XCTAssertEqual(result, .failed)
    }

    func testAnInsecureAddressIsNeverCalled() async {
        let plain = URL(string: "http://home.example.test")!
        let content = await api().content(baseURL: plain, displayToken: "t", contentID: "dev1.abc-1")
        let retire = await api().retire(baseURL: plain, displayToken: "t", deviceID: "dev1")
        XCTAssertEqual(content, .failed)
        XCTAssertEqual(retire, .failed)
        XCTAssertEqual(http.state.requestLog.count, 0)
    }

    func testAServerUnderAPathPrefixKeepsItsPrefix() async throws {
        let prefixed = URL(string: "https://home.example.test/silo/")!
        http.state.stub(path: "/silo/api/bloem/v2/admin/push/content/dev1.abc-1", data: Data(PushSamples.requestJSON.utf8))
        let result = await api().content(baseURL: prefixed, displayToken: "t", contentID: "dev1.abc-1")
        guard case .content = result else { return XCTFail("\(result)") }
    }

    // MARK: Retiring (the display token, so it works with no sign-in left)

    func testRetiringPostsWithTheDisplayToken() async throws {
        http.state.stub(path: "/api/bloem/v2/admin/push/devices/dev1/retire", data: Data(), status: 204)
        let result = await api().retire(baseURL: base, displayToken: "bad_tok", deviceID: "dev1")

        XCTAssertEqual(result, .retired)
        let request = try XCTUnwrap(http.state.requests(path: "/api/bloem/v2/admin/push/devices/dev1/retire").first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer bad_tok")
    }

    func testARetireTheServerNoLongerRecognisesIsAsGoodAsDone() async {
        for status in [401, 404] {
            http.state.stub(path: "/api/bloem/v2/admin/push/devices/dev1/retire", data: Data(), status: status)
            let result = await api().retire(baseURL: base, displayToken: "t", deviceID: "dev1")
            XCTAssertEqual(result, .gone, "\(status)")
        }
        http.state.stub(path: "/api/bloem/v2/admin/push/devices/dev1/retire", data: Data(), status: 503)
        let unavailable = await api().retire(baseURL: base, displayToken: "t", deviceID: "dev1")
        XCTAssertEqual(unavailable, .failed)
    }

    // MARK: The contract

    private final class BundleToken {}

    func testTheDisplayRoutesAreOperationsOfTheServersContract() throws {
        let url = try XCTUnwrap(Bundle(for: BundleToken.self).url(forResource: "api-contract", withExtension: "json"))
        let contract = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: [String: [String: Any]]])

        let expected: [(String, String)] = [
            ("get", "/api/bloem/v2/admin/push/content/{delivery_id}"),
            ("post", "/api/bloem/v2/admin/push/devices"),
            ("delete", "/api/bloem/v2/admin/push/devices/{device_id}"),
            ("patch", "/api/bloem/v2/admin/push/devices/{device_id}/kinds"),
            ("put", "/api/bloem/v2/admin/push/devices/{device_id}/widgets"),
            ("post", "/api/bloem/v2/admin/push/devices/{device_id}/retire"),
        ]
        for (method, path) in expected {
            XCTAssertNotNil(contract[path]?[method], "\(method.uppercased()) \(path) is not in the contract")
        }
        XCTAssertEqual(contract["/api/bloem/v2/admin/push/devices"]?["post"]?["body_required"] as? Bool, true)
        XCTAssertEqual(contract["/api/bloem/v2/admin/push/devices/{device_id}/kinds"]?["patch"]?["body_required"] as? Bool, true)
        XCTAssertEqual(contract["/api/bloem/v2/admin/push/devices/{device_id}/widgets"]?["put"]?["body_required"] as? Bool, true)
    }
}
