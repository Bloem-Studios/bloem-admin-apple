import XCTest
@testable import BloemAdmin

/// v2 operational-log fixtures. Every field the schema marks `required` is present.
enum LogsFixtures {
    static func entry(_ id: String, level: String = "info", message: String = "m", extra: String = "") -> String {
        #"{"id":"\#(id)","timestamp":"2026-08-25T12:00:00.250Z","level":"\#(level)","component":"scanner","message":"\#(message)"\#(extra)}"#
    }

    static func page(_ entries: [String], hasMore: Bool? = nil, cursor: String? = nil) -> Data {
        AuditFixtures.page(entries, hasMore: hasMore, cursor: cursor)
    }

    static func ids(_ prefix: String, _ count: Int = 3) -> [String] {
        (0..<count).map { entry("\(prefix)-\($0)", message: "\(prefix)\($0)") }
    }
}

@MainActor
final class LogsViewModelTests: XCTestCase {
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
        http.state.responseData = LogsFixtures.page([
            LogsFixtures.entry("123", level: "warn", message: "scan completed", extra: #","request_id":"abc","user_id":"5","session_id":"sess1","playback_session_id":"pb1","client_ip":"1.2.3.4","node_id":"node1""#)
        ], hasMore: true, cursor: "page-2")
        let viewModel = LogsViewModel()
        await viewModel.load(filter: LogFilter(level: " warn ", q: " disk "), client: makeClient(http))

        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertEqual(entry.id, "123")
        XCTAssertEqual(entry.userID, "5")
        XCTAssertEqual(entry.requestID, "abc")
        XCTAssertEqual(entry.sessionID, "sess1")
        XCTAssertEqual(entry.playbackSessionID, "pb1")
        XCTAssertEqual(entry.clientIP, "1.2.3.4")
        XCTAssertEqual(entry.nodeID, "node1")
        XCTAssertTrue(viewModel.hasMore)
        let request = try XCTUnwrap(http.state.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/v2/admin/logs/app")
        XCTAssertEqual(try query(request), ["limit": "50", "level": "warn", "q": "disk"])
    }

    func testComponentRequestAndPlaybackSessionFiltersAreSentAndReusedByLoadMore() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("a", 1), hasMore: true, cursor: "page-2")
        let viewModel = LogsViewModel()
        let filter = LogFilter(level: "warn,error", component: "ffmpeg", requestID: "req-1", playbackSessionID: "ps_9")
        await viewModel.load(filter: filter, client: client)
        let expected = ["limit": "50", "level": "warn,error", "component": "ffmpeg", "request_id": "req-1", "playback_session_id": "ps_9"]
        XCTAssertEqual(try query(http.state.lastRequest), expected)

        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("b", 1), hasMore: false)
        await viewModel.loadMore(client: client)
        XCTAssertEqual(try query(http.state.lastRequest), expected.merging(["cursor": "page-2"]) { $1 })
    }

    func testMinimalEntryDecodesAndEmptyFiltersAreOmitted() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = LogsFixtures.page([LogsFixtures.entry("1")])
        let viewModel = LogsViewModel()
        await viewModel.load(client: makeClient(http))

        XCTAssertNil(viewModel.errorMessage)
        let entry = try XCTUnwrap(viewModel.entries.first)
        XCTAssertNil(entry.requestID)
        XCTAssertNil(entry.userID)
        XCTAssertNil(entry.nodeID)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(try query(http.state.lastRequest), ["limit": "50"])
    }

    func testLoadMoreFollowsNextCursorAppendsAndReusesFilters() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("a", 1), hasMore: true, cursor: "page-2")
        let viewModel = LogsViewModel()
        await viewModel.load(filter: LogFilter(level: "warn", q: "disk"), client: client)

        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("b", 1), hasMore: false)
        await viewModel.loadMore(client: client)

        XCTAssertEqual(try query(http.state.lastRequest), ["limit": "50", "level": "warn", "q": "disk", "cursor": "page-2"])
        XCTAssertEqual(viewModel.entries.map(\.id), ["a-0", "b-0"])
        XCTAssertFalse(viewModel.hasMore)
    }

    func testFilterChangeFailureShowsNeitherOldRowsNorLoadMore() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = LogsViewModel()
        await viewModel.load(filter: LogFilter(level: "info"), client: client)
        XCTAssertTrue(viewModel.hasMore)

        http.state.responseData = Data(#"{"error":"server_error","message":"boom"}"#.utf8)
        http.state.responseStatus = 500
        await viewModel.load(filter: LogFilter(level: "error"), client: client)

        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(viewModel.errorMessage, "boom")
    }

    func testResultForSupersededFilterIsDiscarded() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("new", 2), hasMore: false)
        let viewModel = LogsViewModel()
        let staleToken = viewModel.beginLoad(filter: LogFilter(level: "info"))
        await viewModel.load(filter: LogFilter(level: "error"), client: makeClient(http))

        let stale = try JSONDecoder.iso8601.decode(APICollection<OperationalLogEntry>.self, from: LogsFixtures.page(LogsFixtures.ids("stale", 1)))
        viewModel.apply(filter: LogFilter(level: "info"), .success(stale), token: staleToken, sessionState: nil)
        XCTAssertEqual(viewModel.entries.map(\.id), ["new-0", "new-1"])
    }

    func testLoadMoreResultForOldFilterIsDiscardedAfterFilterChange() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = LogsViewModel()
        await viewModel.load(filter: LogFilter(q: "one"), client: client)

        http.state.delayedHosts["example.test"] = 0.3
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("old", 2), hasMore: true, cursor: "old-c")
        let loadMoreTask = Task { await viewModel.loadMore(client: client) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isLoadingMore)

        http.state.delayedHosts = [:]
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("b", 2), hasMore: false)
        await viewModel.load(filter: LogFilter(q: "two"), client: client)
        await loadMoreTask.value

        XCTAssertEqual(viewModel.entries.map(\.id), ["b-0", "b-1"])
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    func testLoadDecodeFailureSetsErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data("not json".utf8)
        let viewModel = LogsViewModel()
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
        let viewModel = LogsViewModel()
        let sessionState = rootSessionState.scoped(to: "srv-1")

        await viewModel.load(client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.errorMessage, "Token expired")
    }

    func testLoadMoreFailureSetsLoadMoreErrorMessageNotErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = LogsFixtures.page(LogsFixtures.ids("a", 1), hasMore: true, cursor: "page-2")
        let viewModel = LogsViewModel()
        await viewModel.load(client: client)

        http.state.responseData = Data(#"{"error":"server_error","message":"boom"}"#.utf8)
        http.state.responseStatus = 500
        await viewModel.loadMore(client: client)

        XCTAssertEqual(viewModel.loadMoreErrorMessage, "boom")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.entries.count, 1)
    }
}
