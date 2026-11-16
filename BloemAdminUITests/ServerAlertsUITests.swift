import UIKit
import XCTest

/// The "Server alerts" section of App settings, and the bloemadmin:// link into a page. Notification
/// permission is a fake (`--ui-testing-notifications`), so no system prompt appears.
final class ServerAlertsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Server alerts

    @MainActor
    func testEverythingIsOffUntilTurnedOn() {
        let app = openSettings(notifications: "undetermined")
        let master = app.switches["alerts-master-switch"]
        XCTAssertTrue(master.waitForExistence(timeout: 5))
        XCTAssertEqual(master.value as? String, "0")
        XCTAssertTrue(app.staticTexts["iOS decides how often background checks run"].exists)
        XCTAssertFalse(app.switches["alerts-server-ui-alpha"].exists, "no server list while alerts are off")
        XCTAssertFalse(app.switches["alerts-details-switch"].exists)
        XCTAssertFalse(app.staticTexts["alerts-permission-denied"].exists)
    }

    @MainActor
    func testTurningOnListsEachServerOffAndTheDetailsSwitchOff() {
        let app = openSettings(notifications: "undetermined")
        flip(app.switches["alerts-master-switch"])

        let alpha = app.switches["alerts-server-ui-alpha"]
        XCTAssertTrue(alpha.waitForExistence(timeout: 5), "the servers appear once alerts are on")
        XCTAssertEqual(alpha.value as? String, "0")
        XCTAssertEqual(app.switches["alerts-server-ui-beta"].value as? String, "0")
        XCTAssertEqual(app.switches["alerts-master-switch"].value as? String, "1")

        flip(alpha)
        XCTAssertEqual(alpha.value as? String, "1")
        XCTAssertEqual(app.switches["alerts-server-ui-beta"].value as? String, "0")

        // The details switch closes the section, below the fold on an iPhone (Appearance comes first).
        let details = app.switches["alerts-details-switch"]
        for _ in 0..<4 where !(details.exists && details.isHittable) { app.swipeUp() }
        XCTAssertEqual(details.value as? String, "0", "details are off by default")
    }

    @MainActor
    func testRefusingThePromptKeepsAlertsOffAndSaysWhy() {
        let app = openSettings(notifications: "undetermined-refuse")
        flip(app.switches["alerts-master-switch"])
        XCTAssertTrue(app.staticTexts["alerts-permission-denied"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["alerts-master-switch"].value as? String, "0")
        XCTAssertFalse(app.switches["alerts-server-ui-alpha"].exists)
        XCTAssertTrue(app.buttons["alerts-open-settings"].exists)
    }

    @MainActor
    func testPermissionAlreadyDeniedShowsTheMessageWithoutAsking() {
        let app = openSettings(notifications: "denied")
        XCTAssertTrue(app.staticTexts["alerts-permission-denied"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["alerts-permission-denied"].label, "Notifications are off for this app in iOS Settings")
        flip(app.switches["alerts-master-switch"])
        XCTAssertEqual(app.switches["alerts-master-switch"].value as? String, "0")
        XCTAssertFalse(app.switches["alerts-server-ui-alpha"].exists)
    }

    @MainActor
    func testPermissionAlreadyGrantedTurnsOnWithoutAMessage() {
        let app = openSettings(notifications: "granted")
        flip(app.switches["alerts-master-switch"])
        XCTAssertTrue(app.switches["alerts-server-ui-alpha"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["alerts-permission-denied"].exists)
    }

    // MARK: Notifications (push)

    @MainActor
    func testAServerThatCanPushListsEveryKindAndAPlainSiloServerSaysItCannot() {
        let app = openSettings(notifications: "granted")

        let status = app.staticTexts["push-status-ui-beta"]
        scrollTo(status, in: app)
        XCTAssertEqual(status.label, "Push isn't available on this server. Only the server-down checks apply")
        // The Settings page is lazy: a row below the fold is not there until it is scrolled to.
        scrollTo(app.switches["push-ui-beta-admin.server_down"], in: app)
        scrollTo(app.switches["push-ui-beta-admin.server_up"], in: app)
        XCTAssertFalse(app.switches["push-ui-beta-admin.scan_failed"].exists, "a plain Silo server has no switch that would do nothing")
        XCTAssertFalse(app.staticTexts["push-permission-denied"].exists, "and no complaint about permission")

        let alphaStatus = app.staticTexts["push-status-ui-alpha"]
        scrollTo(alphaStatus, in: app)
        XCTAssertEqual(alphaStatus.label, "This server sends you notifications")
        for kind in ["admin.request_waiting", "admin.scan_failed", "admin.backup_failed", "admin.node_offline", "admin.plugin_failed"] {
            let toggle = app.switches["push-ui-alpha-\(kind)"]
            scrollTo(toggle, in: app)
            XCTAssertEqual(toggle.value as? String, "1", "\(kind) is on by default")
        }
    }

    @MainActor
    func testASwitchTurnsAKindOffForThatServer() {
        let app = openSettings(notifications: "granted")
        let scan = app.switches["push-ui-alpha-admin.scan_failed"]
        scrollTo(scan, in: app)
        flip(scan)
        XCTAssertEqual(scan.value as? String, "0")
        XCTAssertEqual(app.switches["push-ui-alpha-admin.backup_failed"].value as? String, "1", "only that kind")
    }

    @MainActor
    func testWhenIosHasRefusedSettingsSaysHowToAllowNotifications() {
        let app = openSettings(notifications: "denied")
        let help = app.staticTexts["push-permission-denied"]
        scrollTo(help, in: app)
        XCTAssertEqual(help.label, "Notifications are off for this app in iOS Settings")
        let how = app.staticTexts["Open iOS Settings, tap Notifications, then turn on Allow Notifications"]
        scrollTo(how, in: app)
        XCTAssertTrue(how.exists)
        scrollTo(app.buttons["push-open-settings"], in: app)
        XCTAssertFalse(app.buttons["push-allow"].exists, "a refusal is not asked about again")
    }

    @MainActor
    func testAPhoneNotAskedYetOffersTheButtonAndOnlyAsksWhenTapped() {
        let app = openSettings(notifications: "undetermined")
        let allow = app.buttons["push-allow"]
        scrollTo(allow, in: app)
        XCTAssertFalse(app.staticTexts["push-permission-denied"].exists, "opening the screen asked for nothing")
        allow.tap()
        XCTAssertFalse(app.buttons["push-allow"].waitForExistence(timeout: 2), "the fake prompt was answered once")
        let status = app.staticTexts["push-status-ui-alpha"]
        scrollTo(status, in: app)
        XCTAssertEqual(status.label, "This server sends you notifications")
    }

    // MARK: Links

    @MainActor
    func testALinkOpensASavedServerOnAPage() {
        let app = launch(link: "bloemadmin://server/ui-alpha/work.requests")
        XCTAssertTrue(waitForTitle("Requests", in: app))
        XCTAssertTrue(app.buttons["shell-context"].label.contains("Alpha"))
    }

    @MainActor
    func testALinkToAllServersOpensThatPage() {
        let app = launch(link: "bloemadmin://all/overview.dashboard")
        XCTAssertTrue(waitForTitle("Dashboard", in: app))
        XCTAssertTrue(app.buttons["shell-context"].label.contains("All servers"))
    }

    @MainActor
    func testALinkToAServerThatIsNotSavedChangesNothing() {
        let app = launch(link: "bloemadmin://server/not-saved/work.requests")
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        XCTAssertTrue(app.buttons["shell-context"].label.contains("All servers"))
    }

    // MARK: Helpers

    @MainActor
    private func launch(notifications: String? = nil, link: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-seed-servers",
            "--ui-testing-admin-gate=authorized",
        ]
        if let notifications { app.launchArguments.append("--ui-testing-notifications=\(notifications)") }
        if let link { app.launchArguments.append("--ui-testing-open-url=\(link)") }
        app.launch()
        return app
    }

    @MainActor
    private func openSettings(notifications: String) -> XCUIApplication {
        let app = launch(notifications: notifications)
        let menuButton = app.buttons["shell-menu-button"]
        if menuButton.waitForExistence(timeout: 5) { menuButton.tap() }
        let settings = app.buttons["shell-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "the menu is open")
        settings.tap()
        XCTAssertTrue(
            app.staticTexts.matching(identifier: "shell-title").element(matching: NSPredicate(format: "label == 'Settings'"))
                .waitForExistence(timeout: 5)
        )
        return app
    }

    /// Scrolls a Form until a row it shows below the fold is on screen.
    @MainActor
    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            if element.exists && element.isHittable { break }
            // The screen reads each server's push status when it opens, so a row may need a moment.
            if !element.exists { _ = element.waitForExistence(timeout: 0.5) }
            if !(element.exists && element.isHittable) { app.swipeUp() }
        }
        XCTAssertTrue(element.exists, "\(element) is in Settings")
    }

    /// A Form row's switch spans the whole row; its middle is the label, so the switch is tapped at its
    /// trailing edge.
    @MainActor
    private func flip(_ toggle: XCUIElement) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    @MainActor
    private func waitForTitle(_ expected: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let title = app.staticTexts["shell-title"]
        let predicate = NSPredicate(format: "label == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: title)], timeout: timeout) == .completed
    }
}
