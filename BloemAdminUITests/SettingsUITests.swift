import XCTest

/// The Settings pages, driven through the debug-only fixture server (`--ui-testing-settings`): a server
/// three days and four hours into its run, with keys at their defaults, one secret that is set, one
/// failing server channel and one sign-in provider. `--ui-testing-settings-conflict` makes the first
/// save lose a race.
final class SettingsUITests: XCTestCase {
    private func launch(conflict: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-settings"]
        if conflict { app.launchArguments.append("--ui-testing-settings-conflict") }
        app.launch()
        return app
    }

    private func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Opens a named page from the Settings list.
    @discardableResult
    private func openPage(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let row = element("settings.page.\(id)", in: app)
        scrollUntilVisible(row, in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the \(id) page is listed")
        row.tap()
        return row
    }

    private func scrollUntilVisible(_ target: XCUIElement, in app: XCUIApplication) {
        var attempts = 0
        while !(target.exists && target.isHittable) && attempts < 10 {
            app.swipeUp()
            attempts += 1
        }
    }

    /// Turns a switch by tapping where its knob is: a Form row is one wide element, and a tap at its
    /// centre lands on the label.
    private func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    private func goBack(in app: XCUIApplication) {
        app.navigationBars.buttons.firstMatch.tap()
    }

    // MARK: List, status and restart

    func testSettingsListNamesTheServersUptimeAndEveryPage() {
        let app = launch()
        let uptime = element("settings.uptime", in: app)
        XCTAssertTrue(uptime.waitForExistence(timeout: 10))
        XCTAssertTrue(uptime.label.contains("3d 4h"), "uptime reads as days and hours: \(uptime.label)")
        XCTAssertTrue(element("settings.restartStatus", in: app).label.contains("Not needed"))
        for id in ["general", "network-access", "sign-in", "playback", "logging"] {
            XCTAssertTrue(element("settings.page.\(id)", in: app).exists, "\(id) is in the list")
        }
    }

    func testSavingASettingThatNeedsARestartNamesItAndTheConfirmationWarnsAboutStreams() {
        let app = launch()
        openPage("general", in: app)
        let marker = element("setting.server.public_url.restart", in: app)
        XCTAssertTrue(marker.waitForExistence(timeout: 10), "the setting says it applies after a restart")
        let field = app.textFields["setting.server.public_url.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("https://bloem.example.test")
        XCTAssertTrue(element("settings.saveBar", in: app).waitForExistence(timeout: 5), "the save bar appears with the first edit")

        element("settings.save", in: app).tap()
        XCTAssertTrue(element("settings.saved", in: app).waitForExistence(timeout: 10))

        goBack(in: app)
        let status = element("settings.restartStatus", in: app)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("Public URL"), "the restart reason is the setting's label: \(status.label)")

        element("settings.restart", in: app).tap()
        let warning = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Active streams will be interrupted")).firstMatch
        XCTAssertTrue(warning.waitForExistence(timeout: 5), "the confirmation says what a restart does")
    }

    // MARK: Conflict

    func testASaveThatLosesARaceKeepsTheEditAndOffersTheServersValues() {
        let app = launch(conflict: true)
        openPage("general", in: app)
        let field = app.textFields["setting.server.public_url.field"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("https://mine.example.test")

        element("settings.save", in: app).tap()

        XCTAssertTrue(element("settings.conflict", in: app).waitForExistence(timeout: 10), "Settings changed on the server")
        XCTAssertEqual(app.textFields["setting.server.public_url.field"].value as? String, "https://mine.example.test", "the edit stays visible")

        element("settings.keepMine", in: app).tap()
        XCTAssertTrue(element("settings.save", in: app).waitForExistence(timeout: 5))
        element("settings.save", in: app).tap()
        XCTAssertTrue(element("settings.saved", in: app).waitForExistence(timeout: 10))
    }

    // MARK: Sign-in

    func testTurningOffPasswordSignInWithNoBreakGlassAdminIsExplained() {
        let app = launch()
        openPage("sign-in", in: app)
        let toggle = app.switches["setting.auth.local_password_login.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        flip(toggle)
        element("settings.save", in: app).tap()

        XCTAssertTrue(element("settings.saveError", in: app).waitForExistence(timeout: 10))
        let reason = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "break-glass")).firstMatch
        XCTAssertTrue(reason.waitForExistence(timeout: 5), "the refusal says why")
    }

    func testTheProviderTestAnswersPassedWithItsSteps() {
        let app = launch()
        openPage("sign-in", in: app)
        let test = element("settings.provider.3.test", in: app)
        scrollUntilVisible(test, in: app)
        XCTAssertTrue(test.waitForExistence(timeout: 10))
        test.tap()
        let result = element("settings.provider.3.result", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("Passed"), result.label)
    }

    // MARK: Email test

    func testTheEmailTestShowsAFailureWithTheServersReason() {
        let app = launch()
        openPage("email", in: app)
        let recipient = app.textFields["settings.emailTest.recipient"]
        scrollUntilVisible(recipient, in: app)
        XCTAssertTrue(recipient.waitForExistence(timeout: 10))
        recipient.tap()
        recipient.typeText("admin@example.test")
        let send = element("settings.emailTest.send", in: app)
        scrollUntilVisible(send, in: app)
        send.tap()

        let result = element("settings.emailTest.result", in: app)
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(result.label.contains("Failed"), result.label)
        XCTAssertTrue(result.label.contains("535 authentication failed"), result.label)
    }

    // MARK: Search

    func testSearchFindsASingleSettingAndOpensItsPage() {
        let app = launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("forgot password")

        let hit = element("settings.result.setting:sign-in:password_reset.self_service_enabled", in: app)
        XCTAssertTrue(hit.waitForExistence(timeout: 10), "the setting itself is found, not only its page")
        hit.tap()
        XCTAssertTrue(element("setting.password_reset.self_service_enabled", in: app).waitForExistence(timeout: 10), "the Sign-in page opened at the setting")
    }

    // MARK: Other pages

    func testNetworkAccessOffersTheAuthorizationPageForAWaitingHost() {
        let app = launch()
        openPage("network-access", in: app)
        XCTAssertTrue(element("networkAccess.api.authorize", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("networkAccess.api.disconnect", in: app).exists, "a host that is waiting can be disconnected")
    }

    func testRequestSettingsSaveThroughTheirOwnRoute() {
        let app = launch()
        openPage("requests", in: app)
        let allow = app.switches["requestSettings.allow"]
        XCTAssertTrue(allow.waitForExistence(timeout: 10))
        flip(allow)
        element("settings.save", in: app).tap()
        XCTAssertTrue(element("settings.saved", in: app).waitForExistence(timeout: 10))
    }

    func testOtherSettingsListsAStoredKeyNoPageNames() {
        let app = launch()
        let other = element("settings.other", in: app)
        scrollUntilVisible(other, in: app)
        XCTAssertTrue(other.waitForExistence(timeout: 10))
        other.tap()
        XCTAssertTrue(element("settings.other.scanner.workers", in: app).waitForExistence(timeout: 10))
        XCTAssertTrue(element("settings.other.custom.flag", in: app).exists)
    }
}
