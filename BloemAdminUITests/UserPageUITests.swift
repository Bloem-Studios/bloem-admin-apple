import XCTest

/// The User page, driven through the debug-only fixture server (`--ui-testing-user-page`): the viewer
/// is the admin "alice" (id 1), "root" is the server owner, "erin" another admin, "carol" signs in
/// through an external provider and "dave" is disabled.
final class UserPageUITests: XCTestCase {
    private func launch(conflict: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-user-page"]
        if conflict { app.launchArguments.append("--ui-testing-user-conflict") }
        app.launch()
        return app
    }

    private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "user-row-\(name)").firstMatch
    }

    @discardableResult
    private func openUser(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let target = row(name, in: app)
        XCTAssertTrue(target.waitForExistence(timeout: 10), "\(name)'s row is listed")
        target.tap()
        let back = app.buttons["user-page-back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "the User page opened")
        return back
    }

    private func tab(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["user-tab-\(name)"]
    }

    /// Puts the keyboard away with the page's own Done button, so what is below it can be tapped.
    @MainActor
    private func endEditing(in app: XCUIApplication) {
        let done = app.buttons["user-page-keyboard-done"]
        if done.waitForExistence(timeout: 2) { done.tap() }
    }

    /// Dismisses a confirmation dialog without confirming: its cancel button when this iOS shows one,
    /// otherwise a tap outside it, which is how a person dismisses a dialog that has none.
    @MainActor
    private func dismissDialog(cancelLabel: String, titled title: String, in app: XCUIApplication) {
        let cancel = app.buttons[cancelLabel]
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.45)).tap()
        }
        XCTAssertTrue(app.staticTexts[title].waitForNonExistence(timeout: 5), "\(title) closed")
    }

    private func swipe(left: Bool, in app: XCUIApplication) {
        let page = app.descendants(matching: .any)["user-page-swipe"]
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        if left { page.swipeLeft() } else { page.swipeRight() }
    }

    // MARK: - List and header

    @MainActor
    func testARowShowsNameEmailRoleAndStatusAndOpensThePage() {
        let app = launch()
        let bob = row("bob", in: app)
        XCTAssertTrue(bob.waitForExistence(timeout: 10))
        for part in ["bob", "bob@example.test", "User"] {
            XCTAssertTrue(bob.label.contains(part), "the row says \(part): \(bob.label)")
        }

        bob.tap()

        XCTAssertTrue(app.buttons["user-page-back"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Disabled"].exists, "an enabled account carries no status")
        XCTAssertTrue(app.staticTexts["Password sign-in"].exists)
        XCTAssertTrue(app.buttons["Reset password"].exists)
        XCTAssertTrue(app.buttons["Disable account"].exists)
        XCTAssertTrue(app.buttons["Delete account"].exists)
        XCTAssertFalse(app.buttons["Set password"].exists)
        XCTAssertFalse(app.buttons["View as"].exists, "there is no View as")
    }

    @MainActor
    func testYourOwnAccountCannotBeDisabledOrDeleted() {
        let app = launch()
        openUser("alice", in: app)
        XCTAssertTrue(app.buttons["Reset password"].exists)
        XCTAssertFalse(app.buttons["Disable account"].exists)
        XCTAssertFalse(app.buttons["Delete account"].exists)
    }

    @MainActor
    func testTheOwnerAndAnotherAdminAreViewOnly() {
        let app = launch()
        openUser("root", in: app)
        XCTAssertTrue(app.staticTexts["This is the server owner. Only the owner can change this account."].exists)
        XCTAssertFalse(app.buttons["Reset password"].exists)
        XCTAssertFalse(app.buttons["Delete account"].exists)
        app.buttons["user-page-back"].tap()

        openUser("erin", in: app)
        XCTAssertTrue(app.staticTexts["Only the server owner can change another admin account. You can view it."].exists)
        XCTAssertFalse(app.buttons["Disable account"].exists)
    }

    @MainActor
    func testAnExternalSignInAccountOffersSetPasswordAndShowsTheTemporaryBadge() {
        let app = launch()
        openUser("carol", in: app)
        XCTAssertTrue(app.staticTexts["External sign-in"].exists)
        XCTAssertTrue(app.staticTexts["Temporary password"].exists)
        XCTAssertTrue(app.buttons["Set password"].exists)
        XCTAssertFalse(app.buttons["Reset password"].exists)
    }

    @MainActor
    func testADisabledAccountOffersEnable() {
        let app = launch()
        openUser("dave", in: app)
        XCTAssertTrue(app.staticTexts["Disabled"].exists)
        XCTAssertTrue(app.buttons["Enable account"].exists)
        XCTAssertFalse(app.buttons["Disable account"].exists)
    }

    @MainActor
    func testDisablingAsksFirstThenDisablesTheAccount() {
        let app = launch()
        openUser("bob", in: app)
        app.buttons["Disable account"].tap()
        XCTAssertTrue(app.staticTexts["Disable bob?"].waitForExistence(timeout: 5))
        dismissDialog(cancelLabel: "Cancel", titled: "Disable bob?", in: app)
        XCTAssertFalse(app.staticTexts["Disabled"].exists, "cancelling changes nothing")

        app.buttons["Disable account"].tap()
        XCTAssertTrue(app.staticTexts["Disable bob?"].waitForExistence(timeout: 5))
        // The alert's own button, not the page's button of the same name behind it.
        let confirm = app.alerts.buttons["Disable account"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.buttons["Enable account"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Disabled"].exists)
    }

    // MARK: - Tabs and the swipe

    @MainActor
    func testTheTabsAreOverviewAccessSignInActivityDownloadsAndPreferences() {
        let app = launch()
        openUser("bob", in: app)
        for name in ["overview", "access", "signIn", "activity", "downloads", "preferences"] {
            XCTAssertTrue(tab(name, in: app).exists, "\(name) tab")
        }
        XCTAssertTrue(tab("overview", in: app).isSelected)
        XCTAssertTrue(app.staticTexts["Details"].exists)
    }

    @MainActor
    func testASidewaysSwipeChangesTheTabAndNeverLeavesThePage() {
        let app = launch()
        openUser("bob", in: app)

        // Before the first tab there is nothing: the page stays.
        swipe(left: false, in: app)
        XCTAssertTrue(app.buttons["user-page-back"].exists)
        XCTAssertTrue(tab("overview", in: app).isSelected)

        swipe(left: true, in: app)
        XCTAssertTrue(tab("access", in: app).isSelected)
        swipe(left: true, in: app)
        XCTAssertTrue(tab("signIn", in: app).isSelected)
        swipe(left: false, in: app)
        XCTAssertTrue(tab("access", in: app).isSelected)
        XCTAssertTrue(app.buttons["user-page-back"].exists, "a swipe never goes back")
        XCTAssertFalse(row("bob", in: app).exists, "the list is not showing")
    }

    @MainActor
    func testTheSignInTabListsSessionsAndDevicesWithRevoke() {
        let app = launch()
        openUser("bob", in: app)
        tab("signIn", in: app).tap()
        XCTAssertTrue(app.staticTexts["Sessions"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Revoke all sessions"].exists)
        XCTAssertTrue(app.buttons["Revoke"].exists)
        XCTAssertTrue(app.staticTexts["Devices"].exists)
        XCTAssertTrue(app.staticTexts["Living room TV"].firstMatch.exists)
    }

    @MainActor
    func testTheActivityPreferencesAndDownloadsTabsShowTheirData() {
        let app = launch()
        openUser("bob", in: app)

        tab("activity", in: app).tap()
        XCTAssertTrue(app.staticTexts["The Long Film"].waitForExistence(timeout: 10))
        tab("downloads", in: app).tap()
        XCTAssertTrue(app.staticTexts["Offline Episode"].waitForExistence(timeout: 10))
        tab("preferences", in: app).tap()
        XCTAssertTrue(app.staticTexts["Autoplay next episode"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.switches["Autoplay next episode"].exists, "a boolean setting is edited with a switch")
    }

    // MARK: - Leaving the page

    @MainActor
    func testBackAsksBeforeDroppingUnsavedAccessEdits() {
        let app = launch()
        openUser("bob", in: app)
        tab("access", in: app).tap()
        let field = app.textFields["Max streams"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("5")

        app.buttons["user-page-back"].tap()
        XCTAssertTrue(app.staticTexts["Discard changes?"].waitForExistence(timeout: 5))
        dismissDialog(cancelLabel: "Keep editing", titled: "Discard changes?", in: app)
        XCTAssertTrue(app.buttons["user-page-back"].exists, "still on the page")

        // The edit survives a trip to another tab.
        tab("overview", in: app).tap()
        tab("access", in: app).tap()
        XCTAssertEqual(app.textFields["Max streams"].value as? String, "5")

        app.buttons["user-page-back"].tap()
        XCTAssertTrue(app.staticTexts["Discard changes?"].waitForExistence(timeout: 5))
        app.buttons["Discard"].tap()
        XCTAssertTrue(row("bob", in: app).waitForExistence(timeout: 10))
    }

    @MainActor
    func testBackWithNothingUnsavedReturnsToTheListWithItsSearchKept() {
        let app = launch()
        let search = app.searchFields["Username or email"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("bob")
        XCTAssertTrue(row("bob", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(row("carol", in: app).exists)

        row("bob", in: app).tap()
        XCTAssertTrue(app.buttons["user-page-back"].waitForExistence(timeout: 10))
        app.buttons["user-page-back"].tap()

        XCTAssertTrue(row("bob", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(row("carol", in: app).exists, "the search is still applied")
        XCTAssertEqual(app.searchFields["Username or email"].value as? String, "bob")
    }

    @MainActor
    func testTheListKeepsItsScrollPositionWhenThePageCloses() {
        let app = launch()
        XCTAssertTrue(row("alice", in: app).waitForExistence(timeout: 10))
        let target = row("user30", in: app)
        var swipes = 0
        while !target.isHittable && swipes < 10 {
            app.swipeUp()
            swipes += 1
        }
        XCTAssertTrue(target.isHittable, "scrolled down to user30")

        target.tap()
        XCTAssertTrue(app.buttons["user-page-back"].waitForExistence(timeout: 10))
        app.buttons["user-page-back"].tap()

        XCTAssertTrue(target.waitForExistence(timeout: 10))
        XCTAssertTrue(target.isHittable, "still scrolled down")
        XCTAssertFalse(row("alice", in: app).isHittable, "the top of the list is not showing")
    }

    // MARK: - Access & limits

    @MainActor
    func testSavingAccessAfterSomeoneElseChangedItShowsTheConflictAndTheServersValues() {
        let app = launch(conflict: true)
        openUser("bob", in: app)
        tab("access", in: app).tap()
        let field = app.textFields["Max streams"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("5")
        endEditing(in: app)
        let save = app.buttons["Save changes"]
        XCTAssertTrue(save.isEnabled)

        save.tap()

        XCTAssertTrue(app.staticTexts["This user changed since it was loaded. Review it and try again."].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Max streams"].value as? String, "9", "the form shows the server's values")
        XCTAssertFalse(app.buttons["Save changes"].isEnabled, "nothing is pending any more")
    }

    @MainActor
    func testSavingAccessStoresTheChangeAndSaysSo() {
        let app = launch()
        openUser("bob", in: app)
        tab("access", in: app).tap()
        let field = app.textFields["Max streams"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(XCUIKeyboardKey.delete.rawValue)
        field.typeText("6")
        endEditing(in: app)

        app.buttons["Save changes"].tap()

        XCTAssertTrue(app.staticTexts["Saved"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["Max streams"].value as? String, "6")
        app.buttons["user-page-back"].tap()
        XCTAssertTrue(row("bob", in: app).waitForExistence(timeout: 10), "saved edits leave without asking")
    }
}
