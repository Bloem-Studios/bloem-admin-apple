import XCTest
@testable import BloemAdmin

/// The Nodes page's reads and writes: summaries read page by page, Drain and Resume, Enable and Disable
/// (which need the node's configuration version as `If-Match`), and how failures are reported.
@MainActor
final class NodesModelTests: XCTestCase {
    private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func summary(_ id: String, enabled: Bool = true) -> [String: Any] {
        ["id": id, "name": "node-\(id)", "type": "transcode", "enabled": enabled, "healthy": true, "group": NSNull(),
         "drain_state": "none", "drain_requested": false, "active_jobs": 0, "max_jobs": NSNull(), "egress_kbps": 0,
         "max_bandwidth_kbps": NSNull(), "last_health_check": NSNull(), "created_at": "2026-01-01T00:00:00Z"]
    }

    private func stubSummaries() {
        http.state.stub(path: "/api/v2/admin/nodes/summary", json: ["items": [summary("n1"), summary("n2")]])
    }

    func testLoadReadsEveryPageOfTheSummaryWithTheLargestPageSize() async throws {
        http.state.stubSequence(path: "/api/v2/admin/nodes/summary", responses: [
            MockHTTPResponse(json: ["items": [summary("n1")], "page": ["has_more": true, "next_cursor": "c2"]]),
            MockHTTPResponse(json: ["items": [summary("n2")], "page": ["has_more": false]]),
        ])
        let model = SectionModel<[NodeSummary]>.nodes()

        await model.load(client: http.client)

        XCTAssertEqual(model.payload?.map(\.id), ["n1", "n2"])
        let first = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/nodes/summary").first?.url)
        XCTAssertEqual(URLComponents(url: first, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value, "200")
    }

    func testAFailedLoadIsTypedAndKeepsNothingOnFirstLoad() async {
        http.state.stub(path: "/api/v2/admin/nodes/summary", json: ["message": "nope"], status: 403)
        let model = SectionModel<[NodeSummary]>.nodes()

        await model.load(client: http.client)

        XCTAssertEqual(model.loadFailure?.kind, .forbidden)
        XCTAssertNil(model.payload)
    }

    func testAFailedReloadKeepsTheLastGoodRows() async {
        http.state.stubSequence(path: "/api/v2/admin/nodes/summary", responses: [
            MockHTTPResponse(json: ["items": [summary("n1")]]),
            MockHTTPResponse(json: ["message": "down"], status: 503),
        ])
        let model = SectionModel<[NodeSummary]>.nodes()

        await model.load(client: http.client)
        await model.load(client: http.client)

        XCTAssertEqual(model.payload?.map(\.id), ["n1"])
        XCTAssertNotNil(model.loadFailure)
    }

    func testDrainAndResumePostToTheNodeThenReload() async throws {
        stubSummaries()
        http.state.stub(path: "/api/v2/admin/nodes/n1/drain", json: ["node_id": "n1", "drain_requested": true, "drain_state": "draining", "active_jobs": 1])
        http.state.stub(path: "/api/v2/admin/nodes/n1/resume", json: ["node_id": "n1", "drain_requested": false, "drain_state": "none", "active_jobs": 1])
        let model = SectionModel<[NodeSummary]>.nodes()
        await model.load(client: http.client)

        let drained = await model.drain(id: "n1", client: http.client)
        let resumed = await model.resume(id: "n1", client: http.client)

        XCTAssertTrue(drained)
        XCTAssertTrue(resumed)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/nodes/n1/drain").first?.httpMethod, "POST")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/nodes/n1/resume").first?.httpMethod, "POST")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/nodes/summary").count, 3, "one read to start, one after each action")
        XCTAssertNil(model.actionErrorMessage)
    }

    func testDisableReadsTheConfigurationVersionAndSendsItAsIfMatch() async throws {
        stubSummaries()
        http.state.stub(path: "/api/v2/admin/nodes", json: ["items": [
            ["id": "n1", "config_etag": "\"cfg1\""], ["id": "n2", "config_etag": "\"cfg2\""],
        ]])
        http.state.stub(path: "/api/v2/admin/nodes/n2", json: summary("n2", enabled: false))
        let model = SectionModel<[NodeSummary]>.nodes()
        await model.load(client: http.client)

        let done = await model.setEnabled(false, id: "n2", client: http.client)

        XCTAssertTrue(done)
        let put = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/nodes/n2").first)
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-Match"), "\"cfg2\"")
        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/nodes/n2", requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Bool], ["enabled": false])
    }

    func testANodeWithNoStoredConfigurationVersionIsNotChangedAndTheErrorSaysWhatToDo() async throws {
        stubSummaries()
        http.state.stub(path: "/api/v2/admin/nodes", json: ["items": [["id": "n1"]]])
        let model = SectionModel<[NodeSummary]>.nodes()
        await model.load(client: http.client)

        let done = await model.setEnabled(false, id: "n1", client: http.client)

        XCTAssertFalse(done)
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/nodes/n1").isEmpty, "no write without a version to guard it")
        XCTAssertEqual(model.actionErrorMessage, "This node has no saved configuration version, so it cannot be changed from here. Change it on the web.")
    }

    func testAChangeMadeElsewhereIsAConflictTheErrorExplains() async throws {
        stubSummaries()
        http.state.stub(path: "/api/v2/admin/nodes", json: ["items": [["id": "n1", "config_etag": "\"cfg1\""]]])
        http.state.stub(path: "/api/v2/admin/nodes/n1", response: MockHTTPResponse(
            data: Data(#"{"title":"Precondition Failed","status":412,"detail":"changed"}"#.utf8), status: 412,
            headers: ["Content-Type": "application/problem+json"]
        ))
        let model = SectionModel<[NodeSummary]>.nodes()
        await model.load(client: http.client)

        let done = await model.setEnabled(true, id: "n1", client: http.client)

        XCTAssertFalse(done)
        XCTAssertEqual(model.actionErrorMessage, "This node was changed somewhere else. Reload the page and try again.")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/nodes/summary").count, 1, "a failed action does not reload over its own error")
    }

    func testAFailedDrainNamesTheServerInAllServersMode() async {
        stubSummaries()
        http.state.stub(path: "/api/v2/admin/nodes/n1/drain", json: ["message": "Only transcode nodes drain"], status: 409)
        let model = SectionModel<[NodeSummary]>.nodes(serverName: "Home")
        await model.load(client: http.client)

        let done = await model.drain(id: "n1", client: http.client)

        XCTAssertFalse(done)
        XCTAssertEqual(model.actionErrorMessage, "Home: Only transcode nodes drain")
    }

    func testCheckNowPostsToTheCheckRoute() async {
        stubSummaries()
        http.state.stub(path: "/api/v2/admin/nodes/n1/check", json: ["healthy": true, "active_jobs": 0, "egress_kbps": 0, "health_persisted": true])
        let model = SectionModel<[NodeSummary]>.nodes()
        await model.load(client: http.client)

        let done = await model.checkNow(id: "n1", client: http.client)

        XCTAssertTrue(done)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/nodes/n1/check").first?.httpMethod, "POST")
    }

    func testNodeIDIsOneEncodedPathSegment() async throws {
        http.state.stub(path: "/api/v2/admin/nodes/a b/drain", json: ["node_id": "a b", "drain_requested": true, "drain_state": "draining", "active_jobs": 0])
        http.state.stub(path: "/api/v2/admin/nodes/summary", json: ["items": [Any]()])
        let model = SectionModel<[NodeSummary]>.nodes()

        _ = await model.drain(id: "a b", client: http.client)

        let url = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/nodes/a b/drain").first?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/api/v2/admin/nodes/a%20b/drain")
    }

    func testAnActionOnANodeAlreadyBusyIsIgnored() async {
        stubSummaries()
        http.state.stub(path: "/api/v2/admin/nodes/n1/drain", json: ["node_id": "n1", "drain_requested": true, "drain_state": "draining", "active_jobs": 0])
        let model = SectionModel<[NodeSummary]>.nodes()
        await model.load(client: http.client)

        let client = http.client
        let first = Task { @MainActor in await model.drain(id: "n1", client: client) }
        let second = Task { @MainActor in await model.drain(id: "n1", client: client) }
        let results = [await first.value, await second.value]

        XCTAssertEqual(results.filter { $0 }.count, 1)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/nodes/n1/drain").count, 1)
    }
}
