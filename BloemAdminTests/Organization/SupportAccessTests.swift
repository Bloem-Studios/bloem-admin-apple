import XCTest
@testable import BloemAdmin

/// The server Owner's Support Access page: who sees it, the organizations it lists through a platform pass, and
/// opening one with a reason (once) and again without one.
@MainActor
final class SupportAccessTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let mint = "/api/bloem/v2/admin/session"
    private let organizations = "/api/bloem/v2/admin/platform/organizations"
    private let baseURL = URL(string: "https://example.test")!

    private func organization(id: String, name: String, status: String = "active") -> String {
        #"{"id":"\#(id)","slug":"s-\#(id)","name":"\#(name)","status":"\#(status)","owner_account_id":4,"policy_revision":7,"#
            + #""is_default":false,"membership_count":3,"active_membership_count":3,"profile_count":4,"library_count":1,"entitlement_count":0}"#
    }

    private func platformPass(_ token: String = "platform-pass") -> String {
        #"{"access_token":"\#(token)","expires_at":"2026-11-13T12:15:00Z","context":{"key":"platform","scope":"platform","name":"Platform","status":"active","authority":"platform_admin"}}"#
    }

    private func account(_ http: MockHTTPHarness) -> APIClient {
        APIClient(baseURL: baseURL, accessToken: "account-token", session: http.session)
    }

    private func makeSession(_ http: MockHTTPHarness) -> @MainActor (String) -> OrganizationSession {
        { id in
            OrganizationSession(account: self.account(http), baseURL: self.baseURL, organizationID: id, session: http.session, now: { organizationFixtureNow })
        }
    }

    // MARK: Who sees it

    func testOnlyTheOwnerOfAServerWithOrganizationSupportSeesIt() async throws {
        func check(token: Bool, owner: Bool) async -> Bool {
            let http = MockHTTPHarness()
            defer { http.invalidate() }
            let tokens = token ? #"["organization_support_v1"]"# : "[]"
            http.state.stub(path: "/api/bloem/v2/capabilities", data: F.data(#"{"api":"bloem/v2","identity_schema":2,"features":{},"media_types":[],"feature_tokens":\#(tokens)}"#))
            http.state.stub(path: "/api/v2/account/me", data: F.data(#"{"id":"1"}"#))
            http.state.stub(path: "/api/v2/admin/users/1", json: UserFixtures.user(id: "1", username: "root", overrides: ["role": "admin", "is_owner": owner]))
            return await SupportAccessEligibility.check(client: account(http))
        }
        let ownerWithSupport = await check(token: true, owner: true)
        let adminWithSupport = await check(token: true, owner: false)
        let ownerOfOlderServer = await check(token: false, owner: true)
        XCTAssertTrue(ownerWithSupport)
        XCTAssertFalse(adminWithSupport)
        XCTAssertFalse(ownerOfOlderServer)

        XCTAssertFalse(AdminDestination.singleServer(tenantsVisible: false).contains(AdminDestination.supportAccess))
        XCTAssertTrue(AdminDestination.singleServer(tenantsVisible: false, supportAccessVisible: true).contains(AdminDestination.supportAccess))
    }

    // MARK: The list

    func testTheListComesThroughAPlatformPassAndLeavesOutYourOwnOrganizations() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(platformPass()))
        http.state.stub(path: organizations, data: F.data(#"{"organizations":[\#(organization(id: F.orgID, name: "Default")),\#(organization(id: "o2", name: "Riverside Club")),\#(organization(id: "o3", name: "Paused", status: "suspended"))]}"#))
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", data: F.data(F.memberships(F.membership(id: F.orgID, name: "Default"))))
        let model = SupportAccessListModel(account: account(http), baseURL: baseURL, session: http.session, now: { organizationFixtureNow })

        await model.load(sessionState: nil)

        XCTAssertEqual(model.organizations.map(\.name), ["Riverside Club"])
        let mintBody = try XCTUnwrap(http.state.body(path: mint, requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: mintBody) as? [String: String], ["scope": "platform"])
        XCTAssertEqual(http.state.requests(path: mint).first?.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
        let list = try XCTUnwrap(http.state.requests(path: organizations).first)
        XCTAssertEqual(list.value(forHTTPHeaderField: "Authorization"), "Bearer platform-pass")
        let query = URLComponents(url: list.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "status" }?.value, "active")
    }

    func testAStalePlatformPassIsRenewedOnce() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(platformPass("pass-1"))),
            MockHTTPResponse(data: F.data(platformPass("pass-2"))),
        ])
        http.state.stubSequence(path: organizations, responses: [
            MockHTTPResponse(data: F.data(F.error("authorization_state_stale")), status: 401),
            MockHTTPResponse(data: F.data(#"{"organizations":[\#(organization(id: "o2", name: "Riverside Club"))]}"#)),
        ])
        let model = SupportAccessListModel(account: account(http), baseURL: baseURL, session: http.session, now: { organizationFixtureNow })

        await model.load(sessionState: nil)

        XCTAssertEqual(model.organizations.map(\.id), ["o2"])
        XCTAssertEqual(http.state.requests(path: organizations).map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer pass-1", "Bearer pass-2"])
    }

    // MARK: Opening

    func testOpeningStatesTheReasonOnceAndReopeningNamesTheAccess() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.supportSession()))
        let model = SupportAccessListModel(account: account(http), baseURL: baseURL, session: http.session, now: { organizationFixtureNow })

        let first = await model.open(organizationID: F.orgID, reason: "Admin locked out;\nhelping her", makeSession: makeSession(http), sessionState: nil)
        guard case .success(let opened) = first else { return XCTFail("expected the organization to open, got \(first)") }
        XCTAssertTrue(opened.isSupportAccess)
        XCTAssertEqual(model.openAccess(for: F.orgID)?.accessID, F.supportAccessID)

        let again = await model.open(organizationID: F.orgID, reason: nil, makeSession: makeSession(http), sessionState: nil)
        guard case .success = again else { return XCTFail("expected the open access to be reused, got \(again)") }

        let opening = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: mint, requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(opening["support"] as? [String: String], ["reason": "Admin locked out; helping her"], "one line, as the server takes it")
        let reopening = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: mint, requestIndex: 1))) as? [String: Any])
        XCTAssertEqual(reopening["support"] as? [String: String], ["access_id": F.supportAccessID])
    }

    func testAnAccessThatEndedNeedsANewReason() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.supportSession())),
            MockHTTPResponse(data: F.data(F.error("not_found", message: "Organization not found")), status: 404),
        ])
        let model = SupportAccessListModel(account: account(http), baseURL: baseURL, session: http.session, now: { organizationFixtureNow })
        _ = await model.open(organizationID: F.orgID, reason: "Admin locked out; helping her", makeSession: makeSession(http), sessionState: nil)

        let again = await model.open(organizationID: F.orgID, reason: nil, makeSession: makeSession(http), sessionState: nil)

        XCTAssertEqual(again.failureValue, .reasonNeeded)
        XCTAssertNil(model.openAccess(for: F.orgID))
    }

    func testRefusalsSayWhy() async throws {
        for (status, body, expected) in [
            (404, F.error("not_found", message: "Organization not found"), "This organization can't be opened for support. Only the server Owner can open an active organization this way."),
            (422, #"{"error":"validation_failed","message":"Validation failed","fields":{"support.reason":"x"}}"#, "Say why you're opening this organization, in 10 to 500 characters"),
            (403, F.error("organization_suspended"), "This organization is suspended. Contact the server owner."),
        ] {
            let http = MockHTTPHarness()
            http.state.stub(path: mint, data: F.data(body), status: status)
            let model = SupportAccessListModel(account: account(http), baseURL: baseURL, session: http.session, now: { organizationFixtureNow })
            let result = await model.open(organizationID: F.orgID, reason: "Admin locked out; helping her", makeSession: makeSession(http), sessionState: nil)
            XCTAssertEqual(result.failureValue, .refused(expected), "status \(status)")
            http.invalidate()
        }
    }

    func testTheReasonIsOneLineOfTenToFiveHundredCharacters() {
        XCTAssertEqual(SupportAccessListModel.cleanedReason("  Locked\nout\tnow  "), "Locked outnow")
        XCTAssertFalse(SupportAccessListModel.isAcceptable(reason: "too short"))
        XCTAssertTrue(SupportAccessListModel.isAcceptable(reason: "Admin locked out"))
        XCTAssertTrue(SupportAccessListModel.isAcceptable(reason: String(repeating: "a", count: 500)))
        XCTAssertFalse(SupportAccessListModel.isAcceptable(reason: String(repeating: "a", count: 501)))
    }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let failure) = self { return failure }
        return nil
    }
}
