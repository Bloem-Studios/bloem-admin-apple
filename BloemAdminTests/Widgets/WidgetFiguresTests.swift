import SwiftUI
import XCTest
@testable import BloemAdmin

/// What the Libraries, Nodes, Requests and Server status cards draw, in plain values: the order, the totals, the
/// words, and that no name reaches a surface that hides names.
final class WidgetFiguresTests: XCTestCase {
    private let now = WidgetSamples.now
    private var off: WidgetSettings { WidgetSettings(showDetailsOnLockScreen: false) }
    private var on: WidgetSettings { WidgetSettings(showDetailsOnLockScreen: true) }

    private func context(_ surface: WidgetSurface, _ settings: WidgetSettings) -> WidgetContext {
        WidgetContext(size: .medium, surface: surface, settings: settings, now: now)
    }

    // MARK: Libraries

    func testLibrariesNeedingALookComeFirst() {
        let figures = LibrariesFigures(board: WidgetSamples.entry().libraries)
        XCTAssertEqual(figures.items.map(\.name), ["Music", "Series", "Films"], "a warning, then a scan running, then the rest")
        XCTAssertEqual(figures.total, 3)
        XCTAssertEqual(figures.warnings, 1)
        XCTAssertEqual(figures.scanning, 1)
        XCTAssertEqual(figures.topScan?.name, "Series")
        XCTAssertEqual(figures.stats.map(\.value), ["3", "1", "1"])
        XCTAssertEqual(figures.stats.map(\.label), ["libraries", "scanning", "warning"])
        XCTAssertTrue(figures.stats[1].isLive, "a running scan carries the tally dot")
    }

    func testALibraryCardSaysWhereItsScanIs() {
        let items = WidgetSamples.libraries
        XCTAssertEqual(LibrariesFigures.detail(items[1], now: now), "Scanning 40%")
        XCTAssertEqual(LibrariesFigures.detail(items[0], now: now), "Scanned 1h ago")
        var queued = items[0]
        queued.activity = LibraryScanActivity(phase: .queued, progress: nil)
        XCTAssertEqual(LibrariesFigures.detail(queued, now: now), "Scan queued")
        queued.activity = nil
        queued.lastScannedAt = nil
        XCTAssertEqual(LibrariesFigures.detail(queued, now: now), "Not scanned yet")
    }

    func testNoLibraryNameReachesTheLockScreenUnlessDetailsAreOn() {
        let figures = LibrariesFigures(board: WidgetSamples.entry().libraries)
        XCTAssertTrue(figures.visibleItems(context(.lockScreen, off)).isEmpty)
        XCTAssertEqual(figures.visibleItems(context(.lockScreen, on)).count, 3)
        XCTAssertEqual(figures.visibleItems(context(.homeScreen, off)).count, 3)
        XCTAssertEqual(figures.total, 3, "the counts stay")
    }

    // MARK: Nodes

    func testNodesNeedingALookComeFirstAndTheAveragesIgnoreWhatIsNotReported() {
        let figures = NodesFigures(board: WidgetSamples.entry().nodes)
        XCTAssertEqual(figures.items.map(\.name), ["edge-1", "transcode-2", "transcode-1"], "unhealthy, draining, then healthy")
        XCTAssertEqual(figures.total, 3)
        XCTAssertEqual(figures.healthy, 1)
        XCTAssertEqual(figures.unhealthy, 1)
        XCTAssertEqual(figures.averageCPU, 21, "34 and 8; the unhealthy node reports nothing")
        XCTAssertEqual(figures.averageMemory, 41)
        XCTAssertEqual(figures.fullestDisk, 88)
        XCTAssertEqual(figures.shortResourceLine, "CPU 21% · Memory 41%")
        XCTAssertEqual(figures.resourceLine, "CPU 21% · Memory 41% · Disk 88%")
    }

    func testNoNodeNameReachesTheLockScreenUnlessDetailsAreOn() {
        let figures = NodesFigures(board: WidgetSamples.entry().nodes)
        XCTAssertTrue(figures.visibleItems(context(.lockScreen, off)).isEmpty)
        XCTAssertEqual(figures.visibleItems(context(.lockScreen, on)).count, 3)
    }

    func testNodesWithNoReadingsHaveNoResourceLine() {
        var board = WidgetSamples.entry().nodes
        board.feeds[0].items = [WidgetSamples.nodes[2]]
        XCTAssertNil(NodesFigures(board: board).resourceLine)
        XCTAssertNil(NodesFigures(board: board).averageCPU)
    }

    // MARK: Requests

    func testRequestsFootersCountOnlyAndNameNoOne() {
        let figures = RequestsFigures(board: WidgetSamples.entry().requests)
        let stats = figures.stats(now: now, more: 2)
        XCTAssertEqual(stats.map(\.id), ["waiting", "oldest", "more"])
        XCTAssertEqual(stats.map(\.value), ["4", "1d", "+2"])
        for stat in stats {
            for name in ["Maya", "Tomas", "Priya", "Dune", "Shogun"] { XCTAssertFalse(stat.value.contains(name) || stat.label.contains(name)) }
        }
        XCTAssertTrue(figures.hasRows)
    }

    // MARK: Server status and the card plans

