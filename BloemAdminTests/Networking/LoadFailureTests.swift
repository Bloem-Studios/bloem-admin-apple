import XCTest
@testable import BloemAdmin

/// A single-server page that cannot load says what kind of failure it is, not "Connection lost"
/// for everything: it reuses the kinds the All servers sections already have.
@MainActor
final class LoadFailureTests: XCTestCase {
    private func failure(_ error: Error) -> ServerSectionFailure {
        ErrorMessage.failure(for: error, sessionState: nil, fallback: "Could not load things.")
    }

    func testAForbiddenAnswerIsNoAccessAndKeepsTheServersMessage() {
        let result = failure(APIError(statusCode: 403, message: "Administrator access required"))

        XCTAssertEqual(result.kind, .forbidden)
        XCTAssertEqual(result.message, "Administrator access required")
        XCTAssertEqual(result.title, "No access")
        XCTAssertEqual(result.kind.icon, .lock)
    }

    func testAServerErrorNamesItsStatus() {
        let result = failure(APIError(statusCode: 500, message: "Database is down"))

        XCTAssertEqual(result.kind, .serverFailure)
        XCTAssertEqual(result.message, "Database is down")
        XCTAssertEqual(result.title, "Server error 500")
        XCTAssertEqual(result.kind.icon, .triangleAlert)
    }

    func testAServerErrorWithoutAStatusHasAPlainTitle() {
        let result = failure(NSError(domain: "x", code: 1))

        XCTAssertEqual(result.kind, .serverFailure)
        XCTAssertEqual(result.message, "Could not load things.")
        XCTAssertEqual(result.title, "Server error")
    }

    func testAnExpiredSignInIsSignedOut() {
        let result = failure(APIError(statusCode: 401, message: "Token expired"))

        XCTAssertEqual(result.kind, .signedOut)
        XCTAssertEqual(result.title, "Signed out")
        XCTAssertEqual(result.kind.icon, .userRoundX)
    }

    func testATransportFailureIsCantReach() {
        let result = failure(URLError(.notConnectedToInternet))

        XCTAssertEqual(result.kind, .connectivity)
        XCTAssertEqual(result.title, "Can't reach the server")
        XCTAssertEqual(result.kind.icon, .wifiOff)
    }

    func testAnUndecodableAnswerIsAnUnexpectedResponse() {
        let result = failure(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x")))

        XCTAssertEqual(result.kind, .incompatibleResponse)
        XCTAssertEqual(result.title, "Unexpected response")
    }

    func testTheServerNameIsPutInFrontOfTheMessageInAllServersMode() {
        let result = ErrorMessage.failure(
            for: APIError(statusCode: 500, message: "Down"), sessionState: nil, fallback: "x", serverName: "Home"
        )

        XCTAssertEqual(result.message, "Home: Down")
        XCTAssertEqual(result.kind, .serverFailure)
    }

    func testViewModelsKeepTheKindOfALoadFailure() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)

        http.state.stub(path: "/api/v2/admin/tasks", data: Data(#"{"error":"forbidden","message":"No"}"#.utf8), status: 403)
        let jobs = JobsViewModel()
        await jobs.load(client: client)
        XCTAssertEqual(jobs.loadFailure?.kind, .forbidden)
        XCTAssertEqual(jobs.errorMessage, "No")

        http.state.stub(path: "/api/v2/admin/logs/app", data: Data(#"{"error":"boom","message":"Down"}"#.utf8), status: 500)
        let logs = LogsViewModel()
        await logs.load(client: client)
        XCTAssertEqual(logs.loadFailure?.kind, .serverFailure)
        XCTAssertEqual(logs.loadFailure?.title, "Server error 500")

        http.state.stub(path: "/api/v2/admin/invitations", data: Data(#"{"error":"boom","message":"Down"}"#.utf8), status: 503)
        let invitations = InvitationsViewModel()
        await invitations.load(client: client)
        XCTAssertEqual(invitations.loadFailure?.title, "Server error 503")

        http.state.stub(path: "/api/v2/admin/sessions", data: Data(#"{"error":"forbidden","message":"No"}"#.utf8), status: 403)
        let streams = StreamsViewModel()
        await streams.load(client: client)
        XCTAssertEqual(streams.loadFailure?.kind, .forbidden)

        http.state.stub(path: "/api/v2/admin/users", data: Data(#"{"error":"boom","message":"Down"}"#.utf8), status: 500)
        let users = UsersViewModel()
        await users.load(client: client)
        XCTAssertEqual(users.loadFailure?.kind, .serverFailure)

        http.state.stub(path: "/api/v2/admin/logs/audit", data: Data(#"{"error":"boom","message":"Down"}"#.utf8), status: 500)
        let audit = AuditViewModel()
        await audit.load(client: client)
        XCTAssertEqual(audit.loadFailure?.kind, .serverFailure)

        http.state.stub(path: "/api/v2/admin/playback-history", data: Data(#"{"error":"forbidden","message":"No"}"#.utf8), status: 403)
        let activity = ActivityViewModel()
        await activity.load(client: client)
        XCTAssertEqual(activity.loadFailure?.kind, .forbidden)

        http.state.stub(path: "/api/v2/admin/settings/effective", data: Data(#"{"error":"boom","message":"Down"}"#.utf8), status: 500)
        let config = ServerSettingsModel()
        await config.load(client: client)
        XCTAssertEqual(config.loadFailure?.kind, .serverFailure)

        http.state.stub(path: "/api/v2/admin/requests/counts", data: Data(#"{"error":"forbidden","message":"No"}"#.utf8), status: 403)
        let queue = RequestQueueViewModel()
        await queue.load(client: client)
        XCTAssertEqual(queue.loadFailure?.kind, .forbidden)
    }

    func testASuccessfulReloadClearsTheFailure() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
        http.state.stubSequence(path: "/api/v2/admin/invitations", responses: [
            MockHTTPResponse(data: Data(#"{"error":"boom","message":"Down"}"#.utf8), status: 500),
            MockHTTPResponse(data: Data(#"{"items":[]}"#.utf8), status: 200),
        ])
        let model = InvitationsViewModel()

        await model.load(client: client)
        XCTAssertNotNil(model.loadFailure)
        await model.load(client: client)

        XCTAssertNil(model.loadFailure)
        XCTAssertNil(model.errorMessage)
    }
}
