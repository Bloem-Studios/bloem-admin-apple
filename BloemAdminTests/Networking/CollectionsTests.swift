import XCTest
@testable import BloemAdmin

@MainActor
final class CollectionsTests: XCTestCase {
    private struct Row: Decodable, Sendable, Equatable {
        let id: String
    }

    private func page(_ prefix: String, hasMore: Bool, cursor: String? = nil) -> MockHTTPResponse {
        var pageInfo: [String: Any] = ["has_more": hasMore]
        if let cursor { pageInfo["next_cursor"] = cursor }
        return MockHTTPResponse(json: [
            "items": [["id": "\(prefix)-1"], ["id": "\(prefix)-2"]],
            "page": pageInfo,
        ])
    }

    private func makeClient(_ http: MockHTTPHarness) -> APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
    }

    private func queryStrings(_ http: MockHTTPHarness, path: String) -> [String] {
        http.state.requests(path: path).map { $0.url?.query ?? "" }
    }

    func testReadsItemsAndCursorFromAV2Envelope() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things", json: [
            "items": [["id": "a"]],
            "page": ["has_more": true, "next_cursor": "c1"],
        ])

        let result: APICollection<Row> = try await makeClient(http).getCollection("/api/v2/things")

        XCTAssertEqual(result.items, [Row(id: "a")])
        XCTAssertEqual(result.page?.nextCursor, "c1")
        XCTAssertEqual(result.page?.hasMore, true)
    }

    func testMissingPageMeansOnePage() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things", json: ["items": [Any]()])

        let result: APICollection<Row> = try await makeClient(http).getCollection("/api/v2/things")

        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.page)
    }

    func testGetCollectionSendsQuery() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things", json: ["items": [Any]()])

        let _: APICollection<Row> = try await makeClient(http).getCollection("/api/v2/things", query: ["status": "open"])

        XCTAssertEqual(queryStrings(http, path: "/api/v2/things"), ["status=open"])
    }

    func testReadAllPagesFollowsCursorsAndSendsLimit() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/things", responses: [
            page("p1", hasMore: true, cursor: "c1"),
            page("p2", hasMore: true, cursor: "c2"),
            page("p3", hasMore: false),
        ])

        let all: [Row] = try await makeClient(http).readAllPages("/api/v2/things")

        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(
            queryStrings(http, path: "/api/v2/things"),
            ["limit=200", "cursor=c1&limit=200", "cursor=c2&limit=200"]
        )
    }

    func testReadAllPagesKeepsCallerQuery() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things", json: ["items": [Any]()])

        let _: [Row] = try await makeClient(http).readAllPages("/api/v2/things", query: ["status": "open"], pageSize: 50)

        XCTAssertEqual(queryStrings(http, path: "/api/v2/things"), ["limit=50&status=open"])
    }

    func testReadAllPagesStopsWhenTheCursorRepeats() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things", response: page("p", hasMore: true, cursor: "c1"))

        let all: [Row] = try await makeClient(http).readAllPages("/api/v2/things")

        XCTAssertEqual(http.state.requests(path: "/api/v2/things").count, 2)
        XCTAssertEqual(all.count, 4)
    }

    func testReadAllPagesStopsAtMaxPages() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/things", responses: (1...10).map { page("p\($0)", hasMore: true, cursor: "c\($0)") })

        let all: [Row] = try await makeClient(http).readAllPages("/api/v2/things", maxPages: 3)

        XCTAssertEqual(http.state.requests(path: "/api/v2/things").count, 3)
        XCTAssertEqual(all.count, 6)
    }

    func testReadAllPagesStopsWhenHasMoreIsFalseEvenWithACursor() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things", response: page("p", hasMore: false, cursor: "c1"))

        let all: [Row] = try await makeClient(http).readAllPages("/api/v2/things")

        XCTAssertEqual(http.state.requests(path: "/api/v2/things").count, 1)
        XCTAssertEqual(all.count, 2)
    }
}
