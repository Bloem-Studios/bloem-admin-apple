import XCTest
@testable import BloemAdmin

@MainActor
private final class RecordingPresenter: AdminJobActivityPresenting {
    enum Event: Equatable {
        case start(AdminJobActivityAttributes.Kind, String)
        case update(String, AdminJobActivityAttributes.Phase, Double?)
        case end(String, AdminJobActivityAttributes.Phase)
    }

    var events: [Event] = []
    var enabled = true

    func start(_ attributes: AdminJobActivityAttributes, state: AdminJobActivityAttributes.ContentState) -> String? {
        guard enabled else { return nil }
        events.append(.start(attributes.kind, attributes.serverName))
        return "activity-\(events.count)"
    }

    func update(id: String, state: AdminJobActivityAttributes.ContentState) { events.append(.update(id, state.phase, state.progress)) }
    func end(id: String, state: AdminJobActivityAttributes.ContentState) { events.append(.end(id, state.phase)) }
}

private func scanRun(_ id: String, library: String = "l1", status: String) -> ScanRun {
    let json = #"{"id":"\#(id)","library_id":"\#(library)","status":"\#(status)","completed_at":"2026-11-15T10:00:00Z"}"#
    return try! JSONDecoder().decode(ScanRun.self, from: Data(json.utf8))
}

private func overview(active: BackupActive? = nil, lastRun: BackupRun? = nil) -> BackupsOverview {
    BackupsOverview(
        active: active, busy: active != nil, destinationAvailable: true, enabled: true, items: [], keep: 7,
        lastRun: lastRun, lastSuccessAt: nil, warnings: []
    )
}

/// The Live Activity for a scan or a backup started in the app.
@MainActor
final class AdminJobActivityTests: XCTestCase {
    private let start = WidgetSamples.now

    // MARK: Planner

    func testAScanThatTheServerListsAsActiveIsRunning() {
        let verdict = AdminJobPlanner.scan(
            libraryID: "l1", activeRuns: [scanRun("a", status: "running")], recentRuns: [], startedAt: start, sawActive: false, now: start.addingTimeInterval(5)
        )
        XCTAssertEqual(verdict.decision?.phase, .running)
        XCTAssertTrue(verdict.sawActive)
    }

    func testAScanTheListHasNotShownYetIsStillRunningForAMoment() {
        let verdict = AdminJobPlanner.scan(libraryID: "l1", activeRuns: [], recentRuns: [], startedAt: start, sawActive: false, now: start.addingTimeInterval(5))
        XCTAssertEqual(verdict.decision?.phase, .running)
        XCTAssertFalse(verdict.sawActive)
    }

    func testAScanThatWasActiveAndIsNowGoneFinishedOrFailed() {
        let done = AdminJobPlanner.scan(
            libraryID: "l1", activeRuns: [], recentRuns: [scanRun("a", status: "completed")], startedAt: start, sawActive: true, now: start.addingTimeInterval(60)
        )
        XCTAssertEqual(done.decision?.phase, .finished)
        let failed = AdminJobPlanner.scan(
            libraryID: "l1", activeRuns: [], recentRuns: [scanRun("a", status: "failed")], startedAt: start, sawActive: true, now: start.addingTimeInterval(60)
        )
        XCTAssertEqual(failed.decision?.phase, .failed)
    }

    func testAScanOfAnotherLibraryDoesNotKeepThisOneRunning() {
        let verdict = AdminJobPlanner.scan(
            libraryID: "l1", activeRuns: [scanRun("a", library: "l2", status: "running")], recentRuns: [], startedAt: start, sawActive: true, now: start.addingTimeInterval(60)
        )
        XCTAssertEqual(verdict.decision?.phase, .finished)
    }

    func testABackupReportsItsProgress() {
        let active = BackupActive(operation: "backup", progress: 42, message: nil, uploadId: nil)
        let verdict = AdminJobPlanner.backup(overview: overview(active: active), startedAt: start, sawActive: false, now: start.addingTimeInterval(5))
        XCTAssertEqual(verdict.decision, AdminJobDecision(phase: .running, progress: 0.42))
        XCTAssertTrue(verdict.sawActive)
    }

    func testABackupThatIsOverEndsFinishedOrFailed() {
        let ok = BackupRun(status: "completed", startedAt: "2026-11-15T10:00:00Z", finishedAt: "2026-11-15T10:05:00Z", error: nil)
        XCTAssertEqual(AdminJobPlanner.backup(overview: overview(lastRun: ok), startedAt: start, sawActive: true, now: start.addingTimeInterval(400)).decision.phase, .finished)
        let bad = BackupRun(status: "failed", startedAt: "2026-11-15T10:00:00Z", finishedAt: "2026-11-15T10:05:00Z", error: "disk full")
        XCTAssertEqual(AdminJobPlanner.backup(overview: overview(lastRun: bad), startedAt: start, sawActive: true, now: start.addingTimeInterval(400)).decision.phase, .failed)
    }

