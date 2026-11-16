import XCTest

/// Platform › Organizations, driven through the real pages over an in-process stub server
/// (`--ui-testing-platform-organizations`): the list with search, filter and paging; one organization's page with its
/// owner and members; Suspend and Reactivate with their confirmations; and a plan change confirmed from its preview.
final class PlatformOrganizationsUITests: XCTestCase {
    private let riverside = "platform-organization-30000000-0000-0000-0000-000000000006"
    private let harbor = "platform-organization-30000000-0000-0000-0000-000000000004"

    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", "--ui-testing-platform-organizations"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Opens Riverside Club's page from the list (searching puts it on screen without scrolling).
    @MainActor
    private func openRiverside(_ app: XCUIApplication) {
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("river")
        let row = element(app, riverside)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Riverside Club is found by its short name")
        row.tap()
        XCTAssertTrue(element(app, "platform-organization-detail").waitForExistence(timeout: 10))
    }

    /// Scrolls the organization's page until `identifier` is on screen: the plan sits below the members.
    @MainActor
    private func scrollTo(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let target = element(app, identifier)
        for _ in 0..<8 where !(target.exists && target.isHittable) {
            app.swipeUp()
        }
        if !target.exists {
            let seen = app.staticTexts.allElementsBoundByIndex.prefix(60).map(\.label).joined(separator: " | ")
            XCTFail("\(identifier) is not on the page. Texts on screen: \(seen)")
        }
        return target
    }

    /// Swipes until `target` is clear of the bottom of the screen. On an iPhone the search field floats over the
    /// bottom of the list: a control under it still counts as hittable, but the field takes the tap.
    @MainActor
    private func bringAboveSearchBar(_ target: XCUIElement, in app: XCUIApplication) {
        let screen = app.windows.firstMatch.frame
        for _ in 0..<6 where !(target.exists && target.isHittable && target.frame.maxY < screen.maxY - 120) {
            app.swipeUp()
        }
        XCTAssertTrue(target.isHittable, "\(target) is on screen")
    }

    /// The button of a confirmation: an alert on an iPhone, a popover on an iPad.
    @MainActor
    private func confirmationButton(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            for container in [app.alerts, app.sheets, app.popovers] where container.buttons[title].exists {
                return container.buttons[title]
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return app.alerts.buttons[title]
    }

    // MARK: The list

    @MainActor
    func testTheListShowsStatusAndCountsInWordsAndPagesOnRequest() throws {
        let app = launch()

        XCTAssertTrue(element(app, "platform-organizations-page").waitForExistence(timeout: 10))
        let first = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ashford Film Society'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertTrue(first.label.contains("Active"), "the status is a word: \(first.label)")
        XCTAssertTrue(first.label.contains("3 people · 4 profiles · 3 libraries"), "the counts are said: \(first.label)")
        XCTAssertFalse(element(app, riverside).exists, "the second page has not been asked for")

        let more = element(app, "platform-organizations-more")
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        bringAboveSearchBar(more, in: app)
        more.tap()

        XCTAssertTrue(element(app, riverside).waitForExistence(timeout: 10), "Show more adds the next page")
        XCTAssertFalse(more.exists, "nothing left to ask for")
    }

    @MainActor
    func testSearchNarrowsTheListAndANoMatchSaysSo() throws {
        let app = launch()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("willow")

        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Willow Co-op'")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ashford'")).firstMatch.exists)

        search.clearAndTypeText("zzzz")

        XCTAssertTrue(element(app, "platform-organizations-empty").waitForExistence(timeout: 10))
    }

    @MainActor
    func testTheStatusFilterShowsOnlySuspendedOrganizations() throws {
        let app = launch()
        let picker = element(app, "platform-organizations-status")
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.tap()
        app.buttons["Suspended"].firstMatch.tap()

        XCTAssertTrue(element(app, harbor).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Ashford'")).firstMatch.exists)
        XCTAssertTrue(element(app, harbor).label.contains("Suspended"))
    }

    // MARK: One organization

    @MainActor
    func testAnOrganizationShowsItsOwnerByNameAndItsMembersWithRoleAndStatus() throws {
        let app = launch()
        openRiverside(app)

        XCTAssertTrue(element(app, "platform-organization-owner").label.hasSuffix("avery"), "the owner is named, never 'Account 4'")
        XCTAssertTrue(element(app, "platform-organization-status").label.hasSuffix("Active"))
        let avery = element(app, "platform-organization-member-m-avery")
        XCTAssertTrue(avery.waitForExistence(timeout: 10))
        XCTAssertTrue(avery.label.contains("Owner · Active"), avery.label)
        XCTAssertTrue(element(app, "platform-organization-member-m-sam").label.contains("Member · Active"))
        XCTAssertTrue(element(app, "platform-organization-member-m-jo").label.contains("Member · Suspended"))
    }

    @MainActor
    func testOpenAsAdministratorIsOfferedOnlyForAnOrganizationTheAccountAdministers() throws {
        let app = launch()
        openRiverside(app)
        let open = element(app, "platform-organization-open")
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        open.tap()
        XCTAssertTrue(element(app, "ui-test-opened-organization").waitForExistence(timeout: 5), "tapping enters organization mode for it")

        app.buttons["BackButton"].firstMatch.tap()
        let search = app.searchFields.firstMatch
        search.clearAndTypeText("harbor")
        let harborRow = element(app, harbor)
        XCTAssertTrue(harborRow.waitForExistence(timeout: 10))
        harborRow.tap()
        XCTAssertTrue(element(app, "platform-organization-detail").waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "platform-organization-open").exists, "Harbor Studio is not one the account administers")
    }

    // MARK: Suspend and reactivate

    @MainActor
    func testSuspendingAsksFirstSaysWhoLosesAccessAndThenReactivatingBringsItBack() throws {
        let app = launch()
        openRiverside(app)
        let suspend = element(app, "platform-organization-suspend")
        XCTAssertTrue(suspend.waitForExistence(timeout: 10))
        suspend.tap()

        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))
        let consequence = app.alerts.firstMatch.staticTexts
            .matching(NSPredicate(format: "label CONTAINS '10 active members lose access to Riverside Club until you reactivate it'")).firstMatch
        XCTAssertTrue(consequence.exists, "the confirmation says what happens to its people")
        XCTAssertTrue(element(app, "platform-organization-status").label.hasSuffix("Active"), "nothing changed yet")
        confirmationButton(app, "Suspend").tap()

