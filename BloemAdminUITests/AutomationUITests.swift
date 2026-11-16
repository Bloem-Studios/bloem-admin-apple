import XCTest

/// The Scheduled tasks, Nodes, Backups and Plugins pages, driven through the debug-only fixture server
/// (`--ui-testing-automation=tasks|nodes|backups|plugins`). Task "scan" is idle with a daily 02:00 run,
/// "cleanup" is running at 42% after a failed run, "nightly" is overdue; nodes n1 and n2 are healthy
/// transcode nodes; backups b2 and b1 are saved; plugin "subs" has failed and "tmdb" has an update.
final class AutomationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func launch(_ page: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-automation=\(page)"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// A button of the confirmation dialog that is up: the last one with that title, since a page button
    /// of the same name can sit behind it.
    @MainActor
    private func dialogButton(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let matches = app.buttons.matching(identifier: title)
        _ = matches.firstMatch.waitForExistence(timeout: 5)
        return matches.element(boundBy: max(0, matches.count - 1))
    }

    /// Dismisses a confirmation dialog without confirming: its cancel button where the system shows one,
    /// otherwise a tap outside it (an iPad popover has no cancel button).
    @MainActor
    private func dismissDialog(cancelLabel: String, titled title: String, in app: XCUIApplication) {
        let cancel = app.buttons[cancelLabel]
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        }
        XCTAssertTrue(app.staticTexts[title].waitForNonExistence(timeout: 5), "\(title) closed")
    }

    @MainActor
    private func text(_ part: String, in app: XCUIApplication) -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", part)).firstMatch.waitForExistence(timeout: 5)
    }

    /// Swipes until `target` is clear of the bottom of the screen. On an iPhone the search field floats over the
    /// bottom of the list: a control under it still counts as hittable, but the field takes the tap.
    @MainActor
    private func bringAboveSearchBar(_ target: XCUIElement, in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        for _ in 0..<6 where !(target.exists && target.isHittable && target.frame.maxY < screen.maxY - 120) {
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, "\(target) is on screen")
    }

    /// Scrolls the page up until `target` exists (a List does not build rows below the fold).
    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication, attempts: Int = 8) {
        var tries = 0
        // Hittable, not only present: a list builds the row just below the fold before it is on screen.
        while !(target.exists && target.isHittable) && tries < attempts {
            app.swipeUp()
            tries += 1
        }
        XCTAssertTrue(target.waitForExistence(timeout: 3), "\(target) is on the page")
    }

    // MARK: Scheduled tasks

    @MainActor
    func testTaskRowsSayTheLastResultNextRunOverdueAndProgress() {
        let app = launch("tasks")
        let scan = element("task-row-scan", in: app)
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        XCTAssertTrue(scan.label.contains("Idle"), scan.label)
        XCTAssertTrue(scan.label.contains("Completed 2 h ago, took 2 min 5 s"), scan.label)
        XCTAssertTrue(scan.label.contains("Next run in 12 h"), scan.label)

        let cleanup = element("task-row-cleanup", in: app)
        XCTAssertTrue(cleanup.label.contains("Running, 42%"), cleanup.label)
        XCTAssertTrue(cleanup.label.contains("Failed"), "the failed last run is said in words: \(cleanup.label)")

        let nightly = element("task-row-nightly", in: app)
        XCTAssertTrue(nightly.label.contains("Overdue"), nightly.label)
    }

    @MainActor
    func testRunIsOfferedOnlyWhileIdleAndCancelAsksFirst() {
        let app = launch("tasks")
        element("task-row-cleanup", in: app).tap()
        let run = app.buttons["task-run"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        XCTAssertFalse(run.isEnabled, "a running task cannot be started again")

        app.buttons["task-cancel"].tap()
        let title = "Cancel Clean up images? The run may have already changed server data"
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5))
        dismissDialog(cancelLabel: "Keep running", titled: title, in: app)
        XCTAssertTrue(app.buttons["task-cancel"].waitForExistence(timeout: 3), "still running after Keep running")

        app.buttons["task-cancel"].tap()
        dialogButton("Cancel run", in: app).tap()
        XCTAssertTrue(app.buttons["task-run"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("State, Idle", in: app), "the task shows as idle after it was cancelled")
    }

    @MainActor
    func testRunStartsAnIdleTask() {
        let app = launch("tasks")
        element("task-row-scan", in: app).tap()
        let run = app.buttons["task-run"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        XCTAssertTrue(run.isEnabled)
        run.tap()
        XCTAssertTrue(app.buttons["task-cancel"].waitForExistence(timeout: 10), "the task is running")
    }

    @MainActor
    func testTaskPageShowsTheScheduleInWordsAndRecentRunsWithLoadMore() {
        let app = launch("tasks")
        element("task-row-scan", in: app).tap()
        let schedule = element("task-schedule-words", in: app)
        XCTAssertTrue(schedule.waitForExistence(timeout: 10))
        XCTAssertTrue(schedule.label.contains("Every day at 02:00"), schedule.label)

        let more = element("task-history-load-more", in: app)
        reveal(more, in: app)
        XCTAssertTrue(app.staticTexts["Failed steps: Probe files"].exists, "failed steps are listed")
        XCTAssertTrue(app.staticTexts["Disk full"].exists, "the error is shown")
        more.tap()
        XCTAssertTrue(more.waitForNonExistence(timeout: 10), "there is nothing more after the second page")
    }

    @MainActor
    func testScheduleEditorOffersDailyAndWeeklyTimes() {
        let app = launch("tasks")
        element("task-row-scan", in: app).tap()
        let edit = element("task-edit-schedule", in: app)
        reveal(edit, in: app)
        edit.tap()
        XCTAssertTrue(element("schedule-timed-row", in: app).waitForExistence(timeout: 10), "the daily 02:00 time is a row")
        let addWeekly = element("schedule-add-weekly", in: app)
        reveal(addWeekly, in: app)
        addWeekly.tap()
        XCTAssertTrue(app.buttons["Save changes"].isEnabled, "a new weekly time can be saved")
        app.buttons["Cancel"].tap()
    }

    @MainActor
    func testJobHistoryListsJobsAndLoadsMore() {
        let app = launch("tasks")
        let link = element("job-history-link", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        link.tap()
        XCTAssertTrue(app.staticTexts["Library refresh"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["40 of 100 items"].exists, "a running job shows its progress in words")
        let more = element("job-history-load-more", in: app)
        reveal(more, in: app)
        more.tap()
        XCTAssertTrue(app.staticTexts["Backup restore"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Restore failed: Not enough space"].exists)
    }

    // MARK: Nodes

    @MainActor
    func testNodeRowsSayStateLoadAndCapacity() {
        let app = launch("nodes")
        let node = element("node-n1", in: app)
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        for part in ["Healthy", "Transcode node", "37%", "1 of 4 transcodes"] {
            XCTAssertTrue(text(part, in: app), "\(part) is on the node")
        }
    }

    @MainActor
    func testDrainAsksFirstThenTheNodeShowsDrainingAndOffersResume() {
        let app = launch("nodes")
        let drain = app.buttons["node-drain-n1"]
        XCTAssertTrue(drain.waitForExistence(timeout: 10))
        drain.tap()
        XCTAssertTrue(app.staticTexts["Drain node-n1?"].waitForExistence(timeout: 5))
        dismissDialog(cancelLabel: "Keep as is", titled: "Drain node-n1?", in: app)
        XCTAssertTrue(app.buttons["node-drain-n1"].exists, "nothing changed")

        app.buttons["node-drain-n1"].tap()
        dialogButton("Drain", in: app).tap()
        XCTAssertTrue(app.buttons["node-resume-n1"].waitForExistence(timeout: 10), "Resume is offered once the node drains")
        XCTAssertTrue(text("Draining", in: app), "the node says it is draining")
    }

    @MainActor
    func testDisableAsksFirstAndTheNodeShowsDisabled() {
        let app = launch("nodes")
        let toggle = app.buttons["node-enable-n2"]
        reveal(toggle, in: app)
        toggle.tap()
        XCTAssertTrue(app.staticTexts["Disable node-n2?"].waitForExistence(timeout: 5))
        dialogButton("Disable", in: app).tap()
        XCTAssertTrue(app.buttons["Enable"].waitForExistence(timeout: 10), "the node can be enabled again")
    }

    // MARK: Backups

    @MainActor
    func testBackupsShowLastSuccessAndSavedBackupsAndSayRestoreIsOnTheWeb() {
        let app = launch("backups")
        let status = element("backups-status", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("Last successful backup 5 h ago"), status.label)
        XCTAssertTrue(status.label.contains("Next backup in 16 h"), status.label)
        reveal(app.staticTexts["To restore a backup, use the web admin"], in: app)
    }

    @MainActor
    func testBackUpNowShowsTheProgressOfTheRunningBackup() {
        let app = launch("backups")
        let backUp = app.buttons["backup-now"]
        XCTAssertTrue(backUp.waitForExistence(timeout: 10))
        backUp.tap()
        XCTAssertTrue(app.staticTexts["Backup running, 42%"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["backup-now"].isEnabled, "no second backup while one runs")
        XCTAssertTrue(app.staticTexts["A backup is already running"].exists)
    }

    @MainActor
    func testDeleteAsksFirstThenRemovesTheBackup() {
        let app = launch("backups")
        let delete = app.buttons["backup-delete-b1"]
        reveal(delete, in: app)
        delete.tap()
        XCTAssertTrue(app.staticTexts["Delete this backup?"].waitForExistence(timeout: 5))
        dismissDialog(cancelLabel: "Keep backup", titled: "Delete this backup?", in: app)
        XCTAssertTrue(app.buttons["backup-delete-b1"].exists)

        app.buttons["backup-delete-b1"].tap()
        dialogButton("Delete backup", in: app).tap()
        XCTAssertTrue(app.buttons["backup-delete-b1"].waitForNonExistence(timeout: 10))
    }

    @MainActor
    func testBackupScheduleEditorSavesAChangedNumberOfCopies() {
        let app = launch("backups")
        let edit = app.buttons["backup-edit-schedule"]
        reveal(edit, in: app)
        edit.tap()
        let save = app.buttons["Save changes"]
        XCTAssertTrue(save.waitForExistence(timeout: 10))
        XCTAssertFalse(save.isEnabled, "nothing changed yet")
        app.steppers.firstMatch.buttons["Increment"].tap()
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(text("Copies kept, 8", in: app), "the page shows the saved number of copies")
    }

    // MARK: Plugins

    @MainActor
    func testNeedsAttentionFilterListsTheFailedPlugin() {
        let app = launch("plugins")
        XCTAssertTrue(element("plugin-subs", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("plugin-tmdb", in: app).exists)
        let filter = element("plugins-filter", in: app)
        filter.tap()
        app.buttons["Needs attention (1)"].tap()
        XCTAssertTrue(element("plugin-subs", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("plugin-tmdb", in: app).exists, "healthy plugins are filtered out")
        XCTAssertTrue(text("Failed", in: app))
        XCTAssertTrue(text("exit status 2", in: app))
    }

    @MainActor
    func testRestartAsksFirstThenTheFailedPluginRuns() {
        let app = launch("plugins")
        let restart = app.buttons["plugin-restart-subs"]
        XCTAssertTrue(restart.waitForExistence(timeout: 10))
        restart.tap()
        XCTAssertTrue(app.staticTexts["Restart Subtitles?"].waitForExistence(timeout: 5))
        dialogButton("Restart", in: app).tap()
        XCTAssertTrue(app.staticTexts["Running"].waitForExistence(timeout: 10) || text("Running", in: app))
    }

    @MainActor
    func testUpdateAsksFirstAndShowsTheNewVersion() {
        let app = launch("plugins")
        let update = app.buttons["plugin-update-tmdb"]
        reveal(update, in: app)
        bringAboveSearchBar(update, in: app)
        update.tap()
        XCTAssertTrue(app.staticTexts["Update Movie database to 1.1.0?"].waitForExistence(timeout: 5))
        dialogButton("Update", in: app).tap()
        XCTAssertTrue(app.buttons["plugin-update-tmdb"].waitForNonExistence(timeout: 10), "no update is offered once it is applied")
    }
}
