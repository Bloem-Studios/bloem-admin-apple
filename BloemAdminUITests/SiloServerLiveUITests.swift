import UIKit
import XCTest

/// A live run against a real, plain upstream Silo server (no Bloem routes). It is skipped unless the run supplies the
/// server through the environment of the test runner: `SILO_LIVE_URL`, `SILO_LIVE_USER` and `SILO_LIVE_PASSWORD`
/// (`scripts/ios-live-silo-test.sh` sets them from the credentials file and never prints them; xcodebuild passes
/// `TEST_RUNNER_`-prefixed variables on without the prefix). Nothing about the server is committed.
///
/// The test checks that the Add server form recognises the server, signs in through the same sign-in the form uses, opens
/// every page of All servers and of the server itself, and finds each either loaded or showing its own "not on this
/// server" state, with no Bloem page in the menu and no mention of Bloem on screen. Each page is photographed to
/// `/tmp/silo-server-shots/` on the machine running the simulator, which the script copies to
/// `docs/screenshots/silo-server/`.
final class SiloServerLiveUITests: XCTestCase {
    private static let shots = "/tmp/silo-server-shots"

    private var address = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        guard let address = environment["SILO_LIVE_URL"], !address.isEmpty,
              let user = environment["SILO_LIVE_USER"], !user.isEmpty,
              let password = environment["SILO_LIVE_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("no live Silo server is supplied (SILO_LIVE_URL, SILO_LIVE_USER, SILO_LIVE_PASSWORD)")
        }
        self.address = address
        try FileManager.default.createDirectory(atPath: Self.shots, withIntermediateDirectories: true)
    }

    // MARK: The tour

    @MainActor
    func testEveryPageOfAPlainSiloServerLoadsOrSaysItIsNotOnThisServer() throws {
        let app = XCUIApplication()
        let environment = ProcessInfo.processInfo.environment
        app.launchArguments = [
            "--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-live-silo",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearancePreference", "dark",
        ]
        app.launchEnvironment["SILO_LIVE_URL"] = address
        app.launchEnvironment["SILO_LIVE_USER"] = environment["SILO_LIVE_USER"]
        app.launchEnvironment["SILO_LIVE_PASSWORD"] = environment["SILO_LIVE_PASSWORD"]
        app.launch()

        // Sign in (the app runs the Add server form's discovery and password sign-in, and saves the server).
        let title = app.descendants(matching: .any).matching(identifier: "shell-title").firstMatch
        let status = app.descendants(matching: .any).matching(identifier: "silo-live-status").firstMatch
        let signedIn = title.waitForExistence(timeout: 90)
        if !signedIn {
            let reason = status.exists ? status.label : "the app did not open"
            XCTFail("could not sign in to the live server: \(reason)")
            return
        }
        Thread.sleep(forTimeInterval: 2)
        photograph("all-servers-start")

        // With only a plain Silo server saved, All servers has no Bloem page.
        openMenu(app)
        photograph("menu-all-servers")
        assertNoBloem(app, in: "the All servers menu")
        XCTAssertFalse(app.buttons["shell-destination:platform.organizations"].exists, "no Organizations page")
        XCTAssertFalse(app.staticTexts["shell-group:platform"].exists, "no Platform group")
        closeMenu(app)

        let allServersPages = [
            "overview.dashboard", "live.streams", "content.libraries", "work.requests", "people.users", "live.activity",
            "playback.nodes", "system.server", "work.jobs", "system.backups", "system.plugins", "system.audit",
        ]
        var summary: [String] = []
        for id in allServersPages {
            summary.append(visit(app, id: id, prefix: "all"))
        }

        // The server itself.
        app.buttons["shell-context"].tap()
        let serverItem = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'shell-context-item:server:'")).firstMatch
        XCTAssertTrue(serverItem.waitForExistence(timeout: 5), "the saved server is in the context menu")
        photograph("context-menu")
        serverItem.tap()
        _ = title.waitForExistence(timeout: 10)

        openMenu(app)
        photograph("menu-server")
        assertNoBloem(app, in: "the server's menu")
        XCTAssertFalse(app.buttons["shell-destination:platform.organizations"].exists, "no Organizations page")
        XCTAssertFalse(app.buttons["shell-destination:platform.support-access"].exists, "no Support access page")
        XCTAssertFalse(app.staticTexts["shell-group:platform"].exists, "no Platform group")
        closeMenu(app)

        let serverPages = ["live.streams", "overview.dashboard", "system.logs"] + allServersPages.filter {
            !["live.streams", "overview.dashboard"].contains($0)
        } + ["system.api-keys"]
        for id in serverPages {
            summary.append(visit(app, id: id, prefix: "server"))
        }

        // The Settings page names the app as Silo.
        openMenu(app)
        scrollMenuTo(app.buttons["shell-settings"], app: app)
        app.buttons["shell-settings"].tap()
        if app.staticTexts.matching(identifier: "shell-title").element(matching: NSPredicate(format: "label == 'Settings'"))
            .waitForExistence(timeout: 5) {
            Thread.sleep(forTimeInterval: 1)
            photograph("app-settings")
            assertNoBloem(app, in: "Settings")
        }

        let report = summary.joined(separator: "\n")
        try? report.write(toFile: "\(Self.shots)/pages.txt", atomically: true, encoding: .utf8)
        let attachment = XCTAttachment(string: report)
        attachment.name = "page results"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Add server form against the live address: it recognises a Silo server and offers its sign-in. The password is
    /// not typed here; the tour above signs in without it appearing in a typed string.
    @MainActor
    func testTheAddServerFormRecognisesAPlainSiloServer() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "--ui-testing-reset", "--ui-testing-auth=success", "-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-appearancePreference", "dark",
        ]
        app.launch()
        let add = app.buttons["server-list-add-server"]
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        XCTAssertTrue(app.navigationBars["Add a Silo server"].waitForExistence(timeout: 5))
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(address)
        app.buttons["Continue"].tap()

        XCTAssertTrue(app.staticTexts["Admin login"].waitForExistence(timeout: 30), "the server's sign-in options are offered")
        XCTAssertTrue(app.secureTextFields["Password"].exists)
        XCTAssertFalse(app.staticTexts["That address isn't a Silo server. Check it and try again."].exists)
        photograph("add-server-sign-in")
        assertNoBloem(app, in: "Add server")
    }

    // MARK: One page

    /// Opens a page from the menu, waits for it to settle and reports how it ended.
    @MainActor
    private func visit(_ app: XCUIApplication, id: String, prefix: String) -> String {
        openMenu(app)
        let row = app.buttons["shell-destination:\(id)"]
        scrollMenuTo(row, app: app)
        guard row.waitForExistence(timeout: 5) else {
            XCTFail("\(prefix): \(id) is not in the menu")
            closeMenu(app)
            return "\(prefix) \(id): NOT IN MENU"
        }
        let label = row.label
        row.tap()
        waitUntilSettled(app)
        photograph("\(prefix)-\(id)")

        var findings = failureMarkers(app)
        let bloem = bloemText(app)
        if !bloem.isEmpty { findings.append("mentions Bloem: \(bloem.joined(separator: " | "))") }
        for finding in findings { XCTFail("\(prefix) \(label): \(finding)") }
        if findings.isEmpty {
            let unavailable = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'not available on this server' OR label CONTAINS[c] 'isn’t available on this server' OR label CONTAINS[c] 'This server has no'")).firstMatch
            return "\(prefix) \(label): " + (unavailable.exists ? "not on this server (\(unavailable.label))" : "loaded")
        }
        return "\(prefix) \(label): FAILED (\(findings.joined(separator: "; ")))"
    }

    /// Waits until the page has stopped loading: no spinner for a moment, within 40 seconds.
    @MainActor
    private func waitUntilSettled(_ app: XCUIApplication) {
        Thread.sleep(forTimeInterval: 1.5)
        let deadline = Date().addingTimeInterval(40)
        var quiet = 0
        while Date() < deadline {
            quiet = app.activityIndicators.count == 0 ? quiet + 1 : 0
            if quiet >= 3 { break }
            Thread.sleep(forTimeInterval: 0.7)
        }
    }

    /// What a page that could not load shows (see `LoadFailureView` and `ServerSectionFailureView`).
    @MainActor
    private func failureMarkers(_ app: XCUIApplication) -> [String] {
        var found: [String] = []
        for text in ["Signed out", "No access", "Can't reach the server", "Unexpected response"] where app.staticTexts[text].exists {
            found.append("shows \"\(text)\"")
        }
        if app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Server error'")).firstMatch.exists {
            found.append("shows a server error")
        }
        if app.buttons["Try again"].exists { found.append("offers \"Try again\"") }
        return found
    }

    // MARK: Words on screen

    /// Anything on screen that names Bloem.
    @MainActor
    private func bloemText(_ app: XCUIApplication) -> [String] {
        let predicate = NSPredicate(format: "label CONTAINS[c] 'bloem'")
        var found: [String] = []
        for query in [app.staticTexts, app.buttons, app.navigationBars, app.textFields, app.searchFields] {
            found += query.matching(predicate).allElementsBoundByIndex.prefix(5).map(\.label)
        }
        return found
    }

    @MainActor
    private func assertNoBloem(_ app: XCUIApplication, in place: String) {
        let found = bloemText(app)
        XCTAssertTrue(found.isEmpty, "\(place) mentions Bloem: \(found)")
    }

    // MARK: Menu and screenshots

    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["shell-menu-button"]
        if button.waitForExistence(timeout: 5) { button.tap() }
        XCTAssertTrue(app.buttons["shell-manage-servers"].waitForExistence(timeout: 5), "the menu is open")
    }

    @MainActor
    private func closeMenu(_ app: XCUIApplication) {
        guard UIDevice.current.userInterfaceIdiom != .pad else { return }
        let scrim = app.buttons["shell-menu-scrim"]
        if scrim.exists { scrim.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap() }
        _ = app.buttons["shell-manage-servers"].waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func scrollMenuTo(_ row: XCUIElement, app: XCUIApplication) {
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 5 {
            app.swipeUp()
            swipes += 1
        }
    }

    @MainActor
    private func photograph(_ name: String) {
        Thread.sleep(forTimeInterval: 0.6)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let screenshot = XCUIScreen.main.screenshot()
        let path = "\(Self.shots)/\(name)-\(device).png"
        do { try screenshot.pngRepresentation.write(to: URL(fileURLWithPath: path)) } catch { XCTFail("could not write \(path): \(error)") }
    }
}
