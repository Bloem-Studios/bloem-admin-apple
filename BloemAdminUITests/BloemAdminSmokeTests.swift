import XCTest

final class BloemAdminSmokeTests: XCTestCase {
    @MainActor
    func testLockedLaunchCoversAdministratorContent() throws {
        let app = launch(authentication: "unavailable")

        XCTAssertTrue(app.staticTexts["Bloem Admin is locked"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Now playing"].exists, "The protected hierarchy must remain mounted")
        XCTAssertFalse(app.staticTexts["Now playing"].isHittable)
        XCTAssertTrue(app.buttons["Add server"].exists, "The protected hierarchy must remain mounted")
        XCTAssertFalse(app.buttons["Add server"].isHittable)
    }

    @MainActor
    func testUnavailableAuthenticationExplainsFailClosedRequirement() throws {
        let app = launch(authentication: "unavailable")

        XCTAssertTrue(app.buttons["Try again"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts[
                "Turn on a passcode, Face ID or Touch ID in Settings to use Bloem Admin."
            ].exists
        )
    }

    @MainActor
    func testResetLaunchShowsAllServersWithTheNoServersState() throws {
        let app = launch(authentication: "success")

        XCTAssertTrue(app.staticTexts["Now playing"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No servers"].exists)
        XCTAssertTrue(app.buttons["Add server"].exists)
        XCTAssertTrue(app.buttons["Add server"].isHittable)
    }

    @MainActor
    func testInvalidHTTPOriginIsRejectedBeforeNetworking() throws {
        let app = launch(authentication: "success")
        XCTAssertTrue(app.buttons["Add server"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add server"].isHittable)
        app.buttons["Add server"].tap()

        let serverURL = app.textFields["your-server.example.com"]
        XCTAssertTrue(serverURL.waitForExistence(timeout: 5))
        serverURL.tap()
        serverURL.typeText("http://media.example.com")
        dismissKeyboard(in: app)
        // Step one reads the server; an address that is not HTTPS stops before any request.
        let next = app.buttons["Continue"]
        XCTAssertTrue(next.isHittable)
        next.tap()

        XCTAssertTrue(app.staticTexts["The server address must use HTTPS."].waitForExistence(timeout: 5))
    }

    @MainActor
    func testLockShieldHidesMountedAddServerHierarchyAfterForegrounding() throws {
        let app = launch(authentication: "success-then-pending")
        XCTAssertTrue(app.buttons["Add server"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Add server"].isHittable)
        app.buttons["Add server"].tap()
        XCTAssertTrue(app.navigationBars["Add a Silo server"].waitForExistence(timeout: 5))

        XCUIDevice.shared.press(.home)
        app.activate()

        XCTAssertTrue(app.staticTexts["Bloem Admin is locked"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.navigationBars["Add a Silo server"].exists, "The presented form must remain mounted")
        XCTAssertFalse(app.navigationBars["Add a Silo server"].isHittable)
        XCTAssertTrue(app.textFields["your-server.example.com"].exists)
        XCTAssertFalse(app.textFields["your-server.example.com"].isHittable)
    }

    @MainActor
    private func launch(authentication: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-reset",
            "--ui-testing-auth=\(authentication)"
        ]
        app.launch()
        return app
    }

    @MainActor
    private func dismissKeyboard(in app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        let hideKeyboard = app.keyboards.buttons["Hide keyboard"]
        if hideKeyboard.exists {
            hideKeyboard.tap()
            return
        }
        // iPhone's software keyboard has no dedicated dismissal button; its Return key (labelled
        // "Go" on the server address field) resigns the current TextField.
        let returnKey = app.keyboards.buttons["return"]
        let goKey = app.keyboards.buttons["Go"]
        let key = goKey.waitForExistence(timeout: 2) ? goKey : returnKey
        XCTAssertTrue(key.waitForExistence(timeout: 2))
        key.tap()
    }
}
