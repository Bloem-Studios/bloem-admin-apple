import XCTest
@testable import BloemAdmin

final class DeepLinkRouteTests: XCTestCase {
    private func route(_ string: String) -> DeepLinkRoute? {
        URL(string: string).flatMap(DeepLinkRoute.init(url:))
    }

    // MARK: Parsing

    func testServerWithPage() {
        XCTAssertEqual(
            route("bloemadmin://server/3F2A9C10-7B1E-4C55-9D0A-1B2C3D4E5F60/work.requests"),
            DeepLinkRoute(target: .server("3F2A9C10-7B1E-4C55-9D0A-1B2C3D4E5F60"), pageID: "work.requests")
        )
    }

    func testServerWithoutPageOpensItsStartPage() {
        XCTAssertEqual(route("bloemadmin://server/abc"), DeepLinkRoute(target: .server("abc"), pageID: nil))
        XCTAssertEqual(route("bloemadmin://server/abc/"), DeepLinkRoute(target: .server("abc"), pageID: nil))
    }

    func testAllServersWithAndWithoutPage() {
        XCTAssertEqual(route("bloemadmin://all"), DeepLinkRoute(target: .allServers, pageID: nil))
        XCTAssertEqual(route("bloemadmin://all/live.streams"), DeepLinkRoute(target: .allServers, pageID: "live.streams"))
    }

    func testSchemeAndHostIgnoreCase() {
        XCTAssertEqual(route("BloemAdmin://ALL/overview.dashboard"),
                       DeepLinkRoute(target: .allServers, pageID: "overview.dashboard"))
    }

    func testRefusesAnythingElse() {
        let refused = [
            "https://server/abc",                       // another scheme
            "org.siloserver.silo://server/abc",         // the OAuth redirect scheme
            "bloemadmin://",                            // no target
            "bloemadmin://servers/abc",                 // unknown target
            "bloemadmin://server",                      // no server id
            "bloemadmin://server//work.requests",       // empty server id
            "bloemadmin://server/abc/work.requests/1/extra",  // too many segments
            "bloemadmin://server/abc/work.requests/a%20b",    // an item that is not a plain id
            "bloemadmin://server/abc/work.requests//",        // an empty item
            "bloemadmin://all/live.streams/extra",
            "bloemadmin://all/work.requests/1",               // an item belongs to one server's page
            "bloemadmin://user:pw@all",                 // sign-in details
            "bloemadmin://all:8080",                    // port
            "bloemadmin://server/a%20b",                // not a plain id
            "bloemadmin://server/abc/work requests",
            "bloemadmin://all/..%2Fx",
            "bloemadmin://all?next=evil",               // query
            "bloemadmin://all#frag",                    // fragment
        ]
        for string in refused {
            XCTAssertNil(route(string), string)
        }
        XCTAssertNil(route("bloemadmin://server/" + String(repeating: "a", count: 129)))
        XCTAssertNil(route("bloemadmin://all/" + String(repeating: "a", count: 65)))
        XCTAssertNil(route("bloemadmin://server/abc/work.requests/" + String(repeating: "a", count: 129)))
    }

    // MARK: Building

    func testURLRoundTrips() {
        let routes = [
            DeepLinkRoute(target: .allServers, pageID: nil),
            DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.requests),
            DeepLinkRoute(target: .server("3F2A9C10-7B1E-4C55-9D0A-1B2C3D4E5F60"), pageID: nil),
            DeepLinkRoute(target: .server("3F2A9C10-7B1E-4C55-9D0A-1B2C3D4E5F60"), pageID: DeepLinkPage.dashboard),
        ]
        for original in routes {
            XCTAssertEqual(DeepLinkRoute(url: original.url), original, original.url.absoluteString)
        }
        XCTAssertEqual(
            DeepLinkRoute(target: .server("abc"), pageID: "live.streams").url.absoluteString,
            "bloemadmin://server/abc/live.streams"
        )
        XCTAssertEqual(DeepLinkRoute(target: .allServers, pageID: nil).url.absoluteString, "bloemadmin://all")
    }

    // MARK: Collisions

    func testSchemeDiffersFromTheOAuthRedirectScheme() {
        XCTAssertNotEqual(DeepLinkRoute.scheme, OAuthRedirectSpec.scheme)
        XCTAssertNotEqual(DeepLinkRoute.scheme.lowercased(), OAuthRedirectSpec.scheme.lowercased())
    }

    func testPageNamesAreTheMenuPageIDs() {
        XCTAssertEqual(DeepLinkPage.nowPlaying, AdminDestination.nowPlaying.id)
        XCTAssertEqual(DeepLinkPage.dashboard, AdminDestination.dashboard.id)
        XCTAssertEqual(DeepLinkPage.requests, AdminDestination.requests.id)
    }

    // MARK: Quick actions

    func testQuickActionsMapToRoutes() {
        XCTAssertEqual(DeepLinkRoute(quickActionType: "com.bloemstudios.admin.quick.now-playing"),
                       DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.nowPlaying))
        XCTAssertEqual(DeepLinkRoute(quickActionType: "com.bloemstudios.admin.quick.requests"),
                       DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.requests))
        XCTAssertEqual(DeepLinkRoute(quickActionType: "com.bloemstudios.admin.quick.dashboard"),
                       DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.dashboard))
        XCTAssertNil(DeepLinkRoute(quickActionType: "com.example.other"))
    }

    // MARK: The hand-off between whatever receives a link and the window

    @MainActor
    func testCenterKeepsTheLatestLinkUntilTaken() {
        let center = DeepLinkCenter()
        XCTAssertNil(center.pending)
        XCTAssertFalse(center.receive(URL(string: "https://example.test")!))
        XCTAssertNil(center.pending)

        XCTAssertTrue(center.receive(URL(string: "bloemadmin://all/work.requests")!))
        center.submit(DeepLinkRoute(target: .server("abc"), pageID: nil))
        XCTAssertEqual(center.pending, DeepLinkRoute(target: .server("abc"), pageID: nil))
        XCTAssertEqual(center.take(), DeepLinkRoute(target: .server("abc"), pageID: nil))
        XCTAssertNil(center.pending)
        XCTAssertNil(center.take())
    }
}
