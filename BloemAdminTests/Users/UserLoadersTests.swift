import XCTest
@testable import BloemAdmin

@MainActor
final class UserLoadersTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let downloadsPath = "/api/v2/admin/users/42/downloads"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private var client: APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
    }

    private func download(_ id: String) -> [String: Any] {
        ["id": id, "title": "Title \(id)", "media_type": "movie", "status": "completed", "file_size": 1500, "quality": "1080p", "created_at": "2026-01-02T03:04:05.678Z"]
    }

    private func feed(serverName: String? = nil) -> PagedFeed<UserDownload> {
        let client = client
        return PagedFeed(serverName: serverName) { cursor in try await client.userDownloads(userID: "42", cursor: cursor) }
    }

    func testASectionLoadsOnceAndKeepsItsValueWhenAReReadFails() async {
        var reads = 0
        let loader = SectionLoader<Int> {
            reads += 1
            if reads == 2 { throw URLError(.notConnectedToInternet) }
            return reads
        }

        await loader.load()
        XCTAssertEqual(loader.state.value, 1)
        await loader.load()
        XCTAssertEqual(loader.state.value, 1, "a failed re-read leaves the section shown")
    }

    func testASectionThatFailsFirstShowsAGenericMessageAndAnAPIErrorItsOwn() async {
        let generic = SectionLoader<Int>(fallback: "This section couldn't be loaded. Try again.") { throw URLError(.timedOut) }
        await generic.load()
        XCTAssertEqual(generic.state.failure, "This section couldn't be loaded. Try again.")

        let own = SectionLoader<Int>(serverName: "Home") { throw APIError(statusCode: 500, message: "Boom") }
        await own.load()
        XCTAssertEqual(own.state.failure, "Home: Boom")
    }

    func testAFeedAppendsPagesUntilTheServerSaysThereAreNoMore() async {
        http.state.stubSequence(path: downloadsPath, responses: [
            UserFixtures.response(UserFixtures.page([download("1"), download("2")], next: "c2")),
            UserFixtures.response(UserFixtures.page([download("3")])),
        ])
        let feed = feed()

        await feed.reload()
        XCTAssertEqual(feed.items.map(\.id), ["1", "2"])
        XCTAssertTrue(feed.hasMore)

        await feed.loadMore()
        XCTAssertEqual(feed.items.map(\.id), ["1", "2", "3"])
        XCTAssertFalse(feed.hasMore)
        let cursors = http.state.requests(path: downloadsPath).map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value }
        XCTAssertEqual(cursors, [nil, "c2"])
    }

    func testAFeedStopsWhenTheServerRepeatsACursor() async {
        http.state.stubSequence(path: downloadsPath, responses: [
            UserFixtures.response(UserFixtures.page([download("1")], next: "same")),
            UserFixtures.response(UserFixtures.page([download("2")], next: "same")),
            UserFixtures.response(UserFixtures.page([download("3")])),
        ])
        let feed = feed()

        await feed.reload()
        await feed.loadMore()
        XCTAssertEqual(feed.items.map(\.id), ["1", "2"])
        XCTAssertFalse(feed.hasMore, "a repeated cursor ends the list instead of looping")
    }

    func testAFailedPageKeepsTheRowsAndShowsTheErrorAndReloadClearsIt() async {
        http.state.stubSequence(path: downloadsPath, responses: [
            UserFixtures.response(UserFixtures.page([download("1")], next: "c2")),
            MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Boom"}"#.utf8), status: 500),
            UserFixtures.response(UserFixtures.page([download("9")])),
        ])
        let feed = feed()

        await feed.reload()
        await feed.loadMore()
        XCTAssertEqual(feed.items.map(\.id), ["1"])
        XCTAssertEqual(feed.errorMessage, "Boom")

        await feed.reload()
        XCTAssertEqual(feed.items.map(\.id), ["9"])
        XCTAssertNil(feed.errorMessage)
    }

    func testWatchTimeAndSizesAreShort() {
        XCTAssertEqual(UserFormat.watchTime(7500), "2 h 5 min")
        XCTAssertEqual(UserFormat.watchTime(2700), "45 min")
        XCTAssertEqual(UserFormat.watchTime(30), "30 s")
        XCTAssertEqual(UserFormat.watchTime(-5), "0 s")
        XCTAssertEqual(UserFormat.bytes(1_500_000_000), "1.5 GB")
    }

    func testTheDetailModelsDecodeWhatTheServerSends() throws {
        let capabilities = try JSONDecoder().decode(UserCapabilities.self, from: Data(#"{"account_downloads":true}"#.utf8))
        XCTAssertTrue(capabilities.available, "a server that omits `available` does not lock the page")
        XCTAssertTrue(capabilities.accountDownloads)
        XCTAssertFalse(capabilities.loginSessions)

        let ip = try JSONDecoder.iso8601.decode(UserIP.self, from: Data(#"{"client_ip":"10.0.0.2","first_seen":"2026-01-02T03:04:05.678Z","last_seen":"2026-01-03T03:04:05Z"}"#.utf8))
        XCTAssertEqual(ip.requestCount, 0)
        XCTAssertEqual(ip.location, "")

        let summary = try JSONDecoder.iso8601.decode(UserDownloadSummary.self, from: Data(#"{"total":3,"completed":2,"in_progress":1,"failed":0}"#.utf8))
        XCTAssertEqual(summary.totalBytes, 0)
        XCTAssertEqual(summary.devices, 0)
    }
}
