import XCTest
@testable import BloemAdmin

@MainActor
final class UserSessionsViewModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }
    private let sessionsPath = "/api/v2/admin/users/42/login-sessions"
    private let devicesPath = "/api/v2/admin/users/42/devices"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func loginSession(id: String = "s1", overrides: [String: Any] = [:]) -> [String: Any] {
        var session: [String: Any] = [
            "id": id,
            "device_name": "iPhone",
            "ip_address": "203.0.113.7",
            "created_at": "2026-01-01T00:00:00.000Z",
            "expires_at": "2026-02-01T00:00:00.000Z",
            "last_seen_at": NSNull(),
            "current": false,
        ]
        session.merge(overrides) { _, new in new }
        return session
    }

    private func sessionsBody(_ items: [[String: Any]], next: String? = nil) -> [String: Any] {
        var body = UserFixtures.page(items, next: next)
        body["current_session"] = NSNull()
        return body
    }

    private func device(id: String = "d1", overrides: [String: Any] = [:]) -> [String: Any] {
        var device: [String: Any] = [
            "device_id": id,
            "device_name": "Living Room",
            "device_platform": "tvOS",
            "last_seen_at": "2026-01-01T00:00:00.000Z",
            "last_updated": NSNull(),
            "override_count": 2,
            "profiles": [[
                "profile_id": "p1", "profile_name": "Household", "override_count": 2, "last_seen_at": NSNull(),
            ]],
        ]
        device.merge(overrides) { _, new in new }
        return device
    }

    private func stubEmpty() {
        http.state.stubSequence(path: sessionsPath, responses: [UserFixtures.response(sessionsBody([]))])
        http.state.stubSequence(path: devicesPath, responses: [UserFixtures.response(UserFixtures.page([]))])
    }

    // MARK: - Load

    func testInitialSessionsAndDevicesAreLoadingRatherThanEmpty() {
        let viewModel = UserSessionsViewModel()

        XCTAssertEqual(viewModel.sessionsPresentation, .loading)
        XCTAssertEqual(viewModel.devicesPresentation, .loading)
    }

    func testSuccessfulZeroItemLoadResolvesSessionsAndDevicesToEmpty() async {
        stubEmpty()
        let viewModel = UserSessionsViewModel()

        await viewModel.load(userID: "42", client: client)

        XCTAssertEqual(viewModel.sessionsPresentation, .empty)
        XCTAssertEqual(viewModel.devicesPresentation, .empty)
    }

    func testLoadDecodesLoginSessionsAndPagesWithLimit() async throws {
        http.state.stubSequence(path: sessionsPath, responses: [
            UserFixtures.response(sessionsBody([loginSession(id: "s1", overrides: ["device_id": "dev-1", "device_platform": "iOS", "current": true, "last_seen_at": "2026-01-05T00:00:00.000Z"])], next: "c2")),
            UserFixtures.response(sessionsBody([loginSession(id: "s2", overrides: ["device_name": "", "ip_address": ""])])),
        ])
        http.state.stubSequence(path: devicesPath, responses: [UserFixtures.response(UserFixtures.page([]))])
        let viewModel = UserSessionsViewModel()

        await viewModel.load(userID: "42", client: client)

        XCTAssertEqual(viewModel.sessions.map(\.id), ["s1", "s2"])
        let first = try XCTUnwrap(viewModel.sessions.first)
        XCTAssertEqual(first.deviceName, "iPhone")
        XCTAssertEqual(first.deviceId, "dev-1")
        XCTAssertEqual(first.devicePlatform, "iOS")
        XCTAssertEqual(first.ipAddress, "203.0.113.7")
        XCTAssertTrue(first.current)
        XCTAssertNotNil(first.lastSeenAt)
        XCTAssertNil(viewModel.sessions[1].deviceId)
        let requests = http.state.requests(path: sessionsPath)
        XCTAssertEqual(requests.count, 2)
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)).queryItems
        XCTAssertEqual(query?.map(\.name), ["limit"])
        XCTAssertEqual(query?.first?.value, "200")
    }

    func testLoadDecodesDevicesAndSendsNoQuery() async throws {
        http.state.stubSequence(path: sessionsPath, responses: [UserFixtures.response(sessionsBody([]))])
        http.state.stubSequence(path: devicesPath, responses: [UserFixtures.response(UserFixtures.page([
            device(), device(id: "d2", overrides: ["last_seen_at": NSNull(), "profiles": [Any]()]),
        ]))])
        let viewModel = UserSessionsViewModel()

        await viewModel.load(userID: "42", client: client)

        XCTAssertEqual(viewModel.devices.map(\.deviceId), ["d1", "d2"])
        let first = try XCTUnwrap(viewModel.devices.first)
        XCTAssertEqual(first.deviceName, "Living Room")
        XCTAssertEqual(first.devicePlatform, "tvOS")
        XCTAssertEqual(first.overrideCount, 2)
        XCTAssertEqual(first.profiles.map(\.profileName), ["Household"])
        XCTAssertNil(viewModel.devices[1].lastSeenAt)
        let request = try XCTUnwrap(http.state.requests(path: devicesPath).first)
        XCTAssertNil(request.url?.query, "the devices route declares no paging parameters")
    }

    func testUserIDInThePathIsEncodedAsOneSegment() async throws {
        http.state.stubSequence(path: "/api/v2/admin/users/a b/c/login-sessions", responses: [UserFixtures.response(sessionsBody([]))])
        http.state.stubSequence(path: "/api/v2/admin/users/a b/c/devices", responses: [UserFixtures.response(UserFixtures.page([]))])
        let viewModel = UserSessionsViewModel()

        await viewModel.load(userID: "a b/c", client: client)

        let request = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/users/a b/c/login-sessions").first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/users/a%20b%2Fc/login-sessions")
        XCTAssertEqual(viewModel.sessionsPresentation, .empty)
    }

    func testSessionsSuccessIsPreservedWhenDevicesFailLater() async {
        http.state.stub(path: sessionsPath, response: UserFixtures.response(sessionsBody([loginSession()])))
        http.state.stub(
            path: devicesPath,
            response: MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Devices unavailable"}"#.utf8), status: 500),
            delayUntilReleased: true
        )
        let client = self.client
        let viewModel = UserSessionsViewModel()

        let load = Task { await viewModel.load(userID: "42", client: client) }
        await http.state.waitForCompletion(path: sessionsPath)
        await http.state.waitForRequest(path: devicesPath)
        http.state.releaseResponses(matching: devicesPath)
        await load.value

        XCTAssertNil(viewModel.sessionsErrorMessage)
        XCTAssertEqual(viewModel.devicesErrorMessage, "Devices unavailable")
        XCTAssertEqual(viewModel.sessionsPresentation, .content)
        XCTAssertEqual(viewModel.devicesPresentation, .failure)
    }

    func testDevicesSuccessIsPreservedWhenSessionsFailLater() async {
        http.state.stub(
            path: sessionsPath,
            response: MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Sessions unavailable"}"#.utf8), status: 500),
            delayUntilReleased: true
        )
        http.state.stub(path: devicesPath, response: UserFixtures.response(UserFixtures.page([device()])))
        let client = self.client
        let viewModel = UserSessionsViewModel()

        let load = Task { await viewModel.load(userID: "42", client: client) }
        await http.state.waitForCompletion(path: devicesPath)
        await http.state.waitForRequest(path: sessionsPath)
        http.state.releaseResponses(matching: sessionsPath)
        await load.value

        XCTAssertEqual(viewModel.sessionsErrorMessage, "Sessions unavailable")
        XCTAssertNil(viewModel.devicesErrorMessage)
        XCTAssertEqual(viewModel.sessionsPresentation, .failure)
        XCTAssertEqual(viewModel.devicesPresentation, .content)
    }

    func testAggregateLoadFailureNamesTheServer() async {
        http.state.stubSequence(path: sessionsPath, responses: [MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Down"}"#.utf8), status: 500)])
        http.state.stubSequence(path: devicesPath, responses: [UserFixtures.response(UserFixtures.page([]))])
        let viewModel = UserSessionsViewModel()
        viewModel.serverName = "Home"

        await viewModel.load(userID: "42", client: client)

        XCTAssertEqual(viewModel.sessionsErrorMessage, "Home: Down")
    }

    // MARK: - Revoke

    func testRevokeSessionSendsDeleteToTheLoginSessionPathWithoutIfMatch() async throws {
        http.state.stubSequence(path: "\(sessionsPath)/s1", responses: [MockHTTPResponse(status: 204)])
        let viewModel = UserSessionsViewModel()
        let target = try JSONDecoder.iso8601.decode(AuthSession.self, from: JSONSerialization.data(withJSONObject: loginSession()))

        await viewModel.revokeSession(target, userID: "42", client: client)

        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(http.state.lastRequest?.url?.path, "\(sessionsPath)/s1")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "DELETE")
        XCTAssertNil(http.state.lastRequest?.value(forHTTPHeaderField: "If-Match"))
    }

    func testRevokeSessionFailureSetsActionErrorMessage() async throws {
        http.state.stubSequence(path: "\(sessionsPath)/s1", responses: [MockHTTPResponse(data: Data(#"{"error":"not_found","message":"Session not found"}"#.utf8), status: 404)])
        let viewModel = UserSessionsViewModel()
        let target = try JSONDecoder.iso8601.decode(AuthSession.self, from: JSONSerialization.data(withJSONObject: loginSession()))

        await viewModel.revokeSession(target, userID: "42", client: client)

        XCTAssertEqual(viewModel.actionErrorMessage, "Session not found")
    }

    func testRevokeAllSessionsReportsTheRevokedCount() async {
        http.state.stubSequence(path: sessionsPath, responses: [UserFixtures.response(["revoked": 3])])
        let viewModel = UserSessionsViewModel()

        await viewModel.revokeAllSessions(userID: "42", client: client)

        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(viewModel.revokedCount, 3)
        XCTAssertEqual(http.state.lastRequest?.url?.path, sessionsPath)
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "DELETE")
    }

    func testRevokeAllSessionsFailureSetsActionErrorMessageAndNoCount() async {
        http.state.stubSequence(path: sessionsPath, responses: [MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Could not revoke sessions"}"#.utf8), status: 500)])
        let viewModel = UserSessionsViewModel()

        await viewModel.revokeAllSessions(userID: "42", client: client)

        XCTAssertEqual(viewModel.actionErrorMessage, "Could not revoke sessions")
        XCTAssertNil(viewModel.revokedCount)
    }
}
