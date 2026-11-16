import XCTest
@testable import BloemAdmin

/// One organization on the platform: who owns it (by name), its members, and suspending and reactivating it with the
/// revision the person saw.
@MainActor
final class PlatformOrganizationDetailModelTests: XCTestCase {
    typealias F = PlatformFixtures

    private let baseURL = URL(string: "https://example.test")!
    private var org: String { "\(F.base)/\(F.orgID)" }

    private func model(_ http: MockHTTPHarness) -> PlatformOrganizationDetailModel {
        let account = APIClient(baseURL: baseURL, accessToken: "account-token", session: http.session)
        return PlatformOrganizationDetailModel(
            organizationID: F.orgID, account: account, pass: PlatformPass(account: account, baseURL: baseURL, session: http.session)
        )
    }

    private func harness() -> MockHTTPHarness {
        let http = MockHTTPHarness()
        http.state.stub(path: F.mint, data: F.data(F.platformPass()))
        return http
    }

    private func stubMembers(_ http: MockHTTPHarness, next: String? = nil) {
        http.state.stub(path: "\(org)/memberships", data: F.data(F.members(
            F.member(id: "m1", account: 4, username: "avery", email: "avery@example.test", role: "admin"),
            F.member(id: "m2", account: 9, username: "sam", email: "sam@example.test", status: "suspended"),
            next: next
        )))
    }

    // MARK: What the page shows

