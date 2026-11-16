import XCTest
@testable import BloemAdmin

/// Daily and weekly triggers in the schedule editor, as the web's trigger form edits them: a time of
/// day, a weekday for weekly, an optional maximum runtime. The ETag, the conflict handling and the
/// triggers this editor does not own are unchanged.
@MainActor
final class TimedTriggerEditorTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let path = "/api/v2/admin/tasks/scan/triggers"
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func task(key: String = "scan") -> AdminTask {
        AdminTask(key: key, name: "Scan libraries", description: "", category: "library", state: "idle", progress: 0, progressMessage: nil, manualOnly: false, triggers: [])
    }

    private func schedule(_ triggers: String, etag: String? = "\"s1\"") -> MockHTTPResponse {
        MockHTTPResponse(data: Data(#"{"task_key":"scan","triggers":\#(triggers)}"#.utf8), status: 200, headers: etag.map { ["ETag": $0] } ?? [:])
    }

    private func opened(_ triggers: String) async -> ScheduleEditor {
        http.state.stubSequence(path: path, responses: [schedule(triggers), schedule("[]", etag: "\"s2\"")])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)
        return editor
    }

    private func sentTriggers() throws -> [[String: Any]] {
        let body = try XCTUnwrap(http.state.capturedBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(object["triggers"] as? [[String: Any]])
    }

    func testOpenFillsADraftForEachDailyAndWeeklyTrigger() async throws {
        let editor = await opened(#"[{"type":"daily","time_of_day":"02:00"},{"type":"weekly","day_of_week":3,"time_of_day":"03:30","max_runtime_ms":5400000}]"#)

        XCTAssertEqual(editor.timed.map(\.kind), [.daily, .weekly])
        XCTAssertEqual(editor.timed[0].timeText, "02:00")
        XCTAssertEqual(editor.timed[1].weekday, 3)
        XCTAssertEqual(editor.timed[1].timeText, "03:30")
        XCTAssertEqual(editor.timed[1].maxRuntimeText, "90")
        XCTAssertFalse(editor.canSave, "nothing changed yet")
    }

    func testChangingTheTimeOfADailyTriggerSavesWithTheOpenETag() async throws {
        let editor = await opened(#"[{"type":"daily","time_of_day":"02:00"}]"#)

        editor.timed[0].minutes = 4 * 60 + 15
        XCTAssertTrue(editor.canSave)
        let saved = await editor.save(client: client)

        XCTAssertTrue(saved)
        XCTAssertEqual(http.state.requests(path: path).last?.value(forHTTPHeaderField: "If-Match"), "\"s1\"")
        let triggers = try sentTriggers()
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0]["type"] as? String, "daily")
        XCTAssertEqual(triggers[0]["time_of_day"] as? String, "04:15")
    }

    func testAddingAWeeklyTriggerAppendsItWithItsDayAndTime() async throws {
        let editor = await opened(#"[{"type":"startup"}]"#)

        editor.addTimed(.weekly)
        editor.timed[0].weekday = 6
        editor.timed[0].minutes = 5 * 60

        XCTAssertTrue(editor.canSave)
        _ = await editor.save(client: client)
        let triggers = try sentTriggers()
        XCTAssertEqual(triggers.map { $0["type"] as? String }, ["startup", "weekly"])
        XCTAssertEqual(triggers[1]["day_of_week"] as? Int, 6)
        XCTAssertEqual(triggers[1]["time_of_day"] as? String, "05:00")
    }

    func testRemovingATimedTriggerDropsItAndKeepsTheOthersInPlace() async throws {
        let editor = await opened(#"[{"type":"daily","time_of_day":"02:00"},{"type":"startup"},{"type":"weekly","day_of_week":0,"time_of_day":"06:00"}]"#)

        editor.removeTimed(id: editor.timed[0].id)
        _ = await editor.save(client: client)

        XCTAssertEqual(try sentTriggers().map { $0["type"] as? String }, ["startup", "weekly"])
    }

    func testMaxRuntimeIsSentInMillisecondsAndClearedWhenEmptied() async throws {
        let editor = await opened(#"[{"type":"daily","time_of_day":"02:00","max_runtime_ms":600000}]"#)
        XCTAssertEqual(editor.timed[0].maxRuntimeText, "10")

        editor.timed[0].maxRuntimeText = "45"
        _ = await editor.save(client: client)
        XCTAssertEqual(try sentTriggers()[0]["max_runtime_ms"] as? Int, 2_700_000)

        let again = await opened(#"[{"type":"daily","time_of_day":"02:00","max_runtime_ms":600000}]"#)
        again.timed[0].maxRuntimeText = ""
        _ = await again.save(client: client)
        XCTAssertNil(try sentTriggers()[0]["max_runtime_ms"])
    }

    func testABadMaximumRuntimeBlocksSavingAndSaysWhy() async {
        let editor = await opened(#"[{"type":"daily","time_of_day":"02:00"}]"#)

        editor.timed[0].maxRuntimeText = "soon"

        XCTAssertFalse(editor.canSave)
        XCTAssertEqual(editor.timed[0].validationMessage, "Enter the longest run in minutes, or leave it empty for no limit.")
    }

    func testAnUnreadableTimeKeepsTheTriggerAsItWasUntilItIsChanged() async throws {
        let editor = await opened(#"[{"type":"daily","time_of_day":"late"},{"type":"startup"}]"#)

        XCTAssertNil(editor.timed[0].minutes)
        XCTAssertFalse(editor.canSave, "an untouched trigger is never rewritten")

        editor.startupEnabled = false
        XCTAssertTrue(editor.canSave)
        _ = await editor.save(client: client)
        let triggers = try sentTriggers()
        XCTAssertEqual(triggers.count, 1)
        XCTAssertEqual(triggers[0]["time_of_day"] as? String, "late", "the original trigger is carried over unchanged")
    }

    func testChangingAnUnreadableTimeNeedsAValidTime() async {
        let editor = await opened(#"[{"type":"daily","time_of_day":"late"}]"#)

        editor.timed[0].maxRuntimeText = "30"

        XCTAssertFalse(editor.canSave, "a changed trigger needs a time of day")
        XCTAssertEqual(editor.timed[0].validationMessage, "Choose a time of day.")
    }

    func testAConflictStillKeepsTheDraftsAndOffersTheCurrentSchedule() async {
        http.state.stubSequence(path: path, responses: [
            schedule(#"[{"type":"daily","time_of_day":"02:00"}]"#),
            MockHTTPResponse(data: Data(#"{"title":"Precondition Failed","status":412,"detail":"The schedule changed."}"#.utf8), status: 412, headers: ["Content-Type": "application/problem+json"]),
            schedule(#"[{"type":"daily","time_of_day":"01:00"}]"#, etag: "\"s9\""),
        ])
        let editor = ScheduleEditor(task: task())
        await editor.open(client: client)
        editor.timed[0].minutes = 5 * 60

        let saved = await editor.save(client: client)
        await editor.reviewCurrent(client: client)

        XCTAssertFalse(saved)
        XCTAssertTrue(editor.hasConflict)
        XCTAssertEqual(editor.timed[0].timeText, "05:00", "the edit is kept")
        XCTAssertEqual(editor.latest?.triggers.first?.timeOfDay, "01:00")
    }

    func testTheBackupTaskFollowsTheBackupSetting() {
        XCTAssertTrue(task(key: "backup").followsBackupSetting)
        XCTAssertFalse(task(key: "scan").followsBackupSetting)
    }

    func testWeekdayNamesStartOnSundayAsTheServerNumbersThem() {
        let names = TimedTriggerDraft.weekdayNames(calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(names.first, "Sunday")
        XCTAssertEqual(names.count, 7)
        XCTAssertEqual(names[6], "Saturday")
    }
}
