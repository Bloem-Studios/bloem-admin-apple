import UIKit
import XCTest

/// Photographs the app's pages from the debug fixtures, in dark and light, for the before and after
/// screenshots under `docs/screenshots/bloem-look/`. It is not a check: it asserts nothing and is skipped
/// unless the marker file `/tmp/bloem-look-shots/phase` exists on the machine running the simulator (it
/// holds the folder name for this run, such as `before`). The simulator shares that machine's file system,
/// so the images are written straight to `/tmp/bloem-look-shots/<phase>/`.
///
/// Every page comes from a `--ui-testing-*` fixture: no server is contacted and no real data is shown.
final class LookTourUITests: XCTestCase {
    private static let root = "/tmp/bloem-look-shots"

    private var phase = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let text = try? String(contentsOfFile: Self.root + "/phase", encoding: .utf8) else {
            throw XCTSkip("no screenshot run is wanted (no \(Self.root)/phase)")
        }
        phase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(atPath: "\(Self.root)/\(phase)", withIntermediateDirectories: true)
    }

    // MARK: Helpers

    private static let base = ["--ui-testing-reset", "--ui-testing-auth=success"]

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    /// Runs `steps` once per appearance, each time on a fresh launch.
    @MainActor
    private func tour(_ arguments: [String], settle: TimeInterval = 2.5, _ steps: (XCUIApplication, (String) -> Void) -> Void) {
        for (scheme, appearance) in [("dark", XCUIDevice.Appearance.dark), ("light", .light)] {
            XCUIDevice.shared.appearance = appearance
            let app = XCUIApplication()
            // The app's own appearance setting as well as the device's, so a slot where the device setting does not
            // take still photographs the right theme.
            app.launchArguments = arguments + ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearancePreference", scheme]
            app.launch()
            Thread.sleep(forTimeInterval: settle)
            steps(app) { name in
                Thread.sleep(forTimeInterval: 0.8)
                self.save(name: name, scheme: scheme)
            }
            app.terminate()
        }
    }

    private func save(name: String, scheme: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let path = "\(Self.root)/\(phase)/\(name)-\(device)-\(scheme).png"
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { XCTFail("could not write \(path): \(error)") }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @discardableResult
    private func tap(_ target: XCUIElement, timeout: TimeInterval = 6) -> Bool {
        guard target.waitForExistence(timeout: timeout) else { return false }
        target.tap()
        return true
    }

    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["shell-menu-button"]
        if button.waitForExistence(timeout: 4) { button.tap() }
        _ = app.buttons["shell-manage-servers"].waitForExistence(timeout: 4)
    }

    /// Chooses a page from the shell menu (an iPhone drawer or an iPad sidebar).
    private func openPage(_ app: XCUIApplication, _ id: String) {
        openMenu(app)
        let row = app.buttons["shell-destination:\(id)"]
        var swipes = 0
        while !(row.exists && row.isHittable) && swipes < 4 {
            app.swipeUp()
            swipes += 1
        }
        tap(row, timeout: 3)
        Thread.sleep(forTimeInterval: 1.5)
    }

    private func scrollDown(_ app: XCUIApplication, times: Int = 1) {
        for _ in 0..<times { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
    }

    // MARK: Shell, servers and settings

    @MainActor
    func testShellAndServers() {
        tour(Self.base) { app, shot in
            shot("shell-now-playing-empty")
            openMenu(app)
            shot("shell-menu")
        }
        tour(Self.base + ["--ui-testing-seed-servers"]) { app, shot in
            tap(app.buttons["shell-context"])
            shot("shell-context-menu")
            app.tap()
            openMenu(app)
            tap(app.buttons["shell-manage-servers"], timeout: 2)
            shot("manage-servers")
            tap(app.buttons["server-list-add-server"], timeout: 3)
            shot("add-server")
        }
        tour(Self.base + ["--ui-testing-seed-servers", "--ui-testing-admin-gate=authorized"]) { app, shot in
            tap(app.buttons["server-row:ui-alpha"], timeout: 3)
            Thread.sleep(forTimeInterval: 2)
            shot("server-page-unreachable")
            openMenu(app)
            shot("shell-menu-server")
        }
    }

    @MainActor
    func testAppSettingsLockAndAlerts() {
        tour(Self.base + ["--ui-testing-notifications=undetermined", "--ui-testing-seed-servers"]) { app, shot in
            openMenu(app)
            tap(app.buttons["shell-settings"], timeout: 3)
            shot("app-settings")
            scrollDown(app)
            shot("app-settings-2")
        }
        tour(["--ui-testing-reset", "--ui-testing-auth=unavailable"]) { _, shot in
            shot("lock-screen")
        }
    }

    @MainActor
    func testSettingsPages() {
        tour(Self.base + ["--ui-testing-settings"]) { app, shot in
            shot("settings-list")
            scrollDown(app)
            shot("settings-list-2")
            scrollDown(app, times: 3)
            shot("settings-list-3")
        }
    }

    // MARK: Live pages

    @MainActor
    func testDashboardAndStreams() {
        tour(["--ui-testing-dashboard-fixture"]) { app, shot in
            shot("dashboard-1")
            scrollDown(app, times: 2)
            shot("dashboard-2")
            scrollDown(app, times: 2)
            shot("dashboard-3")
            scrollDown(app, times: 2)
            shot("dashboard-4")
        }
        tour(["--ui-testing-stream-rows"]) { app, shot in
            shot("now-playing-rows")
            scrollDown(app)
            shot("now-playing-rows-2")
        }
    }

    // MARK: People and requests

    @MainActor
    func testPeopleAndRequests() {
        let args = Self.base + ["--ui-testing-user-page", "--ui-testing-people-shell"]
        tour(args) { app, shot in
            _ = element(app, "request-view-needs_approval").waitForExistence(timeout: 8)
            shot("requests")
            openMenu(app)
            shot("shell-menu-badge")
            app.buttons["shell-destination:work.requests"].tap()
            Thread.sleep(forTimeInterval: 1)
            openPage(app, "people.users")
            shot("users")
            tap(element(app, "user-row-bob"), timeout: 4)
            Thread.sleep(forTimeInterval: 1.5)
            shot("user-overview")
            scrollDown(app)
            shot("user-overview-2")
            openPage(app, "system.api-keys")
            shot("api-keys")
        }
        tour(Self.base + ["--ui-testing-user-page", "--ui-testing-people-shell", "--ui-testing-requests-unavailable"]) { _, shot in
            shot("requests-unavailable")
        }
        tour(Self.base + ["--ui-testing-user-page", "--ui-testing-user-support"]) { app, shot in
            tap(element(app, "user-row-bob"), timeout: 8)
            Thread.sleep(forTimeInterval: 1.5)
            shot("user-page-support")
        }
    }

    // MARK: History, logs, audit and automation

    @MainActor
    func testIncidentPages() {
        tour(Self.base + ["--ui-testing-incident-pages"]) { app, shot in
            shot("history")
            tap(app.buttons["fixture-page-logs"], timeout: 3)
            Thread.sleep(forTimeInterval: 1.5)
            shot("logs")
            tap(app.buttons["fixture-page-audit"], timeout: 3)
            Thread.sleep(forTimeInterval: 1.5)
            shot("audit")
            tap(app.buttons["fixture-page-history"], timeout: 3)
            Thread.sleep(forTimeInterval: 1.5)
            let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'history-row'")).firstMatch
            tap(row, timeout: 3)
            shot("history-detail")
        }
    }

    @MainActor
    func testAutomationPages() {
        for page in ["tasks", "nodes", "backups", "plugins"] {
            tour(Self.base + ["--ui-testing-automation=\(page)"]) { _, shot in
                shot("automation-\(page)")
            }
        }
    }

    // MARK: Libraries and organizations

    @MainActor
    func testLibraries() {
        tour(Self.base + ["--ui-testing-libraries"]) { app, shot in
            shot("libraries")
            scrollDown(app)
            shot("libraries-2")
        }
    }

    @MainActor
    func testOrganizations() {
        tour(Self.base + ["--ui-testing-organization"]) { app, shot in
            shot("organization-menu")
            tap(element(app, "organization-menu-people"), timeout: 4)
            Thread.sleep(forTimeInterval: 1.5)
            shot("organization-people")
        }
        tour(Self.base + ["--ui-testing-platform-organizations"]) { app, shot in
            shot("platform-organizations")
            scrollDown(app)
            shot("platform-organizations-2")
        }
        tour(Self.base + ["--ui-testing-organization=suspended"]) { _, shot in
            shot("organization-suspended")
        }
    }
}
