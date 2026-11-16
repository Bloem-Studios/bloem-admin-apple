import XCTest
@testable import BloemAdmin

/// A link that names an item on a page: the grammar, and what the shell does with it.
@MainActor
final class PushLinkTests: XCTestCase {
    private func route(_ string: String) -> DeepLinkRoute? {
        URL(string: string).flatMap(DeepLinkRoute.init(url:))
    }

    private func router() -> ShellRouter {
        let suite = "PushLinkTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return ShellRouter(scope: .allServers, preferences: ShellScopePreferences(defaults: defaults))
    }

    // MARK: The grammar

    func testAServerLinkMayNameAPageAndAnItemOnIt() {
        XCTAssertEqual(
            route("bloemadmin://server/s1/work.requests/9f1c-7"),
            DeepLinkRoute(target: .server("s1"), pageID: "work.requests", itemID: "9f1c-7")
        )
        XCTAssertEqual(route("bloemadmin://server/s1/work.requests/9f1c-7")?.itemID, "9f1c-7")
        XCTAssertNil(route("bloemadmin://server/s1/work.requests")?.itemID)
        XCTAssertNil(route("bloemadmin://server/s1")?.itemID)
    }

    func testTheItemRoundTripsAndOnlyTravelsWithAPage() {
        let withItem = DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.plugins, itemID: "silo.tmdb-provider")
        XCTAssertEqual(withItem.url.absoluteString, "bloemadmin://server/s1/system.plugins/silo.tmdb-provider")
        XCTAssertEqual(DeepLinkRoute(url: withItem.url), withItem)
        XCTAssertEqual(
            DeepLinkRoute(target: .server("s1"), pageID: nil, itemID: "lost").url.absoluteString,
            "bloemadmin://server/s1",
            "an item with no page would read as a page"
        )
    }

    func testTheItemAllowsWhatAServerIdAllowsAndNothingMore() {
        XCTAssertNotNil(route("bloemadmin://server/s1/content.libraries/" + String(repeating: "a", count: 128)))
        XCTAssertNil(route("bloemadmin://server/s1/content.libraries/" + String(repeating: "a", count: 129)))
        for bad in ["a%2Fb", "a%20b", "a?b", "a#b", "a:b", "%2E%2E%2F"] {
            XCTAssertNil(route("bloemadmin://server/s1/content.libraries/\(bad)"), bad)
        }
        XCTAssertNil(route("bloemadmin://all/work.requests/9"), "all servers has no single item")
    }

    func testTheNewPageIdsAreTheMenusIds() {
        XCTAssertEqual(DeepLinkPage.backups, AdminDestination.backups.id)
        XCTAssertEqual(DeepLinkPage.plugins, AdminDestination.plugins.id)
        XCTAssertEqual(DeepLinkPage.libraries, AdminDestination.libraries.id)
        XCTAssertEqual(DeepLinkPage.nodes, AdminDestination.nodes.id)
        XCTAssertEqual(DeepLinkPage.requests, AdminDestination.requests.id)
    }

    // MARK: What the shell does

    func testALinkWithAnItemMovesToThePageAndAsksItToShowTheItem() {
        let router = router()
        let opened = router.open(
            DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.requests, itemID: "req-9"), savedServerIDs: ["s1"]
        )

        XCTAssertTrue(opened)
        XCTAssertEqual(router.scope, .server("s1"))
        XCTAssertEqual(router.selectedDestinationID, DeepLinkPage.requests)
        XCTAssertEqual(router.itemFocus, ItemFocus(pageID: DeepLinkPage.requests, itemID: "req-9"))
    }

    func testThePageTakesTheItemOnce() {
        let router = router()
        router.open(DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.libraries, itemID: "lib-4"), savedServerIDs: ["s1"])

        XCTAssertNil(router.takeItemFocus(for: DeepLinkPage.requests), "another page does not take it")
        XCTAssertEqual(router.takeItemFocus(for: DeepLinkPage.libraries), "lib-4")
        XCTAssertNil(router.takeItemFocus(for: DeepLinkPage.libraries))
        XCTAssertNil(router.itemFocus)
    }

    func testAPageLinkWithNoItemAsksForNone() {
        let router = router()
        router.open(DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.backups), savedServerIDs: ["s1"])
        XCTAssertEqual(router.selectedDestinationID, DeepLinkPage.backups)
        XCTAssertNil(router.itemFocus)
    }

    func testAnItemForAnUnknownPageIsDropped() {
        let router = router()
        router.open(DeepLinkRoute(target: .server("s1"), pageID: "no.such.page", itemID: "x"), savedServerIDs: ["s1"])
        XCTAssertEqual(router.selectedDestinationID, AdminDestination.startID)
        XCTAssertNil(router.itemFocus)
    }

    func testALinkToAServerThatIsNotSavedChangesNothing() {
        let router = router()
        let opened = router.open(
            DeepLinkRoute(target: .server("gone"), pageID: DeepLinkPage.requests, itemID: "req-9"), savedServerIDs: ["s1"]
        )
        XCTAssertFalse(opened)
        XCTAssertNil(router.itemFocus)
        XCTAssertEqual(router.scope, .allServers)
    }

    func testGoingAnywhereByHandForgetsAWaitingItem() {
        let router = router()
        router.open(DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.requests, itemID: "req-9"), savedServerIDs: ["s1"])
        router.select(destinationID: DeepLinkPage.nodes)
        XCTAssertNil(router.itemFocus, "a later visit to Requests must not open a request nobody asked for")
    }

    func testANewerLinkReplacesAnItemStillWaiting() {
        let router = router()
        router.open(DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.requests, itemID: "old"), savedServerIDs: ["s1"])
        router.open(DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.requests, itemID: "new"), savedServerIDs: ["s1"])
        XCTAssertEqual(router.takeItemFocus(for: DeepLinkPage.requests), "new")
    }

    func testALinkWaitsForTheAppLockLikeEveryOther() {
        let center = DeepLinkCenter()
        let link = DeepLinkRoute(target: .server("s1"), pageID: DeepLinkPage.requests, itemID: "req-9")
        center.submit(link)
        XCTAssertEqual(center.pending, link, "a tap is only handed over; DeepLinkHandling applies it once the lock is open")
        XCTAssertEqual(center.take(), link)
        XCTAssertNil(center.pending)
    }

    // MARK: Preferences

    func testEveryKindIsOnUntilSwitchedOffPerServer() {
        let (defaults, suite) = AlertTestDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PushPreferences(defaults: defaults)

        for kind in PushKind.allCases { XCTAssertTrue(preferences.isEnabled(kind, serverID: "a")) }
        preferences.setKind(.scanFailed, enabled: false, serverID: "a")
        preferences.setKind(.serverUp, enabled: false, serverID: "a")

        XCTAssertFalse(preferences.isEnabled(.scanFailed, serverID: "a"))
        XCTAssertTrue(preferences.isEnabled(.scanFailed, serverID: "b"))
        XCTAssertEqual(preferences.disabledRemoteKinds(serverID: "a"), ["admin.scan_failed"])
        XCTAssertEqual(PushPreferences(defaults: defaults).disabledKinds(serverID: "a"), [.scanFailed, .serverUp], "kept across launches")

        preferences.setKind(.scanFailed, enabled: true, serverID: "a")
        XCTAssertTrue(preferences.isEnabled(.scanFailed, serverID: "a"))
    }

    func testPermissionAskedAndTheInstallationIdAreKept() {
        let (defaults, suite) = AlertTestDefaults.make()
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PushPreferences(defaults: defaults)

        XCTAssertFalse(preferences.permissionAsked)
        preferences.permissionAsked = true
        XCTAssertTrue(PushPreferences(defaults: defaults).permissionAsked)
        XCTAssertEqual(preferences.installationID, PushPreferences(defaults: defaults).installationID)
        XCTAssertNil(preferences.apnsToken)
        preferences.apnsToken = "ab12"
        XCTAssertEqual(PushPreferences(defaults: defaults).apnsToken, "ab12")
    }

    func testTheLocalServerAlertsShareAThreadPerServer() {
        let down = AlertNotificationContent.serverDown(serverID: "s1", name: "Home", since: nil, reason: nil, showsDetails: false)
        let back = AlertNotificationContent.serverBack(serverID: "s1", name: "Home", at: Date(), showsDetails: false)
        XCTAssertEqual(down.threadIdentifier, back.threadIdentifier, "each replaces the other")
        XCTAssertEqual(down.threadIdentifier, PushKind.serverDown.threadIdentifier(serverID: "s1"))
    }
}
