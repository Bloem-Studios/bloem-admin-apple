import XCTest
@testable import BloemAdmin

/// v2 audit fixtures. Every field the schema marks `required` is present.
enum AuditFixtures {
    static func entry(_ id: String, path: String = "/x", userID: String? = nil, impersonator: String? = nil, pattern: String? = "/x", status: Int = 200) -> String {
        var json = #"{"id":"\#(id)","timestamp":"2026-08-25T12:00:00.250Z","client_ip":"1.2.3.4","method":"GET","path":"\#(path)","status_code":\#(status),"duration_ms":5"#
        if let userID { json += #","user_id":"\#(userID)""# }
        if let impersonator { json += #","impersonator_user_id":"\#(impersonator)""# }
        if let pattern { json += #","path_pattern":"\#(pattern)""# }
        return json + "}"
    }

    static func page(_ entries: [String], hasMore: Bool? = nil, cursor: String? = nil) -> Data {
        var json = #"{"items":[\#(entries.joined(separator: ","))]"#
        if let hasMore {
            json += #","page":{"has_more":\#(hasMore)"#
            if let cursor { json += #","next_cursor":"\#(cursor)""# }
            json += "}"
        }
        return Data((json + "}").utf8)
    }

    static func ids(_ prefix: String, _ count: Int = 3) -> [String] {
        (0..<count).map { entry("\(prefix)-\($0)", path: "/\(prefix)\($0)") }
    }
}

@MainActor
final class AuditViewModelTests: XCTestCase {
    private func query(_ request: URLRequest?) throws -> [String: String] {
        let url = try XCTUnwrap(request?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func makeClient(_ http: MockHTTPHarness) -> APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
    }

    func testLoadDecodesV2EntriesAndSendsOnlyDeclaredParameters() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = AuditFixtures.page(
            [AuditFixtures.entry("123", path: "/api/v2/admin/users/42", userID: "42", impersonator: "7")],
            hasMore: true, cursor: "page-2"
        )
        let viewModel = AuditViewModel()
        await viewModel.load(filter: AuditFilter(userID: " 42 "), client: makeClient(http))

        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertEqual(entry.id, "123")
        XCTAssertEqual(entry.userID, "42")
        XCTAssertEqual(entry.impersonatorUserID, "7")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.hasMore)
        let request = try XCTUnwrap(http.state.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/v2/admin/logs/audit")
        XCTAssertEqual(try query(request), ["limit": "50", "user_id": "42"])
    }

    func testEmptyFilterOmitsUserID() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = AuditFixtures.page([])
        await AuditViewModel().load(client: makeClient(http))
        XCTAssertEqual(try query(http.state.lastRequest), ["limit": "50"])
    }

    func testLoadMoreFollowsNextCursorAppendsAndHidesWhenNoMore() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("a", 1), hasMore: true, cursor: "page-2")
        let viewModel = AuditViewModel()
        await viewModel.load(client: client)
        XCTAssertTrue(viewModel.hasMore)

        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("b", 1), hasMore: false)
        await viewModel.loadMore(client: client)

        XCTAssertEqual(try query(http.state.lastRequest)["cursor"], "page-2")
        XCTAssertEqual(viewModel.entries.map(\.id), ["a-0", "b-0"])
        XCTAssertFalse(viewModel.hasMore)
    }

