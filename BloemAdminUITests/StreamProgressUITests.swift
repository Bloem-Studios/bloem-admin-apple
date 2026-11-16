import XCTest

/// The progress readout a stream row embeds, on the app's progress fixture page
/// (`--ui-testing-stream-rows --ui-testing-stream-progress`). The page's clock moves only when a test taps
/// **Advance clock 3 s**, so every number here is exact. One stream starts playing at 0:10 of 1:40.
final class StreamProgressUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-stream-rows", "--ui-testing-stream-progress", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func progress(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "stream-progress.tick").firstMatch
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, toStartWith prefix: String, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label BEGINSWITH %@", prefix)
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "expected \"\(prefix)…\", found \"\(element.label)\"", file: file, line: line)
    }

    @MainActor
    func testAPlayingStreamMovesForwardAsTheClockRuns() throws {
        let app = launch()
        let readout = progress(in: app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10))
        XCTAssertEqual(readout.label, "0:10 of 1:40, 1m left")

        app.buttons["Advance clock 3 s"].tap()
        waitForLabel(readout, toStartWith: "0:13 of 1:40")

        app.buttons["Advance clock 3 s"].tap()
        waitForLabel(readout, toStartWith: "0:16 of 1:40")
    }

    @MainActor
    func testANewReportReplacesTheProjectionInsteadOfAddingToIt() throws {
        let app = launch()
        let readout = progress(in: app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10))
        app.buttons["Advance clock 3 s"].tap()
        waitForLabel(readout, toStartWith: "0:13 of 1:40")

        app.buttons["Report 0:20"].tap()
        waitForLabel(readout, toStartWith: "0:20 of 1:40")

        app.buttons["Advance clock 3 s"].tap()
        waitForLabel(readout, toStartWith: "0:23 of 1:40")
    }

    @MainActor
    func testAPausedStreamHoldsItsPosition() throws {
        let app = launch()
        let readout = progress(in: app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10))

        app.buttons["Report paused at 0:30"].tap()
        waitForLabel(readout, toStartWith: "0:30 of 1:40")

        app.buttons["Advance clock 3 s"].tap()
        app.buttons["Advance clock 3 s"].tap()
        // Inverted: the wait completes only if the readout never leaves 0:30.
        let moved = expectation(for: NSPredicate(format: "NOT (label BEGINSWITH %@)", "0:30 of 1:40"), evaluatedWith: readout)
        moved.isInverted = true
        XCTAssertEqual(XCTWaiter().wait(for: [moved], timeout: 2), .completed, "a paused stream moved: \(readout.label)")
    }

    @MainActor
    func testTheCountPicksUpAgainWhenTheAppReturnsToTheFront() throws {
        let app = launch()
        let readout = progress(in: app)
        XCTAssertTrue(readout.waitForExistence(timeout: 10))

        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(readout.waitForExistence(timeout: 10))

        app.buttons["Advance clock 3 s"].tap()
        waitForLabel(readout, toStartWith: "0:13 of 1:40")
    }
}
