import XCTest
@testable import BloemAdmin

/// What a Scheduled tasks row says: the last result with its duration, Next run or Overdue, a progress
/// bar while running, and which of Run and Cancel the row offers. The clock is injected.
final class TaskRowPresentationTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-15T12:00:00Z")!

    private func decodeTask(_ json: String) throws -> AdminTask {
        try JSONDecoder().decode(AdminTask.self, from: Data(json.utf8))
    }

    private func task(
        state: String = "idle",
        progress: Double = 0,
        last: String? = nil,
        next: String? = nil,
        triggers: String = #"[{"type":"startup"}]"#,
        manualOnly: Bool = false
    ) throws -> AdminTask {
        var fields = #""key":"scan","name":"Scan libraries","description":"Finds new files","category":"library","state":"\#(state)","progress":\#(progress),"manual_only":\#(manualOnly),"triggers":\#(triggers),"execution_scope":"process""#
        if let last { fields += #","last_execution":\#(last)"# }
        if let next { fields += #","next_run_at":"\#(next)""# }
        return try decodeTask("{\(fields)}")
    }

    private func execution(status: String, completedAt: String = "2026-11-15T10:00:00Z", durationMs: Int = 125_000, error: String? = nil) -> String {
        var json = #"{"task_key":"scan","started_at":"2026-11-15T09:57:55Z","completed_at":"\#(completedAt)","status":"\#(status)","duration_ms":\#(durationMs)"#
        if let error { json += #","error_message":"\#(error)""# }
        return json + "}"
    }

    // MARK: Decoding

    func testDecodesLastExecutionNextRunAndProgressFromTheListRoute() throws {
        let task = try task(state: "running", progress: 42.5, last: execution(status: "failed", error: "disk full"), next: "2026-11-15T14:00:00Z")

        XCTAssertEqual(task.progress, 42.5)
        XCTAssertEqual(task.lastExecution?.status, "failed")
        XCTAssertEqual(task.lastExecution?.durationMs, 125_000)
        XCTAssertEqual(task.lastExecution?.errorMessage, "disk full")
        XCTAssertEqual(task.nextRunAt, "2026-11-15T14:00:00Z")
    }

    func testATaskWithoutARunOrNextRunDecodes() throws {
        let task = try task()
        XCTAssertNil(task.lastExecution)
        XCTAssertNil(task.nextRunAt)
    }

    func testAnExecutionDecodesFailedStepsAndKeepsTheHistoryID() throws {
        let json = #"""
        {"id":"run-7","task_key":"scan","started_at":"2026-11-15T09:57:55.250Z","completed_at":"2026-11-15T10:00:00Z","status":"failed","duration_ms":900,
         "steps":[{"key":"a","name":"Read folders","status":"completed"},{"key":"b","name":"Probe files","status":"failed"}]}
        """#
        let run = try JSONDecoder().decode(TaskExecution.self, from: Data(json.utf8))

        XCTAssertEqual(run.id, "run-7")
        XCTAssertEqual(run.failedSteps.map(\.name), ["Probe files"])
        XCTAssertNotNil(AdminTimestamp.date(from: run.startedAt), "fractional seconds parse")
    }

    // MARK: Last result

    func testCompletedLastResultNamesTheStatusTheAgeAndTheDuration() throws {
        let row = TaskRowPresentation(task: try task(last: execution(status: "completed")), now: now)
        XCTAssertEqual(row.lastResult, "Completed 2 h ago, took 2 min 5 s")
        XCTAssertFalse(row.lastResultFailed)
    }

    func testFailedLastResultIsMarkedAndSaysFailed() throws {
        let row = TaskRowPresentation(task: try task(last: execution(status: "failed", durationMs: 800)), now: now)
        XCTAssertEqual(row.lastResult, "Failed 2 h ago, took 800 ms")
        XCTAssertTrue(row.lastResultFailed)
    }

    func testCancelledLastResultIsNotAFailure() throws {
        let row = TaskRowPresentation(task: try task(last: execution(status: "cancelled", durationMs: 4_000)), now: now)
        XCTAssertEqual(row.lastResult, "Cancelled 2 h ago, took 4 s")
        XCTAssertFalse(row.lastResultFailed)
    }

    func testATaskThatNeverRanSaysSo() throws {
        let row = TaskRowPresentation(task: try task(), now: now)
        XCTAssertEqual(row.lastResult, "Never run")
    }

    // MARK: Next run

    func testNextRunInMinutesHoursAndDays() throws {
        func text(_ iso: String) throws -> String? { TaskRowPresentation(task: try task(next: iso), now: now).nextRun }
        XCTAssertEqual(try text("2026-11-15T12:30:00Z"), "Next run in 30 min")
        XCTAssertEqual(try text("2026-11-15T14:10:00Z"), "Next run in 2 h")
        XCTAssertEqual(try text("2026-11-18T12:00:00Z"), "Next run in 3 d")
        XCTAssertEqual(try text("2026-11-15T12:00:20Z"), "Next run in under a minute")
    }

    func testAPastNextRunIsOverdue() throws {
        let row = TaskRowPresentation(task: try task(next: "2026-11-15T11:00:00Z"), now: now)
        XCTAssertEqual(row.nextRun, "Overdue")
        XCTAssertTrue(row.isOverdue)
    }

    func testNoNextRunMeansNothingToSay() throws {
        XCTAssertNil(TaskRowPresentation(task: try task(), now: now).nextRun)
    }

    func testARunningTaskIsNeverOverdue() throws {
        let row = TaskRowPresentation(task: try task(state: "running", progress: 10, next: "2026-11-15T11:00:00Z"), now: now)
        XCTAssertNil(row.nextRun)
        XCTAssertFalse(row.isOverdue)
    }

    // MARK: State, progress and actions

    func testIdleRowOffersRunOnly() throws {
        let row = TaskRowPresentation(task: try task(), now: now)
        XCTAssertEqual(row.stateText, "Idle")
        XCTAssertTrue(row.canRun)
        XCTAssertFalse(row.canCancel)
        XCTAssertNil(row.progress)
    }

    func testRunningRowShowsProgressAndOffersCancelOnly() throws {
        let row = TaskRowPresentation(task: try task(state: "running", progress: 42), now: now)
        XCTAssertEqual(row.stateText, "Running, 42%")
        XCTAssertEqual(try XCTUnwrap(row.progress), 0.42, accuracy: 0.0001)
        XCTAssertFalse(row.canRun)
        XCTAssertTrue(row.canCancel)
    }

    func testStoppingRowOffersNeitherRunNorCancel() throws {
        let row = TaskRowPresentation(task: try task(state: "cancelling", progress: 60), now: now)
        XCTAssertEqual(row.stateText, "Stopping")
        XCTAssertFalse(row.canRun)
        XCTAssertFalse(row.canCancel)
    }

    func testProgressIsClampedToTheBar() throws {
        XCTAssertEqual(TaskRowPresentation(task: try task(state: "running", progress: 180), now: now).progress, 1)
        // Below zero reads as no progress yet: an indeterminate bar, not an empty determinate one.
        XCTAssertNil(TaskRowPresentation(task: try task(state: "running", progress: -5), now: now).progress)
    }

    func testRunningRowWithNoProgressYetHasAnIndeterminateBar() throws {
        let row = TaskRowPresentation(task: try task(state: "running", progress: 0), now: now)
        XCTAssertEqual(row.stateText, "Running")
        XCTAssertNil(row.progress)
        XCTAssertTrue(row.isRunning)
    }

    // MARK: Schedule in words

    func testScheduleInWords() throws {
        func words(_ triggers: String) throws -> String {
            TaskTrigger.words(for: try task(triggers: triggers).triggers, calendar: Calendar(identifier: .gregorian), locale: Locale(identifier: "en_US"))
        }
        XCTAssertEqual(try words("[]"), "Not scheduled")
        XCTAssertEqual(try words(#"[{"type":"startup"}]"#), "When the server starts")
        XCTAssertEqual(try words(#"[{"type":"interval","interval_ms":10800000}]"#), "Every 3 hours")
        XCTAssertEqual(try words(#"[{"type":"interval","interval_ms":60000}]"#), "Every minute")
        XCTAssertEqual(try words(#"[{"type":"interval","interval_ms":90000}]"#), "Every 90 seconds")
        XCTAssertEqual(try words(#"[{"type":"daily","time_of_day":"02:00"}]"#), "Every day at 02:00")
        XCTAssertEqual(try words(#"[{"type":"weekly","day_of_week":0,"time_of_day":"03:30"}]"#), "Every Sunday at 03:30")
        XCTAssertEqual(try words(#"[{"type":"weekly","day_of_week":3,"time_of_day":"03:30"}]"#), "Every Wednesday at 03:30")
        XCTAssertEqual(
            try words(#"[{"type":"daily","time_of_day":"02:00","max_runtime_ms":7200000},{"type":"startup"}]"#),
            "Every day at 02:00, stops after 2 hours; When the server starts"
        )
    }

    // MARK: Durations and ages

    func testDurationText() {
        XCTAssertEqual(AdminDuration.text(milliseconds: 0), "0 ms")
        XCTAssertEqual(AdminDuration.text(milliseconds: 999), "999 ms")
        XCTAssertEqual(AdminDuration.text(milliseconds: 5_000), "5 s")
        XCTAssertEqual(AdminDuration.text(milliseconds: 60_000), "1 min")
        XCTAssertEqual(AdminDuration.text(milliseconds: 125_000), "2 min 5 s")
        XCTAssertEqual(AdminDuration.text(milliseconds: 3_600_000), "1 h")
        XCTAssertEqual(AdminDuration.text(milliseconds: 3_900_000), "1 h 5 min")
    }
}
