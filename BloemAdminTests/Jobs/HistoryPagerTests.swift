import XCTest
@testable import BloemAdmin

/// Task history (`GET /api/v2/admin/tasks/{key}/history`) and Job history (`GET /api/v2/admin/jobs`):
/// cursor paged, Load more appends, a failed first page and a failed next page are told apart.
@MainActor
final class HistoryPagerTests: XCTestCase {
    private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func run(_ id: String, status: String = "completed") -> [String: Any] {
        ["id": id, "task_key": "scan", "started_at": "2026-11-15T09:00:00Z", "completed_at": "2026-11-15T09:01:00Z", "status": status, "duration_ms": 60_000]
    }

    private func job(_ id: String, kind: String = "library_refresh", state: String = "completed") -> [String: Any] {
        ["id": id, "kind": kind, "state": state, "terminal": true, "cancelable": false, "created_at": "2026-11-15T09:00:00Z", "library_ids": [Int]()]
    }

    // MARK: Task history

    func testFirstPageReadsTheTasksHistoryWithALimitAndNoCursor() async throws {
        http.state.stub(path: "/api/v2/admin/tasks/scan/history", json: ["items": [run("r1"), run("r2")], "page": ["has_more": true, "next_cursor": "c2"]])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)

        XCTAssertEqual(pager.items.map(\.id), ["r1", "r2"])
        XCTAssertTrue(pager.hasMore)
        let url = try XCTUnwrap(http.state.lastRequest?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "limit" }?.value, "20")
        XCTAssertNil(query.first { $0.name == "cursor" })
    }

    func testTaskKeyIsOneEncodedPathSegment() async throws {
        http.state.stub(path: "/api/v2/admin/tasks/a b?c/history", json: ["items": [Any]()])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "a b?c")

        await pager.load(client: http.client)

        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(http.state.lastRequest?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/tasks/a%20b%3Fc/history")
    }

    func testLoadMoreSendsTheCursorAndAppends() async throws {
        http.state.stubSequence(path: "/api/v2/admin/tasks/scan/history", responses: [
            MockHTTPResponse(json: ["items": [run("r1")], "page": ["has_more": true, "next_cursor": "c2"]]),
            MockHTTPResponse(json: ["items": [run("r2")], "page": ["has_more": false]]),
        ])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)
        await pager.loadMore(client: http.client)

        XCTAssertEqual(pager.items.map(\.id), ["r1", "r2"])
        XCTAssertFalse(pager.hasMore)
        let second = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/tasks/scan/history").last?.url)
        XCTAssertEqual(URLComponents(url: second, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value, "c2")
    }

    func testLoadMoreDropsARowItAlreadyHas() async {
        http.state.stubSequence(path: "/api/v2/admin/tasks/scan/history", responses: [
            MockHTTPResponse(json: ["items": [run("r1"), run("r2")], "page": ["has_more": true, "next_cursor": "c2"]]),
            MockHTTPResponse(json: ["items": [run("r2"), run("r3")], "page": ["has_more": false]]),
        ])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)
        await pager.loadMore(client: http.client)

        XCTAssertEqual(pager.items.map(\.id), ["r1", "r2", "r3"])
    }

    func testARepeatedCursorStopsThePaging() async {
        http.state.stubSequence(path: "/api/v2/admin/tasks/scan/history", responses: [
            MockHTTPResponse(json: ["items": [run("r1")], "page": ["has_more": true, "next_cursor": "same"]]),
            MockHTTPResponse(json: ["items": [run("r2")], "page": ["has_more": true, "next_cursor": "same"]]),
        ])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)
        await pager.loadMore(client: http.client)

        XCTAssertFalse(pager.hasMore, "a server that repeats its cursor would otherwise loop")
    }

    func testLoadMoreWithNothingMoreSendsNoRequest() async {
        http.state.stub(path: "/api/v2/admin/tasks/scan/history", json: ["items": [run("r1")]])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)
        await pager.loadMore(client: http.client)

        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/tasks/scan/history").count, 1)
    }

    func testFailedFirstPageIsATypedFailureWithNoRows() async {
        http.state.stub(path: "/api/v2/admin/tasks/scan/history", json: ["message": "Not allowed"], status: 403)
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)

        XCTAssertEqual(pager.loadFailure?.kind, .forbidden)
        XCTAssertTrue(pager.items.isEmpty)
        XCTAssertTrue(pager.hasLoaded)
    }

    func testFailedNextPageKeepsTheRowsAndSaysWhatToDo() async {
        http.state.stubSequence(path: "/api/v2/admin/tasks/scan/history", responses: [
            MockHTTPResponse(json: ["items": [run("r1")], "page": ["has_more": true, "next_cursor": "c2"]]),
            MockHTTPResponse(json: ["message": "Busy"], status: 503),
        ])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)
        await pager.loadMore(client: http.client)

        XCTAssertEqual(pager.items.map(\.id), ["r1"])
        XCTAssertNil(pager.loadFailure)
        XCTAssertNotNil(pager.moreFailure)
        XCTAssertTrue(pager.hasMore, "Load more is still offered so the person can try again")
    }

    func testReloadStartsFromTheFirstPageAgain() async {
        http.state.stubSequence(path: "/api/v2/admin/tasks/scan/history", responses: [
            MockHTTPResponse(json: ["items": [run("r1")], "page": ["has_more": true, "next_cursor": "c2"]]),
            MockHTTPResponse(json: ["items": [run("r9")], "page": ["has_more": false]]),
        ])
        let pager = HistoryPager<TaskExecution>.taskHistory(key: "scan")

        await pager.load(client: http.client)
        await pager.load(client: http.client)

        XCTAssertEqual(pager.items.map(\.id), ["r9"])
    }

    // MARK: Job history

    func testJobHistoryReadsAdminJobs() async throws {
        http.state.stub(path: "/api/v2/admin/jobs", json: ["items": [job("j1"), job("j2", kind: "backup_restore", state: "failed")], "page": ["has_more": false]])
        let pager = HistoryPager<AdminJob>.jobHistory()

        await pager.load(client: http.client)

        XCTAssertEqual(pager.items.map(\.id), ["j1", "j2"])
        let url = try XCTUnwrap(http.state.lastRequest?.url)
        XCTAssertEqual(url.path, "/api/v2/admin/jobs")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "limit" }?.value, "20")
    }

    func testJobDecodesTheOptionalTargetProgressAndFailure() throws {
        let json = #"""
        {"id":"j9","kind":"library_refresh","state":"failed","terminal":true,"cancelable":false,"created_at":"2026-11-15T09:00:00.123Z",
         "started_at":"2026-11-15T09:00:01Z","finished_at":"2026-11-15T09:05:00Z","library_name":"Movies","library_ids":[3],
         "progress":{"current":40,"total":100,"unit":"items"},
         "failure":{"type":"x","title":"Refresh failed","detail":"Provider timed out","retryable":true}}
        """#
        let job = try JSONDecoder().decode(AdminJob.self, from: Data(json.utf8))

        XCTAssertEqual(job.libraryName, "Movies")
        XCTAssertEqual(job.progress?.current, 40)
        XCTAssertEqual(job.failure?.detail, "Provider timed out")
    }

    // MARK: Job rows

    private func jobRow(_ json: String, now: String = "2026-11-15T12:00:00Z") throws -> JobRowPresentation {
        JobRowPresentation(job: try JSONDecoder().decode(AdminJob.self, from: Data(json.utf8)), now: AdminTimestamp.date(from: now)!)
    }

    func testKnownKindsAreNamedInWords() throws {
        func title(_ kind: String) throws -> String {
            try jobRow(#"{"id":"j","kind":"\#(kind)","state":"completed","terminal":true,"cancelable":false,"created_at":"2026-11-15T09:00:00Z","library_ids":[]}"#).title
        }
        XCTAssertEqual(try title("library_refresh"), "Library refresh")
        XCTAssertEqual(try title("backup_restore"), "Backup restore")
        XCTAssertEqual(try title("delete_library"), "Library deletion")
        XCTAssertEqual(try title("image_cache_cleanup"), "Image cache cleanup")
        XCTAssertEqual(try title("catalog_export"), "Catalog export")
        XCTAssertEqual(try title("something_new"), "Something new", "an unknown kind is shown readably, never hidden")
    }

    func testTheRowNamesItsTargetAndItsStatusInWords() throws {
        let row = try jobRow(#"{"id":"j","kind":"library_refresh","state":"completed","terminal":true,"cancelable":false,"created_at":"2026-11-15T09:00:00Z","finished_at":"2026-11-15T10:00:00Z","library_name":"Movies","library_ids":[3]}"#)
        XCTAssertEqual(row.target, "Movies")
        XCTAssertEqual(row.stateText, "Completed")
        XCTAssertEqual(row.when, "Finished 2 h ago")
        XCTAssertFalse(row.isFailed)
    }

    func testAFailedRowCarriesTheFailureDetail() throws {
        let row = try jobRow(#"{"id":"j","kind":"backup_restore","state":"failed","terminal":true,"cancelable":false,"created_at":"2026-11-15T09:00:00Z","finished_at":"2026-11-15T09:30:00Z","library_ids":[],"failure":{"type":"x","title":"Restore failed","detail":"Not enough space","retryable":false}}"#)
        XCTAssertTrue(row.isFailed)
        XCTAssertEqual(row.stateText, "Failed")
        XCTAssertEqual(row.failure, "Restore failed: Not enough space")
    }

    func testARunningRowShowsItsProgressInWords() throws {
        let row = try jobRow(#"{"id":"j","kind":"library_refresh","state":"running","terminal":false,"cancelable":true,"created_at":"2026-11-15T11:50:00Z","started_at":"2026-11-15T11:55:00Z","library_ids":[],"progress":{"current":40,"total":100,"unit":"items"}}"#)
        XCTAssertEqual(row.stateText, "Running")
        XCTAssertEqual(row.progressText, "40 of 100 items")
        XCTAssertEqual(try XCTUnwrap(row.progress), 0.4, accuracy: 0.0001)
        XCTAssertEqual(row.when, "Started 5 min ago")
    }

    func testAQueuedRowWithNoStartSaysWhenItWasQueued() throws {
        let row = try jobRow(#"{"id":"j","kind":"item_refresh","state":"queued","terminal":false,"cancelable":true,"created_at":"2026-11-15T11:00:00Z","library_ids":[]}"#)
        XCTAssertEqual(row.stateText, "Queued")
        XCTAssertEqual(row.when, "Queued 1 h ago")
        XCTAssertNil(row.progress)
    }
}
