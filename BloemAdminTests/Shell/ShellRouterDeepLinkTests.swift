import XCTest
@testable import BloemAdmin

@MainActor
final class ShellRouterDeepLinkTests: XCTestCase {
    private func makeRouter(scope: ShellScope = .allServers) throws -> (ShellRouter, UserDefaults, String) {
        let suite = "ShellRouterDeepLinkTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ShellRouter(scope: scope, preferences: ShellScopePreferences(defaults: defaults)), defaults, suite)
    }

    func testOpensASavedServerOnThePage() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        let opened = router.open(
            DeepLinkRoute(target: .server("a"), pageID: DeepLinkPage.requests),
            savedServerIDs: ["a", "b"]
        )
        XCTAssertTrue(opened)
        XCTAssertEqual(router.scope, .server("a"))
        XCTAssertEqual(router.selectedDestinationID, "work.requests")
    }

    func testServerWithoutAPageOpensOnNowPlaying() throws {
        let (router, defaults, suite) = try makeRouter(scope: .server("a"))
        defer { defaults.removePersistentDomain(forName: suite) }
        router.select(destinationID: "people.users")
        XCTAssertTrue(router.open(DeepLinkRoute(target: .server("a"), pageID: nil), savedServerIDs: ["a"]))
        XCTAssertEqual(router.selectedDestinationID, "live.streams")
    }

    func testAllServersOpensThePage() throws {
        let (router, defaults, suite) = try makeRouter(scope: .server("a"))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(router.open(DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.dashboard), savedServerIDs: ["a"]))
        XCTAssertEqual(router.scope, .allServers)
        XCTAssertEqual(router.selectedDestinationID, "overview.dashboard")
    }

    func testAServerThatIsNotSavedChangesNothing() throws {
        let (router, defaults, suite) = try makeRouter(scope: .server("a"))
        defer { defaults.removePersistentDomain(forName: suite) }
        router.select(destinationID: "people.users")
        router.isShowingAppSettings = true
        XCTAssertFalse(router.open(DeepLinkRoute(target: .server("gone"), pageID: nil), savedServerIDs: ["a"]))
        XCTAssertEqual(router.scope, .server("a"))
        XCTAssertEqual(router.selectedDestinationID, "people.users")
        XCTAssertTrue(router.isShowingAppSettings)
    }

    func testAnUnknownPageFallsBackToNowPlaying() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        router.select(destinationID: "work.jobs")
        XCTAssertTrue(router.open(DeepLinkRoute(target: .allServers, pageID: "nodes.list"), savedServerIDs: []))
        XCTAssertEqual(router.selectedDestinationID, "live.streams")
        // An organization page id is not a link target either.
        XCTAssertTrue(router.open(DeepLinkRoute(target: .allServers, pageID: "organization.people"), savedServerIDs: []))
        XCTAssertEqual(router.selectedDestinationID, "live.streams")
    }

    func testClosesWhatCoversThePage() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        router.isManagingServers = true
        router.isShowingAppSettings = true
        router.isAddingServer = true
        router.isMenuOpen = true
        router.isSearching = true
        XCTAssertTrue(router.open(DeepLinkRoute(target: .allServers, pageID: nil), savedServerIDs: []))
        XCTAssertFalse(router.coversPage)
    }

    func testLeavesAnOpenOrganizationForTheServerPage() throws {
        let (router, defaults, suite) = try makeRouter(scope: .server("a"))
        defer { defaults.removePersistentDomain(forName: suite) }
        router.selectedOrganizationID = "org-1"
        XCTAssertTrue(router.open(DeepLinkRoute(target: .server("a"), pageID: DeepLinkPage.requests), savedServerIDs: ["a"]))
        XCTAssertNil(router.selectedOrganizationID)
        XCTAssertEqual(router.selectedDestinationID, "work.requests")
    }
}
