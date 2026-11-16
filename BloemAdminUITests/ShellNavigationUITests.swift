import UIKit
import XCTest

/// The shell on iPhone (drawer menu) and iPad (permanent sidebar): the menu, page search, sideways swipe,
/// the context dropdown and Manage servers. The pages themselves are not under test here; All servers with no
/// saved server shows its "No servers" state on every page, which is all these tests need.
final class ShellNavigationUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Menu

    @MainActor
    func testOpensOnNowPlayingWithTheOneRowTopBar() {
        let app = launch()
        XCTAssertTrue(title(app).waitForExistence(timeout: 5))
        XCTAssertEqual(title(app).label, "Now playing")
        XCTAssertTrue(app.buttons["shell-search-button"].exists)
        XCTAssertTrue(app.buttons["shell-context"].exists)
        XCTAssertEqual(app.buttons["shell-menu-button"].exists, !isPad(app), "iPad has the sidebar instead of a menu button")
        XCTAssertEqual(app.tabBars.count, 0, "no tab bar")
    }

    @MainActor
    func testMenuListsTheWebGroupsAndPagesInOrder() {
        let app = launch()
        openMenu(app)

        // With no saved server there is no Bloem server, so there is no Platform group and no Organizations page
        // (`SiloServerUITests` covers a Bloem server).
        let groups = ["monitor", "manage", "configure"].map { app.staticTexts["shell-group:\($0)"] }
        let expectedPages = [
            "overview.dashboard", "live.streams", "system.audit",
            "content.libraries", "work.requests", "people.users", "live.activity", "playback.nodes",
            "system.server", "work.jobs", "system.backups", "system.plugins",
        ]
        let pages = expectedPages.map { app.buttons["shell-destination:\($0)"] }
        for element in groups + pages {
            XCTAssertTrue(element.waitForExistence(timeout: 3), "\(element)")
        }
        XCTAssertFalse(app.staticTexts["shell-group:platform"].exists, "no Bloem server, no Platform group")
        XCTAssertFalse(app.buttons["shell-destination:platform.organizations"].exists, "Organizations is a Bloem page")
        // Top to bottom is menu order.
        let order = [groups[0], pages[0], pages[1], pages[2], groups[1], pages[3], pages[4], pages[5], pages[6],
                     pages[7], groups[2], pages[8], pages[9], pages[10], pages[11]]
        let ys = order.map(\.frame.minY)
        XCTAssertEqual(ys, ys.sorted(), "groups and pages follow the web's order")
        XCTAssertEqual(pages.map(\.label), [
            "Dashboard", "Now playing", "Audit", "Libraries", "Requests", "Users", "Playback history",
            "Nodes", "Server settings", "Scheduled tasks", "Backups", "Plugins",
        ])
        XCTAssertFalse(app.buttons["shell-destination:system.logs"].exists, "Logs are for a single server")
        XCTAssertFalse(app.buttons["shell-destination:platform.support-access"].exists, "Support access is for one organization")

        // The app's own items sit below the pages.
        let manage = app.buttons["shell-manage-servers"]
        let settings = app.buttons["shell-settings"]
        let signOut = app.buttons["shell-sign-out"]
        XCTAssertTrue(manage.exists)
        XCTAssertTrue(settings.exists)
        XCTAssertTrue(signOut.exists)
        XCTAssertEqual(manage.label, "Manage servers")
        XCTAssertEqual(settings.label, "Settings")
        XCTAssertEqual(signOut.label, "Sign out")
        // Pinned below the page list: under every page on screen (on an iPhone the last pages scroll under it).
        XCTAssertGreaterThan(manage.frame.minY, pages[0].frame.minY)
        for page in pages where page.isHittable {
            XCTAssertGreaterThan(manage.frame.minY, page.frame.minY, "\(page.label) is above Manage servers")
        }
        XCTAssertGreaterThan(settings.frame.minY, manage.frame.minY, "the foot reads Manage servers, Settings, Sign out")
        XCTAssertGreaterThan(signOut.frame.minY, settings.frame.minY, "the foot reads Manage servers, Settings, Sign out")
    }

    @MainActor
    func testChoosingAPageOpensItAndClosesTheMenu() throws {
        let app = launch()
        openMenu(app)
        app.buttons["shell-destination:live.activity"].tap()
        XCTAssertTrue(waitForTitle("Playback history", in: app))
        if !isPad(app) {
            XCTAssertFalse(app.buttons["shell-destination:live.activity"].waitForExistence(timeout: 1), "the drawer closed")
        }
    }

    @MainActor
    func testSettingsIsAPageOfTheShellNotADialog() {
        let app = launch()
        openMenu(app)
        app.buttons["shell-settings"].tap()
        XCTAssertTrue(waitForTitle("Settings", in: app), "the shell's bar titles the page")
        XCTAssertTrue(app.staticTexts["Device unlock"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Done"].exists, "a page has no Done button to dismiss it")
        XCTAssertTrue(app.buttons["shell-search-button"].exists, "the shell's bar is still there")
        // Choosing a page from the menu leaves Settings.
        openMenu(app)
        app.buttons["shell-destination:live.activity"].tap()
        XCTAssertTrue(waitForTitle("Playback history", in: app))
    }

    @MainActor
    func testSignOutAsksAndNamesWhatItEnds() {
        let app = launch(seedServers: true, admitGate: true)
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        app.buttons["shell-context"].tap()
        app.buttons["shell-context-item:server:ui-alpha"].tap()
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        openMenu(app)
        app.buttons["shell-sign-out"].tap()
        XCTAssertTrue(app.staticTexts["Sign out of Alpha?"].waitForExistence(timeout: 5), "the question names the server")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Sign out of Alpha?"]))
    }

    @MainActor
    func testMenuOpensOnlyFromItsButton() throws {
        let app = launch()
        try XCTSkipIf(isPad(app), "iPad shows the menu permanently")
        XCTAssertTrue(title(app).waitForExistence(timeout: 5))
        // An edge drag over the page does not open the menu.
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertFalse(app.buttons["shell-destination:live.streams"].exists)

        app.buttons["shell-menu-button"].tap()
        XCTAssertTrue(app.buttons["shell-destination:live.streams"].waitForExistence(timeout: 3))
        // Tapping outside closes it again.
        app.buttons["shell-menu-scrim"].coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(waitForNonExistence(app.buttons["shell-destination:live.streams"]))
    }

    // MARK: Swipe

    @MainActor
    func testSwipingSidewaysWalksThePagesWithoutWrapping() {
        let app = launch()
        XCTAssertTrue(waitForTitle("Now playing", in: app))

        app.swipeRight()
        XCTAssertTrue(waitForTitle("Dashboard", in: app))
        app.swipeRight()
        XCTAssertEqual(title(app).label, "Dashboard", "no wrap before the first page: Dashboard leads a menu with no Bloem server")

        app.swipeLeft()
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        app.swipeLeft()
        XCTAssertTrue(waitForTitle("Audit", in: app))
        app.swipeRight()
        XCTAssertTrue(waitForTitle("Now playing", in: app))

        for expected in ["Audit", "Libraries", "Requests", "Users", "Playback history", "Nodes", "Server settings",
                         "Scheduled tasks", "Backups", "Plugins"] {
            app.swipeLeft()
            XCTAssertTrue(waitForTitle(expected, in: app))
        }
        app.swipeLeft()
        XCTAssertEqual(title(app).label, "Plugins", "no wrap past the last page")
    }

    @MainActor
    func testNoSwipeWhileADialogIsUp() {
        let app = launch()
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        app.buttons["Add server"].tap()
        XCTAssertTrue(app.navigationBars["Add a Silo server"].waitForExistence(timeout: 5))
        app.navigationBars["Add a Silo server"].swipeLeft()
        app.swipeLeft()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(waitForTitle("Now playing", in: app), "the page did not change under the sheet")
    }

    // MARK: Search

    @MainActor
    func testSearchFindsAPageByItsKeywordAndOpensIt() {
        let app = launch()
        app.buttons["shell-search-button"].tap()
        let field = app.textFields["shell-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("scheduler")
        let result = app.buttons["shell-search-result:work.jobs"]
        XCTAssertTrue(result.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["shell-search-result:live.streams"].exists)
        XCTAssertTrue(result.label.contains("Scheduled tasks"))
        XCTAssertTrue(result.label.contains("Background task schedules, runs, and run history"), "the web's description is shown")

        result.tap()
        XCTAssertTrue(waitForTitle("Scheduled tasks", in: app))
        XCTAssertFalse(app.textFields["shell-search-field"].exists, "the sheet closed")
    }

    @MainActor
    func testSearchByGroupNameListsAllItsPagesAndNoMatchSaysSo() {
        let app = launch()
        app.buttons["shell-search-button"].tap()
        let field = app.textFields["shell-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))

        field.typeText("monitor")
        for id in ["overview.dashboard", "live.streams"] {
            XCTAssertTrue(app.buttons["shell-search-result:\(id)"].waitForExistence(timeout: 3), id)
        }
        XCTAssertFalse(app.buttons["shell-search-result:work.jobs"].exists)

        app.buttons["Clear search"].tap()
        field.typeText("zzzz")
        XCTAssertTrue(app.staticTexts["shell-search-empty"].waitForExistence(timeout: 3))
    }

    @MainActor
    func testSearchKeyOpensTheFirstMatchAndTheArrowClosesWithoutChoosing() {
        let app = launch()
        app.buttons["shell-search-button"].tap()
        var field = app.textFields["shell-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        app.buttons["shell-search-close"].tap()
        XCTAssertTrue(waitForTitle("Now playing", in: app), "closing without choosing leaves the page")

        app.buttons["shell-search-button"].tap()
        field = app.textFields["shell-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("audit\n")
        XCTAssertTrue(waitForTitle("Audit", in: app))
    }

    // MARK: Context dropdown and Manage servers

    @MainActor
    func testDropdownListsAllServersAndEachSavedServerThenOpensOnNowPlaying() {
        let app = launch(seedServers: true, admitGate: true)
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        let context = app.buttons["shell-context"]
        XCTAssertTrue(context.label.contains("All servers"))
        context.tap()
        XCTAssertTrue(app.buttons["shell-context-item:all-servers"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["shell-context-item:server:ui-alpha"].exists)
        XCTAssertTrue(app.buttons["shell-context-item:server:ui-beta"].exists)

        app.buttons["shell-context-item:server:ui-alpha"].tap()
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        XCTAssertTrue(app.buttons["shell-context"].label.contains("Alpha"))
        openMenu(app)
        XCTAssertTrue(app.buttons["shell-destination:system.logs"].waitForExistence(timeout: 3), "a server has Logs")
    }

    @MainActor
    func testSwitcherIsASheetWithTheCurrentMarkedAndAddServerAtTheBottom() {
        let app = launch(seedServers: true, admitGate: true)
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        app.buttons["shell-context"].tap()
        let all = app.buttons["shell-context-item:all-servers"]
        XCTAssertTrue(all.waitForExistence(timeout: 3))
        XCTAssertTrue(all.isSelected, "the current scope is marked")
        XCTAssertFalse(app.buttons["shell-context-item:server:ui-alpha"].isSelected)
        let add = app.buttons["shell-context-add-server"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        XCTAssertEqual(add.label, "Add server")
        XCTAssertGreaterThan(add.frame.minY, app.buttons["shell-context-item:server:ui-beta"].frame.minY, "Add server is last")
        XCTAssertFalse(app.buttons["shell-context-manage-servers"].exists, "Manage servers lives in the drawer")
        add.tap()
        XCTAssertTrue(app.navigationBars["Add a Silo server"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testScreensBeforeAServersPagesHaveTheBarWithTitleAndDropdownButNoMenu() {
        let app = launch(seedServers: true, admitGate: false)
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        app.buttons["shell-context"].tap()
        app.buttons["shell-context-item:server:ui-beta"].tap()
        XCTAssertTrue(waitForTitleIn(["Checking access", "Can't reach server", "Sign in"], app: app))
        XCTAssertTrue(app.buttons["shell-context"].exists)
        XCTAssertTrue(app.buttons["shell-context"].label.contains("Beta"))
        XCTAssertFalse(app.buttons["shell-menu-button"].exists, "no menu before the pages")
        XCTAssertFalse(app.buttons["shell-search-button"].exists, "no search before the pages")
    }

    @MainActor
    func testManageServersShowsSignInStateAndRenamesForgetsAndRemoves() {
        let app = launch(seedServers: true, admitGate: true)
        openMenu(app)
        app.buttons["shell-manage-servers"].tap()
        XCTAssertTrue(app.navigationBars["Manage servers"].waitForExistence(timeout: 5))

        XCTAssertTrue(app.buttons["server-list-all-servers"].exists)
        XCTAssertFalse(app.buttons["server-row:ui-alpha"].label.contains("Signed out"), "a signed-in server says nothing")
        XCTAssertTrue(app.buttons["server-row:ui-beta"].label.contains("Signed out"))
        XCTAssertTrue(app.buttons["server-list-add-server"].exists)

        // Rename.
        app.buttons["server-actions:ui-beta"].tap()
        XCTAssertTrue(app.buttons["Rename"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Forget credentials"].exists)
        XCTAssertFalse(app.buttons["Forget credentials"].isEnabled, "a signed-out server has nothing to forget")
        XCTAssertTrue(app.buttons["Remove server"].exists)
        app.buttons["Rename"].tap()
        let name = app.textFields["Server name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.clearAndTypeText("Gamma")
        app.buttons["Save changes"].tap()
        XCTAssertTrue(app.buttons["server-row:ui-beta"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["server-row:ui-beta"].label.contains("Gamma"))

        // Forget credentials, after a confirmation. Tapping outside the dialog cancels it.
        app.buttons["server-actions:ui-alpha"].tap()
        app.buttons["Forget credentials"].tap()
        let dismiss = app.otherElements["PopoverDismissRegion"]
        if dismiss.waitForExistence(timeout: 3) {
            dismiss.tap()
        } else {
            app.buttons["Cancel"].tap()
        }
        XCTAssertTrue(waitForNonExistence(app.staticTexts["Forget credentials for Alpha?"]))
        XCTAssertFalse(app.buttons["server-row:ui-alpha"].label.contains("Signed out"), "cancel keeps the sign-in")
        app.buttons["server-actions:ui-alpha"].tap()
        app.buttons["Forget credentials"].tap()
        XCTAssertTrue(app.staticTexts["Forget credentials for Alpha?"].waitForExistence(timeout: 3))
        let forget = app.buttons.matching(identifier: "Forget credentials").allElementsBoundByIndex.last
        XCTAssertNotNil(forget)
        forget?.tap()
        XCTAssertTrue(waitForLabelContaining(app.buttons["server-row:ui-alpha"], "Signed out"))

        // Remove, after a confirmation.
        app.buttons["server-actions:ui-alpha"].tap()
        app.buttons["Remove server"].tap()
        XCTAssertTrue(app.staticTexts["Remove Alpha?"].waitForExistence(timeout: 3))
        let remove = app.buttons.matching(identifier: "Remove server").allElementsBoundByIndex.last
        XCTAssertNotNil(remove)
        remove?.tap()
        XCTAssertTrue(waitForNonExistence(app.buttons["server-row:ui-alpha"]))
        XCTAssertTrue(app.buttons["server-row:ui-beta"].exists)
    }

    @MainActor
    func testManageServersOpensAServerAndAddServerLivesThere() {
        let app = launch(seedServers: true, admitGate: true)
        openMenu(app)
        app.buttons["shell-manage-servers"].tap()
        XCTAssertTrue(app.navigationBars["Manage servers"].waitForExistence(timeout: 5))

        app.buttons["server-list-add-server"].tap()
        XCTAssertTrue(app.navigationBars["Add a Silo server"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        app.buttons["server-row:ui-alpha"].tap()
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        XCTAssertTrue(app.buttons["shell-context"].label.contains("Alpha"))
    }

    // MARK: Helpers

    @MainActor
    private func launch(seedServers: Bool = false, admitGate: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success"]
        if seedServers { app.launchArguments.append("--ui-testing-seed-servers") }
        if admitGate { app.launchArguments.append("--ui-testing-admin-gate=authorized") }
        app.launch()
        return app
    }

    @MainActor
    private func isPad(_ app: XCUIApplication) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    @MainActor
    private func title(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["shell-title"]
    }

    /// Opens the drawer on iPhone; the iPad sidebar is already open.
    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["shell-menu-button"]
        if button.waitForExistence(timeout: 5) { button.tap() }
        XCTAssertTrue(app.buttons["shell-manage-servers"].waitForExistence(timeout: 5), "the menu is open")
    }

    @MainActor
    private func waitForTitle(_ expected: String, in app: XCUIApplication) -> Bool {
        waitForLabel(title(app), expected)
    }

    @MainActor
    private func waitForTitleIn(_ options: [String], app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if options.contains(title(app).label) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, _ expected: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label == %@", expected)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForLabelContaining(_ element: XCUIElement, _ text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }
}

private extension XCUIElement {
    func clearAndTypeText(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