    func testTheOrganizationShowsItsStatusCountsAndMembersWithTheOwnerByName() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: org, data: F.data(F.detail()))
        stubMembers(http)
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.organization?.name, "Riverside Club")
        XCTAssertEqual(model.organization?.membershipCount, 12)
        XCTAssertEqual(model.members.map(\.label), ["avery", "sam"])
        XCTAssertEqual(model.ownerText, "avery")
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.isLoading)
    }

    func testAnOwnerBeyondTheFirstPageOfMembersIsLookedUpByName() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: org, data: F.data(F.detail(F.organization(owner: 77))))
        stubMembers(http, next: "m-next")
        http.state.stub(path: "/api/v2/admin/users/77", json: UserFixtures.user(id: "77", username: "morgan"))
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.ownerText, "morgan")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/users/77").first?.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
    }

    func testAnOwnerWhoCannotBeNamedIsNeverShownAsAnAccountNumber() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: org, data: F.data(F.detail(F.organization(owner: 77))))
        stubMembers(http, next: "m-next")
        http.state.stub(path: "/api/v2/admin/users/77", data: F.data(F.error("not_found")), status: 404)
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.ownerText, "Not available")
        XCTAssertFalse(model.ownerText.contains("77"))
    }

    func testAnOrganizationWithNoOwnerSaysNobodyYet() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: org, data: F.data(F.detail(F.organization(owner: nil))))
        stubMembers(http)
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.ownerText, "Nobody yet")
    }

    func testMoreMembersAreAddedAfterTheFirstPage() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: org, data: F.data(F.detail()))
        http.state.stubSequence(path: "\(org)/memberships", responses: [
            MockHTTPResponse(data: F.data(F.members(F.member(id: "m1", account: 4, username: "avery", email: "a@example.test"), next: "m-next"))),
            MockHTTPResponse(data: F.data(F.members(F.member(id: "m2", account: 9, username: "sam", email: "s@example.test")))),
        ])
        let model = model(http)
        await model.load(sessionState: nil)
        XCTAssertTrue(model.hasMoreMembers)

        await model.loadMoreMembers(sessionState: nil)

        XCTAssertEqual(model.members.map(\.label), ["avery", "sam"])
        XCTAssertFalse(model.hasMoreMembers)
        let second = try XCTUnwrap(http.state.requests(path: "\(org)/memberships").last)
        XCTAssertEqual(URLComponents(url: second.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value, "m-next")
    }

    func testALoadThatFailsSaysSoAndTryingAgainRecovers() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: org, responses: [
            MockHTTPResponse(data: F.data(F.error("not_found", message: "Administrative resource not found")), status: 404),
            MockHTTPResponse(data: F.data(F.detail())),
        ])
        stubMembers(http)
        let model = model(http)

        await model.load(sessionState: nil)
        XCTAssertNotNil(model.failure)
        XCTAssertNil(model.organization)

        await model.load(sessionState: nil)
        XCTAssertNil(model.failure)
        XCTAssertEqual(model.organization?.name, "Riverside Club")
    }

    // MARK: Suspend and reactivate

    func testSuspendingQuotesTheRevisionThePersonSawAndShowsTheNewStatus() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: org, responses: [
            MockHTTPResponse(data: F.data(F.detail(F.organization(status: "active", revision: 7)))),
            MockHTTPResponse(data: F.data(F.detail(F.organization(status: "suspended", revision: 8)))),
        ])
        stubMembers(http)
        http.state.stub(path: "\(org)/suspend", data: F.data(F.changed(status: "suspended", revision: 8)))
        let model = model(http)
        await model.load(sessionState: nil)

        await model.setSuspended(true, sessionState: nil)

        let body = try XCTUnwrap(http.state.body(path: "\(org)/suspend", requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Int], ["expected_revision": 7])
        XCTAssertEqual(model.organization?.status, "suspended")
        XCTAssertEqual(model.organization?.policyRevision, 8)
        XCTAssertEqual(model.notice, "Riverside Club is suspended")
        XCTAssertNil(model.actionError)
        XCTAssertFalse(model.isChangingStatus)
    }

    func testReactivatingUsesTheReactivateRoute() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: org, responses: [
            MockHTTPResponse(data: F.data(F.detail(F.organization(status: "suspended", revision: 8)))),
            MockHTTPResponse(data: F.data(F.detail(F.organization(status: "active", revision: 9)))),
        ])
        stubMembers(http)
        http.state.stub(path: "\(org)/reactivate", data: F.data(F.changed(status: "active", revision: 9)))
        let model = model(http)
        await model.load(sessionState: nil)

        await model.setSuspended(false, sessionState: nil)

        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: "\(org)/reactivate", requestIndex: 0))) as? [String: Int], ["expected_revision": 8])
        XCTAssertTrue(http.state.requests(path: "\(org)/suspend").isEmpty)
        XCTAssertEqual(model.organization?.status, "active")
        XCTAssertEqual(model.notice, "Riverside Club is active again")
    }

    func testALostRaceReloadsWhatTheServerHasAndSaysSoWithoutSendingTheWriteAgain() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: org, responses: [
            MockHTTPResponse(data: F.data(F.detail(F.organization(status: "active", revision: 7)))),
            MockHTTPResponse(data: F.data(F.detail(F.organization(status: "suspended", revision: 9)))),
        ])
        stubMembers(http)
        http.state.stub(
            path: "\(org)/suspend",
            data: F.data(#"{"error":"authorization_state_changed","message":"Authorization state changed; reload and retry","current_revision":9}"#),
            status: 409
        )
        let model = model(http)
        await model.load(sessionState: nil)

        await model.setSuspended(true, sessionState: nil)

        XCTAssertEqual(http.state.requests(path: "\(org)/suspend").count, 1)
        XCTAssertEqual(model.organization?.policyRevision, 9, "reloaded")
        XCTAssertEqual(model.actionError, "Someone else changed this just now. It has been reloaded; check it and try again.")
        XCTAssertNil(model.notice)
    }

    func testAStalePassIsRenewedTheOrganizationReloadedAndTheWriteNotRepeated() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: F.mint, responses: [
            MockHTTPResponse(data: F.data(F.platformPass("pass-1"))), MockHTTPResponse(data: F.data(F.platformPass("pass-2"))),
        ])
        http.state.stub(path: org, data: F.data(F.detail()))
        stubMembers(http)
        http.state.stub(path: "\(org)/suspend", data: F.data(F.error("authorization_state_stale")), status: 401)
        let model = model(http)
        await model.load(sessionState: nil)

        await model.setSuspended(true, sessionState: nil)

        XCTAssertEqual(http.state.requests(path: "\(org)/suspend").count, 1)
        XCTAssertEqual(model.actionError, "Your administrator access was renewed. Check the organization and try again.")
        XCTAssertEqual(http.state.requests(path: org).last?.value(forHTTPHeaderField: "Authorization"), "Bearer pass-2", "the reload uses the new pass")
    }

    func testARefusalIsShownInTheServersWordsAndTheOrganizationIsUnchanged() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: org, data: F.data(F.detail()))
        stubMembers(http)
        http.state.stub(path: "\(org)/suspend", data: F.data(F.error("tenant_unavailable", message: "Tenant administration is unavailable")), status: 503)
        let model = model(http)
        await model.load(sessionState: nil)

        await model.setSuspended(true, sessionState: nil)

        XCTAssertEqual(model.actionError, "Tenant administration is unavailable")
        XCTAssertEqual(model.organization?.status, "active")
        XCTAssertNil(model.notice)
    }

    func testNothingIsSentWithoutAnOrganizationOnScreen() async throws {
        let http = harness()
        defer { http.invalidate() }
        let model = model(http)

        await model.setSuspended(true, sessionState: nil)

        XCTAssertTrue(http.state.requests(path: "\(org)/suspend").isEmpty)
    }

    // MARK: Opening it as an administrator

    func testOpenAsAdministratorIsOfferedOnlyWhenTheAccountAdministersThatOrganizationOnThatServer() {
        let mine = ScopeOrganization(serverID: "s1", organizationID: F.orgID, displayName: "Riverside Club")
        let elsewhere = ScopeOrganization(serverID: "s2", organizationID: F.otherOrgID, displayName: "Other")
        XCTAssertEqual(PlatformOrganizationAccess.scopeOrganization(organizationID: F.orgID, serverID: "s1", in: [elsewhere, mine]), mine)
        XCTAssertNil(PlatformOrganizationAccess.scopeOrganization(organizationID: F.orgID, serverID: "s2", in: [elsewhere, mine]), "same organization id, other server")
        XCTAssertNil(PlatformOrganizationAccess.scopeOrganization(organizationID: F.otherOrgID, serverID: "s1", in: [mine]))
        XCTAssertNil(PlatformOrganizationAccess.scopeOrganization(organizationID: F.orgID, serverID: "s1", in: []))
    }
}
