import XCTest
@testable import BloemAdmin

final class ContextDropdownTests: XCTestCase {
    private let servers = [ScopeOption(id: "a", displayName: "Alpha"), ScopeOption(id: "b", displayName: "Beta")]

    func testListsAllServersThenEachSavedServer() {
        let model = ContextDropdownModel(allServers: true, selectedServerID: nil, servers: servers)
        XCTAssertEqual(model.items.map(\.title), ["All servers", "Alpha", "Beta"])
        XCTAssertEqual(model.items.map(\.isSelected), [true, false, false])
        XCTAssertEqual(model.title, "All servers")
    }

    func testTheSelectedServerIsMarkedAndNamesTheButton() {
        let model = ContextDropdownModel(allServers: false, selectedServerID: "b", servers: servers)
        XCTAssertEqual(model.items.map(\.isSelected), [false, false, true])
        XCTAssertEqual(model.title, "Beta")
    }

    func testAllServersIsDimmedWithNoSavedServer() {
        let model = ContextDropdownModel(allServers: true, selectedServerID: nil, servers: [])
        XCTAssertEqual(model.items.count, 1)
        XCTAssertFalse(model.items[0].isEnabled)
        XCTAssertTrue(ContextDropdownModel(allServers: true, selectedServerID: nil, servers: servers).items[0].isEnabled)
    }

    func testOrganizationsAreListedIndentedUnderTheirServer() {
        let model = ContextDropdownModel(
            allServers: false,
            selectedServerID: "a",
            servers: servers,
            organizations: [
                ScopeOrganization(serverID: "b", organizationID: "o2", displayName: "Second"),
                ScopeOrganization(serverID: "a", organizationID: "o1", displayName: "First"),
            ],
            selectedOrganizationID: nil
        )
        XCTAssertEqual(model.items.map(\.title), ["All servers", "Alpha", "First", "Beta", "Second"])
        XCTAssertEqual(model.items.map(\.isIndented), [false, false, true, false, true])
        XCTAssertEqual(model.items.map(\.isSelected), [false, true, false, false, false])
    }

    func testAnOpenOrganizationIsTheSelectedOneAndNamesTheButton() {
        let organization = ScopeOrganization(serverID: "a", organizationID: "o1", displayName: "First")
        let model = ContextDropdownModel(
            allServers: false, selectedServerID: "a", servers: servers,
            organizations: [organization], selectedOrganizationID: "o1"
        )
        XCTAssertEqual(model.items.map(\.isSelected), [false, false, true, false])
        XCTAssertEqual(model.title, "First")
    }

    func testOrganizationsAreEmptyByDefault() {
        XCTAssertTrue(ContextDropdownModel(allServers: true, selectedServerID: nil, servers: servers).organizations.isEmpty)
    }

    @MainActor
    func testRouterHooksForOrganizationsStartEmptyAndDoNothing() {
        let router = ShellRouter()
        XCTAssertTrue(router.organizations.isEmpty)
        XCTAssertNil(router.selectedOrganizationID)
        router.onSelectOrganization(ScopeOrganization(serverID: "a", organizationID: "o", displayName: "O"))
        XCTAssertEqual(router.scope, .allServers)
    }

    func testChoosingARowCallsTheMatchingCallback() {
        var calls: [String] = []
        let organization = ScopeOrganization(serverID: "a", organizationID: "o1", displayName: "First")
        let control = ScopeControl(
            model: ContextDropdownModel(allServers: true, selectedServerID: nil, servers: servers, organizations: [organization]),
            onSelectAllServers: { calls.append("all") },
            onSelectServer: { calls.append("server:\($0)") },
            onSelectOrganization: { calls.append("org:\($0.organizationID)") }
        )
        control.model.items.forEach(control.select)
        XCTAssertEqual(calls, ["all", "server:a", "org:o1", "server:b"])
    }

    func testStartScopeFallsBackToAllServers() {
        XCTAssertEqual(ShellScope.start(allServers: true, selectedServerID: "a", savedIDs: ["a"]), .allServers)
        XCTAssertEqual(ShellScope.start(allServers: false, selectedServerID: "a", savedIDs: ["a"]), .server("a"))
        XCTAssertEqual(ShellScope.start(allServers: false, selectedServerID: "gone", savedIDs: ["a"]), .allServers)
        XCTAssertEqual(ShellScope.start(allServers: false, selectedServerID: nil, savedIDs: ["a"]), .allServers)
    }

    func testPreferencesRememberTheLastScope() throws {
        let suite = "ContextDropdownTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = ShellScopePreferences(defaults: defaults)
        XCTAssertEqual(preferences.startScope(savedIDs: ["a"]), .allServers)
        preferences.remember(.server("a"))
        XCTAssertEqual(preferences.startScope(savedIDs: ["a"]), .server("a"))
        XCTAssertEqual(preferences.startScope(savedIDs: []), .allServers, "a removed server falls back")
        preferences.remember(.allServers)
        XCTAssertEqual(preferences.startScope(savedIDs: ["a"]), .allServers)
        preferences.remember(.server("a"))
        preferences.reset()
        XCTAssertEqual(preferences.startScope(savedIDs: ["a"]), .allServers)
    }
}
