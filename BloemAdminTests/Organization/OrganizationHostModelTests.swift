import XCTest
@testable import BloemAdmin

/// How the organization entry point reacts to the pass exchange: in, turned away (with the reason), the account's
/// own sign-in rejected, or a failure to show.
@MainActor
final class OrganizationHostModelTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let mint = "/api/bloem/v2/admin/session"

    private func session(_ http: MockHTTPHarness, accountToken: String = "account-token") -> OrganizationSession {
        let account = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: accountToken, session: http.session)
        return OrganizationSession(
            account: account, baseURL: URL(string: "https://example.test")!, organizationID: F.orgID,
            session: http.session, now: { organizationFixtureNow }
        )
    }

    func testOpeningSucceedsAndNamesTheOrganization() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        let host = OrganizationHostModel()
        let opened = session(http)

        await host.open(session: opened, accountSession: nil)

        XCTAssertEqual(host.phase, .ready)
        XCTAssertEqual(opened.context?.name, "Acme Media")
    }

    func testEachRefusalOfTheMintIsToldApart() async {
        let cases: [(Int, String, OrganizationDenial)] = [
            (403, "organization_suspended", .suspended),
            (403, "insufficient_organization_authority", .lostAuthority),
            (404, "not_found", .notFound),
        ]
        for (status, code, reason) in cases {
            let http = MockHTTPHarness()
            defer { http.invalidate() }
            http.state.stub(path: mint, data: F.data(F.error(code)), status: status)
            let host = OrganizationHostModel()
            let opened = session(http)

            await host.open(session: opened, accountSession: nil)

            XCTAssertEqual(host.phase, .denied(reason), code)
            XCTAssertEqual(opened.denial, reason, code)
        }
    }

    func testARejectedSignInExpiresTheAccountTokenSoTheGateShowsReLogin() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.error("unauthorized")), status: 401)
        let state = AdminSessionState()
        state.setAdministratorToken("account-token", serverID: "srv-1")
        let accountClient = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: state.credentialProvider(serverID: "srv-1"), session: http.session
        )
        let opened = OrganizationSession(
            account: accountClient, baseURL: URL(string: "https://example.test")!, organizationID: F.orgID,
            session: http.session, now: { organizationFixtureNow }
        )
        let host = OrganizationHostModel()

        await host.open(session: opened, accountSession: state.scoped(to: "srv-1"))

        XCTAssertEqual(host.phase, .signedOut)
        XCTAssertTrue(state.isTokenExpired(for: "srv-1"), "the gate's re-login form takes over")
        XCTAssertNil(opened.denial, "an expired sign-in is not a refusal of the organization")
    }

    func testAnUnreachableServerIsAFailureToShowNotARefusal() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.error("tenant_unavailable", message: "Try again soon")), status: 503)
        let host = OrganizationHostModel()
        let opened = session(http)

        await host.open(session: opened, accountSession: nil)

        XCTAssertEqual(host.phase, .failed("Try again soon"))
        XCTAssertNil(opened.denial)
    }

    func testThePassIsHeldOnlyInMemory() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session(token: "super-secret-pass")))
        let store = makeIsolatedServerStore()
        try store.updateToken("account-token", forServerID: "srv-1")
        let opened = session(http)

        try await opened.open()

        XCTAssertEqual(try store.credentials(for: "srv-1")?.accessToken, "account-token", "the pass never replaces the account's credentials")
        XCTAssertFalse("\(opened)".contains("super-secret-pass"))
        XCTAssertFalse(String(describing: opened.context as Any).contains("super-secret-pass"))
    }
}
