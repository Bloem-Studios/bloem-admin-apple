import XCTest
@testable import BloemAdmin

@MainActor
final class TenantsViewModelTests: XCTestCase {

    // MARK: - Tenant list decode

    func testInitialTenantAndMemberListsAreLoadingRatherThanEmpty() {
        let viewModel = TenantsViewModel()

        XCTAssertEqual(viewModel.tenantsPresentation, .loading)
        XCTAssertEqual(viewModel.membersPresentation, .loading)
    }

    func testSuccessfulZeroItemLoadsResolveTenantAndMemberListsToEmpty() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data("[]".utf8)
        http.state.responseStatus = 200
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = TenantsViewModel()

        await viewModel.load(client: client)
        await viewModel.loadMembers(tenantID: "t-1", client: client)

        XCTAssertEqual(viewModel.tenantsPresentation, .empty)
        XCTAssertEqual(viewModel.membersPresentation, .empty)
    }

    func testLoadDecodesTenantsWithOptionalFieldsPresent() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"""
        [{"tenant_id":"t-1","name":"Acme Hosting","external_ref":{"operator_id":"op-1","service_id":"svc-1"},"limits":{"slots":10,"transcodes":2},"usage":{"slots_used":7},"frozen":false,"frozen_reason":"","applied_entitlement_revision":3}]
        """#.utf8)
        http.state.responseStatus = 200
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = TenantsViewModel()

        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.tenants.count, 1)
        let tenant = try? XCTUnwrap(viewModel.tenants.first)
        XCTAssertEqual(tenant?.tenantId, "t-1")
        XCTAssertEqual(tenant?.name, "Acme Hosting")
        XCTAssertEqual(tenant?.limits?.slots, 10)
        XCTAssertEqual(tenant?.limits?.transcodes, 2)
        XCTAssertEqual(tenant?.usage?.slotsUsed, 7)
        XCTAssertEqual(tenant?.frozen, false)
        XCTAssertEqual(tenant?.appliedEntitlementRevision, 3)
        XCTAssertEqual(tenant?.slotsUsageText, "7 / 10 slots")
        XCTAssertEqual(tenant?.transcodeLimitText, "2 transcodes")
    }

    /// `frozen_reason` and `applied_entitlement_revision` are documented as
    /// optional/`omitempty` — proves decoding tolerates both being entirely
    /// absent from the JSON.
    func testLoadDecodesTenantsWithOptionalFieldsAbsent() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"""
        [{"tenant_id":"t-2","name":"Bare Tenant","limits":{"slots":5,"transcodes":1},"usage":{"slots_used":0},"frozen":true}]
        """#.utf8)
        http.state.responseStatus = 200
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = TenantsViewModel()

        await viewModel.load(client: client)

        let tenant = try? XCTUnwrap(viewModel.tenants.first)
        XCTAssertNil(tenant?.frozenReason)
        XCTAssertNil(tenant?.appliedEntitlementRevision)
        XCTAssertEqual(tenant?.frozen, true)
    }

    func testLoadFailureSetsErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"server_error","message":"Something broke"}"#.utf8)
        http.state.responseStatus = 500
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = TenantsViewModel()

        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.errorMessage, "Something broke")
        XCTAssertTrue(viewModel.tenants.isEmpty)
    }

    // MARK: - Tenant member list decode

    func testLoadMembersDecodesMemberList() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"""
        [{"user_id":42,"username":"alice","email":"alice@example.com","status":"active"},{"user_id":43,"username":"bob","email":"bob@example.com","status":"suspended"}]
        """#.utf8)
        http.state.responseStatus = 200
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = TenantsViewModel()

        await viewModel.loadMembers(tenantID: "t-1", client: client)

        XCTAssertEqual(viewModel.members.count, 2)
        XCTAssertEqual(viewModel.members.first?.userId, 42)
        XCTAssertEqual(viewModel.members.first?.username, "alice")
        XCTAssertEqual(viewModel.members.first?.status, "active")
        XCTAssertEqual(viewModel.members.last?.status, "suspended")
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/bloem/v2/admin/platform/tenants/t-1/members")
    }

    func testLoadMembersFailureSetsMembersErrorMessageDistinctFromTenantsError() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"not_found","message":"Tenant not found"}"#.utf8)
        http.state.responseStatus = 404
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = TenantsViewModel()

        await viewModel.loadMembers(tenantID: "missing", client: client)

        XCTAssertEqual(viewModel.membersErrorMessage, "Tenant not found")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testChangingTenantClearsPreviousMembersAndFailureCannotShowThem() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let tenantAData = Data(#"[{"user_id":42,"username":"alice","email":"alice@example.com","status":"active"}]"#.utf8)
        let tenantBFailure = Data(#"{"error":"server_error","message":"Tenant B unavailable"}"#.utf8)
        http.state.stub(path: "/api/bloem/v2/admin/platform/tenants/a/members", response: MockHTTPResponse(data: tenantAData, status: 200))
        http.state.stub(
            path: "/api/bloem/v2/admin/platform/tenants/b/members",
            response: MockHTTPResponse(data: tenantBFailure, status: 500),
            delayUntilReleased: true
        )
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = TenantsViewModel()

        await viewModel.loadMembers(tenantID: "a", client: client)
        XCTAssertEqual(viewModel.members.first?.username, "alice")

        let tenantBLoad = Task { await viewModel.loadMembers(tenantID: "b", client: client) }
        await http.state.waitForRequest(path: "/api/bloem/v2/admin/platform/tenants/b/members")
        XCTAssertTrue(viewModel.members.isEmpty)
        XCTAssertEqual(viewModel.membersPresentation, .loading)

        http.state.releaseResponses(matching: "/api/bloem/v2/admin/platform/tenants/b/members")
        await tenantBLoad.value

        XCTAssertTrue(viewModel.members.isEmpty)
        XCTAssertEqual(viewModel.membersPresentation, .failure)
        XCTAssertEqual(viewModel.membersErrorMessage, "Tenant B unavailable")
    }

    func testOlderTenantMemberResponseCannotReplaceCurrentTenantMembers() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let tenantAData = Data(#"[{"user_id":42,"username":"alice","email":"alice@example.com","status":"active"}]"#.utf8)
        let tenantBData = Data(#"[{"user_id":43,"username":"bob","email":"bob@example.com","status":"active"}]"#.utf8)
        http.state.stub(
            path: "/api/bloem/v2/admin/platform/tenants/a/members",
            response: MockHTTPResponse(data: tenantAData, status: 200),
            delayUntilReleased: true
        )
        http.state.stub(path: "/api/bloem/v2/admin/platform/tenants/b/members", response: MockHTTPResponse(data: tenantBData, status: 200))
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        let viewModel = TenantsViewModel()

        let tenantALoad = Task { await viewModel.loadMembers(tenantID: "a", client: client) }
        await http.state.waitForRequest(path: "/api/bloem/v2/admin/platform/tenants/a/members")
        await viewModel.loadMembers(tenantID: "b", client: client)

        XCTAssertEqual(viewModel.members.map(\.username), ["bob"])

        http.state.releaseResponses(matching: "/api/bloem/v2/admin/platform/tenants/a/members")
        await tenantALoad.value

        XCTAssertEqual(viewModel.members.map(\.username), ["bob"])
    }
}
