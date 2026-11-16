import XCTest
@testable import BloemAdmin

/// The Organizations list: search, the status filter, paging by cursor, and what a failure leaves on screen.
@MainActor
final class PlatformOrganizationsModelTests: XCTestCase {
    typealias F = PlatformFixtures

    private let baseURL = URL(string: "https://example.test")!

    private func model(_ http: MockHTTPHarness) -> PlatformOrganizationsModel {
        let account = APIClient(baseURL: baseURL, accessToken: "account-token", session: http.session)
        return PlatformOrganizationsModel(pass: PlatformPass(account: account, baseURL: baseURL, session: http.session))
    }

    private func query(_ http: MockHTTPHarness, _ index: Int = 0) -> [String: String] {
        let request = http.state.requests(path: F.base)[index]
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private func harness() -> MockHTTPHarness {
        let http = MockHTTPHarness()
        http.state.stub(path: F.mint, data: F.data(F.platformPass()))
        return http
    }

    // MARK: Who sees the page

    func testEveryPlatformAdministratorOfABloemServerSeesOrganizationsNotOnlyTheOwner() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        // No organization_support_v1 token and no Owner check: the page needs only a Bloem server.
        http.state.stub(path: "/api/bloem/v2/capabilities", data: F.data(#"{"api":"bloem/v2","identity_schema":2,"features":{},"media_types":[],"feature_tokens":[]}"#))
        let account = APIClient(baseURL: baseURL, accessToken: "account-token", session: http.session)

        let offered = await PlatformOrganizationsEligibility.check(client: account)

        XCTAssertTrue(offered)
        XCTAssertTrue(http.state.requests(path: "/api/v2/account/me").isEmpty, "no Owner check")
    }

    func testAServerThatIsNotABloemServerLeavesTheOrganizationsPageOut() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/bloem/v2/capabilities", data: F.data(F.error("not_found")), status: 404)
        let account = APIClient(baseURL: baseURL, accessToken: "account-token", session: http.session)

        let offered = await PlatformOrganizationsEligibility.check(client: account)

        XCTAssertFalse(offered)
    }

    func testTheFirstPageLoadsWithNoFilter() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: F.base, data: F.data(F.page(F.organization(), F.organization(id: F.otherOrgID, name: "Paused", status: "suspended"))))
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.organizations.map(\.name), ["Riverside Club", "Paused"])
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.failure)
        XCTAssertEqual(query(http), ["limit": "50"])
        XCTAssertFalse(model.hasMore)
    }

    func testSearchAndStatusAreSentAndStartAgainFromTheFirstPage() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: F.base, responses: [
            MockHTTPResponse(data: F.data(F.page(F.organization(), next: "c2"))),
            MockHTTPResponse(data: F.data(F.page(F.organization(id: F.otherOrgID, name: "Paused", status: "suspended")))),
        ])
        let model = model(http)
        await model.load(sessionState: nil)

        model.query = " river "
        model.statusFilter = .suspended
        await model.load(sessionState: nil)

        XCTAssertEqual(query(http, 1), ["query": "river", "status": "suspended", "limit": "50"], "no cursor: a new search starts at the top")
        XCTAssertEqual(model.organizations.map(\.name), ["Paused"], "the old list is replaced, not added to")
    }

    func testMoreOrganizationsAreAskedForWithTheCursorAndAdded() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: F.base, responses: [
            MockHTTPResponse(data: F.data(F.page(F.organization(), next: "c2"))),
            MockHTTPResponse(data: F.data(F.page(F.organization(id: F.otherOrgID, name: "Second Club")))),
        ])
        let model = model(http)
        await model.load(sessionState: nil)
        XCTAssertTrue(model.hasMore)

        await model.loadMore(sessionState: nil)

        XCTAssertEqual(query(http, 1)["cursor"], "c2")
        XCTAssertEqual(model.organizations.map(\.name), ["Riverside Club", "Second Club"])
        XCTAssertFalse(model.hasMore)

        await model.loadMore(sessionState: nil)
        XCTAssertEqual(http.state.requests(path: F.base).count, 2, "nothing more to ask for")
    }

    func testAPageThatRepeatsARowDoesNotShowItTwice() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: F.base, responses: [
            MockHTTPResponse(data: F.data(F.page(F.organization(), next: "c2"))),
            MockHTTPResponse(data: F.data(F.page(F.organization(), F.organization(id: F.otherOrgID, name: "Second Club")))),
        ])
        let model = model(http)
        await model.load(sessionState: nil)

        await model.loadMore(sessionState: nil)

        XCTAssertEqual(model.organizations.map(\.id), [F.orgID, F.otherOrgID])
    }

    func testNoMatchIsAnEmptyListAndNotAFailure() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stub(path: F.base, data: F.data(F.page()))
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertTrue(model.organizations.isEmpty)
        XCTAssertNil(model.failure)
        XCTAssertFalse(model.isLoading)
    }

    func testAFailedLoadSaysWhatKindOfFailureItWasAndTryingAgainRecovers() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: F.base, responses: [
            MockHTTPResponse(data: F.data(F.error("tenant_unavailable", message: "Tenant administration is unavailable")), status: 503),
            MockHTTPResponse(data: F.data(F.page(F.organization()))),
        ])
        let model = model(http)

        await model.load(sessionState: nil)

        let failure = try XCTUnwrap(model.failure)
        XCTAssertEqual(failure.kind, .serverFailure)
        XCTAssertEqual(failure.message, "Tenant administration is unavailable")
        XCTAssertTrue(model.organizations.isEmpty)

        await model.load(sessionState: nil)

        XCTAssertNil(model.failure)
        XCTAssertEqual(model.organizations.count, 1)
    }

    func testANoAccessAnswerIsSaidAsNoAccess() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: F.mint, data: F.data(F.error("insufficient_platform_authority", message: "Platform administrator authority required")), status: 403)
        let model = model(http)

        await model.load(sessionState: nil)

        XCTAssertEqual(model.failure?.kind, .forbidden)
    }

    func testAFailedMoreKeepsTheListAndSaysSo() async throws {
        let http = harness()
        defer { http.invalidate() }
        http.state.stubSequence(path: F.base, responses: [
            MockHTTPResponse(data: F.data(F.page(F.organization(), next: "c2"))),
            MockHTTPResponse(data: F.data(F.error("tenant_unavailable", message: "Tenant administration is unavailable")), status: 503),
        ])
        let model = model(http)
        await model.load(sessionState: nil)

        await model.loadMore(sessionState: nil)

        XCTAssertEqual(model.organizations.count, 1, "what was loaded stays")
        XCTAssertNil(model.failure, "the page itself did not fail")
        XCTAssertEqual(model.moreFailure, "Tenant administration is unavailable")
        XCTAssertTrue(model.hasMore, "the same page can be asked for again")
    }
}
