import XCTest
@testable import BloemAdmin

/// "Logs" and "FFmpeg logs" from a stream or a Playback history row open the Logs page already
/// filtered to that playback session. The router carries the request across the page change.
@MainActor
final class ShellRouterLogsFocusTests: XCTestCase {
    private func router() -> ShellRouter {
        ShellRouter(scope: .allServers, preferences: ShellScopePreferences(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    func testOpeningLogsSelectsThePageAndKeepsTheFocus() {
        let router = router()
        router.openLogs(LogsFocus(playbackSessionID: "ps_1", ffmpegOnly: true))
        XCTAssertEqual(router.selectedDestinationID, AdminDestination.logs.id)
        XCTAssertEqual(router.logsFocus, LogsFocus(playbackSessionID: "ps_1", ffmpegOnly: true))
    }

    func testThePageTakesTheFocusOnce() {
        let router = router()
        router.openLogs(LogsFocus(playbackSessionID: "ps_1", ffmpegOnly: false))
        XCTAssertEqual(router.takeLogsFocus(), LogsFocus(playbackSessionID: "ps_1", ffmpegOnly: false))
        XCTAssertNil(router.takeLogsFocus())
    }

    func testChoosingAnyPageFromTheMenuDropsAStaleFocus() {
        let router = router()
        router.openLogs(LogsFocus(playbackSessionID: "ps_1", ffmpegOnly: false))
        router.select(destinationID: AdminDestination.dashboard.id)
        router.select(destinationID: AdminDestination.logs.id)
        XCTAssertNil(router.logsFocus)
    }
}
