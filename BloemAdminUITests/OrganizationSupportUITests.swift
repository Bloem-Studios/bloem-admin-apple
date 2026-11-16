import XCTest

/// Organization support through the real app, over the in-process stub server: a server with the support routes
/// (`--ui-testing-organization=support`) and the server Owner's break-glass access (`=support-access`).
final class OrganizationSupportUITests: XCTestCase {
    @MainActor
    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-organization=\(scenario)"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func openPage(_ identifier: String, in app: XCUIApplication) {
        let row = element(app, "organization-menu-\(identifier)")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(identifier) is in the menu")
        row.tap()
    }

    @MainActor
    private func openPerson(_ name: String, in app: XCUIApplication) {
        openPage("people", in: app)
        let row = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(name) is listed")
        row.tap()
        XCTAssertTrue(element(app, "organization-person-page").waitForExistence(timeout: 10))
    }

    /// The button of a confirmation: a sheet on an iPhone, a popover on an iPad.
    @MainActor
    private func confirmationButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            for container in [app.sheets, app.popovers, app.alerts] {
                let button = container.buttons[title].firstMatch
                if button.exists { return button }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return app.sheets.buttons[title].firstMatch
    }

    /// The person page's list: on an iPad the organization's sidebar is a list too, so it is found by what it holds.
    @MainActor
    private func personList(_ app: XCUIApplication) -> XCUIElement {
        app.collectionViews.containing(.any, identifier: "organization-reset-link").firstMatch
    }

    /// Scrolls the person page until `target` is on screen. The list is lazy: a row below the fold is not in the
    /// accessibility tree until it has been scrolled to.
    @MainActor
    private func scrollTo(_ target: XCUIElement, in app: XCUIApplication) {
        let list = personList(app)
        _ = list.waitForExistence(timeout: 10)
        for _ in 0..<10 where !(target.exists && target.isHittable) {
            list.swipeUp()
        }
    }

    @MainActor
    func testAResetLinkIsShownOnceAndGoneOnceClosed() throws {
        let app = launch("support")
        openPerson("Blake Baker", in: app)

        let create = element(app, "organization-reset-link")
        XCTAssertTrue(create.waitForExistence(timeout: 10), "a server with organization support offers a reset link")
        XCTAssertFalse(app.staticTexts["What you can't do here"].exists, "the older server's explanation is gone")
        create.tap()
        confirmationButton(app, "Create link").tap()

        let url = element(app, "organization-reset-url")
        XCTAssertTrue(url.waitForExistence(timeout: 10), "the link is shown")
        XCTAssertTrue(url.label.contains("reset-password"), "the link itself, to copy or share: \(url.label)")
        app.buttons["Done"].tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5), "closing the sheet forgets the link")
        XCTAssertTrue(element(app, "organization-person-page").exists)
    }

    @MainActor
    func testSigningOutEverywhereAsksFirstThenSaysHowManyEnded() throws {
        let app = launch("support")
        openPerson("Blake Baker", in: app)

        XCTAssertTrue(element(app, "organization-reset-link").waitForExistence(timeout: 10), "the support sections have loaded")
        let everywhere = element(app, "organization-sign-out-everywhere")
        scrollTo(everywhere, in: app)
        XCTAssertTrue(everywhere.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Living room TV"].exists, "the sign-ins are listed by device")
        everywhere.tap()
        confirmationButton(app, "Sign out everywhere").tap()

        let notice = app.staticTexts["Signed out everywhere: 2 sessions ended"]
        // The button goes once the sessions have ended, so the page is found by its own identifier; and on a slow
        // simulator the notice can take a moment, so it gets one before any swipe.
        if !notice.waitForExistence(timeout: 3) {
            let list = app.collectionViews["organization-person-page"].firstMatch
            for _ in 0..<6 where !notice.exists && list.exists { list.swipeDown() }
        }
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
    }

    @MainActor
    func testStreamsShowsTheOrganizationsStreamsWithoutAddressesAndStopsOne() throws {
        let app = launch("support")
        openPage("streams", in: app)

        let row = element(app, "stream-row.st1")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the organization's stream is listed")
        XCTAssertTrue(row.label.contains("Blake Baker"), "who is watching: \(row.label)")
        row.tap()
        XCTAssertTrue(element(app, "stream-details.st1").waitForExistence(timeout: 5), "the details open")
        XCTAssertFalse(element(app, "stream-detail.clientIP").exists, "no client address in an organization")
        XCTAssertFalse(element(app, "stream-detail.node").exists, "no server names in an organization")

        let actions = element(app, "organization-stream-actions-st1")
        XCTAssertTrue(actions.exists)
        actions.tap()
        let stop = app.buttons["Stop playback"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        stop.tap()
        confirmationButton(app, "Stop playback").tap()

        XCTAssertTrue(app.staticTexts["Stream stopped"].waitForExistence(timeout: 10))
        XCTAssertTrue(row.waitForNonExistence(timeout: 10), "the list is read again")
    }

    @MainActor
    func testAnOlderServerOffersNoStreamsPage() throws {
        let app = launch("support")
        XCTAssertTrue(element(app, "organization-menu-streams").waitForExistence(timeout: 10))
        app.terminate()

        let older = XCUIApplication()
        older.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-organization"]
        older.launch()
        XCTAssertTrue(element(older, "organization-menu-people").waitForExistence(timeout: 10))
        XCTAssertFalse(element(older, "organization-menu-streams").exists)
    }

    @MainActor
    func testSupportAccessShowsTheBannerAndEndingItClosesTheOrganization() throws {
        let app = launch("support-access")

        let banner = element(app, "organization-support-banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 10), "a pass opened under support access says so")
        XCTAssertTrue(app.staticTexts["Support access"].exists)
        let end = element(app, "organization-support-end")
        XCTAssertTrue(end.exists)
        end.tap()
        confirmationButton(app, "End access").tap()

        let ended = app.staticTexts["Support access to this organization has ended. To keep helping, open it again with a new reason."]
        XCTAssertTrue(ended.waitForExistence(timeout: 10))
        XCTAssertFalse(banner.exists)
    }
}