    func testAWidgetWithTwoServersOnALargeWidgetUsesTheHeroCard() {
        let plan = WidgetListPlanner.plan(size: CGSize(width: 348, height: 366), rows: 2, tiers: ServerCardTier.tiers)
        XCTAssertEqual(ServerCardTier(rawValue: plan.tierIndex), .hero)
        XCTAssertEqual(plan.visible, 2)
        XCTAssertEqual(plan.footer, .stats, "the totals fill the rest")
    }

    func testManyServersStillShowAtLeastThreeCardsAndSaySoWhenThereAreMore() {
        let plan = WidgetListPlanner.plan(size: CGSize(width: 348, height: 366), rows: 6, tiers: ServerCardTier.tiers)
        XCTAssertGreaterThanOrEqual(plan.visible, 3)
        XCTAssertEqual(plan.more, 6 - plan.visible)
        // A medium widget has room for two of the leanest card only.
        let medium = WidgetListPlanner.plan(size: CGSize(width: 216, height: 124), rows: 6, tiers: ServerCardTier.tiers, hasHeader: false)
        XCTAssertEqual(ServerCardTier(rawValue: medium.tierIndex), .compact)
        XCTAssertEqual(medium.visible, 2)
    }

    func testEveryListWidgetsTiersAreRichestFirstAndEndWithAnyWidth() {
        for tiers in [NowPlayingTier.tiers, RequestsTier.tiers, LibrariesTier.tiers, NodesTier.tiers, ServerCardTier.tiers] {
            XCTAssertEqual(tiers.last?.minWidth, 0, "the leanest card fits any width")
            XCTAssertEqual(tiers.map(\.height), tiers.map(\.height).sorted(by: >), "richest, tallest first")
            XCTAssertEqual(tiers.map(\.minWidth), tiers.map(\.minWidth).sorted(by: >))
        }
    }

    func testEveryTierEnumMatchesItsTiersArray() {
        XCTAssertEqual(NowPlayingTier.allCases.count, NowPlayingTier.tiers.count)
        XCTAssertEqual(RequestsTier.allCases.count, RequestsTier.tiers.count)
        XCTAssertEqual(LibrariesTier.allCases.count, LibrariesTier.tiers.count)
        XCTAssertEqual(NodesTier.allCases.count, NodesTier.tiers.count)
        XCTAssertEqual(ServerCardTier.allCases.count, ServerCardTier.tiers.count)
    }

    // MARK: Deep links

    func testEveryCardOpensAPageTheAppAcceptsForItsOwnServer() throws {
        let links: [(URL, String)] = [
            (WidgetLink.page(DeepLinkPage.nowPlaying, serverID: WidgetSamples.streams[0].serverID), DeepLinkPage.nowPlaying),
            (WidgetLink.page(DeepLinkPage.requests, serverID: WidgetSamples.requests[0].serverID), DeepLinkPage.requests),
            (WidgetLink.page(DeepLinkPage.libraries, serverID: WidgetSamples.libraries[0].serverID), DeepLinkPage.libraries),
            (WidgetLink.page(DeepLinkPage.nodes, serverID: WidgetSamples.nodes[0].serverID), DeepLinkPage.nodes),
            (DeepLinkRoute(target: .server("home"), pageID: DeepLinkPage.nowPlaying).url, DeepLinkPage.nowPlaying),
        ]
        for (url, page) in links {
            let route = try XCTUnwrap(DeepLinkRoute(url: url), url.absoluteString)
            XCTAssertEqual(route.pageID, page)
            XCTAssertEqual(route.target, .server("home"))
        }
    }

    func testARequestCardAndALibraryCardOpenTheirOwnItem() throws {
        let request = WidgetLink.item("req-42", on: DeepLinkPage.requests, serverID: "home")
        XCTAssertEqual(request.absoluteString, "bloemadmin://server/home/work.requests/req-42")
        let route = try XCTUnwrap(DeepLinkRoute(url: request))
        XCTAssertEqual(route, DeepLinkRoute(target: .server("home"), pageID: DeepLinkPage.requests, itemID: "req-42"))
        let library = WidgetLink.item("0f8fad5b-d9cb-469f-a165-70867728950e", on: DeepLinkPage.libraries, serverID: "home")
        XCTAssertEqual(DeepLinkRoute(url: library)?.itemID, "0f8fad5b-d9cb-469f-a165-70867728950e")
        XCTAssertEqual(DeepLinkRoute(url: library)?.pageID, DeepLinkPage.libraries)
    }

    func testAnIdTheAppWouldRefuseLeavesTheLinkAtThePage() {
        for id in ["", "has space", "slash/inside", "query?x=1", String(repeating: "a", count: 200)] {
            XCTAssertEqual(
                WidgetLink.item(id, on: DeepLinkPage.requests, serverID: "home"),
                WidgetLink.page(DeepLinkPage.requests, serverID: "home"), "\(id.prefix(12))"
            )
        }
    }

    func testEachWidgetOpensItsOwnPageWhateverTheServer() throws {
        let pages: [SiloWidgetKind: String] = [
            .nowPlaying: DeepLinkPage.nowPlaying, .requests: DeepLinkPage.requests, .libraries: DeepLinkPage.libraries,
            .nodes: DeepLinkPage.nodes, .serverStatus: DeepLinkPage.nowPlaying,
        ]
        XCTAssertEqual(Set(pages.keys), Set(SiloWidgetKind.allCases))
        let entry = WidgetSamples.entry()
        XCTAssertEqual(entry.statusModel.link, WidgetLink.page(DeepLinkPage.nowPlaying, serverID: nil))
    }
}
