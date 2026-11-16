import XCTest

/// Playback history, Logs and Audit, driven through the debug-only fixture server
/// (`--ui-testing-incident-pages`): bob has two profiles (Living room, Kids) and three plays between
/// them; alice has one. The log has an FFmpeg error and a playback line for bob's partial play of
/// "Night Shift" S02E04 (playback session ps_night_shift_0004), plus an unrelated scanner warning.
final class IncidentPagesUITests: XCTestCase {
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-incident-pages"]
        app.launch()
        return app
    }

    /// Any element whose label or value contains `text`; sheets combine a field's label and value.
    private func element(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch
    }

    private func id(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func openPage(_ name: String, in app: XCUIApplication) {
        let button = app.buttons["fixture-page-\(name)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "\(name) switch exists")
        button.tap()
    }

    private func choose(_ name: String, from picker: String, in app: XCUIApplication) {
        let control = id(picker, in: app)
        XCTAssertTrue(control.waitForExistence(timeout: 10), "\(picker) exists")
        control.tap()
        let option = app.buttons[name].exists ? app.buttons[name] : app.staticTexts[name]
        XCTAssertTrue(option.waitForExistence(timeout: 5), "\(name) is offered")
        option.tap()
    }

    // MARK: Playback history

    func testHistoryRowShowsWhenWatchTimeProfileMethodAndEpisodeCode() {
        let app = launch()
        let row = id("history-row-ps_night_shift_0004", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the play is listed")
        for part in ["Night Shift", "S02E04", "The Handover", "bob", "Living room", "25m 00s of 45m 00s", "Transcode", "Partial"] {
            XCTAssertTrue(row.label.contains(part), "the row says \(part): \(row.label)")
        }
        XCTAssertTrue(row.label.contains("Nov") || row.label.contains("14"), "the row shows the day: \(row.label)")
    }

    func testFilterByPersonThenPartialPlays() {
        let app = launch()
        XCTAssertTrue(id("history-row-ps_alien_00000002", in: app).waitForExistence(timeout: 10))
        choose("bob", from: "history-person", in: app)
        XCTAssertTrue(id("history-row-ps_heat_000000001", in: app).waitForExistence(timeout: 10), "bob's plays stay")
        XCTAssertTrue(id("history-row-ps_alien_00000002", in: app).waitForNonExistence(timeout: 10), "alice's play goes")
        let partial = app.buttons["Partial"]
        XCTAssertTrue(partial.waitForExistence(timeout: 5))
        partial.tap()
        XCTAssertTrue(id("history-row-ps_heat_000000001", in: app).waitForNonExistence(timeout: 10), "a completed play goes")
        XCTAssertTrue(id("history-row-ps_night_shift_0004", in: app).exists)
    }

    func testFilterByProfile() {
        let app = launch()
        choose("bob", from: "history-person", in: app)
        choose("Kids", from: "history-profile", in: app)
        XCTAssertTrue(id("history-row-ps_heat_000000001", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(id("history-row-ps_night_shift_0004", in: app).waitForNonExistence(timeout: 10), "the Living room play goes")
    }

    func testTapOpensDetailsAndFFmpegLogsOpenForThatPlaybackSession() {
        let app = launch()
        let row = id("history-row-ps_night_shift_0004", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element(containing: "Client stopped responding", in: app).waitForExistence(timeout: 10), "how it ended")
        XCTAssertTrue(element(containing: "192.0.2.10", in: app).exists, "the client address is shown")
        let ffmpeg = app.buttons["history-detail-ffmpeg-logs"]
        XCTAssertTrue(ffmpeg.waitForExistence(timeout: 5))
        ffmpeg.tap()

        let session = id("logs-playback-session", in: app)
        XCTAssertTrue(session.waitForExistence(timeout: 10), "Logs opened")
        XCTAssertEqual(session.value as? String, "ps_night_shift_0004")
        XCTAssertEqual(id("logs-component", in: app).value as? String, "ffmpeg")
        XCTAssertTrue(id("logs-session-summary", in: app).waitForExistence(timeout: 10), "the session summary is on top")
        XCTAssertTrue(id("log-row-1", in: app).waitForExistence(timeout: 10), "the FFmpeg line is listed")
        XCTAssertTrue(id("log-row-2", in: app).waitForNonExistence(timeout: 10), "the playback line is not FFmpeg")
        XCTAssertTrue(id("log-row-3", in: app).waitForNonExistence(timeout: 5), "another session's line is not listed")
    }

    // MARK: Logs

    func testLogRowOpensDetailsWithRequestFields() {
        let app = launch()
        openPage("logs", in: app)
        let row = id("log-row-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        for part in ["req-ffmpeg-1", "node-a", "GET", "502", "1840 ms", "192.0.2.10", "ps_night_shift_0004", "muxer failed"] {
            XCTAssertTrue(element(containing: part, in: app).waitForExistence(timeout: 5), "the detail shows \(part)")
        }
        XCTAssertTrue(app.buttons["log-detail-copy"].exists, "Copy")
        XCTAssertTrue(id("log-detail-share", in: app).exists, "Share")
    }

    func testLogComponentFilterNarrowsTheList() {
        let app = launch()
        openPage("logs", in: app)
        XCTAssertTrue(id("log-row-3", in: app).waitForExistence(timeout: 10))
        let component = id("logs-component", in: app)
        component.tap()
        component.typeText("scanner")
        XCTAssertTrue(id("log-row-1", in: app).waitForNonExistence(timeout: 10), "FFmpeg lines go")
        XCTAssertTrue(id("log-row-3", in: app).exists)
    }

    // MARK: Audit

    func testAuditRowLeadsWithTheActionAndItsChanges() {
        let app = launch()
        openPage("audit", in: app)
        let row = id("audit-row-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        for part in ["user.update", "role: user → admin", "max streams: 2 → 3", "PUT /admin/users/2"] {
            XCTAssertTrue(row.label.contains(part), "the row says \(part): \(row.label)")
        }
        XCTAssertLessThan(row.label.range(of: "user.update")!.lowerBound, row.label.range(of: "PUT /admin")!.lowerBound, "the action comes before the request")
        row.tap()
        for part in ["198.51.100.4", "Bloem Admin/1.0", "req-audit-1", "38 ms", "node-a", "sess-1"] {
            XCTAssertTrue(element(containing: part, in: app).waitForExistence(timeout: 5), "the detail shows \(part)")
        }
        XCTAssertTrue(app.buttons["audit-detail-copy"].exists, "Copy")
    }

    func testAuditFilterByPersonName() {
        let app = launch()
        openPage("audit", in: app)
        XCTAssertTrue(id("audit-row-1", in: app).waitForExistence(timeout: 10))
        choose("bob", from: "audit-person", in: app)
        XCTAssertTrue(id("audit-row-1", in: app).waitForNonExistence(timeout: 10), "alice's change goes")
        XCTAssertTrue(id("audit-row-2", in: app).exists, "bob's request stays")
    }
}
