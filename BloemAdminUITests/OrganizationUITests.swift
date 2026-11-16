import XCTest

/// The organization pages, driven through the real app over an in-process stub server
/// (`--ui-testing-organization`): the same menu, filters, bulk bar and sheets an organization administrator uses.
final class OrganizationUITests: XCTestCase {
    private let pageNames = [
        "Overview", "People", "Cohorts", "Access groups", "Libraries",
        "Invitations", "Access checks", "Activity",
    ]

    @MainActor
    private func launch(_ mode: String = "--ui-testing-organization", extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing-reset", "--ui-testing-auth=success", mode] + extra
        app.launch()
        return app
    }

    @MainActor
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A People row: its button reads "<name>, <status words>, ..." until people are being chosen, then "Select <name>".
    @MainActor
    private func personRow(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ OR label == %@", name, "Select \(name)")).firstMatch
    }

    /// The menu entry for a page: a row of the list on an iPhone, a sidebar row on an iPad.
    @MainActor
    private func menuItem(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let identifiers = [
            "Overview": "overview", "People": "people", "Cohorts": "cohorts", "Access groups": "groups",
            "Libraries": "libraries", "Invitations": "invitations", "Access checks": "decisions",
            "Activity": "activity",
        ]
        return element(app, "organization-menu-\(identifiers[name] ?? name)")
    }