    func testAnotherOperationOnTheBackupLockIsNotThisBackup() {
        let restore = BackupActive(operation: "restore", progress: 10, message: nil, uploadId: nil)
        let verdict = AdminJobPlanner.backup(overview: overview(active: restore), startedAt: start, sawActive: true, now: start.addingTimeInterval(60))
        XCTAssertNotEqual(verdict.decision.phase, .running)
    }

    // MARK: Tracker

    private func tracker(_ presenter: RecordingPresenter, now: @escaping () -> Date) -> AdminJobActivityTracker {
        AdminJobActivityTracker(presenter: presenter, serverName: { _ in "Home" }, now: now)
    }

    func testAScanStartedInTheAppStartsAnActivityAndEndsItWhenTheServerIsDone() {
        let presenter = RecordingPresenter()
        var clock = start
        let tracker = tracker(presenter, now: { clock })
        tracker.scanStarted(serverID: "home", libraryID: "l1", libraryName: "Films")
        XCTAssertEqual(presenter.events, [.start(.libraryScan, "Home")])
        clock = start.addingTimeInterval(5)
        tracker.librariesRead(serverID: "home", activeRuns: [scanRun("a", status: "running")], recentRuns: [])
        XCTAssertEqual(presenter.events.last, .update("activity-1", .running, nil))
        clock = start.addingTimeInterval(40)
        tracker.librariesRead(serverID: "home", activeRuns: [], recentRuns: [scanRun("a", status: "completed")])
        XCTAssertEqual(presenter.events.last, .end("activity-1", .finished))
        XCTAssertEqual(tracker.followedCount, 0)
    }

    func testABackupStartedInTheAppFollowsItsProgressToTheEnd() {
        let presenter = RecordingPresenter()
        var clock = start
        let tracker = tracker(presenter, now: { clock })
        tracker.backupStarted(serverID: "home")
        clock = start.addingTimeInterval(10)
        tracker.backupRead(serverID: "home", overview: overview(active: BackupActive(operation: "backup", progress: 50, message: nil, uploadId: nil)))
        XCTAssertEqual(presenter.events.last, .update("activity-1", .running, 0.5))
        clock = start.addingTimeInterval(120)
        tracker.backupRead(serverID: "home", overview: overview(lastRun: BackupRun(status: "completed", startedAt: "x", finishedAt: "y", error: nil)))
        XCTAssertEqual(presenter.events.last, .end("activity-1", .finished))
    }

    func testActivitiesTheSystemRefusesAreNotFollowedIntoUpdates() {
        let presenter = RecordingPresenter()
        presenter.enabled = false
        let tracker = tracker(presenter, now: { self.start })
        tracker.backupStarted(serverID: "home")
        tracker.backupRead(serverID: "home", overview: overview(active: BackupActive(operation: "backup", progress: 50, message: nil, uploadId: nil)))
        XCTAssertTrue(presenter.events.isEmpty)
    }

    func testReadsOfAServerTheAppDidNotStartAJobOnDoNothing() {
        let presenter = RecordingPresenter()
        let tracker = tracker(presenter, now: { self.start })
        tracker.librariesRead(serverID: "home", activeRuns: [scanRun("a", status: "running")], recentRuns: [])
        tracker.backupRead(serverID: "home", overview: overview(active: BackupActive(operation: "backup", progress: 10, message: nil, uploadId: nil)))
        XCTAssertTrue(presenter.events.isEmpty, "only jobs started from the app get an activity")
        tracker.scanStarted(serverID: nil, libraryID: "l1", libraryName: "Films")
        XCTAssertTrue(presenter.events.isEmpty)
    }

    func testAJobThatNeverReportsIsLetGoAfterTheLongestFollow() {
        let presenter = RecordingPresenter()
        var clock = start
        let tracker = tracker(presenter, now: { clock })
        tracker.backupStarted(serverID: "home")
        clock = start.addingTimeInterval(AdminJobPlanner.longestFollow + 1)
        tracker.endStale()
        XCTAssertEqual(tracker.followedCount, 0)
        XCTAssertEqual(presenter.events.last, .end("activity-1", .finished))
    }

    // MARK: What the activity says

    func testTheActivitysWordsAndPercent() {
        let running = AdminJobActivityAttributes.ContentState(phase: .running, progress: 0.426, libraryName: nil)
        XCTAssertEqual(running.title(kind: .libraryScan), "Scanning")
        XCTAssertEqual(running.title(kind: .backup), "Backing up")
        XCTAssertEqual(running.percentText, "43%")
        XCTAssertNil(AdminJobActivityAttributes.ContentState(phase: .running, progress: nil, libraryName: nil).percentText)
        XCTAssertEqual(AdminJobActivityAttributes.ContentState(phase: .finished, progress: nil, libraryName: nil).title(kind: .backup), "Backup finished")
        XCTAssertEqual(AdminJobActivityAttributes.ContentState(phase: .failed, progress: nil, libraryName: nil).title(kind: .libraryScan), "Scan failed")
    }
}
