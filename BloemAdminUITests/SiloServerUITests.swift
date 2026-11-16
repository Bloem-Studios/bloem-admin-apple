import UIKit
import XCTest

/// The app works with every Silo server; what Bloem adds appears only for a Bloem server. These launch the real app
/// over servers answered inside the process (`--ui-testing-silo-server=plain|bloem|mixed`): a plain Silo server has no
/// `/api/bloem/` routes (they answer `404 page not found`), a Bloem server answers its capabilities.
final class SiloServerUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private let organizations = "shell-destination:platform.organizations"
    private let supportAccess = "shell-destination:platform.support-access"
    private let platformGroup = "shell-group:platform"
    private let plainHost = "plain"
    private let bloemHost = "bloem"

    // MARK: A plain Silo server

    @MainActor
    func testAPlainSiloServerHasNoBloemPagesAndIsAskedOnlyWhetherItIsBloem() {
        let app = launch("plain")
        XCTAssertTrue(waitForTitle("Now playing", in: app))

        // All servers.
        openMenu(app)
        XCTAssertTrue(app.buttons["shell-destination:overview.dashboard"].waitForExistence(timeout: 5), "the Silo pages are there")
        XCTAssertFalse(app.buttons[organizations].exists, "Organizations is a Bloem page")
        XCTAssertFalse(app.staticTexts[platformGroup].exists, "no Platform group")
        XCTAssertFalse(app.buttons[supportAccess].exists)
        closeMenu(app)

        // The one server.
        selectServer(app, "fixture-plain")
        openMenu(app)
        XCTAssertTrue(app.buttons["shell-destination:system.logs"].waitForExistence(timeout: 5), "a server has Logs")
        XCTAssertFalse(app.buttons[organizations].exists)
        XCTAssertFalse(app.buttons[supportAccess].exists)
        XCTAssertFalse(app.staticTexts[platformGroup].exists)
        closeMenu(app)

        // Give the background lookups time to run, then read what the server was asked.
        Thread.sleep(forTimeInterval: 3)
        let requests = bloemRequests(app)
        XCTAssertTrue(requests.contains("plain GET /api/bloem/v2/capabilities"), "it is asked once whether it is a Bloem server: \(requests)")
        XCTAssertEqual(requests.filter { $0.contains("/capabilities") }.count, 1, "and only once: \(requests)")
        XCTAssertEqual(requests.filter { !$0.hasSuffix("/api/bloem/v2/capabilities") }, [], "nothing else under /api/bloem/ is asked of it")
    }

    @MainActor
    func testNoBloemPageTurnsUpInSearchOnAPlainSiloServer() {
        let app = launch("plain")
        XCTAssertTrue(waitForTitle("Now playing", in: app))
        app.buttons["shell-search-button"].tap()
        let field = app.textFields["shell-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("organizations")
        XCTAssertTrue(app.staticTexts["shell-search-empty"].waitForExistence(timeout: 3), "no page answers to Organizations")
    }

    // MARK: A Bloem server

    @MainActor
    func testABloemServerKeepsOrganizationsInBothMenus() {
        let app = launch("bloem")
        XCTAssertTrue(waitForTitle("Now playing", in: app))

        openMenu(app)
        XCTAssertTrue(app.buttons[organizations].waitForExistence(timeout: 10), "All servers lists Organizations")
        XCTAssertTrue(app.staticTexts[platformGroup].exists)
        XCTAssertEqual(app.buttons[organizations].label, "Organizations")
        closeMenu(app)

        selectServer(app, "fixture-bloem")
        openMenu(app)
        XCTAssertTrue(app.buttons[organizations].waitForExistence(timeout: 10), "so does the server's own menu")
        closeMenu(app)

        let requests = bloemRequests(app)
        XCTAssertTrue(requests.contains("bloem GET /api/bloem/v2/capabilities"), "\(requests)")
        XCTAssertEqual(requests.filter { $0.contains("/capabilities") }.count, 1, "asked once for the whole session: \(requests)")
    }

    // MARK: A plain Silo server and a Bloem server together

    @MainActor
    func testOneBloemServerAmongPlainSiloServersBringsOrganizationsBackToAllServersOnly() {
        let app = launch("mixed")
        XCTAssertTrue(waitForTitle("Now playing", in: app))

        openMenu(app)
        XCTAssertTrue(app.buttons[organizations].waitForExistence(timeout: 10), "All servers lists Organizations when one server is Bloem")
        closeMenu(app)

        selectServer(app, "fixture-plain")
        openMenu(app)
        XCTAssertTrue(app.buttons["shell-destination:system.logs"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons[organizations].exists, "the plain Silo server's own menu has none")
        closeMenu(app)

        let requests = bloemRequests(app)
        XCTAssertEqual(requests.filter { $0.hasPrefix("plain ") && !$0.hasSuffix("/api/bloem/v2/capabilities") }, [],
                       "the plain Silo server is asked nothing but its capabilities: \(requests)")
    }

    // MARK: Helpers

    @MainActor
    private func launch(_ kind: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-silo-server=\(kind)",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
        ]
        app.launch()
        return app
    }

    @MainActor
    private func isPad(_ app: XCUIApplication) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    @MainActor
    private func title(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "shell-title").firstMatch
    }

    @MainActor
    private func waitForTitle(_ expected: String, in app: XCUIApplication, timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if title(app).exists, title(app).label == expected { return true }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return false
    }

    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["shell-menu-button"]
        if button.waitForExistence(timeout: 5) { button.tap() }
        XCTAssertTrue(app.buttons["shell-manage-servers"].waitForExistence(timeout: 5), "the menu is open")
    }

    @MainActor
    private func closeMenu(_ app: XCUIApplication) {
        guard !isPad(app) else { return }
        let scrim = app.buttons["shell-menu-scrim"]
        if scrim.exists { scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() }
        _ = app.buttons["shell-manage-servers"].waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func selectServer(_ app: XCUIApplication, _ id: String) {
        app.buttons["shell-context"].tap()
        let item = app.buttons["shell-context-item:server:\(id)"]
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
        XCTAssertTrue(waitForTitle("Now playing", in: app))
    }

    /// The `/api/bloem/` requests the fixture servers have received, one per line.
    @MainActor
    private func bloemRequests(_ app: XCUIApplication) -> [String] {
        let probe = app.descendants(matching: .any).matching(identifier: "silo-fixture-bloem-requests").firstMatch
        XCTAssertTrue(probe.waitForExistence(timeout: 5), "the fixture's request log is exposed")
        Thread.sleep(forTimeInterval: 1)
        return probe.label.split(separator: "\n").map(String.init)
    }
}
