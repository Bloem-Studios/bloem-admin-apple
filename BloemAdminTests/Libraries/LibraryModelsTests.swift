import XCTest
@testable import BloemAdmin

/// What the Libraries page reads from the server, checked against the shapes in the server's source
/// (`internal/apiv2/libraries.go`, `admin_autoscan_scans.go`, `admin_task_jobs.go`).
final class LibraryModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.iso8601.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Library

    func testLibraryReadsNameTypePathsEnabledAndLastScanned() throws {
        let library = try decode(AdminLibrary.self, """
        {"id":"3","name":"Movies","type":"movies","paths":["/media/movies","/media/more"],"enabled":true,
         "last_scanned_at":"2026-11-14T10:00:00.250Z"}
        """)
        XCTAssertEqual(library.id, "3")
        XCTAssertEqual(library.name, "Movies")
        XCTAssertEqual(library.type, "movies")
        XCTAssertEqual(library.pathCount, 2)
        XCTAssertTrue(library.enabled)
        XCTAssertNotNil(library.lastScannedAt)
        XCTAssertNil(library.scanWarning)
    }

    func testLibraryWithoutAScanOrWarningHasNeither() throws {
        let library = try decode(AdminLibrary.self, #"{"id":"4","name":"Shows","type":"series","paths":[],"enabled":false}"#)
        XCTAssertNil(library.lastScannedAt)
        XCTAssertNil(library.scanWarning)
        XCTAssertFalse(library.enabled)
        XCTAssertEqual(library.pathCount, 0)
    }

    func testLibraryReadsTheScanWarning() throws {
        let library = try decode(AdminLibrary.self, """
        {"id":"5","name":"Music","type":"mixed","paths":["/nas/music"],"enabled":true,
         "scan_warning_code":"dead_root","scan_warning_message":"Root /nas/music is not reachable",
         "scan_warning_at":"2026-11-14T09:00:00.000Z"}
        """)
        let warning = try XCTUnwrap(library.scanWarning)
        XCTAssertEqual(warning.code, "dead_root")
        XCTAssertEqual(warning.message, "Root /nas/music is not reachable")
        XCTAssertNotNil(warning.raisedAt)
    }

    func testAWarningWithOnlyACodeStillShows() throws {
        let library = try decode(AdminLibrary.self, #"{"id":"6","name":"A","type":"movies","paths":["/a"],"enabled":true,"scan_warning_code":"empty_root"}"#)
        XCTAssertEqual(library.scanWarning?.code, "empty_root")
        XCTAssertNil(library.scanWarning?.message)
    }

    func testAMalformedLastScannedTimeDoesNotLoseTheLibrary() throws {
        let library = try decode(AdminLibrary.self, #"{"id":"7","name":"A","type":"movies","paths":[],"enabled":true,"last_scanned_at":"yesterday"}"#)
        XCTAssertEqual(library.name, "A")
        XCTAssertNil(library.lastScannedAt)
    }

    func testWarningHeadlinesSayWhatHappenedInPlainWords() {
        XCTAssertEqual(LibraryScanWarning(code: "empty_root", message: nil, raisedAt: nil).headline, "The scan found no media files")
        XCTAssertEqual(LibraryScanWarning(code: "dead_root", message: nil, raisedAt: nil).headline, "A library folder cannot be reached")
        XCTAssertEqual(LibraryScanWarning(code: "partial_scan", message: nil, raisedAt: nil).headline, "Partial scan")
    }

    // MARK: Scan runs

    func testScanRunReadsStatusCountsAndTimes() throws {
        let run = try decode(ScanRun.self, """
        {"id":"run-1","library_id":"3","mode":"library","trigger":"manual","status":"completed",
         "requested_at":"2026-11-14T10:00:00.000Z","started_at":"2026-11-14T10:00:02.000Z","completed_at":"2026-11-14T10:01:32.500Z",
         "result":{"new":12,"updated":3,"unchanged":900,"missing":2,"missing_skipped_protected":0,"files_deleted":0,
                   "items_deleted":0,"memberships_removed":0,"errors":1,"skipped":0}}
        """)
        XCTAssertEqual(run.id, "run-1")
        XCTAssertEqual(run.libraryID, "3")
        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.result?.new, 12)
        XCTAssertEqual(run.result?.updated, 3)
        XCTAssertEqual(run.result?.missing, 2)
        XCTAssertEqual(run.result?.errors, 1)
        let duration = try XCTUnwrap(run.duration)
        XCTAssertEqual(duration, 90.5, accuracy: 0.001)
    }

    func testScanRunWithoutResultOrTimesHasNoDuration() throws {
        let run = try decode(ScanRun.self, #"{"id":"r","library_id":"1","mode":"library","trigger":"manual","status":"accepted"}"#)
        XCTAssertEqual(run.status, .queued)
        XCTAssertNil(run.result)
        XCTAssertNil(run.duration)
    }

    func testScanStatusesMapToTheWordsOnThePage() {
        XCTAssertEqual(ScanRunStatus(serverValue: "accepted"), .queued)
        XCTAssertEqual(ScanRunStatus(serverValue: "running"), .running)
        XCTAssertEqual(ScanRunStatus(serverValue: "completed"), .completed)
        XCTAssertEqual(ScanRunStatus(serverValue: "failed"), .failed)
        XCTAssertEqual(ScanRunStatus(serverValue: "cancelled"), .stopped)
        XCTAssertEqual(ScanRunStatus(serverValue: "paused_for_review"), .other("paused_for_review"))
        XCTAssertEqual(ScanRunStatus.queued.label, "Queued")
        XCTAssertEqual(ScanRunStatus.running.label, "Running")
        XCTAssertEqual(ScanRunStatus.completed.label, "Completed")
        XCTAssertEqual(ScanRunStatus.failed.label, "Failed")
        XCTAssertEqual(ScanRunStatus.stopped.label, "Stopped")
        XCTAssertEqual(ScanRunStatus.other("paused_for_review").label, "Paused for review")
        XCTAssertTrue(ScanRunStatus.queued.isActive)
        XCTAssertTrue(ScanRunStatus.running.isActive)
        XCTAssertFalse(ScanRunStatus.completed.isActive)
    }

    func testTriggerLabelsFollowTheWeb() {
        func label(_ trigger: String) throws -> String {
            try JSONDecoder.iso8601.decode(ScanRun.self, from: Data(#"{"id":"r","library_id":"1","mode":"library","trigger":"\#(trigger)","status":"completed"}"#.utf8)).triggerLabel
        }
        XCTAssertEqual(try label("manual"), "Manual")
        XCTAssertEqual(try label("library_id"), "Manual")
        XCTAssertEqual(try label("autoscan"), "Autoscan")
        XCTAssertEqual(try label("task:scan_libraries"), "Scheduled")
        XCTAssertEqual(try label("realtime_monitor"), "File change")
        XCTAssertEqual(try label("library_created"), "Created")
        XCTAssertEqual(try label("admin_library_refresh"), "Admin library refresh")
    }

    // MARK: Mount check

    func testMountCheckHealthyIsReachable() throws {
        let check = try decode(MountCheck.self, """
        {"status":"healthy","library_id":"3","library_name":"Movies","healthy":true,"checked_at":"2026-11-14T10:00:00.000Z",
         "summary":"All configured roots are reachable",
         "roots":[{"path":"/media/movies","reachable":true,"error_code":null,"error_message":null,"suspect_empty":false}]}
        """)
        XCTAssertEqual(check.verdict, .reachable)
        XCTAssertEqual(check.verdict.headline, "The mount is reachable")
        XCTAssertEqual(check.roots.count, 1)
    }

    func testMountCheckWithAnUnreachableRootNamesItAndWhy() throws {
        let check = try decode(MountCheck.self, """
        {"status":"unhealthy","library_id":"3","library_name":"Movies","healthy":false,"checked_at":"2026-11-14T10:00:00.000Z",
         "summary":"1 of 2 roots unreachable",
         "roots":[{"path":"/media/a","reachable":true,"error_code":null,"error_message":null,"suspect_empty":false},
                  {"path":"/media/b","reachable":false,"error_code":"not_found","error_message":"no such file or directory","suspect_empty":false}]}
        """)
        XCTAssertEqual(check.verdict, .unreachable)
        XCTAssertEqual(check.verdict.headline, "The mount cannot be reached")
        XCTAssertEqual(check.roots[1].errorMessage, "no such file or directory")
        XCTAssertEqual(check.problemRoots.map(\.path), ["/media/b"])
    }

    func testMountCheckReachableButEmptyIsNotCalledHealthy() throws {
        let check = try decode(MountCheck.self, """
        {"status":"unhealthy","library_id":"3","library_name":"Movies","healthy":false,"checked_at":"2026-11-14T10:00:00.000Z",
         "summary":"1 of 1 roots reachable but empty while the library still has cataloged files (lost mount?)",
         "roots":[{"path":"/media/a","reachable":true,"error_code":null,"error_message":null,"suspect_empty":true}]}
        """)
        XCTAssertEqual(check.verdict, .looksEmpty)
        XCTAssertEqual(check.verdict.headline, "The mount is reachable but looks empty")
        XCTAssertEqual(check.problemRoots.map(\.path), ["/media/a"])
    }

    // MARK: Refresh jobs

    func testRefreshJobReadsStateProgressAndLibrary() throws {
        let job = try decode(LibraryRefreshJob.self, """
        {"id":"job-9","kind":"library_refresh","state":"running","terminal":false,"cancelable":true,
         "created_at":"2026-11-14T10:00:00.000Z","started_at":"2026-11-14T10:00:05.000Z",
         "progress":{"current":40,"total":200,"unit":"items"},"library_id":"3","library_name":"Movies","library_ids":[]}
        """)
        XCTAssertEqual(job.id, "job-9")
        XCTAssertEqual(job.libraryID, "3")
        XCTAssertEqual(job.libraryName, "Movies")
        XCTAssertEqual(job.state, .running)
        XCTAssertTrue(job.isActive)
        XCTAssertTrue(job.cancelable)
        XCTAssertEqual(job.progressText, "40 of 200 items")
    }

    func testRefreshJobStatesUseTheServersWords() {
        XCTAssertEqual(RefreshJobState(serverValue: "queued"), .queued)
        XCTAssertEqual(RefreshJobState(serverValue: "running"), .running)
        XCTAssertEqual(RefreshJobState(serverValue: "canceling"), .canceling)
        XCTAssertEqual(RefreshJobState(serverValue: "succeeded"), .completed)
        XCTAssertEqual(RefreshJobState(serverValue: "failed"), .failed)
        XCTAssertEqual(RefreshJobState(serverValue: "canceled"), .canceled)
        XCTAssertEqual(RefreshJobState.canceling.label, "Canceling")
        XCTAssertEqual(RefreshJobState.completed.label, "Completed")
        XCTAssertEqual(RefreshJobState.canceled.label, "Canceled")
    }

    func testFinishedRefreshJobSaysHowManyItemsWereRefreshed() throws {
        let job = try decode(LibraryRefreshJob.self, """
        {"id":"job-9","kind":"library_refresh","state":"succeeded","terminal":true,"cancelable":false,
         "created_at":"2026-11-14T10:00:00.000Z","finished_at":"2026-11-14T10:10:00.000Z",
         "refresh_result":{"library_id":"3","refreshed":197,"failed":3},"library_id":"3","library_name":"Movies"}
        """)
        XCTAssertFalse(job.isActive)
        XCTAssertEqual(job.resultText, "197 refreshed, 3 failed")
    }

    func testAJobWithoutALibraryIdIsStillReadable() throws {
        let job = try decode(LibraryRefreshJob.self, #"{"id":"j","kind":"library_refresh","state":"queued","terminal":false,"cancelable":true,"created_at":"2026-11-14T10:00:00.000Z"}"#)
        XCTAssertNil(job.libraryID)
        XCTAssertNil(job.progressText)
        XCTAssertNil(job.resultText)
    }

    // MARK: A failed scan and an unreachable root say it once

    func testAScanDetailThatOnlyRepeatsTheWarningIsNotShownAgain() {
        let warning = "Root /media/shows is not reachable"
        XCTAssertTrue(ScanDetail.repeats("root /media/shows is not reachable", of: warning), "the same sentence in another case")
        XCTAssertTrue(ScanDetail.repeats("  Root /media/shows is not reachable  ", of: warning), "whitespace does not make it new")
        XCTAssertTrue(ScanDetail.repeats("/media/shows is not reachable", of: warning), "a part of it")
    }

    func testAScanDetailWithSomethingNewIsKept() {
        XCTAssertFalse(ScanDetail.repeats("Permission denied", of: "Root /media/shows is not reachable"))
        XCTAssertFalse(ScanDetail.repeats("root /media/shows is not reachable", of: nil), "no warning: nothing to repeat")
        XCTAssertFalse(ScanDetail.repeats("root /media/shows is not reachable", of: ""))
        XCTAssertFalse(ScanDetail.repeats("", of: "Root /media/shows is not reachable"))
    }
}
