import UIKit
import XCTest

/// Bulk triage, the Requests menu badge, the unavailable page, the API keys page, and the User page's reset link,
/// temporary password, Profiles and Watching now, all driven through the debug-only fixture server
/// (`--ui-testing-user-page`, with `--ui-testing-people-shell` for the real shell). In the fixture five requests wait for
/// approval; "Severance" cannot be answered, as if another admin got there first. "bob" has a Main profile with a PIN
/// and a Kids profile, and is watching a film.
final class PeopleUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Launching and finding

    private func launchShell(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-user-page", "--ui-testing-people-shell"] + extra
        app.launch()
        return app
    }

    private func launchUserPage() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-user-page", "--ui-testing-user-support"]
        app.launch()
        return app
    }

    /// A static text anywhere on screen whose label contains `text`: a container's own label is empty, its texts are not.
    private func text(containing text: String, in app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func isPad() -> Bool { UIDevice.current.userInterfaceIdiom == .pad }

    /// Opens the drawer on iPhone; the iPad sidebar is already open.
    @MainActor
    private func openMenu(_ app: XCUIApplication) {
        let button = app.buttons["shell-menu-button"]
        if button.waitForExistence(timeout: 5) { button.tap() }
        XCTAssertTrue(app.buttons["shell-manage-servers"].waitForExistence(timeout: 5), "the menu is open")
    }

    @MainActor
    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        return XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor
    private func openBob(in app: XCUIApplication) {
        let row = element("user-row-bob", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "bob's row is listed")
        row.tap()
        XCTAssertTrue(app.buttons["user-page-back"].waitForExistence(timeout: 10), "the User page opened")
    }

    // MARK: Requests menu badge

    @MainActor
    func testTheRequestsMenuItemShowsHowManyRequestsNeedApproval() {
        let app = launchShell()
        XCTAssertTrue(element("request-view-needs_approval", in: app).waitForExistence(timeout: 10), "the queue opened")

        openMenu(app)

        let badge = element("shell-menu-badge", in: app)
        XCTAssertTrue(badge.waitForExistence(timeout: 10))
        XCTAssertEqual(badge.label, "5")
        XCTAssertTrue(
            waitForLabel(app.buttons["shell-destination:work.requests"], containing: "5 requests need approval"),
            "the badge is said in words too"
        )
    }

    // MARK: Bulk triage

    @MainActor
    func testApprovingOneSelectedRequestSendsItAndTheBadgeFollows() {
        let app = launchShell()
        XCTAssertTrue(element("bulk-select", in: app).waitForExistence(timeout: 10))
        element("bulk-select", in: app).tap()
        XCTAssertTrue(element("bulk-selected-count", in: app).waitForExistence(timeout: 5))
        XCTAssertEqual(element("bulk-selected-count", in: app).label, "None selected")
        XCTAssertFalse(element("bulk-approve", in: app).isEnabled, "nothing is selected, so nothing can be sent")

        let first = element("request-row-r1", in: app)
        XCTAssertTrue(first.waitForExistence(timeout: 5))
        first.tap()
        XCTAssertTrue(waitForLabel(element("bulk-selected-count", in: app), containing: "1 selected"))
        XCTAssertTrue(waitForLabel(element("bulk-approve", in: app), containing: "Approve 1"))
        element("bulk-approve", in: app).tap()

        XCTAssertTrue(text(containing: "1 request approved", in: app).waitForExistence(timeout: 10), "the result says what happened")
        XCTAssertTrue(element("bulk-select", in: app).waitForExistence(timeout: 10), "select mode ended: everything went through")

        openMenu(app)
        XCTAssertEqual(element("shell-menu-badge", in: app).label, "4", "one request left the queue")
    }

    @MainActor
    func testDecliningAllWithANoteLeavesTheRequestThatCouldNotBeAnsweredSelected() {
        let app = launchShell()
        XCTAssertTrue(element("bulk-select", in: app).waitForExistence(timeout: 10))
        element("bulk-select", in: app).tap()
        let selectAll = element("bulk-select-all", in: app)
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        XCTAssertEqual(selectAll.label, "Select all 5 shown")
        selectAll.tap()
        XCTAssertTrue(waitForLabel(element("bulk-selected-count", in: app), containing: "5 selected"))
        XCTAssertTrue(waitForLabel(element("bulk-decline", in: app), containing: "Decline 5"))

        element("bulk-decline", in: app).tap()
        XCTAssertTrue(app.alerts["Decline 5 requests"].waitForExistence(timeout: 5))
        let note = app.alerts.textFields.firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.tap()
        note.typeText("already in the library")
        app.alerts.buttons["Decline 5"].tap()

        XCTAssertTrue(text(containing: "4 of 5 requests declined", in: app).waitForExistence(timeout: 10), "four went through")
        XCTAssertTrue(
            text(containing: "Severance: Someone else already answered this request.", in: app).exists,
            "the one that failed is named, with its reason"
        )
        XCTAssertTrue(waitForLabel(element("bulk-selected-count", in: app), containing: "1 selected"), "it stays selected to try again")
        XCTAssertTrue(element("bulk-done", in: app).exists, "still in select mode")

        element("bulk-done", in: app).tap()
        XCTAssertTrue(element("bulk-select", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("bulk-progress", in: app).exists, "leaving select mode forgets the result")
        XCTAssertFalse(text(containing: "requests declined", in: app).exists)
    }

    // MARK: Unavailable

    @MainActor
    func testARequestPageOnAServerWithoutRequestAdministrationSaysSoAndOffersNoRetry() {
        let app = launchShell(["--ui-testing-requests-unavailable"])

        let message = element("requests-unavailable", in: app)
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForLabel(message, containing: "Request administration isn't available on this server"))
        XCTAssertFalse(app.buttons["Try again"].exists, "nothing to retry")
        XCTAssertFalse(app.buttons["Try again"].exists)
        XCTAssertFalse(element("request-view-needs_approval", in: app).exists, "no queue views either")

        openMenu(app)
        XCTAssertFalse(element("shell-menu-badge", in: app).exists, "and no badge")
    }

    // MARK: API keys

    @MainActor
    func testTheAPIKeysPageListsKeysWithOwnerScopeAndLastUsedAndRevokesOneAfterAsking() {
        let app = launchShell()
        openMenu(app)
        let page = app.buttons["shell-destination:system.api-keys"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        XCTAssertEqual(page.label, "API keys")
        page.tap()

        let backup = element("api-key-row-k1", in: app)
        XCTAssertTrue(backup.waitForExistence(timeout: 10))
        for text in ["Backup script", "Owner: bob", "Full access", "Last used"] {
            XCTAssertTrue(backup.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, "\(text) is on the first key")
        }
        let widget = element("api-key-row-k2", in: app)
        XCTAssertTrue(widget.staticTexts["2 scopes: library.read, stats.read"].exists)
        XCTAssertTrue(widget.staticTexts["Elevated rate limit"].exists)
        XCTAssertTrue(element("api-key-row-k3", in: app).staticTexts["Never used"].exists)

        element("api-key-revoke-k3", in: app).tap()
        XCTAssertTrue(app.alerts["Revoke Old importer?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Keep key"].tap()
        XCTAssertTrue(element("api-key-row-k3", in: app).exists, "keeping it changes nothing")

        element("api-key-revoke-k3", in: app).tap()
        XCTAssertTrue(app.alerts["Revoke Old importer?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Revoke key"].tap()

        XCTAssertTrue(waitForLabel(element("api-keys-notice", in: app), containing: "Revoked Old importer"))
        XCTAssertFalse(element("api-key-row-k3", in: app).exists, "the key left the list")
        XCTAssertTrue(element("api-key-row-k1", in: app).exists, "the others stay")
    }

    // MARK: Reset link and temporary password

    @MainActor
    func testACreatedResetLinkIsShownOnceAndForgottenOnDone() {
        let app = launchUserPage()
        openBob(in: app)

        app.buttons["Reset password"].tap()
        let create = app.buttons["reset-create-link"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["reset-send-email"].exists, "the email option is still there")
        XCTAssertTrue(app.buttons["reset-set-temporary"].exists, "and so is the temporary password")
        create.tap()

        let link = element("reset-link-url", in: app)
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        XCTAssertTrue(link.label.contains("fixture-token-4821"), "the link is shown: \(link.label)")
        XCTAssertTrue(app.buttons["reset-link-copy"].exists)
        XCTAssertTrue(app.buttons["Share link"].exists)
        XCTAssertFalse(app.buttons["reset-create-link"].exists, "a second link is not offered")
        app.buttons["reset-link-copy"].tap()
        XCTAssertEqual(app.buttons["reset-link-copy"].label, "Link copied")

        app.buttons["reset-link-done"].tap()
        XCTAssertTrue(app.buttons["Reset password"].waitForExistence(timeout: 5), "the sheet closed")
        app.buttons["Reset password"].tap()
        XCTAssertTrue(app.buttons["reset-create-link"].waitForExistence(timeout: 10), "a fresh sheet offers a link again")
        XCTAssertFalse(element("reset-link-url", in: app).exists, "and shows no link: it was forgotten")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "fixture-token-4821")).firstMatch.exists)
    }

    @MainActor
    func testSetTemporaryPasswordFromResetPasswordSetsOneThatMustBeChanged() {
        let app = launchUserPage()
        openBob(in: app)

        app.buttons["Reset password"].tap()
        let temporary = app.buttons["reset-set-temporary"]
        XCTAssertTrue(temporary.waitForExistence(timeout: 10))
        temporary.tap()

        XCTAssertTrue(app.navigationBars["Set a temporary password"].waitForExistence(timeout: 10))
        let field = app.secureTextFields["New password"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("temp-pass-1234")
        app.buttons["Set password"].tap()

        XCTAssertTrue(
            app.staticTexts["bob can sign in with the new password and must change it at the next sign-in."].waitForExistence(timeout: 10),
            "the page says what was set"
        )
        XCTAssertTrue(app.staticTexts["Temporary password"].waitForExistence(timeout: 10), "and the header now shows the badge")
    }

    // MARK: Profiles

    @MainActor
    func testTheProfilesTabAddsRenamesClearsAPinAndRemoves() {
        let app = launchUserPage()
        openBob(in: app)

        let tab = app.buttons["user-tab-profiles"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "the server can manage profiles, so the tab is there")
        tab.tap()
        let main = element("profile-row-p1", in: app)
        XCTAssertTrue(main.waitForExistence(timeout: 10))
        XCTAssertTrue(main.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Main profile · PIN set")).firstMatch.exists)
        XCTAssertTrue(element("profile-row-p-kids", in: app).staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Children's profile · No PIN")).firstMatch.exists)
        XCTAssertFalse(element("profile-remove-p1", in: app).exists, "the main profile cannot be removed")

        element("profiles-add", in: app).tap()
        let name = element("profile-name-field", in: app)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Guest")
        element("profile-sheet-save", in: app).tap()
        XCTAssertTrue(waitForLabel(element("profiles-notice", in: app), containing: "Profile Guest added"))
        XCTAssertTrue(element("profile-row-p-101", in: app).waitForExistence(timeout: 5), "the new profile is listed")

        element("profile-clear-pin-p1", in: app).tap()
        XCTAssertTrue(app.alerts["Clear the PIN on Main?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Clear PIN"].tap()
        XCTAssertTrue(waitForLabel(element("profiles-notice", in: app), containing: "PIN cleared on Main"))
        XCTAssertFalse(element("profile-clear-pin-p1", in: app).exists, "it has no PIN to clear now")

        element("profile-remove-p-kids", in: app).tap()
        XCTAssertTrue(app.alerts["Remove Kids?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Remove profile"].tap()
        XCTAssertTrue(waitForLabel(element("profiles-notice", in: app), containing: "Profile Kids removed"))
        XCTAssertFalse(element("profile-row-p-kids", in: app).exists)
    }

    // MARK: Watching now, last seen and expiry

    @MainActor
    func testTheOverviewShowsWhatTheAccountIsWatchingAndTheSignInTabWhenSessionsWereLastSeen() {
        let app = launchUserPage()
        openBob(in: app)

        XCTAssertTrue(app.staticTexts["Watching now · 1 stream"].waitForExistence(timeout: 10), "the card counts what is playing")
        let row = element("watching-now-s-bob-1", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("The Long Film"), row.label)
        XCTAssertTrue(row.label.contains("Playing"), "playing is said in words: \(row.label)")
        XCTAssertTrue(app.staticTexts["Watching now · 1 stream"].exists)

        app.buttons["user-tab-signIn"].tap()
        let lastSeen = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Last seen ")).firstMatch
        XCTAssertTrue(lastSeen.waitForExistence(timeout: 10), "a session says when it was last seen")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH %@", "Expires ", "Expired ")).firstMatch.exists, "and when it expires")
    }
}
