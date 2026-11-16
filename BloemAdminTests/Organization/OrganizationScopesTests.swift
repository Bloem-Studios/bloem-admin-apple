import XCTest
@testable import BloemAdmin

/// What the context dropdown lists under each server: its organization contexts, never the platform one.
final class OrganizationScopesTests: XCTestCase {
    private let home = AdminServer(id: "home", baseURL: URL(string: "https://home.example.test")!, displayName: "Home")
    private let away = AdminServer(id: "away", baseURL: URL(string: "https://away.example.test")!, displayName: "Away")

    private func organization(_ id: String, _ name: String) -> AdminContext {
        AdminContext(key: AdminContext.organizationKey(id), name: name, scope: .organization, organizationID: id, authority: .organizationAdmin)
    }

    private let platform = AdminContext(key: AdminContext.platformKey, name: "Platform", scope: .platform, organizationID: nil, authority: .platformAdmin)

    func testOrganizationsSitUnderTheirServerInServerOrder() {
        let listed = OrganizationScopes.list(
            servers: [home, away],
            contexts: ["away": [organization("o3", "Cole family")], "home": [platform, organization("o1", "Acme"), organization("o2", "Globex")]]
        )
        XCTAssertEqual(listed.map(\.id), ["home/o1", "home/o2", "away/o3"])
        XCTAssertEqual(listed.map(\.displayName), ["Acme", "Globex", "Cole family"])
    }

    func testThePlatformContextAndForgottenServersAreLeftOut() {
        let listed = OrganizationScopes.list(servers: [home], contexts: ["home": [platform], "gone": [organization("o9", "Old")]])
        XCTAssertEqual(listed, [])
    }

    func testAnOpenOrganizationFindsItsContextOnlyOnItsOwnServer() {
        let contexts = ["home": [platform, organization("o1", "Acme")]]
        XCTAssertEqual(OrganizationScopes.context(serverID: "home", organizationID: "o1", in: contexts)?.name, "Acme")
        XCTAssertNil(OrganizationScopes.context(serverID: "away", organizationID: "o1", in: contexts))
        XCTAssertNil(OrganizationScopes.context(serverID: "home", organizationID: "o2", in: contexts))
    }
}
