import XCTest
@testable import BloemAdmin

/// v2 playback-history fixtures. Every field the schema marks `required` is present.
enum ActivityFixtures {
    static func entry(_ id: String, username: String = "u", title: String = "t") -> String {
        #"{"session_id":"\#(id)","user_id":"1","username":"\#(username)","profile_id":"p1","profile_name":"Main","media_item_id":"m1","media_file_id":"f1","media_title":"\#(title)","media_type":"movie","play_method":"direct","started_at":"2026-08-25T15:20:32Z","ended_at":"2026-08-25T16:03:39Z","watched_seconds":1,"duration_seconds":2,"completed":false,"played_seconds":1,"series_title":"","season_number":null,"episode_number":null,"measured":true,"start_position_seconds":0,"paused_seconds":0,"measured_since":null,"measured_until":null,"client_ip":null,"device_id":null,"device_platform":null,"client_name":null,"client_version":null,"video_decision":null,"audio_decision":null,"end_reason":"stopped","lifecycle_seq":null}"#
    }

    /// A decoded row, for tests that need an entry value rather than a response body.
    static func decoded(_ id: String, username: String = "u") -> PlaybackHistoryEntry {
        try! JSONDecoder.iso8601.decode(PlaybackHistoryEntry.self, from: Data(entry(id, username: username).utf8))
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

    static func ids(_ prefix: String, _ count: Int = 3, username: String = "u") -> [String] {
        (0..<count).map { entry("\(prefix)-\($0)", username: username, title: "\(prefix)\($0)") }
    }
}

@MainActor
final class ActivityViewModelTests: XCTestCase {
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
        http.state.responseData = ActivityFixtures.page([ActivityFixtures.entry("s1", username: "mchan969", title: "Hot Off The Press")], hasMore: false)
        let viewModel = ActivityViewModel()
        await viewModel.load(filter: HistoryFilter(userID: " 86 "), client: makeClient(http))

        XCTAssertEqual(viewModel.entries.first?.mediaTitle, "Hot Off The Press")
        XCTAssertFalse(viewModel.hasMore)
        let request = try XCTUnwrap(http.state.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/v2/admin/playback-history")
        XCTAssertEqual(try query(request), ["limit": "50", "user_id": "86"])
    }

    func testLoadMoreFollowsNextCursorAndHidesWhenNoMore() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(client: client)
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertNil(try query(http.state.lastRequest)["cursor"])

        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("b", 1), hasMore: false)
        await viewModel.loadMore(client: client)