    func testMissingPageMeansNoMore() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("a", 2))
        let viewModel = AuditViewModel()
        await viewModel.load(client: makeClient(http))
        XCTAssertEqual(viewModel.entries.count, 2)
        XCTAssertFalse(viewModel.hasMore)
    }

    /// `path_pattern` is absent for requests matching no route (404s); the page must still decode.
    func testEntryWithoutPathPatternDecodes() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = AuditFixtures.page([AuditFixtures.entry("1", path: "/no/such/route", pattern: nil, status: 404)])
        let viewModel = AuditViewModel()
        await viewModel.load(client: makeClient(http))
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertNil(try XCTUnwrap(viewModel.entries.first).pathPattern)
        XCTAssertEqual(viewModel.entries.first?.statusCode, 404)
    }

    func testLoadMoreReusesTheFilterLoadWasCalledWith() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("a", 1), hasMore: true, cursor: "page-2")
        let viewModel = AuditViewModel()
        await viewModel.load(filter: AuditFilter(userID: "42"), client: client)
        http.state.responseData = AuditFixtures.page([], hasMore: false)
        await viewModel.loadMore(client: client)
        XCTAssertEqual(try query(http.state.lastRequest), ["limit": "50", "user_id": "42", "cursor": "page-2"])
    }

    /// A filter change clears rows and hasMore before its request, so a failed load shows neither.
    func testFilterChangeFailureShowsNeitherOldRowsNorLoadMore() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = AuditViewModel()
        await viewModel.load(filter: AuditFilter(userID: "1"), client: client)
        XCTAssertTrue(viewModel.hasMore)

        http.state.responseData = Data(#"{"error":"server_error","message":"boom"}"#.utf8)
        http.state.responseStatus = 500
        await viewModel.load(filter: AuditFilter(userID: "2"), client: client)

        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(viewModel.errorMessage, "boom")
    }

    func testResultForSupersededFilterIsDiscarded() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("new", 2), hasMore: false)
        let viewModel = AuditViewModel()
        let staleToken = viewModel.beginLoad(filter: AuditFilter(userID: "1"))
        await viewModel.load(filter: AuditFilter(userID: "2"), client: makeClient(http))

        let stale = try JSONDecoder.iso8601.decode(APICollection<AuditLogEntry>.self, from: AuditFixtures.page(AuditFixtures.ids("stale", 1)))
        viewModel.apply(filter: AuditFilter(userID: "1"), .success(stale), token: staleToken, sessionState: nil)
        XCTAssertEqual(viewModel.entries.map(\.id), ["new-0", "new-1"])
    }

    /// A Load more started under the old filter must not append to the new filter's rows.
    func testLoadMoreResultForOldFilterIsDiscardedAfterFilterChange() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = AuditViewModel()
        await viewModel.load(filter: AuditFilter(userID: "1"), client: client)

        http.state.delayedHosts["example.test"] = 0.3
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("old", 2), hasMore: true, cursor: "old-c")
        let loadMoreTask = Task { await viewModel.loadMore(client: client) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isLoadingMore)

        http.state.delayedHosts = [:]
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("b", 2), hasMore: false)
        await viewModel.load(filter: AuditFilter(userID: "2"), client: client)
        await loadMoreTask.value

        XCTAssertEqual(viewModel.entries.map(\.id), ["b-0", "b-1"])
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    func testLoadDecodeFailureSetsErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data("not json".utf8)
        let viewModel = AuditViewModel()
        await viewModel.load(client: makeClient(http))
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.entries.isEmpty)
    }

    func testLoad401FlagsSessionStateTokenExpired() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401
        let rootSessionState = AdminSessionState()
        rootSessionState.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: rootSessionState.credentialProvider(serverID: "srv-1"),
            session: http.session
        )
        let viewModel = AuditViewModel()
        let sessionState = rootSessionState.scoped(to: "srv-1")

        await viewModel.load(client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.errorMessage, "Token expired")
    }

    /// A Load more failure must not set `errorMessage` (that would hide the loaded page).
    func testLoadMoreFailureSetsLoadMoreErrorMessageNotErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = AuditFixtures.page(AuditFixtures.ids("a", 1), hasMore: true, cursor: "page-2")
        let viewModel = AuditViewModel()
        await viewModel.load(client: client)

        http.state.responseData = Data(#"{"error":"server_error","message":"boom"}"#.utf8)
        http.state.responseStatus = 500
        await viewModel.loadMore(client: client)

        XCTAssertEqual(viewModel.loadMoreErrorMessage, "boom")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.entries.count, 1)
        XCTAssertTrue(viewModel.hasMore)
    }
}