        XCTAssertTrue(element(app, "platform-organization-notice").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "platform-organization-status").label.hasSuffix("Suspended"))
        let reactivate = element(app, "platform-organization-reactivate")
        XCTAssertTrue(reactivate.waitForExistence(timeout: 5))
        reactivate.tap()
        confirmationButton(app, "Reactivate").tap()

        let active = NSPredicate(format: "label ENDSWITH ', Active'")
        expectation(for: active, evaluatedWith: element(app, "platform-organization-status"))
        waitForExpectations(timeout: 10)
    }

    @MainActor
    func testCancellingTheConfirmationChangesNothing() throws {
        let app = launch()
        openRiverside(app)
        let suspend = element(app, "platform-organization-suspend")
        XCTAssertTrue(suspend.waitForExistence(timeout: 10))
        suspend.tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 5))

        confirmationButton(app, "Cancel").tap()

        XCTAssertTrue(element(app, "platform-organization-status").label.hasSuffix("Active"))
        XCTAssertTrue(element(app, "platform-organization-suspend").exists)
    }

    // MARK: Plan

    @MainActor
    func testAPlanChangeIsPreviewedInPlainWordsAndAppliedFromTheConfirmation() throws {
        let app = launch()
        openRiverside(app)
        let current = scrollTo(app, "platform-plan-current")
        XCTAssertTrue(current.waitForExistence(timeout: 10))
        XCTAssertTrue(current.label.hasSuffix("Family, revision 3"), current.label)

        let picker = scrollTo(app, "platform-plan-picker")
        picker.tap()
        app.buttons["Premium (revision 2)"].firstMatch.tap()
        let preview = scrollTo(app, "platform-plan-preview")
        XCTAssertTrue(preview.isEnabled)
        preview.tap()

        let sheet = element(app, "platform-plan-confirmation")
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Family, revision 3 → Premium, revision 2"].waitForExistence(timeout: 5)
                      || app.staticTexts["FAMILY, REVISION 3 → PREMIUM, REVISION 2"].exists)
        XCTAssertTrue(app.staticTexts["Screens at once goes from 2 screens to 4 screens"].exists)
        XCTAssertTrue(app.staticTexts["Download original files goes from No to Yes"].exists)
        XCTAssertTrue(element(app, "platform-plan-current").label.hasSuffix("Family, revision 3"), "nothing applied before confirming")
        element(app, "platform-plan-apply").tap()

        XCTAssertTrue(scrollTo(app, "platform-plan-notice").waitForExistence(timeout: 10))
        XCTAssertTrue(scrollTo(app, "platform-plan-current").label.hasSuffix("Premium, revision 2"))
    }

    @MainActor
    func testChoosingThePlanItAlreadyUsesSaysNothingChanges() throws {
        let app = launch()
        openRiverside(app)
        let preview = scrollTo(app, "platform-plan-preview")
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.isEnabled, "the current plan is preselected")
        preview.tap()

        let note = scrollTo(app, "platform-plan-note")
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        XCTAssertEqual(note.label, "Nothing changes: Riverside Club already uses this plan")
        XCTAssertFalse(element(app, "platform-plan-confirmation").exists, "nothing to confirm")
    }
}

private extension XCUIElement {
    /// Replaces what is in a search field.
    @MainActor
    func clearAndTypeText(_ text: String) {
        tap()
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
