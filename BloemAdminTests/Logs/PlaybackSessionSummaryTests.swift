import XCTest
@testable import BloemAdmin

/// The summary on top of Logs when it is focused on one playback session: the web's
/// AdminLogsPlaybackSummary counts (app, FFmpeg and audit rows, first and last seen, nodes) taken
/// from the session's rows, which the app reads from `logs/app` and `logs/audit` filtered by it.
@MainActor
final class PlaybackSessionSummaryTests: XCTestCase {
    private func app(_ id: String, _ time: String, component: String = "playback", node: String? = nil, session: String = "ps_1") throws -> OperationalLogEntry {
        let nodeJSON = node.map { #","node_id":"\#($0)""# } ?? ""
        let json = #"{"id":"\#(id)","timestamp":"\#(time)","level":"info","component":"\#(component)","message":"m","playback_session_id":"\#(session)"\#(nodeJSON)}"#
        return try JSONDecoder.iso8601.decode(OperationalLogEntry.self, from: Data(json.utf8))
    }

    private func audit(_ id: String, _ time: String, node: String? = nil, session: String = "ps_1") throws -> AuditLogEntry {
        let nodeJSON = node.map { #","node_id":"\#($0)""# } ?? ""
        let json = #"{"id":"\#(id)","timestamp":"\#(time)","client_ip":"1.2.3.4","method":"GET","path":"/x","status_code":200,"duration_ms":5,"playback_session_id":"\#(session)"\#(nodeJSON)}"#
        return try JSONDecoder.iso8601.decode(AuditLogEntry.self, from: Data(json.utf8))
    }

    func testCountsRowsOfTheSessionOnly() throws {
        let summary = PlaybackSessionSummary(
            playbackSessionID: "ps_1",
            appRows: [try app("1", "2026-11-14T21:00:00Z"), try app("2", "2026-11-14T21:01:00Z", component: "ffmpeg"), try app("3", "2026-11-14T21:02:00Z", session: "ps_other")],
            auditRows: [try audit("a", "2026-11-14T21:03:00Z"), try audit("b", "2026-11-14T21:04:00Z", session: "ps_other")]
        )
        XCTAssertEqual(summary.appCount, 2)
        XCTAssertEqual(summary.ffmpegCount, 1)
        XCTAssertEqual(summary.auditCount, 1)
    }

    func testFirstAndLastSeenSpanAppAndAuditRows() throws {
        let summary = PlaybackSessionSummary(
            playbackSessionID: "ps_1",
            appRows: [try app("1", "2026-11-14T21:05:00Z")],
            auditRows: [try audit("a", "2026-11-14T21:00:00Z"), try audit("b", "2026-11-14T21:09:00Z")]
        )
        XCTAssertEqual(summary.firstSeen, ISO8601DateFormatter().date(from: "2026-11-14T21:00:00Z"))
        XCTAssertEqual(summary.lastSeen, ISO8601DateFormatter().date(from: "2026-11-14T21:09:00Z"))
    }

    func testNodesAreUniqueAndSorted() throws {
        let summary = PlaybackSessionSummary(
            playbackSessionID: "ps_1",
            appRows: [try app("1", "2026-11-14T21:00:00Z", node: "node-b"), try app("2", "2026-11-14T21:01:00Z", node: "node-a")],
            auditRows: [try audit("a", "2026-11-14T21:03:00Z", node: "node-b")]
        )
        XCTAssertEqual(summary.nodes, ["node-a", "node-b"])
    }

    func testNoRowsHasNoTimes() {
        let summary = PlaybackSessionSummary(playbackSessionID: "ps_1", appRows: [], auditRows: [])
        XCTAssertNil(summary.firstSeen)
        XCTAssertNil(summary.lastSeen)
        XCTAssertTrue(summary.nodes.isEmpty)
    }

    func testLoadReadsBothLogsFilteredBySession() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/admin/logs/app", data: LogsFixtures.page([
            LogsFixtures.entry("1", extra: #","playback_session_id":"ps_1""#),
            LogsFixtures.entry("2", extra: #","playback_session_id":"ps_1""#),
        ], hasMore: true, cursor: "c"))
        http.state.stub(path: "/api/v2/admin/logs/audit", data: AuditFixtures.page([], hasMore: false))
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)

        let summary = try await PlaybackSessionSummary.load(playbackSessionID: "ps_1", client: client)

        XCTAssertEqual(summary.appCount, 2)
        XCTAssertTrue(summary.appIsPartial, "a page with more behind it is a lower bound")
        XCTAssertFalse(summary.auditIsPartial)
        let appRequest = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/logs/app").first)
        let items = URLComponents(url: try XCTUnwrap(appRequest.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "playback_session_id" }?.value, "ps_1")
        XCTAssertEqual(items.first { $0.name == "limit" }?.value, "200")
        XCTAssertNil(items.first { $0.name == "component" }, "the summary counts every component, not the focused one")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/logs/audit").count, 1)
    }
}
