import AppIntents
import WidgetKit
import XCTest
@testable import BloemAdmin

/// When the widgets are asked to reload: one entry point, the channels a wake or the live socket names, and at
/// most once every 10 seconds per kind while the app is open.
final class WidgetReloadTests: XCTestCase {
    // MARK: Channels

    func testEachChannelReloadsTheWidgetsThatShowIt() {
        XCTAssertEqual(WidgetReload.kinds(forChannels: ["sessions"]), [.nowPlaying, .serverStatus])
        XCTAssertEqual(WidgetReload.kinds(forChannels: ["requests"]), [.requests, .serverStatus])
        XCTAssertEqual(WidgetReload.kinds(forChannels: ["libraries"]), [.libraries])
        XCTAssertEqual(WidgetReload.kinds(forChannels: ["nodes"]), [.nodes])
        XCTAssertEqual(WidgetReload.kinds(forChannels: ["nodes", "requests"]), [.nodes, .requests, .serverStatus])
    }

    func testTheLiveSocketsScanChannelsChangeTheLibraries() {
        for channel in [LiveChannel.scans, .jobs, .tasks] {
            XCTAssertEqual(WidgetReload.kinds(forChannels: [channel.rawValue]), [.libraries], channel.rawValue)
        }
        XCTAssertEqual(WidgetReload.kinds(forChannels: [LiveChannel.sessions.rawValue]), [.nowPlaying, .serverStatus])
        XCTAssertTrue(WidgetReload.kinds(forChannels: [LiveChannel.notifications.rawValue]).isEmpty, "the inbox shows in no widget")
    }

    func testAnUnknownChannelReloadsNothing() {
        XCTAssertTrue(WidgetReload.kinds(forChannels: ["traffic", ""]).isEmpty)
        XCTAssertTrue(WidgetReload.kinds(forChannels: [String]()).isEmpty)
    }

    func testEveryWidgetShowsAtLeastOneChannelAndEveryKindHasAnId() {
        for kind in SiloWidgetKind.allCases {
            XCTAssertFalse(kind.channels.isEmpty, "\(kind)")
            XCTAssertTrue(WidgetReload.kinds(forChannels: kind.channels).contains(kind), "\(kind)")
        }
        XCTAssertEqual(Set(WidgetReload.kinds), Set(SiloWidgetKind.allCases.map(\.rawValue)))
    }

    func testTheWakesChannelNamesAreTheOnesAWidgetShows() {
        // The server's wake names `sessions`, `requests`, `libraries` and `nodes` (docs/design.md).
        let shown = SiloWidgetKind.allCases.reduce(into: Set<String>()) { $0.formUnion($1.channels) }
        XCTAssertEqual(shown, ["sessions", "requests", "libraries", "nodes"])
    }

    // MARK: Every family

    func testEveryWidgetOffersEveryFamilyThatMakesSense() {
        let all: Set<WidgetFamily> = [
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ]
        for kind in SiloWidgetKind.allCases {
            XCTAssertEqual(Set(kind.families), all, "\(kind)")
        }
    }

    // MARK: The throttle

    func testTheFirstChangeReloadsAtOnceAndLaterOnesInsideTenSecondsAreOneAtTheEnd() {
        var throttle = WidgetReloadThrottle(interval: 10)
        XCTAssertEqual(throttle.offer([.nowPlaying], at: 100), .init(reloadNow: [.nowPlaying], checkAgainIn: nil))
        XCTAssertEqual(throttle.offer([.nowPlaying], at: 103), .init(reloadNow: [], checkAgainIn: 7))
        XCTAssertEqual(throttle.offer([.nowPlaying], at: 106), .init(reloadNow: [], checkAgainIn: 4))
        XCTAssertEqual(throttle.flush(at: 110), .init(reloadNow: [.nowPlaying], checkAgainIn: nil))
        // The reload at 110 starts a new window.
        XCTAssertEqual(throttle.offer([.nowPlaying], at: 112), .init(reloadNow: [], checkAgainIn: 8))
        XCTAssertEqual(throttle.offer([.nowPlaying], at: 125), .init(reloadNow: [.nowPlaying], checkAgainIn: nil))
    }

    func testEachKindHasItsOwnWindow() {
        var throttle = WidgetReloadThrottle(interval: 10)
        _ = throttle.offer([.nowPlaying], at: 0)
        let second = throttle.offer([.nowPlaying, .libraries], at: 4)
        XCTAssertEqual(second.reloadNow, [.libraries])
        XCTAssertEqual(second.checkAgainIn, 6)
        let flushed = throttle.flush(at: 10)
        XCTAssertEqual(flushed.reloadNow, [.nowPlaying])
        XCTAssertNil(flushed.checkAgainIn)
    }

