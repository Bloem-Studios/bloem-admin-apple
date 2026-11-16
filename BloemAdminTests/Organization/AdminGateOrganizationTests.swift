import XCTest
@testable import BloemAdmin

/// Who the gate admits: a platform administrator (as before), an organization-only administrator, or neither.
@MainActor
final class AdminGateOrganizationTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let statusJSON = #"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false,"restart_mark_count":0,"health":{"postgres":{"configured":true,"ok":true},"redis":{"configured":true,"ok":true},"errors_24h":0,"warnings_24h":0},"artwork_storage":{"locked":false,"status_known":true,"private_locked":false}}"#
    private let status = "/api/v2/admin/server/status"
    private let organizations = "/api/bloem/v2/organizations"

    private func check(
        status statusCode: Int,
        organizations body: String = OrganizationFixtures.memberships(),
        organizationsStatus: Int = 200
    ) async throws -> (AdminGateViewModel, MockHTTPHarness) {
        let http = MockHTTPHarness()
        if statusCode == 200 {
            http.state.stub(path: status, data: F.data(statusJSON))
        } else {
            http.state.stub(path: status, data: F.data(F.error(statusCode == 401 ? "unauthorized" : "forbidden")), status: statusCode)
        }
        http.state.stubBloemServer()
        http.state.stub(path: organizations, data: F.data(organizationsStatus == 200 ? body : F.error("refused")), status: organizationsStatus)
        let store = makeIsolatedServerStore()
        try store.updateToken("account-token", forServerID: "srv-1")
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let gate = AdminGateViewModel(session: http.session)
        await gate.checkAccess(server: server, store: store, sessionState: AdminSessionState())
        return (gate, http)
    }

    func testAPlatformAdministratorLandsInThePlatformContextAsBefore() async throws {
        let (gate, http) = try await check(status: 200, organizations: F.memberships(F.membership()))
        defer { http.invalidate() }

        XCTAssertEqual(gate.outcome, .authorized)
        if case .authorized = gate.state {} else { XCTFail("expected .authorized, got \(gate.state)") }
        XCTAssertTrue(http.state.requests(path: organizations).isEmpty, "no organization lookup is needed to admit a platform administrator")
    }

    func testAnAdmittedOrganizationIsNotCheckedAgainWhenThePageThatCoveredTheGateCloses() async throws {
        let (platform, platformHTTP) = try await check(status: 200)
        defer { platformHTTP.invalidate() }
        XCTAssertTrue(platform.shouldCheckAccessOnAppear, "the platform gate keeps checking on every appearance, as before")

        let (organization, organizationHTTP) = try await check(status: 403, organizations: F.memberships(F.membership()))
        defer { organizationHTTP.invalidate() }
        XCTAssertFalse(organization.shouldCheckAccessOnAppear)

        let (refused, refusedHTTP) = try await check(status: 403)
        defer { refusedHTTP.invalidate() }
        XCTAssertTrue(refused.shouldCheckAccessOnAppear)
    }

    func testAnOrganizationOnlyAdministratorIsAdmittedIntoItsOrganization() async throws {
        let (gate, http) = try await check(
            status: 403,
            organizations: F.memberships(F.membership(name: "Acme Media"), F.membership(id: "o2", name: "Other", role: "user"))
        )
        defer { http.invalidate() }

        guard case .organizationOnly(let contexts) = gate.state else { return XCTFail("expected .organizationOnly, got \(gate.state)") }
        XCTAssertEqual(gate.outcome, .organizationOnly)
        XCTAssertNil(gate.failure)
        XCTAssertEqual(contexts.map(\.name), ["Acme Media"])
        XCTAssertEqual(contexts[0].authority, .organizationAdmin)
        XCTAssertEqual(contexts[0].organizationID, F.orgID)
        XCTAssertEqual(http.state.requests(path: organizations).first?.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
    }

    func testAnAdministratorOfSeveralOrganizationsGetsAllOfThem() async throws {
        let (gate, http) = try await check(
            status: 403,
            organizations: F.memberships(F.membership(name: "Acme"), F.membership(id: "o2", name: "Beta"), F.membership(id: "o3", name: "Gamma", role: "user"))
        )
        defer { http.invalidate() }

        guard case .organizationOnly(let contexts) = gate.state else { return XCTFail("expected .organizationOnly") }
        XCTAssertEqual(contexts.map(\.name), ["Acme", "Beta"])
    }

    func testAnAccountThatAdministersNothingIsTurnedAwayAsBefore() async throws {
        for body in [F.memberships(F.membership(role: "user")), F.memberships()] {
            let (gate, http) = try await check(status: 403, organizations: body)
            defer { http.invalidate() }
            if case .unauthorized = gate.state {} else { XCTFail("expected .unauthorized, got \(gate.state)") }
            XCTAssertEqual(gate.outcome, .forbidden)
        }
    }

    func testAServerWithoutOrganizationsKeepsTheNoAccessScreen() async throws {
        let (gate, http) = try await check(status: 403, organizationsStatus: 404)
        defer { http.invalidate() }
        if case .unauthorized = gate.state {} else { XCTFail("expected .unauthorized, got \(gate.state)") }
    }

    func testAnUnreadableOrganizationLookupIsAFailureToShowNotARefusal() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: status, data: F.data(F.error("forbidden")), status: 403)
        http.state.stubBloemServer()
        http.state.stub(path: organizations, data: F.data("<html>not the API</html>"), status: 200)
        let store = makeIsolatedServerStore()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let gate = AdminGateViewModel(session: http.session)

        await gate.checkAccess(server: server, store: store, sessionState: AdminSessionState())

        if case .failed = gate.state {} else { XCTFail("expected .failed, got \(gate.state)") }
        XCTAssertEqual(gate.outcome, .incompatibleResponse)
        XCTAssertTrue(gate.outcome.canRetry)
    }

    func testAnExpiredSignInStillGoesToReLoginWhicheverProbeNoticed() async throws {
        let (first, firstHTTP) = try await check(status: 401)
        defer { firstHTTP.invalidate() }
        if case .needsLogin = first.state {} else { XCTFail("expected .needsLogin, got \(first.state)") }

        let (second, secondHTTP) = try await check(status: 403, organizationsStatus: 401)
        defer { secondHTTP.invalidate() }
        if case .needsLogin = second.state {} else { XCTFail("expected .needsLogin, got \(second.state)") }
    }

    func testAnUnreachableOrganizationLookupIsAFailureToShowNotARefusal() async throws {
        let (gate, http) = try await check(status: 403, organizationsStatus: 503)
        defer { http.invalidate() }
        if case .failed = gate.state {} else { XCTFail("expected .failed, got \(gate.state)") }
        XCTAssertTrue(gate.outcome.canRetry)
    }

    func testAnOrganizationOnlyAdministratorKeepsTheirSessionAfterThePlatformRefusal() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: status, data: F.data(F.error("forbidden")), status: 403)
        http.state.stubBloemServer()
        http.state.stub(path: organizations, data: F.data(F.memberships(F.membership())))
        let store = makeIsolatedServerStore()
        try store.updateToken("account-token", forServerID: "srv-1")
        let sessionState = AdminSessionState()
        let server = AdminServer(id: "srv-1", baseURL: URL(string: "https://example.test")!, displayName: "Test")
        let gate = AdminGateViewModel(session: http.session)

        await gate.checkAccess(server: server, store: store, sessionState: sessionState)

        XCTAssertFalse(sessionState.isTokenExpired(for: "srv-1"), "a 403 on the platform probe must not expire the sign-in")
        XCTAssertEqual(sessionState.requestCredential(serverID: "srv-1")?.accessToken, "account-token")
    }
}
