import XCTest
@testable import BloemAdmin

@MainActor
final class LibrariesViewModelTests: XCTestCase {
    private let libraries: [String: Any] = [
        "items": [
            ["id": "3", "name": "Movies", "type": "movies", "paths": ["/media/movies"], "enabled": true,
             "last_scanned_at": "2026-11-14T10:00:00.000Z"],
            ["id": "4", "name": "Shows", "type": "series", "paths": ["/media/shows", "/media/more"], "enabled": true,
             "scan_warning_code": "dead_root", "scan_warning_message": "Root /media/shows is not reachable",
             "scan_warning_at": "2026-11-14T09:00:00.000Z"],
        ],
    ]

    private func run(_ id: String, library: String, status: String, result: [String: Any]? = nil, error: String? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "library_id": library, "mode": "library", "trigger": "manual", "status": status,
            "requested_at": "2026-11-14T10:00:00.000Z",
        ]
        if status != "accepted" { value["started_at"] = "2026-11-14T10:00:02.000Z" }
        if ["completed", "failed", "cancelled"].contains(status) { value["completed_at"] = "2026-11-14T10:01:00.000Z" }
        if let result { value["result"] = result }
        if let error { value["error_message"] = error }
        return value
    }

    private func page(_ runs: [[String: Any]]) -> [String: Any] {
        ["items": runs, "page": ["has_more": false], "total": runs.count]
    }

    private func job(_ id: String, state: String, terminal: Bool = false, cancelable: Bool = true, library: String = "3", progress: (Int, Int)? = nil) -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "kind": "library_refresh", "state": state, "terminal": terminal, "cancelable": cancelable,
            "created_at": "2026-11-14T10:00:00.000Z", "library_id": library, "library_name": library == "3" ? "Movies" : "Shows",
            "library_ids": [String](),
        ]
        if let progress { value["progress"] = ["current": progress.0, "total": progress.1, "unit": "items"] }
        return value
    }

    private func makeHTTP(scans: [[String: Any]] = [], jobs: [[String: Any]] = []) -> MockHTTPHarness {
        let http = MockHTTPHarness()
        http.state.stub(path: "/api/v2/libraries", json: libraries)
        http.state.stub(path: "/api/v2/scan/capabilities", json: ["revision": "r", "state": "available"])
        http.state.stub(path: "/api/v2/admin/autoscan/scans", json: page(scans))
        http.state.stub(path: "/api/v2/admin/jobs", json: ["items": jobs])
        return http
    }

    private func client(_ http: MockHTTPHarness) -> APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
    }

    private func queryItems(_ request: URLRequest) -> [String: String] {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        return Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func body(_ http: MockHTTPHarness, _ path: String, index: Int = 0) throws -> [String: Any] {
        let data = try XCTUnwrap(http.state.body(path: path, requestIndex: index), "no body sent to \(path)")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Loading

    func testLoadReadsLibrariesScansAndRefreshJobs() async throws {
        let http = makeHTTP(
            scans: [
                run("r1", library: "4", status: "running"),
                run("r2", library: "3", status: "completed", result: ["new": 5, "updated": 1, "unchanged": 0, "missing": 0, "errors": 0, "skipped": 0]),
            ],
            jobs: [job("j1", state: "running", progress: (40, 200))]
        )
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertEqual(viewModel.libraries.map(\.name), ["Movies", "Shows"])
        XCTAssertEqual(viewModel.libraries[1].scanWarning?.code, "dead_root")
        XCTAssertEqual(viewModel.activeRuns.map(\.id), ["r1"])
        XCTAssertEqual(viewModel.recentRuns.map(\.id), ["r2"])
        XCTAssertEqual(viewModel.refreshJobs.map(\.id), ["j1"])
        XCTAssertNil(viewModel.loadFailure)
        XCTAssertNil(viewModel.scanResultsError)
        XCTAssertEqual(viewModel.scanState(for: viewModel.libraries[1]), .running(count: 1, queued: 0))
        XCTAssertEqual(viewModel.scanState(for: viewModel.libraries[0]).label, "Completed")
    }

    func testLoadAsksForQueuedRunningAndRecentScansAndRefreshJobsWithDeclaredQueryParameters() async throws {
        let http = makeHTTP()
        defer { http.invalidate() }

        await LibrariesViewModel().load(client: client(http))

        let scanQueries = http.state.requests(path: "/api/v2/admin/autoscan/scans").map(queryItems)
        XCTAssertEqual(scanQueries.count, 3)
        XCTAssertTrue(scanQueries.contains { $0["status"] == "accepted" && $0["limit"] == "50" })
        XCTAssertTrue(scanQueries.contains { $0["status"] == "running" && $0["limit"] == "50" })
        XCTAssertTrue(scanQueries.contains { $0["status"] == nil && $0["limit"] == "20" })
        let jobQuery = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/jobs").first).url.map { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        XCTAssertEqual(jobQuery??.queryItems?.first { $0.name == "kind" }?.value, "library_refresh")
    }

    func testAQueuedRunReturnedByEveryCallIsCountedOnce() async {
        let http = makeHTTP(scans: [run("r1", library: "3", status: "accepted")])
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertEqual(viewModel.activeRuns.map(\.id), ["r1"])
        XCTAssertTrue(viewModel.recentRuns.isEmpty)
        XCTAssertEqual(viewModel.scanState(for: viewModel.libraries[0]), .queued(count: 1))
    }

    func testLibrariesStayVisibleWhenScanResultsCannotBeRead() async {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/admin/autoscan/scans", json: ["type": "about:blank", "title": "Service unavailable", "status": 503, "detail": "autoscan scan history is unavailable"], status: 503)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertEqual(viewModel.libraries.count, 2)
        XCTAssertNil(viewModel.loadFailure)
        XCTAssertNotNil(viewModel.scanResultsError)
        XCTAssertTrue(viewModel.activeRuns.isEmpty)
    }

    func testLibrariesStayVisibleWhenRefreshJobsCannotBeRead() async {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/admin/jobs", json: ["type": "about:blank", "title": "Service unavailable", "status": 503, "detail": "admin jobs unavailable"], status: 503)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertEqual(viewModel.libraries.count, 2)
        XCTAssertNotNil(viewModel.refreshJobsError)
        XCTAssertTrue(viewModel.refreshJobs.isEmpty)
    }

    func testFailureToReadTheLibrariesIsATypedPageFailure() async {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/libraries", json: ["type": "about:blank", "title": "Internal error", "status": 500, "detail": "database is down"], status: 500)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertTrue(viewModel.libraries.isEmpty)
        XCTAssertEqual(viewModel.loadFailure?.kind, .serverFailure)
    }

    func testScanControlsAreOffWhenTheServerSaysScanningIsNotConfigured() async {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/scan/capabilities", json: ["revision": "r", "state": "not_configured"])
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertFalse(viewModel.scanAvailable)
    }

    func testScanControlsStayOnWhenTheCapabilityCheckFails() async {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/scan/capabilities", json: ["status": 500], status: 500)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertTrue(viewModel.scanAvailable)
    }

    func testASlowerEarlierLoadNeverReplacesANewerOne() async {
        let viewModel = LibrariesViewModel()
        let old = viewModel.beginLoad()
        let new = viewModel.beginLoad()
        let snapshot = LibrariesSnapshot(libraries: [], activeRuns: [], recentRuns: [], refreshJobs: [], scanAvailable: true, scanResultsError: nil, refreshJobsError: nil)

        viewModel.apply(.success(snapshot), token: new, sessionState: nil)
        viewModel.apply(.failure(TestError.expected), token: old, sessionState: nil)

        XCTAssertNil(viewModel.loadFailure)
    }

    // MARK: Scan and Stop

    func testScanPostsTheLibraryIdAndShowsQueuedAtOnce() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/scan", json: ["status": "accepted", "mode": "library", "library_id": "3"], status: 202)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.scan(viewModel.libraries[0], client: apiClient)

        XCTAssertEqual(try body(http, "/api/v2/scan")["library_id"] as? String, "3")
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(viewModel.scanState(for: viewModel.libraries[0]), .queued(count: 1))
        XCTAssertTrue(viewModel.busyLibraryIDs.isEmpty)
        // The runs are read again straight away: 3 calls for the first load, 3 after the scan.
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/autoscan/scans").count, 6)
    }

    func testTheNextReadReplacesTheQueuedGuessWithWhatTheServerSays() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/scan", json: ["status": "accepted", "mode": "library", "library_id": "3"], status: 202)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)
        await viewModel.scan(viewModel.libraries[0], client: apiClient)

        http.state.stub(path: "/api/v2/admin/autoscan/scans", json: page([
            run("r1", library: "3", status: "completed", result: ["new": 12, "updated": 3, "unchanged": 0, "missing": 0, "errors": 0, "skipped": 0]),
        ]))
        await viewModel.load(client: apiClient)

        let state = viewModel.scanState(for: viewModel.libraries[0])
        XCTAssertEqual(state.label, "Completed")
    }

    func testAFailedScanStartSaysWhichLibraryAndWhatToDo() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/scan", json: ["type": "about:blank", "title": "Conflict", "status": 409, "detail": "a scan of this library is already queued"], status: 409)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.scan(viewModel.libraries[0], client: apiClient)

        let message = try XCTUnwrap(viewModel.actionErrorMessage)
        XCTAssertTrue(message.contains("Movies"), message)
        XCTAssertEqual(viewModel.scanState(for: viewModel.libraries[0]), .idle, "a refused scan is not shown as queued")
    }

    func testStopPostsTheLibraryIdAndReportsHowManyScansWereStopped() async throws {
        let http = makeHTTP(scans: [run("r1", library: "3", status: "running")])
        http.state.stub(path: "/api/v2/scan/cancel", json: ["cancelled": 2, "library_id": "3"])
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.stopScans(viewModel.libraries[0], client: apiClient)

        XCTAssertEqual(try body(http, "/api/v2/scan/cancel")["library_id"] as? String, "3")
        XCTAssertEqual(viewModel.noticeMessage, "Stopped 2 scans of Movies")
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/autoscan/scans").count, 6)
    }

    func testStopWithNothingToStopSaysSo() async {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/scan/cancel", json: ["cancelled": 0, "library_id": "3"])
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.stopScans(viewModel.libraries[0], client: apiClient)

        XCTAssertEqual(viewModel.noticeMessage, "No scans of Movies were queued or running")
    }

    // MARK: Check the mount

    func testCheckMountStoresTheAnswerAndReadsTheLibrariesAgain() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/libraries/4/check-mount", json: [
            "status": "healthy", "library_id": "4", "library_name": "Shows", "healthy": true, "checked_at": "2026-11-14T10:00:00.000Z",
            "summary": "All configured roots are reachable",
            "roots": [["path": "/media/shows", "reachable": true, "error_code": NSNull(), "error_message": NSNull(), "suspect_empty": false]],
        ])
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.checkMount(viewModel.libraries[1], client: apiClient)

        XCTAssertEqual(http.state.requests(path: "/api/v2/libraries/4/check-mount").first?.httpMethod, "POST")
        guard case .answered(let check) = viewModel.mountCheck(for: viewModel.libraries[1]) else {
            return XCTFail("expected an answer, got \(String(describing: viewModel.mountCheck(for: viewModel.libraries[1])))")
        }
        XCTAssertEqual(check.verdict, .reachable)
        XCTAssertEqual(http.state.requests(path: "/api/v2/libraries").count, 2, "a healthy check clears the warning on the server, so the list is read again")
    }

    func testCheckMountFailureSaysItCouldNotCheck() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/libraries/3/check-mount", json: ["type": "about:blank", "title": "Not found", "status": 404, "detail": "library not found"], status: 404)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.checkMount(viewModel.libraries[0], client: apiClient)

        guard case .failed(let message) = viewModel.mountCheck(for: viewModel.libraries[0]) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.contains("Movies"), message)
    }

    // MARK: Refresh metadata

    func testRefreshMissingSendsQuickAndTracksTheReturnedJob() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/libraries/3/refresh-metadata", json: job("j7", state: "queued"), status: 202)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.refreshMetadata(viewModel.libraries[0], mode: .missingOnly, client: apiClient)

        XCTAssertEqual(try body(http, "/api/v2/libraries/3/refresh-metadata")["mode"] as? String, "quick")
        XCTAssertEqual(viewModel.activeRefreshJob(for: viewModel.libraries[0])?.id, "j7", "the returned job shows before the next list read")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testRefreshAllSendsFull() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/libraries/3/refresh-metadata", json: job("j8", state: "queued"), status: 202)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.refreshMetadata(viewModel.libraries[0], mode: .all, client: apiClient)

        XCTAssertEqual(try body(http, "/api/v2/libraries/3/refresh-metadata")["mode"] as? String, "full")
    }

    func testRefreshWhileOneIsRunningSaysSoInsteadOfFailingSilently() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/libraries/3/refresh-metadata", json: ["type": "about:blank", "title": "Conflict", "status": 409, "detail": "a refresh is already running"], status: 409)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.refreshMetadata(viewModel.libraries[0], mode: .missingOnly, client: apiClient)

        let message = try XCTUnwrap(viewModel.actionErrorMessage)
        XCTAssertTrue(message.contains("Movies"), message)
    }

    func testAnActiveRefreshJobIsFoundByLibraryAndCanBeCanceled() async throws {
        let http = makeHTTP(jobs: [job("j1", state: "running", progress: (10, 100)), job("j2", state: "running", library: "4")])
        http.state.stub(path: "/api/v2/admin/jobs/j1/cancel", json: job("j1", state: "canceling"), status: 202)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()
        let apiClient = client(http)
        await viewModel.load(client: apiClient)
        let active = try XCTUnwrap(viewModel.activeRefreshJob(for: viewModel.libraries[0]))
        XCTAssertEqual(active.id, "j1")

        await viewModel.cancelRefresh(active, library: viewModel.libraries[0], client: apiClient)

        let request = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/jobs/j1/cancel").first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testTheLastFinishedRefreshIsKeptForTheRowWhenNothingIsActive() async throws {
        let finished: [String: Any] = {
            var value = job("j3", state: "succeeded", terminal: true, cancelable: false)
            value["refresh_result"] = ["library_id": "3", "refreshed": 197, "failed": 3]
            value["finished_at"] = "2026-11-14T10:10:00.000Z"
            return value
        }()
        let http = makeHTTP(jobs: [finished])
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel()

        await viewModel.load(client: client(http))

        XCTAssertNil(viewModel.activeRefreshJob(for: viewModel.libraries[0]))
        XCTAssertEqual(viewModel.lastRefreshJob(for: viewModel.libraries[0])?.resultText, "197 refreshed, 3 failed")
    }

    // MARK: Server name

    func testActionErrorsNameTheServerInAllServers() async throws {
        let http = makeHTTP()
        http.state.stub(path: "/api/v2/scan", json: ["type": "about:blank", "title": "Forbidden", "status": 403, "detail": "not allowed"], status: 403)
        defer { http.invalidate() }
        let viewModel = LibrariesViewModel(serverName: "Home")
        let apiClient = client(http)
        await viewModel.load(client: apiClient)

        await viewModel.scan(viewModel.libraries[0], client: apiClient)

        let message = try XCTUnwrap(viewModel.actionErrorMessage)
        XCTAssertTrue(message.hasPrefix("Home: "), message)
    }
}
