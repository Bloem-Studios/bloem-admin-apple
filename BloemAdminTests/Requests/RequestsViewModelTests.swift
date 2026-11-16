import XCTest
@testable import BloemAdmin

@MainActor
final class RequestsViewModelTests: XCTestCase {
    /// One v2 MediaRequest with every field the schema marks required.
    static func mediaRequestJSON(id: String, title: String, status: String = "pending", outcome: String = "active", lastError: String? = nil) -> String {
        let error = lastError.map { #","last_error":"\#($0)""# } ?? ""
        return #"{"id":"\#(id)","provider":"tmdb","media_type":"movie","tmdb_id":949,"title":"\#(title)","status":"\#(status)","outcome":"\#(outcome)","state":"pending","seasons":[],"season_progress":[],"source":"direct","is_anime":false,"targets":[],"created_at":"2026-01-02T03:04:05.000Z","updated_at":"2026-01-02T03:04:05.000Z","requested_by_user_id":"68"\#(error)}"#
    }

    func testLoadPagesWithTheDeclaredLimitAndFollowsTheCursor() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [
            MockHTTPResponse(data: Data(#"{"items":[\#(Self.mediaRequestJSON(id: "1", title: "A"))],"page":{"has_more":true,"next_cursor":"c1"}}"#.utf8), status: 200),
            MockHTTPResponse(data: Data(#"{"items":[\#(Self.mediaRequestJSON(id: "2", title: "B"))],"page":{"has_more":false}}"#.utf8), status: 200),
        ])
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = RequestsViewModel()

        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.requests.map(\.id), ["1", "2"])
        let requests = http.state.requests(path: "/api/v2/admin/requests")
        XCTAssertEqual(requests.count, 2)
        let first = URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(first?.queryItems?.first { $0.name == "limit" }?.value, "50")
        let second = URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)
        XCTAssertEqual(second?.queryItems?.first { $0.name == "cursor" }?.value, "c1")
    }

    func testEveryActionSendsAnEmptyObjectBodyAndEncodesTheID() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(Self.mediaRequestJSON(id: "a b/c", title: "X").utf8)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = RequestsViewModel()
        let target = MediaRequest(id: "a b/c", provider: "tmdb", mediaType: "movie", title: "X", status: "pending", outcome: "active", requestedByUserID: "1", lastError: nil)

        for (name, act) in [
            ("approve", { await viewModel.approve(target, client: client) }),
            ("retry", { await viewModel.retry(target, client: client) }),
            ("cancel", { await viewModel.cancel(target, client: client) }),
        ] as [(String, () async -> Void)] {
            await act()
            let request = try XCTUnwrap(http.state.lastRequest)
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/requests/a%20b%2Fc/\(name)")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(http.state.capturedBody, Data("{}".utf8), name)
            XCTAssertNil(viewModel.actionErrorMessage)
        }
    }

    func testDeclineSendsTheTrimmedReasonOrAnEmptyObject() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(Self.mediaRequestJSON(id: "req-1", title: "X").utf8)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = RequestsViewModel()
        let target = MediaRequest(id: "req-1", provider: "tmdb", mediaType: "movie", title: "X", status: "pending", outcome: "active", requestedByUserID: "1", lastError: nil)

        await viewModel.decline(target, reason: "  Already in the library  ", client: client)
        XCTAssertEqual(http.state.capturedBody, Data(#"{"reason":"Already in the library"}"#.utf8))

        await viewModel.decline(target, reason: "   ", client: client)
        XCTAssertEqual(http.state.capturedBody, Data("{}".utf8))
    }

    func testAggregateViewModelNamesTheServerInActionErrors() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8)
        http.state.responseStatus = 403
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = RequestsViewModel(serverName: "Home")
        let target = MediaRequest(id: "r", provider: "tmdb", mediaType: "movie", title: "X", status: "pending", outcome: "active", requestedByUserID: "1", lastError: nil)

        await viewModel.approve(target, client: client)

