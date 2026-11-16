import XCTest

/// The dashboard's layout and its charts' plain-number fallback, on the DEBUG-only fixture screen
/// (`--ui-testing-dashboard-fixture`): canned server-shaped data, no network, sign-in or app lock.
final class BloemAdminDashboardUITests: XCTestCase {
    private static let sectionOrder = [
        "dashboard-section-tiles",
        "dashboard-section-health",
        "dashboard-section-now-playing",
        "dashboard-section-concurrent-streams",
        "dashboard-section-playback-activity",
        "dashboard-section-egress",
        "dashboard-section-top-titles",
        "dashboard-section-top-profiles",
        "dashboard-section-libraries",
        "dashboard-section-users",
        "dashboard-section-recent-activity",
    ]

    /// At most four stat cards, two to a row on a phone; the rest of the numbers are a compact list under them.
    private static let tileOrder = [
        "dashboard-tile-activeStreams",
        "dashboard-tile-egressNow",
        "dashboard-tile-profilesActive",
        "dashboard-tile-storage",
    ]

    private static let inventory = [
        "dashboard-tile-movies",
        "dashboard-tile-shows",
    ]

    /// The largest Dynamic Type size (Settings → Accessibility → Larger Text, all the way up).
    private static let largestTextSize = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor
    private func launch(_ argument: String = "--ui-testing-dashboard-fixture", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // English and US number formats, so the labels the tests read do not depend on the
        // simulator's region.
        app.launchArguments = [argument, "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + extra
        app.launch()
        return app
    }

    /// Runs Xcode's accessibility audit on every screenful of the page, top to bottom, and fails
    /// with each distinct issue: missing or unhelpful VoiceOver labels, targets under 44 points,
    /// text that does not follow Dynamic Type, and clipped text.
    @MainActor
    private func auditWholePage(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        var issues = Set<String>()
        let types: XCUIAccessibilityAuditType = [
            .sufficientElementDescription, .hitRegion, .dynamicType, .textClipped, .elementDetection, .trait,
        ]
        let last = element(app, Self.sectionOrder.last!)
        var lastY: CGFloat?
        for step in 0..<20 {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "audit-\(step)"
            // Kept only when the test fails, to show what the audit saw.
            add(shot)
            // A chart scrolled under the bar leaves its axis labels ("24h ago", "now", "0") showing below
            // it, while its one accessibility element (the chart as an image) sits mostly above the visible
            // area, so the audit reports that text as having no element. VoiceOver still reaches the chart;
            // only that report is skipped, and only on a screen where a chart straddles the bar.
            let barBottom = app.navigationBars.firstMatch.frame.maxY
            let chartUnderBar = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH %@", "dashboard-chart-"))
                .allElementsBoundByIndex
                .contains { $0.frame.minY < barBottom && $0.frame.maxY > barBottom }
            try app.performAccessibilityAudit(for: types) { issue in
                if chartUnderBar, issue.element == nil, issue.auditType == .elementDetection { return true }
                let target = issue.element.map { "\($0.elementType.rawValue) '\($0.identifier)' '\($0.label)' \($0.frame)" } ?? "no element (screen \(step))"
                issues.insert("\(issue.compactDescription) [\(issue.detailedDescription)] — \(target)")
                return true
            }
            // The bottom is reached once a swipe no longer moves the last section.
            let y = last.frame.minY
            if let lastY, abs(lastY - y) < 1 { break }
            lastY = y
            app.swipeUp()
            // Audit a page at rest: mid-scroll, the audit sees text where no element is yet and reports it.
            waitForScrollToSettle(last)
        }
        XCTAssertEqual(issues.sorted(), [], file: file, line: line)
    }

    /// Waits, up to about three seconds, until `element` stops moving between two reads.
    @MainActor
    private func waitForScrollToSettle(_ element: XCUIElement) {
        var previous = element.frame.minY
        for _ in 0..<10 {
            Thread.sleep(forTimeInterval: 0.3)
            let current = element.frame.minY
            if abs(current - previous) < 0.5 { return }
            previous = current
        }
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Scrolls until `target` can be tapped. The page is one scroll view.
    @MainActor
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        var swipes = 0
        while !target.isHittable && swipes < 14 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(target.isHittable, "could not scroll to \(target)")
    }

    @MainActor
    func testSectionsAppearInTheWebOrder() throws {
        let app = launch()
        XCTAssertTrue(element(app, Self.sectionOrder[0]).waitForExistence(timeout: 10))

        var previousY = -CGFloat.infinity
        for identifier in Self.sectionOrder {
            let section = element(app, identifier)
            XCTAssertTrue(section.exists, "\(identifier) is missing")
            XCTAssertGreaterThan(section.frame.minY, previousY, "\(identifier) is out of order")
            previousY = section.frame.minY
        }
    }

    @MainActor
    func testNumberTilesAreInTheWebOrder() throws {
        let app = launch()
        XCTAssertTrue(element(app, Self.tileOrder[0]).waitForExistence(timeout: 10))

        var previous = (y: -CGFloat.infinity, x: -CGFloat.infinity)
        for identifier in Self.tileOrder {
            let tile = element(app, identifier)
            XCTAssertTrue(tile.exists, "\(identifier) is missing")
            // Two to a row: reading order is top to bottom, then left to right.
            let frame = tile.frame
            XCTAssertTrue(
                frame.minY > previous.y || (frame.minY == previous.y && frame.minX > previous.x),
                "\(identifier) is out of order"
            )
            previous = (frame.minY, frame.minX)
        }
        XCTAssertEqual(element(app, "dashboard-tile-movies").label, "Movies: 400, 420 files")
    }

    @MainActor
    func testATileWithoutDataAndASectionWithoutDataAreLeftOut() throws {
        let app = launch("--ui-testing-dashboard-fixture=sparse")
        XCTAssertTrue(element(app, "dashboard-tile-activeStreams").waitForExistence(timeout: 10))

        // The newest egress sample is ten minutes old, so Egress now is hidden rather than stale.
        XCTAssertFalse(element(app, "dashboard-tile-egressNow").exists)
        XCTAssertTrue(element(app, "dashboard-tile-movies").exists)
        // No top lists and no libraries were read.
        for identifier in ["dashboard-section-top-titles", "dashboard-section-top-profiles", "dashboard-section-libraries"] {
            XCTAssertFalse(element(app, identifier).exists, "\(identifier) should be hidden")
        }
        // Everything else keeps its place.
        for identifier in ["dashboard-section-health", "dashboard-section-now-playing", "dashboard-section-egress", "dashboard-section-users"] {
            XCTAssertTrue(element(app, identifier).exists, "\(identifier) is missing")
        }
    }

    @MainActor
    func testNowPlayingAndUsersOfferTheirManageButtons() throws {
        let app = launch()
        XCTAssertTrue(element(app, "dashboard-section-now-playing").waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Manage streams"].exists)
        XCTAssertTrue(app.buttons["Manage users"].exists)
    }

    @MainActor
    func testOneRangeControlOffersTheWebsFourWindowsAndMovesAllThreeCharts() throws {
        let app = launch()
        XCTAssertTrue(element(app, "dashboard-chart-egress").waitForExistence(timeout: 10))

        let picker = app.segmentedControls["dashboard-chart-range"]
        XCTAssertTrue(picker.exists, "one range control")
        XCTAssertEqual(app.segmentedControls.matching(identifier: "dashboard-chart-range").count, 1, "not one per chart")
        XCTAssertEqual(picker.buttons.count, 4)
        XCTAssertTrue(picker.buttons.element(boundBy: 1).isSelected, "it starts on 24h")
        let week = picker.buttons.element(boundBy: 2)
        week.tap()
        XCTAssertTrue(week.isSelected)
        XCTAssertFalse(picker.buttons.element(boundBy: 1).isSelected)
    }

    @MainActor
    func testShowValuesSwapsEachChartForItsPlainNumbersAndBack() throws {
        let app = launch()
        XCTAssertTrue(element(app, "dashboard-chart-egress").waitForExistence(timeout: 10))

        for kind in ["streams", "playback", "egress"] {
            let chart = element(app, "dashboard-chart-\(kind)")
            let values = element(app, "dashboard-chart-values-\(kind)")
            let toggle = app.buttons["dashboard-chart-toggle-\(kind)"]
            XCTAssertTrue(chart.exists, "\(kind) chart")
            XCTAssertFalse(values.exists, "\(kind) values start hidden")

            scrollTo(toggle, in: app)
            XCTAssertEqual(toggle.label.hasPrefix("Show values for"), true)
            toggle.tap()
            XCTAssertTrue(values.waitForExistence(timeout: 5), "\(kind) values")
            XCTAssertFalse(chart.exists, "\(kind) chart is replaced by its numbers")
            XCTAssertTrue(toggle.label.hasPrefix("Show chart for"))

            scrollTo(toggle, in: app)
            toggle.tap()
            XCTAssertTrue(chart.waitForExistence(timeout: 5), "\(kind) chart returns")
            XCTAssertFalse(values.exists)
        }
    }

    @MainActor
    func testEachChartIsOneImageThatSaysItsWindowAndItsNumbers() throws {
        let app = launch()
        let egress = element(app, "dashboard-chart-egress")
        XCTAssertTrue(egress.waitForExistence(timeout: 10))
        XCTAssertTrue(egress.label.hasPrefix("Egress over the last 24 hours, in megabits per second. Latest "), egress.label)
        XCTAssertTrue(egress.label.contains(", peak "), egress.label)
        XCTAssertTrue(egress.label.contains(", lowest "), egress.label)

        let playback = element(app, "dashboard-chart-playback")
        XCTAssertTrue(playback.label.hasPrefix("Playback sessions per hour over the last 24 hours, by play method."), playback.label)
        XCTAssertTrue(playback.label.contains("in total."), playback.label)

        let streams = element(app, "dashboard-chart-streams")
        XCTAssertTrue(streams.label.hasPrefix("Concurrent streams over the last 24 hours. Latest "), streams.label)
    }

    // MARK: Accessibility

    @MainActor
    func testTheWholePagePassesTheAccessibilityAudit() throws {
        let app = launch()
        XCTAssertTrue(element(app, Self.sectionOrder[0]).waitForExistence(timeout: 10))
        try auditWholePage(app)
    }

    @MainActor
    func testTheWholePagePassesTheAccessibilityAuditAtTheLargestTextSize() throws {
        let app = launch(extra: Self.largestTextSize)
        XCTAssertTrue(element(app, Self.sectionOrder[0]).waitForExistence(timeout: 10))
        try auditWholePage(app)
    }

    @MainActor
    func testTilesAndHealthCellsStackInOneColumnAtTheLargestTextSize() throws {
        let app = launch(extra: Self.largestTextSize)
        let first = element(app, Self.tileOrder[0])
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        for identifier in Self.inventory { XCTAssertTrue(element(app, identifier).exists, "\(identifier) is missing") }
        var previous = first.frame
        for identifier in Self.tileOrder.dropFirst() {
            let frame = element(app, identifier).frame
            XCTAssertEqual(frame.minX, previous.minX, accuracy: 1, "\(identifier) should sit under the tile before it")
            XCTAssertGreaterThan(frame.minY, previous.minY, "\(identifier) should sit under the tile before it")
            previous = frame
        }
        let postgres = app.descendants(matching: .any)["Postgres: OK, 1.5 ms"]
        let redis = app.descendants(matching: .any)["Redis: Not configured"]
        XCTAssertTrue(postgres.exists)
        XCTAssertTrue(redis.exists)
        XCTAssertEqual(postgres.frame.minX, redis.frame.minX, accuracy: 1)
        XCTAssertGreaterThan(redis.frame.minY, postgres.frame.minY)
    }

    @MainActor
    func testVoiceOverReadsEachTileCellAndRangeButtonAsOnePhrase() throws {
        let app = launch()
        XCTAssertTrue(element(app, Self.tileOrder[0]).waitForExistence(timeout: 10))
        XCTAssertEqual(element(app, "dashboard-tile-activeStreams").label, "Active streams: 1, 1 session")
        XCTAssertEqual(element(app, "dashboard-tile-profilesActive").label, "Profiles · 24h: 5, watched on this server")
        XCTAssertTrue(app.descendants(matching: .any)["Version: 12 · v1.4"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["Errors · 24h: 0, 2 warnings"].exists)
        let picker = app.segmentedControls["dashboard-chart-range"]
        XCTAssertFalse(picker.buttons.element(boundBy: 2).isSelected)
        // Legends sit outside the chart's single image, so each series is read on its own.
        XCTAssertTrue(element(app, "dashboard-chart-legend-playback").exists)
        for entry in ["Direct play 8", "Direct stream 1", "Transcode 3", "Egress", "Downloads"] {
            XCTAssertTrue(app.descendants(matching: .any)[entry].exists, "legend entry \(entry)")
        }
    }
}
