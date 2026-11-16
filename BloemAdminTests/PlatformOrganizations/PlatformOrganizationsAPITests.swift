import XCTest
@testable import BloemAdmin

/// Every platform route the Organizations pages call, with the body and the query the server's handlers read, and
/// the answers decoded the way those handlers write them.
final class PlatformOrganizationsAPITests: XCTestCase {
    typealias F = PlatformFixtures

    private let baseURL = URL(string: "https://example.test")!

    private func client(_ http: MockHTTPHarness) -> APIClient {
        APIClient(baseURL: baseURL, accessToken: "platform-pass", session: http.session)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    // MARK: List

    func testTheListSendsTheSearchTheStatusTheCursorAndTheLimitAndDecodesTheCounts() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: F.base, data: F.data(F.page(F.organization(), F.organization(id: F.otherOrgID, name: "Paused", status: "suspended", owner: nil), next: "c2")))

        let page = try await client(http).listPlatformOrganizations(query: "  river ", status: "suspended", cursor: "c1", limit: 50)

        let sent = query(try XCTUnwrap(http.state.requests(path: F.base).first))
        XCTAssertEqual(sent, ["query": "river", "status": "suspended", "cursor": "c1", "limit": "50"])
        XCTAssertEqual(page.organizations.map(\.name), ["Riverside Club", "Paused"])
        XCTAssertEqual(page.nextCursor, "c2")
        let first = page.organizations[0]
        XCTAssertEqual([first.membershipCount, first.profileCount, first.libraryCount, first.entitlementCount], [12, 25, 3, 2])
        XCTAssertEqual(first.ownerAccountID, 4)
        XCTAssertNil(page.organizations[1].ownerAccountID)
    }

    func testNoStatusMeansEveryStatus() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: F.base, data: F.data(F.page()))

        _ = try await client(http).listPlatformOrganizations(query: "", cursor: nil, limit: 50)

        XCTAssertEqual(query(try XCTUnwrap(http.state.requests(path: F.base).first)), ["limit": "50"])
    }

    // MARK: One organization and its members

    func testOneOrganizationIsReadFromItsOwnPath() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/\(F.orgID)", data: F.data(F.detail()))

        let organization = try await client(http).platformOrganization(id: F.orgID)

        XCTAssertEqual(organization.id, F.orgID)
        XCTAssertEqual(organization.policyRevision, 7)
    }

    func testMembersComeWithTheirRoleStatusAndNames() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/\(F.orgID)/memberships", data: F.data(F.members(
            F.member(id: "m1", account: 4, username: "avery", email: "avery@example.test", role: "admin"),
            F.member(id: "m2", account: 9, username: "", email: "sam@example.test", status: "suspended"),
            next: "m-next"
        )))

        let page = try await client(http).platformOrganizationMemberships(id: F.orgID, cursor: "m-1", limit: 100)

        XCTAssertEqual(query(try XCTUnwrap(http.state.requests(path: "\(F.base)/\(F.orgID)/memberships").first)), ["cursor": "m-1", "limit": "100"])
        XCTAssertEqual(page.memberships.map(\.accountID), [4, 9])
        XCTAssertTrue(page.memberships[0].isAdministrator)
        XCTAssertEqual(page.memberships[1].status, "suspended")
        XCTAssertEqual(page.memberships[0].label, "avery")
        XCTAssertEqual(page.memberships[1].label, "sam@example.test", "a member with no username is named by email")
        XCTAssertEqual(page.nextCursor, "m-next")
    }

    // MARK: Suspend and reactivate

    func testSuspendQuotesTheRevisionAndReadsTheNewState() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/\(F.orgID)/suspend", data: F.data(F.changed(status: "suspended", revision: 8)))

        let organization = try await client(http).suspendPlatformOrganization(id: F.orgID, expectedRevision: 7)

        let request = try XCTUnwrap(http.state.requests(path: "\(F.base)/\(F.orgID)/suspend").first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try json(http.state.body(path: "\(F.base)/\(F.orgID)/suspend", requestIndex: 0)) as? [String: Int], ["expected_revision": 7])
        XCTAssertEqual(organization.status, "suspended")
        XCTAssertEqual(organization.policyRevision, 8)
    }

    func testReactivateUsesItsOwnRoute() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/\(F.orgID)/reactivate", data: F.data(F.changed(status: "active", revision: 9)))

        let organization = try await client(http).reactivatePlatformOrganization(id: F.orgID, expectedRevision: 8)

        XCTAssertEqual(try json(http.state.body(path: "\(F.base)/\(F.orgID)/reactivate", requestIndex: 0)) as? [String: Int], ["expected_revision": 8])
        XCTAssertEqual(organization.status, "active")
    }

    // MARK: Plan

    func testTheEntitlementDecodesThePlanTheLimitsAndTheDefaultSettings() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/\(F.orgID)/entitlement", data: F.data(F.entitlement(group: F.policy(screens: 2))))

        let entitlement = try await client(http).platformOrganizationEntitlement(id: F.orgID)

        XCTAssertEqual(entitlement.templateKey, "family")
        XCTAssertEqual(entitlement.templateRevision, 3)
        XCTAssertEqual(entitlement.slots, 8)
        XCTAssertEqual(entitlement.transcodes, 2)
        XCTAssertEqual(entitlement.managedDefaultGroup?.name, "Family plan")
        XCTAssertEqual(entitlement.managedDefaultGroup?.policy.maxStreams, 2)
        XCTAssertNil(entitlement.managedDefaultGroup?.policy.libraryIDs, "null libraries means all of them")
        XCTAssertEqual(entitlement.lastReconciledAt, "2026-11-12T09:30:00.123456Z")
    }

    func testAnOrganizationWithNoPlanYetDecodes() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/\(F.orgID)/entitlement", data: F.data(F.entitlement(key: "", revision: 0, reconciled: nil)))

        let entitlement = try await client(http).platformOrganizationEntitlement(id: F.orgID)

        XCTAssertFalse(entitlement.hasPlan)
        XCTAssertNil(entitlement.managedDefaultGroup)
        XCTAssertNil(entitlement.lastReconciledAt)
    }

    func testPlansOfferedAreAskedForEnabledOnly() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: F.templates, data: F.data(F.templateList(F.template(key: "family", name: "Family", revision: 3), F.template(key: "premium", name: "Premium", revision: 2))))

        let plans = try await client(http).platformEntitlementTemplates()

        XCTAssertEqual(query(try XCTUnwrap(http.state.requests(path: F.templates).first)), ["status": "enabled"])
        XCTAssertEqual(plans.map(\.name), ["Family", "Premium"])
        XCTAssertEqual(plans.map(\.revision), [3, 2])
    }

    func testThePreviewSendsThePlanAndReadsTheTokenAndTheChange() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let path = "\(F.base)/\(F.orgID)/entitlement/dry-run"
        http.state.stub(path: path, data: F.data(F.dryRun()))

        let preview = try await client(http).dryRunPlatformOrganizationEntitlement(id: F.orgID, templateKey: "premium", templateRevision: 2)

        let body = try json(http.state.body(path: path, requestIndex: 0))
        XCTAssertEqual(body["template_key"] as? String, "premium")
        XCTAssertEqual(body["template_revision"] as? Int, 2)
        XCTAssertEqual(Set(body.keys), ["template_key", "template_revision"])
        XCTAssertTrue(preview.changed)
        XCTAssertEqual(preview.token, "dry.run.token")
        XCTAssertEqual(preview.result.previousTemplateKey, "family")
        XCTAssertEqual(preview.result.previousTemplateRevision, 3)
        XCTAssertEqual(preview.result.policy.maxStreams, 4)
        XCTAssertEqual(preview.warnings, [])
    }

    func testApplyCarriesThePlanTheTokenAndAnIdempotencyKey() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let path = "\(F.base)/\(F.orgID)/entitlement/apply"
        http.state.stub(path: path, data: F.data(F.applied()))

        let result = try await client(http).applyPlatformOrganizationEntitlement(
            id: F.orgID, templateKey: "premium", templateRevision: 2, token: "dry.run.token", idempotencyKey: "key-1"
        )

        let body = try json(http.state.body(path: path, requestIndex: 0))
        XCTAssertEqual(body["template_key"] as? String, "premium")
        XCTAssertEqual(body["template_revision"] as? Int, 2)
        XCTAssertEqual(body["dry_run_token"] as? String, "dry.run.token")
        XCTAssertEqual(body["idempotency_key"] as? String, "key-1")
        XCTAssertEqual(Set(body.keys), ["template_key", "template_revision", "dry_run_token", "idempotency_key"])
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.templateKey, "premium")
    }
}
