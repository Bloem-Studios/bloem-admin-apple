import XCTest
@testable import BloemAdmin

@MainActor
final class JobsViewModelTests: XCTestCase {
    func testLoadDecodesTasks() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"""
        {"items":[{"key":"refresh_metadata","name":"Refresh Metadata","description":"Refreshes stale metadata","category":"metadata","state":"idle","progress":0,"manual_only":false,"triggers":[{"type":"startup"}],"execution_scope":"process"}]}
        """#.utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = JobsViewModel()
        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.tasks.count, 1)
        XCTAssertEqual(viewModel.tasks.first?.key, "refresh_metadata")
        XCTAssertEqual(viewModel.tasks.first?.triggers, [.startup])
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/tasks")
    }

    /// The tasks route declares only `include_hidden`; the server answers 422 to `limit`/`cursor`.
    func testLoadSendsNoQueryParameters() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"items":[]}"#.utf8)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = JobsViewModel()

        await viewModel.load(client: client)

        let url = try XCTUnwrap(http.state.lastRequest?.url)
        XCTAssertNil(url.query)
        XCTAssertFalse(url.absoluteString.contains("?"))
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/tasks").count, 1)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testTaskKeyIsOneEncodedPathSegmentForRunAndCancel() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data("{}".utf8)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = JobsViewModel()
        let target = AdminTask(key: "a b?c#d", name: "n", description: "", category: "system", state: "idle", progress: 0, progressMessage: nil, manualOnly: false, triggers: [])

        await viewModel.run(target, client: client)
        var components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(http.state.lastRequest?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/tasks/a%20b%3Fc%23d/run")
        XCTAssertNil(components.query)
        XCTAssertNil(viewModel.actionErrorMessage)

        await viewModel.cancel(target, client: client)
        components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(http.state.lastRequest?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/tasks/a%20b%3Fc%23d/cancel")
    }

    func testAggregateViewModelNamesTheServerInActionErrors() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8)
        http.state.responseStatus = 403
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = JobsViewModel(serverName: "Home")
        let target = AdminTask(key: "k", name: "n", description: "", category: "system", state: "idle", progress: 0, progressMessage: nil, manualOnly: false, triggers: [])

        await viewModel.run(target, client: client)

        XCTAssertEqual(viewModel.actionErrorMessage, "Home: Not allowed")
    }

    func testRunPostsToRunEndpoint() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data("[]".utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = JobsViewModel()
        let target = AdminTask(key: "refresh_metadata", name: "Refresh Metadata", description: "", category: "metadata", state: "idle", progress: 0, progressMessage: nil, manualOnly: false, triggers: [])

        await viewModel.run(target, client: client)

        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/tasks/refresh_metadata/run")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
    }

    /// Regression test for the exact silent-failure pattern already caught
    /// once in Task 4 (Streams): a rejected Run (e.g. 403) must leave
    /// `errorMessage` set. `run` itself never calls `load` (that's the
    /// caller's job, conditional on success) — this test proves the model
    /// side of that contract holds, mirroring
    /// StreamsViewModelTests.testStopFailureSetsErrorMessageAndIsNotClearedByConditionalReload.
    func testRunFailureSetsActionErrorMessageAndDoesNotReload() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"forbidden","message":"Not authorized to run this job"}"#.utf8)
        http.state.responseStatus = 403

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = JobsViewModel()
        let target = AdminTask(key: "refresh_metadata", name: "Refresh Metadata", description: "", category: "metadata", state: "idle", progress: 0, progressMessage: nil, manualOnly: false, triggers: [])

        await viewModel.run(target, client: client)

        // actionErrorMessage, NOT errorMessage — errorMessage drives the
        // list screen's full-screen "Connection lost" overlay, reserved for
        // load() failures only.
        XCTAssertEqual(viewModel.actionErrorMessage, "Not authorized to run this job")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/tasks/refresh_metadata/run")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")

        // Mirrors the guard used by JobDetailView's button handlers: only
        // reload when the action succeeded. Because it failed, load() must
        // NOT run here, so the error stays visible instead of being
        // silently wiped by a subsequent successful GET.
        if viewModel.actionErrorMessage == nil {
            await viewModel.load(client: client)
        }

        XCTAssertEqual(viewModel.actionErrorMessage, "Not authorized to run this job")
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/tasks/refresh_metadata/run")
        XCTAssertTrue(viewModel.tasks.isEmpty)
    }

    func testCancelPostsToCancelEndpoint() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data("[]".utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = JobsViewModel()
        let target = AdminTask(key: "refresh_metadata", name: "Refresh Metadata", description: "", category: "metadata", state: "running", progress: 0.5, progressMessage: nil, manualOnly: false, triggers: [])

        await viewModel.cancel(target, client: client)

        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/tasks/refresh_metadata/cancel")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    /// Feature 3: a 401 from an action must flag the shared session state so
    /// AdminGateView can route the whole tab view back to re-login.
    func testRunAction401FlagsSessionStateTokenExpired() async {
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
        let viewModel = JobsViewModel()
        let sessionState = rootSessionState.scoped(to: "srv-1")
        let target = AdminTask(key: "refresh_metadata", name: "Refresh Metadata", description: "", category: "metadata", state: "idle", progress: 0, progressMessage: nil, manualOnly: false, triggers: [])

        await viewModel.run(target, client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.actionErrorMessage, "Token expired")
    }

    // MARK: - Trigger schedule (Feature 4)

    func testTriggerContractRoundTripPreservesEveryServerField() throws {
        let original = Data(#"[{"type":"daily","time_of_day":"03:30","day_of_week":2,"max_runtime_ms":900000},{"type":"interval","interval_ms":3600000,"max_runtime_ms":120000}]"#.utf8)

        let triggers = try JSONDecoder().decode([TaskTrigger].self, from: original)
        let encoded = try JSONEncoder().encode(triggers)
        let roundTripped = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])

        XCTAssertEqual(roundTripped[0]["time_of_day"] as? String, "03:30")
        XCTAssertEqual(roundTripped[0]["day_of_week"] as? Int, 2)
        XCTAssertEqual(roundTripped[0]["max_runtime_ms"] as? Int, 900_000)
        XCTAssertEqual(roundTripped[1]["interval_ms"] as? Int, 3_600_000)
        XCTAssertEqual(roundTripped[1]["max_runtime_ms"] as? Int, 120_000)
    }

    func testEditingIntervalPreservesItsServerRuntimeFields() {
        let loaded = TaskTrigger(
            type: "interval",
            intervalMs: 3_600_000,
            timeOfDay: "fallback",
            dayOfWeek: 4,
            maxRuntimeMs: 120_000
        )

        let edited = loaded.replacingInterval(minutes: 30)

        XCTAssertEqual(edited.intervalMs, 1_800_000)
        XCTAssertEqual(edited.timeOfDay, "fallback")
        XCTAssertEqual(edited.dayOfWeek, 4)
        XCTAssertEqual(edited.maxRuntimeMs, 120_000)
    }

    func testScheduleEditorPreservesEveryRepeatedStartupAndIntervalTrigger() {
        let loaded = [
            TaskTrigger(type: "startup", maxRuntimeMs: 10),
            TaskTrigger(type: "interval", intervalMs: 60_000, timeOfDay: "a", maxRuntimeMs: 20),
            TaskTrigger(type: "startup", maxRuntimeMs: 30),
            TaskTrigger(type: "interval", intervalMs: 120_000, dayOfWeek: 4, maxRuntimeMs: 40),
            TaskTrigger(type: "daily", timeOfDay: "03:30", maxRuntimeMs: 50),
        ]

        let edited = TaskTrigger.applyingScheduleEditor(
            startupEnabled: true,
            intervalMinutes: 15,
            to: loaded
        )

        XCTAssertEqual(edited.count, 5)
        XCTAssertEqual(edited.filter(\.isStartup).map(\.maxRuntimeMs), [10, 30])
        XCTAssertEqual(edited.filter(\.isInterval).map(\.intervalMs), [900_000, 900_000])
        XCTAssertEqual(edited.filter(\.isInterval).map(\.timeOfDay), ["a", nil])
        XCTAssertEqual(edited.filter(\.isInterval).map(\.dayOfWeek), [nil, 4])
        XCTAssertEqual(edited.filter(\.isInterval).map(\.maxRuntimeMs), [20, 40])
        XCTAssertEqual(edited.last?.type, "daily")
        XCTAssertEqual(edited.last?.timeOfDay, "03:30")
    }

    func testExplicitlyDisablingIntervalRemovesOnlyIntervalTriggers() {
        let loaded = [
            TaskTrigger(type: "startup"),
            TaskTrigger.interval(minutes: 30),
            TaskTrigger(type: "daily", timeOfDay: "03:30"),
        ]
        let editor = TaskTrigger.scheduleEditorState(from: loaded)

        let edited = editor.makePayload(
            startupEnabled: true,
            intervalEnabled: false,
            intervalInput: "",
            triggers: loaded
        )

        XCTAssertEqual(edited?.map(\.type), ["startup", "daily"])
    }
}
