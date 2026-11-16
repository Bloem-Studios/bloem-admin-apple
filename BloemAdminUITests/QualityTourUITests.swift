import UIKit
import XCTest

/// The quality audit's photographs: the app's pages from the debug fixtures, in dark and light, upright and held
/// sideways, at the default text size and at a very large one, on an iPhone and an iPad. It is not a check: it
/// asserts nothing and is skipped unless the marker file `/tmp/bloem-admin-quality-shots/phase` exists on the machine
/// running the simulator (`scripts/quality-shots.sh` writes it). The simulator shares that machine's file system, so
/// the images are written straight to `/tmp/bloem-admin-quality-shots/<phase>/<screen>-<variant>-<scheme>.png`.
///
/// Every page comes from a `--ui-testing-*` fixture: no server is contacted and no real data is shown. The launch
/// arguments are the ones `LookTourUITests` uses.
final class QualityTourUITests: XCTestCase {
    private static let root = "/tmp/bloem-admin-quality-shots"

    private var phase = ""

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let text = try? String(contentsOfFile: Self.root + "/phase", encoding: .utf8) else {
            throw XCTSkip("no quality run is wanted (no \(Self.root)/phase)")
        }
        phase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        try FileManager.default.createDirectory(atPath: "\(Self.root)/\(phase)", withIntermediateDirectories: true)
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // MARK: Variants

    private struct Variant {
        let name: String
        let landscape: Bool
        /// The system text size's launch name.
        let size: String
        let schemes: [(String, XCUIDevice.Appearance)]
    }

    private static let both: [(String, XCUIDevice.Appearance)] = [("dark", .dark), ("light", .light)]
    private static let light: [(String, XCUIDevice.Appearance)] = [("light", .light)]
    private static let large = "UICTContentSizeCategoryL"
    /// Accessibility 3: the third of the five accessibility sizes.
    private static let veryLarge = "UICTContentSizeCategoryAccessibilityXL"

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private var variants: [Variant] {
        if isPad {
            return [
                Variant(name: "ipad", landscape: false, size: Self.large, schemes: Self.both),
                Variant(name: "ipad-land", landscape: true, size: Self.large, schemes: Self.both),
                Variant(name: "ipad-ax", landscape: false, size: Self.veryLarge, schemes: Self.light),
            ]
        }
        return [
            Variant(name: "phone", landscape: false, size: Self.large, schemes: Self.both),
            Variant(name: "phone-ax", landscape: false, size: Self.veryLarge, schemes: Self.both),
            Variant(name: "phone-land", landscape: true, size: Self.large, schemes: Self.both),
            Variant(name: "phone-land-ax", landscape: true, size: Self.veryLarge, schemes: Self.light),
        ]
    }

    // MARK: Helpers

    private static let base = ["--ui-testing-reset", "--ui-testing-auth=success"]

    /// Runs `steps` once per variant and appearance, each time on a fresh launch.
    @MainActor
    private func tour(_ arguments: [String], settle: TimeInterval = 2.5, _ steps: (XCUIApplication, (String) -> Void) -> Void) {
        for variant in variants {
            XCUIDevice.shared.orientation = variant.landscape ? .landscapeLeft : .portrait
            for (scheme, appearance) in variant.schemes {
                XCUIDevice.shared.appearance = appearance
                let app = XCUIApplication()
                app.launchArguments = arguments + [
                    "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-appearancePreference", scheme,
                    "-UIPreferredContentSizeCategoryName", variant.size,
                ]
                app.launch()
                Thread.sleep(forTimeInterval: settle)
                steps(app) { name in
                    Thread.sleep(forTimeInterval: 0.8)
                    self.save(name: name, variant: variant.name, scheme: scheme, landscape: variant.landscape)
                }
                app.terminate()
            }
        }
    }

    private func save(name: String, variant: String, scheme: String, landscape: Bool) {
        let screenshot = XCUIScreen.main.screenshot()
        var png = screenshot.pngRepresentation
        // A screenshot is always taken in the device's own (upright) orientation, so a sideways page comes out lying on its
        // side: stand it up (the device was turned to the left).
        if landscape, let cgImage = screenshot.image.cgImage {
            let turned = UIImage(cgImage: cgImage, scale: screenshot.image.scale, orientation: .left)
            let upright = UIGraphicsImageRenderer(size: turned.size).image { _ in turned.draw(at: .zero) }
            png = upright.pngData() ?? png
        }
        let path = "\(Self.root)/\(phase)/\(name)-\(variant)-\(scheme).png"
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

    private func scrollDown(_ app: XCUIApplication, times: Int = 1) {
        for _ in 0..<times { app.swipeUp() }
        Thread.sleep(forTimeInterval: 0.6)
    }

    // MARK: Shell, servers and settings

    @MainActor
    func testShellAndServers() {
        tour(Self.base) { app, shot in
            shot("first-launch")
            openMenu(app)
            shot("menu")
        }
        tour(Self.base + ["--ui-testing-seed-servers"]) { app, shot in
            tap(app.buttons["shell-context"])
            shot("context-menu")
            app.tap()
            openMenu(app)
            tap(app.buttons["shell-manage-servers"], timeout: 2)
            shot("manage-servers")
            tap(app.buttons["server-list-add-server"], timeout: 3)
            shot("add-server")
            // The address field with the keyboard up, as a person would see it while typing.
            let field = app.textFields.firstMatch
            if field.waitForExistence(timeout: 3) {
                field.tap()
                field.typeText("silo.example.test")
                shot("add-server-typing")
            }
        }
        tour(Self.base + ["--ui-testing-seed-servers", "--ui-testing-admin-gate=authorized"]) { app, shot in
            tap(app.buttons["server-row:ui-alpha"], timeout: 3)
            Thread.sleep(forTimeInterval: 2)
            // The server's own Now playing page, with a server that does not answer.
            shot("now-playing-unreachable")
            openMenu(app)
            shot("menu-server")
        }
    }

    @MainActor
    func testAppSettingsAndLock() {
        tour(Self.base + ["--ui-testing-notifications=undetermined", "--ui-testing-seed-servers"]) { app, shot in
            openMenu(app)
            tap(app.buttons["shell-settings"], timeout: 3)
            shot("app-settings")
            scrollDown(app)
            shot("app-settings-2")
        }
        tour(["--ui-testing-reset", "--ui-testing-auth=unavailable"]) { _, shot in
            shot("lock")
        }
    }

    @MainActor
    func testSettingsPages() {
        tour(Self.base + ["--ui-testing-settings"]) { app, shot in
            shot("settings-list")
            scrollDown(app)
            shot("settings-list-2")
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
            scrollDown(app)
            shot("requests-2")
            openMenu(app)
            shot("menu-badge")
        }
        tour(Self.base + ["--ui-testing-user-page", "--ui-testing-user-support"]) { app, shot in
            tap(element(app, "user-row-bob"), timeout: 8)
            Thread.sleep(forTimeInterval: 1.5)
            shot("user-page")
            scrollDown(app)
            shot("user-page-2")
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
        }
    }
}
