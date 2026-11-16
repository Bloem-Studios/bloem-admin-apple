import XCTest
@testable import BloemAdmin

/// The App Shortcuts, the control and the quick actions all end in a `DeepLinkRoute`.
final class OpenPageIntentsTests: XCTestCase {
    func testWithoutAServerEachIntentOpensItsPageAcrossAllServers() {
        XCTAssertEqual(OpenNowPlayingIntent().route, DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.nowPlaying))
        XCTAssertEqual(OpenRequestsIntent().route, DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.requests))
        XCTAssertEqual(OpenDashboardIntent().route, DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.dashboard))
    }

    func testWithAServerEachIntentOpensThatServersPage() {
        let server = ServerEntity(id: "abc", name: "Home")
        XCTAssertEqual(
            OpenNowPlayingIntent(server: server).route,
            DeepLinkRoute(target: .server("abc"), pageID: DeepLinkPage.nowPlaying)
        )
        XCTAssertEqual(
            OpenRequestsIntent(server: server).route,
            DeepLinkRoute(target: .server("abc"), pageID: DeepLinkPage.requests)
        )
        XCTAssertEqual(
            OpenDashboardIntent(server: server).route,
            DeepLinkRoute(target: .server("abc"), pageID: DeepLinkPage.dashboard)
        )
    }

    func testEveryIntentOpensTheApp() {
        XCTAssertTrue(OpenNowPlayingIntent.openAppWhenRun)
        XCTAssertTrue(OpenRequestsIntent.openAppWhenRun)
        XCTAssertTrue(OpenDashboardIntent.openAppWhenRun)
    }

    @MainActor
    func testPerformingAnIntentLeavesTheLinkWaitingForTheLock() async throws {
        let center = DeepLinkCenter.shared
        _ = center.take()
        _ = try await OpenRequestsIntent(server: ServerEntity(id: "abc", name: "Home")).perform()
        XCTAssertEqual(center.take(), DeepLinkRoute(target: .server("abc"), pageID: DeepLinkPage.requests))
    }

    func testTheQuickActionsDeclaredInProjectYmlAreTheOnesTheAppHandles() throws {
        let yml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        for type in [
            DeepLinkRoute.QuickAction.nowPlaying, DeepLinkRoute.QuickAction.requests, DeepLinkRoute.QuickAction.dashboard,
        ] {
            XCTAssertTrue(yml.contains("UIApplicationShortcutItemType: \(type)"), type)
            XCTAssertNotNil(DeepLinkRoute(quickActionType: type), type)
        }
        XCTAssertEqual(yml.components(separatedBy: "UIApplicationShortcutItemType:").count - 1, 3)
    }

    func testTheLinkSchemeIsDeclaredInProjectYml() throws {
        let yml = try String(contentsOf: SourceTree.root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(yml.contains("CFBundleURLSchemes:\n              - \(DeepLinkRoute.scheme)"))
    }
}
