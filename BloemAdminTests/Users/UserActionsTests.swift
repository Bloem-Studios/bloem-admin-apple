import XCTest
@testable import BloemAdmin

/// Who may do what on the User page: the owner is the platform admin, organization admins are his
/// customers and support their own organization only. Mirrors the web's `lib/accountOwner.ts`.
final class UserActionsTests: XCTestCase {
    private func user(
        id: String = "2", role: String = "user", enabled: Bool = true,
        owner: Bool = false, passwordLogin: Bool = true
    ) -> AdminUser {
        AdminUser(
            id: id, username: "name\(id)", email: "n\(id)@example.test", role: role, enabled: enabled,
            maxStreams: nil, maxTranscodes: nil, passwordLogin: passwordLogin, isOwner: owner
        )
    }

    private let orgAdmin = Viewer(id: "1", isOwner: false)
    private let owner = Viewer(id: "9", isOwner: true)

    func testNothingIsOfferedUntilTheViewerIsKnown() {
        let actions = UserActions.resolve(for: user(), viewer: nil)
        XCTAssertFalse(actions.manageable)
        XCTAssertFalse(actions.canDelete)
        XCTAssertFalse(actions.canDisable)
        XCTAssertFalse(actions.canResetPassword)
        XCTAssertNil(actions.viewOnly)
    }

    func testAnOrganizationAdminSupportsARegularUserFully() {
        let actions = UserActions.resolve(for: user(), viewer: orgAdmin)
        XCTAssertTrue(actions.manageable && actions.policyManageable)
        XCTAssertTrue(actions.canDisable && actions.canDelete && actions.canResetPassword)
        XCTAssertFalse(actions.canEnable)
        XCTAssertTrue(actions.canSetPassword, "a temporary password is offered on every enabled account the admin may manage")
        XCTAssertNil(actions.viewOnly)
    }

    func testAnOrganizationAdminCannotChangeAnotherAdminOrTheOwner() {
        let otherAdmin = UserActions.resolve(for: user(role: "admin"), viewer: orgAdmin)
        XCTAssertFalse(otherAdmin.manageable)
        XCTAssertFalse(otherAdmin.canDelete || otherAdmin.canResetPassword || otherAdmin.canDisable)
        XCTAssertEqual(otherAdmin.viewOnly, .anotherAdmin)

        let theOwner = UserActions.resolve(for: user(role: "admin", owner: true), viewer: orgAdmin)
        XCTAssertFalse(theOwner.manageable)
        XCTAssertEqual(theOwner.viewOnly, .owner)
    }

    func testTheOwnerManagesAnotherAdmin() {
        let actions = UserActions.resolve(for: user(role: "admin"), viewer: owner)
        XCTAssertTrue(actions.manageable && actions.policyManageable && actions.canDelete)
    }

    func testYourOwnAccountCannotBeDisabledOrDeleted() {
        let actions = UserActions.resolve(for: user(id: "1", role: "admin"), viewer: orgAdmin)
        XCTAssertTrue(actions.ownAccount)
        XCTAssertTrue(actions.manageable)
        XCTAssertFalse(actions.canDisable)
        XCTAssertFalse(actions.canDelete)
        // An admin does not change their own limits; only the owner does.
        XCTAssertFalse(actions.policyManageable)
    }

    func testTheOwnerCannotBeDisabledOrDeletedEvenByThemselves() {
        let actions = UserActions.resolve(for: user(id: "9", role: "admin", owner: true), viewer: owner)
        XCTAssertTrue(actions.manageable && actions.policyManageable)
        XCTAssertFalse(actions.canDisable || actions.canDelete)
    }

    func testADisabledAccountOffersEnableAndDeleteButNotDisable() {
        let actions = UserActions.resolve(for: user(enabled: false), viewer: orgAdmin)
        XCTAssertTrue(actions.canEnable && actions.canDelete)
        XCTAssertFalse(actions.canDisable)
    }

    func testPasswordSignInOffersResetAndAnyEnabledAccountOffersSetPassword() {
        let password = UserActions.resolve(for: user(passwordLogin: true), viewer: orgAdmin)
        XCTAssertTrue(password.canResetPassword)
        XCTAssertTrue(password.canSetPassword)

        let external = UserActions.resolve(for: user(passwordLogin: false), viewer: orgAdmin)
        XCTAssertFalse(external.canResetPassword)
        XCTAssertTrue(external.canSetPassword)
    }

    func testSetPasswordIsNotOfferedForADisabledExternalAccount() {
        XCTAssertFalse(UserActions.resolve(for: user(enabled: false, passwordLogin: false), viewer: orgAdmin).canSetPassword)
    }

    func testTheOwnerIsLabelledOwner() {
        XCTAssertEqual(user(role: "admin", owner: true).roleLabel, "owner")
        XCTAssertEqual(user(role: "admin").roleLabel, "admin")
    }

    func testAPasswordNeedsEightCharactersAndAtMost72Bytes() {
        XCTAssertEqual(PasswordProblem.check("short"), .tooShort)
        XCTAssertNil(PasswordProblem.check("eight888"))
        XCTAssertNil(PasswordProblem.check(String(repeating: "a", count: 72)))
        XCTAssertEqual(PasswordProblem.check(String(repeating: "a", count: 73)), .tooLong)
        // 40 two-byte characters are 80 bytes.
        XCTAssertEqual(PasswordProblem.check(String(repeating: "é", count: 40)), .tooLong)
    }

    // MARK: - Tabs and the sideways swipe

    func testDownloadsIsOnlyATabWhenTheServerHasAccountDownloads() {
        XCTAssertEqual(
            UserTab.visible(accountDownloads: false),
            [.overview, .access, .signIn, .activity, .preferences]
        )
        XCTAssertEqual(
            UserTab.visible(accountDownloads: true),
            [.overview, .access, .signIn, .activity, .downloads, .preferences]
        )
    }

    func testASidewaysSwipeStepsTheTabAndStopsAtBothEnds() {
        let tabs = UserTab.visible(accountDownloads: false)
        XCTAssertEqual(UserTabSwipe.target(from: .overview, in: tabs, width: -120, height: 4), .access)
        XCTAssertEqual(UserTabSwipe.target(from: .access, in: tabs, width: 120, height: -4), .overview)
        // Before the first tab and after the last there is nothing: the page stays on its tab.
        XCTAssertEqual(UserTabSwipe.target(from: .overview, in: tabs, width: 200, height: 0), .overview)
        XCTAssertEqual(UserTabSwipe.target(from: .preferences, in: tabs, width: -200, height: 0), .preferences)
    }

    func testAShortOrMostlyVerticalDragNeverChangesTab() {
        let tabs = UserTab.visible(accountDownloads: true)
        XCTAssertNil(UserTabSwipe.step(width: -40, height: 0), "too short")
        XCTAssertNil(UserTabSwipe.step(width: -100, height: 90), "scrolling, not swiping")
        XCTAssertEqual(UserTabSwipe.target(from: .signIn, in: tabs, width: -50, height: 0), .signIn)
        XCTAssertEqual(UserTabSwipe.step(width: -100, height: 20), 1)
        XCTAssertEqual(UserTabSwipe.step(width: 100, height: 20), -1)
    }

    func testTheSwipeSkipsDownloadsWhenItIsNotATab() {
        let tabs = UserTab.visible(accountDownloads: false)
        XCTAssertEqual(UserTabSwipe.target(from: .activity, in: tabs, width: -120, height: 0), .preferences)
    }
}