        XCTAssertEqual(viewModel.actionErrorMessage, "Home: Not allowed")
    }

    func testLoadDecodesRequestsEnvelope() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"items":[\#(Self.mediaRequestJSON(id: "139513934062288898", title: "One Second After", status: "queued", outcome: "active", lastError: "one or more fulfillment targets failed"))],"page":{"has_more":false}}"#.utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = RequestsViewModel()
        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.requests.count, 1)
        XCTAssertEqual(viewModel.requests.first?.title, "One Second After")
    }

    func testApprovePostsToApproveEndpoint() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{}"#.utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = RequestsViewModel()
        let target = MediaRequest(id: "req-1", provider: "tmdb", mediaType: "movie", title: "X", status: "queued", outcome: "pending", requestedByUserID: "1", lastError: nil)

        await viewModel.approve(target, client: client)

        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/requests/req-1/approve")
    }

    func testDeclinePostsToDeclineEndpoint() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{}"#.utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = RequestsViewModel()
        let target = MediaRequest(id: "req-1", provider: "tmdb", mediaType: "movie", title: "X", status: "queued", outcome: "pending", requestedByUserID: "1", lastError: nil)

        await viewModel.decline(target, reason: nil, client: client)

        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/requests/req-1/decline")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
    }

    func testRetryPostsToRetryEndpoint() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{}"#.utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = RequestsViewModel()
        let target = MediaRequest(id: "req-1", provider: "tmdb", mediaType: "movie", title: "X", status: "queued", outcome: "failed", requestedByUserID: "1", lastError: "boom")

        await viewModel.retry(target, client: client)

        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/requests/req-1/retry")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
    }

    func testCancelPostsToCancelEndpoint() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{}"#.utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = RequestsViewModel()
        let target = MediaRequest(id: "req-1", provider: "tmdb", mediaType: "movie", title: "X", status: "queued", outcome: "pending", requestedByUserID: "1", lastError: nil)

        await viewModel.cancel(target, client: client)

        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/requests/req-1/cancel")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    /// Regression test for the exact silent-failure pattern already caught
    /// in Task 4 (Streams) and correctly guarded against in Task 6 (Jobs):
    /// a rejected action (e.g. 403) must leave `actionErrorMessage` set
    /// (NOT the load-only `errorMessage`, which drives the list screen's
    /// full-screen "Connection lost" overlay), and
    /// `approve`/`decline`/`retry`/`cancel` must never call `load`
    /// themselves — that's the caller's job, conditional on success. This
    /// test proves the model side of that contract holds for Requests.
    func testApproveFailureSetsActionErrorMessageAndDoesNotReload() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"forbidden","message":"Not authorized to approve this request"}"#.utf8)
        http.state.responseStatus = 403

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = RequestsViewModel()
        let target = MediaRequest(id: "req-1", provider: "tmdb", mediaType: "movie", title: "X", status: "queued", outcome: "pending", requestedByUserID: "1", lastError: nil)

        await viewModel.approve(target, client: client)

        XCTAssertEqual(viewModel.actionErrorMessage, "Not authorized to approve this request")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/requests/req-1/approve")

        // Mirrors the guard used by RequestDetailView's button handlers:
        // only reload when the action succeeded. Because it failed, load()
        // must NOT run here, so the error stays visible instead of being
        // silently wiped by a subsequent successful GET.
        if viewModel.actionErrorMessage == nil {
            await viewModel.load(client: client)
        }

        XCTAssertEqual(viewModel.actionErrorMessage, "Not authorized to approve this request")
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/requests/req-1/approve")
        XCTAssertTrue(viewModel.requests.isEmpty)
    }

    /// Feature 3: a 401 from an action must flag the shared session state
    /// so AdminGateView can route the whole tab view back to re-login.
    func testApproveAction401FlagsSessionStateTokenExpired() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401

        let rootSessionState = AdminSessionState()
        rootSessionState.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: rootSessionState.credentialProvider(serverID: "srv-1"),
            session: session
        )
        let viewModel = RequestsViewModel()
        let sessionState = rootSessionState.scoped(to: "srv-1")
        let target = MediaRequest(id: "req-1", provider: "tmdb", mediaType: "movie", title: "X", status: "queued", outcome: "pending", requestedByUserID: "1", lastError: nil)

        await viewModel.approve(target, client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.actionErrorMessage, "Token expired")
    }
}
