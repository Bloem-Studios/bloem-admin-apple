import Foundation
@testable import BloemAdmin

/// The moment the fixtures' pass was minted: 15 minutes before its `expires_at`. A fixed clock keeps a write from
/// renewing the pass first just because the machine's own date has moved on.
let organizationFixtureNow = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!

/// An opened organization session over a mock server whose mint answers with `OrganizationFixtures.session`.
@MainActor
func openedOrganizationSession(
    _ http: MockHTTPHarness,
    policyRevision: Int = 7,
    now: @escaping () -> Date = { organizationFixtureNow }
) async throws -> OrganizationSession {
    http.state.stub(path: "/api/bloem/v2/admin/session", data: OrganizationFixtures.data(OrganizationFixtures.session(policyRevision: policyRevision)))
    let account = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "account-token", session: http.session)
    let session = OrganizationSession(
        account: account, baseURL: URL(string: "https://example.test")!, organizationID: OrganizationFixtures.orgID,
        session: http.session, now: now
    )
    try await session.open()
    return session
}

extension MockHTTPState {
    /// Stubs a route under `/api/bloem/v2/admin/organization`.
    func stubOrganization(_ route: String, _ body: String, status: Int = 200) {
        stub(path: "\(OrganizationFixtures.base)\(route)", data: OrganizationFixtures.data(body), status: status)
    }

    func organizationRequests(_ route: String) -> [URLRequest] {
        requests(path: "\(OrganizationFixtures.base)\(route)")
    }

    func organizationBody(_ route: String, index: Int = 0) -> [String: Any]? {
        guard let data = body(path: "\(OrganizationFixtures.base)\(route)", requestIndex: index) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
