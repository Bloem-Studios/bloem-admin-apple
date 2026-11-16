import XCTest
@testable import BloemAdmin

@MainActor
final class ShellRouterTests: XCTestCase {
    private func makeRouter(scope: ShellScope = .allServers) throws -> (ShellRouter, UserDefaults, String) {
        let suite = "ShellRouterTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (ShellRouter(scope: scope, preferences: ShellScopePreferences(defaults: defaults)), defaults, suite)
    }

    func testOpensOnNowPlaying() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(router.selectedDestinationID, "live.streams")
    }

    func testSwitchingScopeReturnsToNowPlayingAndClosesWhatIsOpen() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        router.select(destinationID: "work.jobs")
        router.isMenuOpen = true
        router.isSearching = true
        router.select(scope: .server("a"))
        XCTAssertEqual(router.scope, .server("a"))
        XCTAssertEqual(router.selectedDestinationID, "live.streams")
        XCTAssertFalse(router.isMenuOpen)
        XCTAssertFalse(router.isSearching)
        XCTAssertEqual(ShellScopePreferences(defaults: defaults).selectedServerID, "a")
    }

    func testChoosingTheCurrentScopeAgainKeepsThePage() throws {
        let (router, defaults, suite) = try makeRouter(scope: .server("a"))
        defer { defaults.removePersistentDomain(forName: suite) }
        router.select(destinationID: "people.users")
        router.select(scope: .server("a"))
        XCTAssertEqual(router.selectedDestinationID, "people.users")
    }

    func testPickingAPageClosesTheMenuAndSearch() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        router.isMenuOpen = true
        router.isSearching = true
        router.select(destinationID: "system.audit")
        XCTAssertEqual(router.selectedDestinationID, "system.audit")
        XCTAssertFalse(router.isMenuOpen)
        XCTAssertFalse(router.isSearching)
    }

    func testSwipeMovesAlongTheMenuAndStopsAtTheEnds() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = AdminDestination.allServers
        router.swipe(step: -1, in: menu)
        XCTAssertEqual(router.selectedDestinationID, "overview.dashboard")
        router.swipe(step: -1, in: menu)
        XCTAssertEqual(router.selectedDestinationID, "platform.organizations", "Organizations lead the All servers menu")
        router.swipe(step: -1, in: menu)
        XCTAssertEqual(router.selectedDestinationID, "platform.organizations", "no wrap before the first page")
        router.swipe(step: 1, in: menu)
        router.swipe(step: 1, in: menu)
        XCTAssertEqual(router.selectedDestinationID, "live.streams")
        for _ in 0..<20 { router.swipe(step: 1, in: menu) }
        XCTAssertEqual(router.selectedDestinationID, "system.plugins", "no wrap past the last page")
        router.swipe(step: -1, in: menu)
        XCTAssertEqual(router.selectedDestinationID, "system.backups", "Backups sits before Plugins in the menu")
    }

    func testNoSwipeWhileSomethingCoversThePage() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        let menu = AdminDestination.allServers
        for cover in [\ShellRouter.isMenuOpen, \.isSearching, \.isManagingServers, \.isShowingAppSettings, \.isAddingServer, \.isSwitchingContext, \.isConfirmingSignOut] {
            router[keyPath: cover] = true
            router.swipe(step: 1, in: menu)
            XCTAssertEqual(router.selectedDestinationID, "live.streams", "\(cover) blocks the swipe")
            router[keyPath: cover] = false
        }
        router.swipe(step: 1, in: menu)
        XCTAssertEqual(router.selectedDestinationID, "system.audit")
    }

    func testARemovedServerFallsBackToAllServers() throws {
        let (router, defaults, suite) = try makeRouter(scope: .server("a"))
        defer { defaults.removePersistentDomain(forName: suite) }
        router.select(destinationID: "work.jobs")
        router.reconcile(savedServerIDs: ["a", "b"])
        XCTAssertEqual(router.scope, .server("a"))
        XCTAssertEqual(router.selectedDestinationID, "work.jobs")
        router.reconcile(savedServerIDs: ["b"])
        XCTAssertEqual(router.scope, .allServers)
        XCTAssertEqual(router.selectedDestinationID, "live.streams")
    }

    func testManageServersSettingsSwitcherAndSignOutCloseTheMenu() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        router.isMenuOpen = true
        router.openManageServers()
        XCTAssertTrue(router.isManagingServers)
        XCTAssertFalse(router.isMenuOpen)
        router.isMenuOpen = true
        router.openSettings()
        XCTAssertTrue(router.isShowingAppSettings)
        XCTAssertFalse(router.isMenuOpen)
        router.isMenuOpen = true
        router.openContextSwitcher()
        XCTAssertTrue(router.isSwitchingContext)
        XCTAssertFalse(router.isMenuOpen)
        router.isMenuOpen = true
        router.openSignOut()
        XCTAssertTrue(router.isConfirmingSignOut)
        XCTAssertFalse(router.isMenuOpen)
    }

    func testSettingsIsAPageThatAnyOtherPageOrScopeLeaves() throws {
        let (router, defaults, suite) = try makeRouter()
        defer { defaults.removePersistentDomain(forName: suite) }
        router.openSettings()
        router.select(destinationID: "people.users")
        XCTAssertFalse(router.isShowingAppSettings, "picking a page leaves Settings")
        XCTAssertEqual(router.selectedDestinationID, "people.users")

        router.openSettings()
        router.select(scope: .server("a"))
        XCTAssertFalse(router.isShowingAppSettings, "switching server leaves Settings")

        router.openSettings()
        router.select(scope: .server("a"))
        XCTAssertFalse(router.isShowingAppSettings, "choosing the current server also leaves Settings")
    }

    func testInteractionLockCountsLeases() {
        let lock = ShellInteractionLock()
        XCTAssertFalse(lock.isLocked)
        let first = lock.acquire()
        let second = lock.acquire()
        XCTAssertTrue(lock.isLocked)
        first.release()
        first.release()
        XCTAssertTrue(lock.isLocked, "releasing twice frees one lease only")
        second.release()
        XCTAssertFalse(lock.isLocked)
    }
}
