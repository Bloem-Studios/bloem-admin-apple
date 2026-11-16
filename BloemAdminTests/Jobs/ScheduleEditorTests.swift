import XCTest
@testable import BloemAdmin

@MainActor
final class ScheduleEditorTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let path = "/api/v2/admin/tasks/refresh_metadata/triggers"
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func task(manualOnly: Bool = false, key: String = "refresh_metadata") -> AdminTask {
        AdminTask(key: key, name: "Refresh Metadata", description: "", category: "metadata", state: "idle", progress: 0, progressMessage: nil, manualOnly: manualOnly, triggers: [])
    }

    private func scheduleResponse(_ triggers: String, etag: String?) -> MockHTTPResponse {
        MockHTTPResponse(
            data: Data(#"{"task_key":"refresh_metadata","triggers":\#(triggers)}"#.utf8),
            status: 200,
            headers: etag.map { ["ETag": $0] } ?? [:]
        )
    }

    private let conflict = MockHTTPResponse(
        data: Data(#"{"type":"https://example.test/problems/precondition_failed","title":"Precondition Failed","status":412,"detail":"The schedule changed."}"#.utf8),
        status: 412,
        headers: ["Content-Type": "application/problem+json"]
    )

    func testOpenReadsTheScheduleWithItsETagAndFillsTheForm() async {
        http.state.stubSequence(path: path, responses: [
            scheduleResponse(#"[{"type":"startup"},{"type":"interval","interval_ms":3600000},{"type":"daily","time_of_day":"03:30"}]"#, etag: "\"s1\""),
        ])
        let editor = ScheduleEditor(task: task())

        await editor.open(client: client)

        XCTAssertEqual(editor.snapshot?.validator, "\"s1\"")
        XCTAssertEqual(editor.snapshot?.triggers.count, 3)
        XCTAssertTrue(editor.startupEnabled)
        XCTAssertTrue(editor.intervalEnabled)
        XCTAssertEqual(editor.intervalMinutesText, "60")
        XCTAssertNil(editor.errorMessage)
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "GET")
    }

    func testMissingETagRefusesTheEdit() async {
        http.state.stubSequence(path: path, responses: [scheduleResponse("[]", etag: nil)])
        let editor = ScheduleEditor(task: task())

        await editor.open(client: client)

        XCTAssertNil(editor.snapshot)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertFalse(editor.canSave)
        let saved = await editor.save(client: client)
        XCTAssertFalse(saved)
        XCTAssertNil(http.state.requests(path: path).first { $0.httpMethod == "PUT" })
    }

    func testManualOnlyTaskCannotBeScheduledAndNothingIsRequested() async {
        let editor = ScheduleEditor(task: task(manualOnly: true))

        await editor.open(client: client)

        XCTAssertNil(editor.snapshot)
        XCTAssertNotNil(editor.errorMessage)
        XCTAssertFalse(editor.canSave)
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testSaveSendsIfMatchFromTheOpenReadWrapsTriggersAndKeepsOtherTypes() async throws {
        http.state.stubSequence(path: path, responses: [
            scheduleResponse(#"[{"type":"daily","time_of_day":"03:30","max_runtime_ms":900000}]"#, etag: "\"s1\""),
            scheduleResponse(#"[]"#, etag: "\"s2\""),
        ])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)
        editor.startupEnabled = true
        editor.intervalEnabled = true
        editor.intervalMinutesText = "30"

        let saved = await editor.save(client: client)

        XCTAssertTrue(saved)
        let requests = http.state.requests(path: path)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Match"), "\"s1\"")
        let body = try XCTUnwrap(http.state.capturedBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let triggers = try XCTUnwrap(object["triggers"] as? [[String: Any]])
        XCTAssertEqual(triggers.map { $0["type"] as? String }, ["daily", "startup", "interval"])
        XCTAssertEqual(triggers[0]["time_of_day"] as? String, "03:30")
        XCTAssertEqual(triggers[0]["max_runtime_ms"] as? Int, 900_000)
        XCTAssertEqual(triggers[2]["interval_ms"] as? Int, 1_800_000)
    }

    func testTaskKeyIsOneEncodedPathSegment() async throws {
        http.state.stub(path: "/api/v2/admin/tasks/a b?c#d/triggers", response: scheduleResponse("[]", etag: "\"s1\""))
        let editor = ScheduleEditor(task: task(key: "a b?c#d"))

        await editor.open(client: client)

        let request = try XCTUnwrap(http.state.lastRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/tasks/a%20b%3Fc%23d/triggers")
        XCTAssertNil(components.query)
    }

    func testUnchangedFormCannotBeSaved() async {
        http.state.stubSequence(path: path, responses: [scheduleResponse(#"[{"type":"startup"}]"#, etag: "\"s1\"")])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)

        XCTAssertFalse(editor.canSave)
        editor.startupEnabled = false
        XCTAssertTrue(editor.canSave)
    }

    func testInvalidIntervalBlocksSaving() async {
        http.state.stubSequence(path: path, responses: [scheduleResponse("[]", etag: "\"s1\"")])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)
        editor.intervalEnabled = true
        editor.intervalMinutesText = "0"

        XCTAssertNotNil(editor.validationError)
        XCTAssertFalse(editor.canSave)
    }

    func testStaleETagKeepsTheDraftAndOffersTheCurrentScheduleWithoutRetrying() async throws {
        http.state.stubSequence(path: path, responses: [
            scheduleResponse(#"[{"type":"startup"}]"#, etag: "\"s1\""),
            conflict,
            scheduleResponse(#"[{"type":"startup"},{"type":"daily","time_of_day":"04:00"}]"#, etag: "\"s2\""),
            scheduleResponse("[]", etag: "\"s3\""),
        ])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)
        editor.intervalEnabled = true
        editor.intervalMinutesText = "15"

        let saved = await editor.save(client: client)

        XCTAssertFalse(saved)
        XCTAssertTrue(editor.hasConflict)
        XCTAssertEqual(editor.intervalMinutesText, "15")
        XCTAssertFalse(editor.canSave)
        XCTAssertEqual(http.state.requests(path: path).filter { $0.httpMethod == "PUT" }.count, 1)

        await editor.reviewCurrent(client: client)
        XCTAssertEqual(editor.latest?.triggers.count, 2)
        XCTAssertEqual(editor.intervalMinutesText, "15")

        editor.adoptCurrent()
        XCTAssertFalse(editor.hasConflict)
        XCTAssertTrue(editor.canSave)
        XCTAssertTrue(editor.intervalEnabled)

        let savedAgain = await editor.save(client: client)
        XCTAssertTrue(savedAgain)
        let last = try XCTUnwrap(http.state.requests(path: path).last)
        XCTAssertEqual(last.value(forHTTPHeaderField: "If-Match"), "\"s2\"")
        let body = try XCTUnwrap(http.state.capturedBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let types = (object["triggers"] as? [[String: Any]])?.map { $0["type"] as? String }
        XCTAssertEqual(types, ["startup", "daily", "interval"])
    }

    func testMissingIfMatchAnswer428IsAlsoAConflict() async {
        http.state.stubSequence(path: path, responses: [
            scheduleResponse("[]", etag: "\"s1\""),
            MockHTTPResponse(data: Data(#"{"type":"about:blank","title":"Precondition Required","status":428,"detail":"If-Match is required."}"#.utf8), status: 428, headers: ["Content-Type": "application/problem+json"]),
        ])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)
        editor.startupEnabled = true

        _ = await editor.save(client: client)

        XCTAssertTrue(editor.hasConflict)
    }

    func testOtherFailureKeepsTheDraftAndShowsTheServerMessage() async {
        http.state.stubSequence(path: path, responses: [
            scheduleResponse("[]", etag: "\"s1\""),
            MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Not authorized to change schedules"}"#.utf8), status: 403),
        ])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)
        editor.startupEnabled = true

        let saved = await editor.save(client: client)

        XCTAssertFalse(saved)
        XCTAssertFalse(editor.hasConflict)
        XCTAssertEqual(editor.errorMessage, "Not authorized to change schedules")
        XCTAssertTrue(editor.startupEnabled)
    }

    func testSave401FlagsSessionStateTokenExpired() async {
        http.state.stubSequence(path: path, responses: [
            scheduleResponse("[]", etag: "\"s1\""),
            MockHTTPResponse(data: Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), status: 401),
        ])
        let root = AdminSessionState()
        root.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(baseURL: URL(string: "https://example.test")!, credentialProvider: root.credentialProvider(serverID: "srv-1"), session: http.session)
        let scoped = root.scoped(to: "srv-1")
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client, sessionState: scoped)
        editor.startupEnabled = true

        _ = await editor.save(client: client, sessionState: scoped)

        XCTAssertTrue(scoped.tokenExpired)
        XCTAssertEqual(editor.errorMessage, "Token expired")
    }

    func testAggregateEditorNamesTheServerInTitleConflictAndErrors() async {
        http.state.stubSequence(path: path, responses: [
            scheduleResponse("[]", etag: "\"s1\""),
            conflict,
            MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8), status: 403),
        ])
        let editor = ScheduleEditor(task: task(), serverName: "Home")
        XCTAssertEqual(editor.title, "Home · Refresh Metadata")
        XCTAssertEqual(ScheduleEditor(task: task()).title, "Refresh Metadata")
        await editor.open(client: client)
        editor.startupEnabled = true
        _ = await editor.save(client: client)
        XCTAssertTrue(editor.conflictMessage.contains("Home"))
        await editor.reviewCurrent(client: client)
        XCTAssertEqual(editor.errorMessage, "Home: Not allowed")
    }
}