        XCTAssertEqual(try query(http.state.lastRequest)["cursor"], "c2")
        XCTAssertEqual(viewModel.entries.count, 4)
        XCTAssertFalse(viewModel.hasMore)
    }

    func testMissingPageMeansNoMore() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"))
        let viewModel = ActivityViewModel()
        await viewModel.load(client: makeClient(http))
        XCTAssertEqual(viewModel.entries.count, 3)
        XCTAssertFalse(viewModel.hasMore)
    }

    func testHasLoadedBeyondFirstPageTracksPagingState() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(client: client)
        XCTAssertFalse(viewModel.hasLoadedBeyondFirstPage)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("b", 1), hasMore: true, cursor: "c3")
        await viewModel.loadMore(client: client)
        XCTAssertTrue(viewModel.hasLoadedBeyondFirstPage)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        await viewModel.load(client: client)
        XCTAssertFalse(viewModel.hasLoadedBeyondFirstPage)
    }

    func testLoadMoreReusesTheFilterLoadWasCalledWith() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(filter: HistoryFilter(userID: "86"), client: client)
        http.state.responseData = ActivityFixtures.page([], hasMore: false)
        await viewModel.loadMore(client: client)
        XCTAssertEqual(try query(http.state.lastRequest), ["limit": "50", "user_id": "86", "cursor": "c2"])
    }

    /// A filter change clears rows and hasMore before its request, so a failed load shows neither.
    func testFilterChangeFailureShowsNeitherOldRowsNorLoadMore() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(filter: HistoryFilter(userID: "1"), client: client)
        XCTAssertTrue(viewModel.hasMore)

        http.state.responseData = Data(#"{"error":"server_error","message":"boom"}"#.utf8)
        http.state.responseStatus = 500
        await viewModel.load(filter: HistoryFilter(userID: "2"), client: client)

        XCTAssertTrue(viewModel.entries.isEmpty)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(viewModel.errorMessage, "boom")
    }

    func testResultForSupersededFilterIsDiscarded() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("new", 2), hasMore: false)
        let viewModel = ActivityViewModel()
        let staleToken = viewModel.beginLoad(filter: HistoryFilter(userID: "1"))
        await viewModel.load(filter: HistoryFilter(userID: "2"), client: client)

        let stale = APICollection(items: [ActivityFixtures.decoded("stale", username: "stale")], page: nil)
        viewModel.apply(filter: HistoryFilter(userID: "1"), .success(stale), token: staleToken, sessionState: nil)
        XCTAssertEqual(viewModel.entries.map(\.sessionID), ["new-0", "new-1"])
    }

    /// A Load more started under the old filter must not append to the new filter's rows.
    func testLoadMoreResultForOldFilterIsDiscardedAfterFilterChange() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(filter: HistoryFilter(userID: "1"), client: client)

        http.state.delayedHosts["example.test"] = 0.3
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("old", 2), hasMore: true, cursor: "old-c")
        let loadMoreTask = Task { await viewModel.loadMore(client: client) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isLoadingMore)

        http.state.delayedHosts = [:]
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("b", 2), hasMore: false)
        await viewModel.load(filter: HistoryFilter(userID: "2"), client: client)
        await loadMoreTask.value

        XCTAssertEqual(viewModel.entries.map(\.sessionID), ["b-0", "b-1"])
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertFalse(viewModel.isLoadingMore)
    }

    /// The poll lands while Load more is in flight. The first page differs from the original,
    /// so replacing instead of merging would drop a-* rows and take the first page's cursor.
    func testPollDuringLoadMoreKeepsAppendedPageAndCursor() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(client: client)

        http.state.delayedHosts["example.test"] = 0.3
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("b", 2), hasMore: true, cursor: "c3")
        let loadMoreTask = Task { await viewModel.loadMore(client: client) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isLoadingMore)

        http.state.delayedHosts = [:]
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("p", 2), hasMore: true, cursor: "poll-c")
        await viewModel.pollRefresh(client: client)
        await loadMoreTask.value

        let ids = Set(viewModel.entries.map(\.sessionID))
        XCTAssertTrue(ids.isSuperset(of: ["p-0", "p-1", "a-0", "a-1", "a-2", "b-0", "b-1"]), "\(ids)")
        XCTAssertEqual(viewModel.entries.count, 7)
        XCTAssertTrue(viewModel.hasMore)

        http.state.responseData = ActivityFixtures.page([], hasMore: false)
        await viewModel.loadMore(client: client)
        XCTAssertEqual(try query(http.state.lastRequest)["cursor"], "c3", "the cursor stays the Load more page's, not the poll's")
    }

    func testPollAfterLoadMoreRefreshesFirstPageRowsAndKeepsCursor() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a", 2), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(filter: HistoryFilter(userID: "7"), client: client)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("b", 1), hasMore: true, cursor: "c3")
        await viewModel.loadMore(client: client)

        http.state.responseData = ActivityFixtures.page([ActivityFixtures.entry("a-0", title: "renamed")], hasMore: true, cursor: "poll-c")
        await viewModel.pollRefresh(client: client)
        XCTAssertEqual(try query(http.state.lastRequest), ["limit": "50", "user_id": "7"])
        XCTAssertEqual(viewModel.entries.map(\.sessionID), ["a-0", "a-1", "b-0"])
        XCTAssertEqual(viewModel.entries.first?.mediaTitle, "renamed")

        http.state.responseData = ActivityFixtures.page([], hasMore: false)
        await viewModel.loadMore(client: client)
        XCTAssertEqual(try query(http.state.lastRequest)["cursor"], "c3")
    }

    func testPollBeforeLoadMoreReplacesFirstPageAndCursor() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a", 2), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(client: client)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("p", 2), hasMore: true, cursor: "poll-c")
        await viewModel.pollRefresh(client: client)
        XCTAssertEqual(viewModel.entries.map(\.sessionID), ["p-0", "p-1"])
        http.state.responseData = ActivityFixtures.page([], hasMore: false)
        await viewModel.loadMore(client: client)
        XCTAssertEqual(try query(http.state.lastRequest)["cursor"], "poll-c")
    }

    /// A loadMore failure must NOT clobber `errorMessage` (which would hide the loaded page).
    func testLoadMoreFailureSetsLoadMoreErrorMessageNotErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = makeClient(http)
        http.state.responseData = ActivityFixtures.page(ActivityFixtures.ids("a"), hasMore: true, cursor: "c2")
        let viewModel = ActivityViewModel()
        await viewModel.load(client: client)

        http.state.responseData = Data(#"{"error":"server_error","message":"boom"}"#.utf8)
        http.state.responseStatus = 500
        await viewModel.loadMore(client: client)

        XCTAssertEqual(viewModel.loadMoreErrorMessage, "boom")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.entries.count, 3)
        XCTAssertTrue(viewModel.hasMore)
    }

    func testLoadDecodeFailureSetsErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data("not json".utf8)
        let viewModel = ActivityViewModel()
        await viewModel.load(client: makeClient(http))
        XCTAssertNotNil(viewModel.errorMessage)
    }
}