    @MainActor
    private func openPage(_ name: String, in app: XCUIApplication) {
        let row = menuItem(app, name)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "\(name) is in the menu")
        row.tap()
    }

    /// On an iPhone a page is pushed onto the menu; the back button returns to it. An iPad's sidebar stays on screen.
    @MainActor
    private func backToMenu(_ app: XCUIApplication) {
        let back = app.buttons["BackButton"]
        if back.exists { back.tap() }
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

    @MainActor
    func testTheMenuListsTheWebsPagesAndNothingPlatformLevel() throws {
        let app = launch()

        for name in pageNames {
            let item = menuItem(app, name)
            XCTAssertTrue(item.waitForExistence(timeout: 10), "\(name) is missing from the organization menu")
            XCTAssertTrue(item.label.contains(name), "\(name) is named like the web's page, not \(item.label)")
        }
        for platformOnly in ["Organizations", "Platform", "Dashboard", "Scheduled tasks", "Server settings", "Logs", "Users"] {
            XCTAssertFalse(app.buttons[platformOnly].exists, "\(platformOnly) must not be reachable from an organization")
            XCTAssertFalse(app.staticTexts[platformOnly].exists, "\(platformOnly) must not be reachable from an organization")
        }
    }

    @MainActor
    func testOverviewShowsTheCountsAndTheOwner() throws {
        let app = launch()
        openPage("Overview", in: app)

        XCTAssertTrue(app.staticTexts["Libraries shared with it"].waitForExistence(timeout: 10))
        let owner = app.staticTexts["organization-owner"]
        XCTAssertTrue(owner.waitForExistence(timeout: 5), "the owner is shown")
        XCTAssertTrue(owner.label.hasSuffix("Alex Adams"), "the owner is named: \(owner.label)")
        XCTAssertFalse(owner.label.contains("Account"), "never 'Account 101'")
    }

    @MainActor
    func testSearchNarrowsPeopleAndTheListShowsEveryone() throws {
        let app = launch()
        openPage("People", in: app)

        XCTAssertTrue(personRow(app, "Alex Adams").waitForExistence(timeout: 10))
        XCTAssertTrue(personRow(app, "Casey Chen").exists)
        XCTAssertFalse(personRow(app, "Kim Kerr").exists, "a row far down the list is not built until it scrolls near")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Kim")

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: personRow(app, "Alex Adams"))
        waitForExpectations(timeout: 10)
        XCTAssertTrue(personRow(app, "Kim Kerr").waitForExistence(timeout: 5))
    }

    @MainActor
    func testSuspendingFromARowMenuConfirmsFirstThenSaysSo() throws {
        let app = launch()
        openPage("People", in: app)

        let actions = app.buttons["Actions for Blake Baker"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(actions.frame.height, 44, "tap targets are at least 44pt")
        actions.tap()
        app.buttons["Suspend"].firstMatch.tap()
        let confirm = confirmationButton(app, "Suspend")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "a suspend is confirmed first")
        confirm.tap()

        XCTAssertTrue(app.staticTexts["Membership suspended"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Suspended"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheAdministratorCannotSuspendThemself() throws {
        let app = launch()
        openPage("People", in: app)

        let actions = app.buttons["Actions for Alex Adams"]
        XCTAssertTrue(actions.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["You"].exists)
        actions.tap()
        XCTAssertTrue(app.buttons["Details"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Suspend"].exists, "an administrator never suspends their own membership from here")
    }

    @MainActor
    func testBulkActionsWrapAndNeverCoverTheListRowsOnANarrowPhoneWithLargeText() throws {
        let app = launch(extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityL"])
        openPage("People", in: app)

        XCTAssertTrue(app.buttons["Select people"].waitForExistence(timeout: 10))
        app.buttons["Select people"].tap()
        let bar = element(app, "organization-bulk-bar")
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let list = app.collectionViews["organization-page-people"]
        // At this text size the filters fill the space above the bar and the rows scroll through a small window:
        // tick whichever row is on screen once the list has moved.
        let choosable = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Select ' AND NOT label BEGINSWITH 'Select all'"))
        let top = app.navigationBars.firstMatch.frame.maxY
        func fullyVisibleRow() -> XCUIElement? {
            choosable.allElementsBoundByIndex.first {
                $0.exists && $0.isHittable && $0.frame.minY > top && $0.frame.maxY < bar.frame.minY - 4
            }
        }
        for _ in 0..<8 where fullyVisibleRow() == nil { list.swipeUp() }
        XCTAssertNotNil(fullyVisibleRow(), "a person row is fully visible above the bar")
        fullyVisibleRow()?.tap()
        let count = app.descendants(matching: .any).matching(NSPredicate(format: "label == '1 person selected'")).firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 5), "the ticked person is counted")

        // Every action stays on screen, wrapped onto further lines instead of running off the edge.
        let screen = app.windows.firstMatch.frame
        for identifier in ["organization-bulk-select-all", "organization-bulk-move", "organization-bulk-suspend", "organization-bulk-reactivate"] {
            let button = element(app, identifier)
            XCTAssertTrue(button.exists, "\(identifier) is in the bar")
            XCTAssertGreaterThanOrEqual(button.frame.minX, screen.minX, "\(identifier) runs off the left edge")
            XCTAssertLessThanOrEqual(button.frame.maxX, screen.maxX, "\(identifier) runs off the right edge")
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, "\(identifier) is at least 44pt tall")
        }

        // Scroll to the very end: the last row comes to rest above the bar, never under it.
        let last = personRow(app, "Lee Lopez")
        var previous = CGRect.null
        for _ in 0..<20 {
            list.swipeUp()
            if last.exists, last.frame == previous { break }
            previous = last.exists ? last.frame : .null
        }
        XCTAssertTrue(last.exists, "the last row can be reached")
        XCTAssertLessThanOrEqual(last.frame.maxY, bar.frame.minY + 1, "the bulk bar covers the last list row")
    }

    @MainActor
    func testTickingPeopleCountsThemAndTickingAgainUnticks() throws {
        let app = launch()
        openPage("People", in: app)
        app.buttons["Select people"].tap()

        let alex = personRow(app, "Alex Adams")
        XCTAssertTrue(alex.waitForExistence(timeout: 10))
        alex.tap()
        XCTAssertTrue(app.staticTexts["1 person selected"].waitForExistence(timeout: 5), "one person is ticked")
        personRow(app, "Blake Baker").tap()
        XCTAssertTrue(app.staticTexts["2 people selected"].waitForExistence(timeout: 5), "two people are ticked")
        alex.tap()
        XCTAssertTrue(app.staticTexts["1 person selected"].waitForExistence(timeout: 5), "ticking again unticks")
    }

    @MainActor
    func testSelectAllThenSuspendRunsOneJobAndReportsWhoWasSkipped() throws {
        let app = launch()
        openPage("People", in: app)
        app.buttons["Select people"].tap()

        let selectAll = element(app, "organization-bulk-select-all")
        XCTAssertTrue(selectAll.waitForExistence(timeout: 5))
        selectAll.tap()
        XCTAssertTrue(app.staticTexts["All 12 people selected"].waitForExistence(timeout: 10))
        element(app, "organization-bulk-suspend").tap()
        let apply = confirmationButton(app, "Apply")
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()

        XCTAssertTrue(app.staticTexts["Some people were changed"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Alex Adams: skipped so you keep your own admin access"].exists)
    }

    @MainActor
    func testAPersonPageExplainsWhatAnOrganizationAdministratorCannotDo() throws {
        let app = launch()
        openPage("People", in: app)

        let row = personRow(app, "Casey Chen")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()

        XCTAssertTrue(app.staticTexts["What you can't do here"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Profiles and access groups"].exists)
        XCTAssertFalse(app.buttons["Reset password"].exists)
    }

    @MainActor
    func testPausingASharedLibraryAsksFirstThenRestoreIsOffered() throws {
        let app = launch()
        openPage("Libraries", in: app)

        let pause = app.buttons["Pause for Shows"]
        XCTAssertTrue(pause.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Pause for Films"].exists, "an owned library is never paused")
        pause.tap()
        let confirm = confirmationButton(app, "Pause")
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(app.staticTexts["Library paused. Members can't use it until you restore it."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Restore for Shows"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Give back for Shows"].exists)
    }

    @MainActor
    func testInvitingShowsTheOneTimeLinkAndItIsGoneOnceDismissed() throws {
        let app = launch()
        openPage("Invitations", in: app)

        app.buttons["Invite someone"].firstMatch.tap()
        let email = app.textFields["organization-invite-email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("new@example.test")
        app.buttons["Create invite link"].tap()

        XCTAssertTrue(app.navigationBars["Invitation link ready"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["https://fixture.example.test/invite/ui-test-claim-token"].exists, "the link is readable")
        XCTAssertTrue(app.buttons["Copy link"].exists)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.staticTexts["https://fixture.example.test/invite/ui-test-claim-token"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["new@example.test"].waitForExistence(timeout: 5), "the new invitation is in the list")
    }

    @MainActor
    func testCreatingAnAccessGroupOpensItsEditor() throws {
        let app = launch()
        openPage("Access groups", in: app)

        XCTAssertTrue(app.staticTexts["Family"].waitForExistence(timeout: 10))
        app.buttons["New group"].firstMatch.tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.typeText("Guests")
        app.alerts.buttons["Create"].tap()

        XCTAssertTrue(app.navigationBars["Guests"].waitForExistence(timeout: 10), "the new group opens in the editor")
        XCTAssertTrue(app.staticTexts["Libraries & playback"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testTheReadOnlyPagesLoad() throws {
        let app = launch()

        openPage("Cohorts", in: app)
        XCTAssertTrue(app.staticTexts["Family plan"].waitForExistence(timeout: 10))
        backToMenu(app)

        openPage("Access checks", in: app)
        XCTAssertTrue(app.staticTexts["Library access check: refused"].waitForExistence(timeout: 10))
        backToMenu(app)

        openPage("Activity", in: app)
        XCTAssertTrue(app.staticTexts["Membership changed"].waitForExistence(timeout: 10))
    }

    /// The app pushes the organization from the server list, inside that list's NavigationStack, under a gate that
    /// checks access again whenever it reappears. Opening a page must not cover the gate (which would re-run the check
    /// and throw the organization away), and there must be one navigation bar, not two.
    @MainActor
    func testUnderTheServerListPagesPushInsideTheOrganizationAndTheGateStaysPut() throws {
        let app = launch("--ui-testing-organization=nested")
        let example = app.buttons["Example"]
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        example.tap()

        let checks = app.staticTexts["ui-test-gate-checks"]
        XCTAssertTrue(menuItem(app, "People").waitForExistence(timeout: 10))
        XCTAssertEqual(app.navigationBars.count, 1, "a second navigation bar is stacked on the first")
        XCTAssertTrue(app.navigationBars["Acme Media"].exists, "the menu is titled with the organization")

        openPage("People", in: app)
        XCTAssertTrue(personRow(app, "Alex Adams").waitForExistence(timeout: 10), "the People page is on top")
        XCTAssertTrue(app.navigationBars["People"].exists)
        XCTAssertEqual(app.navigationBars.count, 1, "a second navigation bar is stacked on the first")

        // One level deeper: a person page, then back to People.
        personRow(app, "Casey Chen").tap()
        XCTAssertTrue(app.staticTexts["What you can't do here"].waitForExistence(timeout: 10), "the person page is on top")
        app.navigationBars.buttons["People"].tap()
        XCTAssertTrue(personRow(app, "Alex Adams").waitForExistence(timeout: 5))

        app.navigationBars.buttons["Acme Media"].tap()
        XCTAssertTrue(menuItem(app, "People").waitForExistence(timeout: 5), "back returns to the organization's menu")
        XCTAssertTrue(checks.waitForExistence(timeout: 5))
        XCTAssertEqual(checks.label, "Gate checks: 1, appearances: 2", "the page covered the gate, and uncovering it did not check access again")

        app.navigationBars.buttons["Servers"].tap()
        XCTAssertTrue(app.buttons["Example"].waitForExistence(timeout: 5), "back again returns to the server list")
    }

    /// The search sheet's field, a result and the button that opens it, by the shell's own identifiers.
    @MainActor
    private func searchFor(_ text: String, pick pageID: String, in app: XCUIApplication) {
        let button = element(app, "shell-search-button")
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the organization menu has a search button")
        button.tap()
        let field = element(app, "shell-search-field")
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the search sheet opens")
        field.typeText(text)
        let result = element(app, "shell-search-result:\(pageID)")
        XCTAssertTrue(result.waitForExistence(timeout: 5), "\(text) finds \(pageID)")
        result.tap()
    }

    @MainActor
    func testSearchJumpsToANamedOrganizationPage() throws {
        let app = launch()

        searchFor("invit", pick: "organization.invitations", in: app)

        XCTAssertFalse(element(app, "shell-search-field").waitForExistence(timeout: 2), "picking a page closes the search")
        XCTAssertTrue(
            app.navigationBars["Invitations"].waitForExistence(timeout: 10) || app.staticTexts["Invitations"].waitForExistence(timeout: 5),
            "the Invitations page is open"
        )
    }

    @MainActor
    func testSearchShowsOnlyOrganizationPages() throws {
        let app = launch()
        let button = element(app, "shell-search-button")
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        button.tap()
        XCTAssertTrue(element(app, "shell-search-field").waitForExistence(timeout: 10))

        XCTAssertTrue(element(app, "shell-search-result:organization.people").waitForExistence(timeout: 5))
        for platformPage in ["live.streams", "overview.dashboard", "work.jobs", "system.server", "people.users"] {
            XCTAssertFalse(element(app, "shell-search-result:\(platformPage)").exists, "\(platformPage) is not an organization page")
        }
    }

    /// Under the server list the page is pushed inside the organization, and the gate beneath is not asked again.
    @MainActor
    func testSearchUnderTheServerListPushesInsideTheOrganizationAndTheGateStaysPut() throws {
        let app = launch("--ui-testing-organization=nested")
        let example = app.buttons["Example"]
        XCTAssertTrue(example.waitForExistence(timeout: 10))
        example.tap()
        XCTAssertTrue(menuItem(app, "People").waitForExistence(timeout: 10))

        searchFor("people", pick: "organization.people", in: app)

        XCTAssertTrue(personRow(app, "Alex Adams").waitForExistence(timeout: 10), "the People page is on top")
        XCTAssertEqual(app.navigationBars.count, 1, "a second navigation bar is stacked on the first")

        app.navigationBars.buttons["Acme Media"].tap()
        XCTAssertTrue(menuItem(app, "People").waitForExistence(timeout: 5), "back returns to the organization's menu")
        let checks = app.staticTexts["ui-test-gate-checks"]
        XCTAssertTrue(checks.waitForExistence(timeout: 5))
        XCTAssertEqual(checks.label, "Gate checks: 1, appearances: 2")
    }

    @MainActor
    func testASuspendedOrganizationSaysSoAndOffersTheWayBackToContextChoice() throws {
        let app = launch("--ui-testing-organization=suspended")

        XCTAssertTrue(app.staticTexts["This organization is suspended. Contact the server owner."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Overview"].exists, "no page is reachable once the server has turned the organization away")
        let choose = app.buttons["Choose another organization"]
        XCTAssertTrue(choose.exists)
        choose.tap()
        XCTAssertTrue(app.staticTexts["Choose an organization"].waitForExistence(timeout: 5))
    }
}