    func testAFlushBeforeAnythingIsDueReloadsNothing() {
        var throttle = WidgetReloadThrottle(interval: 10)
        _ = throttle.offer([.nodes], at: 0)
        _ = throttle.offer([.nodes], at: 2)
        XCTAssertEqual(throttle.flush(at: 5), .init(reloadNow: [], checkAgainIn: 5))
    }
}

@MainActor
final class WidgetLiveReloaderTests: XCTestCase {
    private let clock = TestLiveClock()
    private var reloads: [Set<SiloWidgetKind>] = []

    private func makeReloader() -> WidgetLiveReloader {
        reloads = []
        return WidgetLiveReloader(interval: 10, clock: clock) { [unowned self] kinds in self.reloads.append(kinds) }
    }

    func testASessionChangeReloadsNowPlayingAndServerStatusAtOnce() {
        let reloader = makeReloader()
        reloader.note(.sessions)
        XCTAssertEqual(reloads, [[.nowPlaying, .serverStatus]])
    }

    func testAChangeNoWidgetShowsReloadsNothing() async {
        let reloader = makeReloader()
        reloader.note(.notifications)
        await clock.advance(30)
        XCTAssertTrue(reloads.isEmpty)
    }

    func testABurstOfChangesIsOneReloadNowAndOneAtTheEndOfTheTenSeconds() async {
        let reloader = makeReloader()
        reloader.note(.sessions)
        await clock.advance(1)
        reloader.note(.sessions)
        reloader.note(.sessions)
        await clock.advance(3)
        reloader.note(.sessions)
        XCTAssertEqual(reloads.count, 1, "nothing more inside the window")
        await clock.advance(5.5)
        XCTAssertEqual(reloads.count, 1)
        await clock.advance(1)
        XCTAssertEqual(reloads, [[.nowPlaying, .serverStatus], [.nowPlaying, .serverStatus]], "one more, at 10 seconds")
        await clock.advance(30)
        XCTAssertEqual(reloads.count, 2, "and then quiet")
    }

    func testScanChangesReloadTheLibrariesWithoutWaitingForTheSessionWindow() async {
        let reloader = makeReloader()
        reloader.note(.sessions)
        await clock.advance(2)
        reloader.note(.scans)
        XCTAssertEqual(reloads.last, [.libraries])
        XCTAssertEqual(reloads.count, 2)
    }

    func testTheEarliestWaitingKindIsNeverLate() async {
        let reloader = makeReloader()
        reloader.note(.scans)
        await clock.advance(1)
        reloader.note(.sessions)
        await clock.advance(1)
        reloader.note(.scans)
        reloader.note(.sessions)
        await clock.advance(8.5)
        XCTAssertEqual(reloads.count, 3, "libraries reload at 10 seconds after their own last reload")
        XCTAssertEqual(reloads.last, [.libraries])
        await clock.advance(1)
        XCTAssertEqual(reloads.count, 4, "sessions one second later")
        XCTAssertEqual(reloads.last, [.nowPlaying, .serverStatus])
    }
}

/// The three buttons of a widget are App Intents that need the phone unlocked, and nothing destructive is offered.
final class WidgetIntentPolicyTests: XCTestCase {
    func testRefreshApproveAndDeclineAllNeedTheDeviceToBeUnlocked() {
        let required = String(describing: IntentAuthenticationPolicy.requiresAuthentication)
        XCTAssertEqual(String(describing: RefreshWidgetsIntent.authenticationPolicy), required)
        XCTAssertEqual(String(describing: ApproveRequestIntent.authenticationPolicy), required)
        XCTAssertEqual(String(describing: DeclineRequestIntent.authenticationPolicy), required)
    }

    func testTheWidgetsDrawEveryButtonAsAnIntentAndNothingElse() throws {
        let views = try SourceTree.sources(in: "BloemAdmin/Shared/Widgets/Views")
        var buttons = 0
        for file in views {
            for (index, line) in file.lines.enumerated() where line.range(of: #"(^|[^A-Za-z])Button\("#, options: .regularExpression) != nil {
                buttons += 1
                XCTAssertTrue(line.contains("intent:"), "\(file.path):\(index + 1) has a Button that is not an App Intent: \(line)")
            }
        }
        XCTAssertGreaterThanOrEqual(buttons, 3, "Refresh, Approve and Decline")
    }
}
