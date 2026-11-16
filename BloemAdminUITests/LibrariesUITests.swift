import XCTest

/// The Libraries page, driven through the debug-only fixture server (`--ui-testing-libraries`): "Movies" (1) is
/// healthy; "Shows" (2) has a dead root and a failed scan from the past. A scan the page starts is queued for 3
/// seconds, runs for 3 more, then completes with 12 new, 3 updated, 2 missing and 1 error; a metadata refresh is
/// queued for 2 seconds, runs to 40 of 200 items and completes after 8.
final class LibrariesUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-libraries"]
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls until the element can be tapped: rows below the fold are not found by taps until then.
    @MainActor
    private func reveal(_ target: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(target) exists")
        var swipes = 0
        while !target.isHittable && swipes < 8 {
            app.swipeUp()
            swipes += 1
        }
    }

    @MainActor
    private func waitForLabel(_ target: XCUIElement, containing text: String, timeout: TimeInterval = 15) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: target)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: List

    @MainActor
    func testEachLibraryShowsItsTypePathsEnabledAndLastScan() {
        let app = launch()
        let facts = element(app, "library-facts-1")
        XCTAssertTrue(facts.waitForExistence(timeout: 10))
        XCTAssertEqual(facts.label, "Movies · 1 path · Enabled")
        XCTAssertEqual(element(app, "library-last-scanned-1").label, "Last scanned 2 h ago")
        reveal(element(app, "library-facts-2"), in: app)
        XCTAssertEqual(element(app, "library-facts-2").label, "Series · 2 paths · Enabled")
    }

    @MainActor
    func testTheScanWarningIsShownPlainlyWithTheServersMessage() {
        let app = launch()
        let warning = element(app, "library-warning")
        reveal(warning, in: app)
        XCTAssertTrue(warning.label.contains("A library folder cannot be reached"), warning.label)
        XCTAssertTrue(warning.label.contains("Root /media/shows is not reachable"), warning.label)
    }

    @MainActor
    func testRecentScansListEarlierRunsWithTheirOutcome() {
        let app = launch()
        let failed = element(app, "scan-run-seed-2")
        reveal(failed, in: app)
        XCTAssertTrue(failed.label.contains("Shows: Failed"), failed.label)
        XCTAssertTrue(failed.label.contains("root /media/shows is not reachable"), failed.label)
        let completed = element(app, "scan-run-seed-1")
        reveal(completed, in: app)
        XCTAssertTrue(completed.label.contains("Movies: Completed"), completed.label)
        XCTAssertTrue(completed.label.contains("New 4"), completed.label)
        XCTAssertTrue(completed.label.contains("Errors 0"), completed.label)
    }

    // MARK: Scan and Stop

    @MainActor
    func testScanShowsQueuedThenRunningThenCompletedWithTheCounts() {
        let app = launch()
        let scan = app.buttons["library-scan-1"]
        XCTAssertTrue(scan.waitForExistence(timeout: 10))
        scan.tap()

        let state = element(app, "library-scan-state-1")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(state, containing: "Scan: Queued", timeout: 5), "queued first: \(state.label)")
        XCTAssertTrue(waitForLabel(state, containing: "Scan: Running", timeout: 12), "then running: \(state.label)")
        XCTAssertTrue(waitForLabel(state, containing: "Last scan: Completed", timeout: 20), "then completed: \(state.label)")

        let newRun = element(app, "scan-run-run-1")
        reveal(newRun, in: app)
        XCTAssertTrue(newRun.label.contains("Movies: Completed"), newRun.label)
        for part in ["New 12", "Updated 3", "Missing 2", "Errors 1", "Manual"] {
            XCTAssertTrue(newRun.label.contains(part), "\(part) in \(newRun.label)")
        }
    }

    @MainActor
    func testStopAsksFirstNamingTheLibraryAndKeepsScanningWhenDeclined() {
        let app = launch()
        app.buttons["library-scan-1"].tap()
        let state = element(app, "library-scan-state-1")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let stop = app.buttons["library-stop-1"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        XCTAssertTrue(stop.isEnabled, "Stop is on while a scan is queued")

        stop.tap()

        XCTAssertTrue(app.staticTexts["Stop scans of Movies?"].waitForExistence(timeout: 5), "the dialog names the library")
        let keep = app.buttons["Keep scanning"]
        if keep.waitForExistence(timeout: 2) {
            keep.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        }
        XCTAssertTrue(app.staticTexts["Stop scans of Movies?"].waitForNonExistence(timeout: 5))
        // Declining stops nothing: no notice, and the row never says Stopped (the scan may well have finished meanwhile).
        XCTAssertFalse(element(app, "libraries-notice").exists)
        XCTAssertFalse(state.label.contains("Stopped"), "the scan carries on: \(state.label)")
    }

    @MainActor
    func testStopAfterConfirmingEndsTheScanAndSaysSo() {
        let app = launch()
        app.buttons["library-scan-1"].tap()
        XCTAssertTrue(element(app, "library-scan-state-1").waitForExistence(timeout: 5))
        app.buttons["library-stop-1"].tap()
        let confirm = app.buttons["Stop scans"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let notice = element(app, "libraries-notice")
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        XCTAssertEqual(notice.label, "Stopped the scan of Movies")
        XCTAssertTrue(waitForLabel(element(app, "library-scan-state-1"), containing: "Last scan: Stopped", timeout: 10))
    }

    // MARK: Check the mount

    @MainActor
    func testCheckTheMountSaysItIsReachableForAHealthyLibrary() {
        let app = launch()
        let check = app.buttons["library-check-mount-1"]
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        check.tap()
        let answer = element(app, "library-mount-answer-1")
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertEqual(answer.label, "The mount is reachable")
    }

    @MainActor
    func testCheckTheMountNamesTheRootThatCannotBeReached() {
        let app = launch()
        let check = app.buttons["library-check-mount-2"]
        reveal(check, in: app)
        check.tap()
        let answer = element(app, "library-mount-answer-2")
        XCTAssertTrue(answer.waitForExistence(timeout: 5))
        XCTAssertEqual(answer.label, "The mount cannot be reached")
        XCTAssertTrue(app.staticTexts["/media/shows: not reachable, no such file or directory"].waitForExistence(timeout: 5))
    }

    // MARK: Refresh metadata

    @MainActor
    func testRefreshMissingStartsAtOnceAndShowsItsProgress() {
        let app = launch()
        let menu = app.buttons["library-refresh-1"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Refresh missing metadata"].tap()

        let state = element(app, "library-refresh-state-1")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(state, containing: "Metadata refresh: Running", timeout: 12), state.label)
        let progress = element(app, "library-refresh-progress-1")
        XCTAssertTrue(progress.waitForExistence(timeout: 5))
        XCTAssertEqual(progress.label, "40 of 200 items")
    }

    @MainActor
    func testRefreshAllAsksFirstNamingTheLibraryThenCanBeCanceled() {
        let app = launch()
        let menu = app.buttons["library-refresh-1"]
        XCTAssertTrue(menu.waitForExistence(timeout: 10))
        menu.tap()
        app.buttons["Refresh all metadata"].tap()

        XCTAssertTrue(app.staticTexts["Refresh all metadata for Movies?"].waitForExistence(timeout: 5), "the dialog names the library")
        XCTAssertFalse(element(app, "library-refresh-state-1").exists, "nothing started before confirming")
        let confirm = app.buttons["Refresh all metadata"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        let state = element(app, "library-refresh-state-1")
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        let cancel = app.buttons["library-cancel-refresh-1"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 12))
        cancel.tap()
        let last = element(app, "library-last-refresh-1")
        XCTAssertTrue(last.waitForExistence(timeout: 12))
        XCTAssertTrue(last.label.contains("Last metadata refresh: Canceled"), last.label)
    }
}
