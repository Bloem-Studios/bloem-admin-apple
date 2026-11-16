import XCTest
@testable import BloemAdmin

/// The Now playing widget cannot scroll, so it pages: the count in the header, the page buttons, the page kept
/// in the App Group, and the plan that turns a list of streams into pages.
final class WidgetPagingTests: XCTestCase {
    private let t0 = WidgetSamples.now

    // MARK: The count

    private func figures(total: Int, items: [StreamItem] = []) -> NowPlayingFigures {
        let feed = ServerFeed(serverID: "home", serverName: "Silo Home", condition: .current, items: items, total: total, asOf: t0)
        return NowPlayingFigures(board: WidgetBoard(title: "All servers", serverID: nil, feeds: [feed]))
    }

    func testTheHeaderCountIsNoStreamsOneStreamAndNStreams() {
        XCTAssertEqual(figures(total: 0).streamsText, "No streams")
        XCTAssertEqual(figures(total: 1).streamsText, "1 stream")
        XCTAssertEqual(figures(total: 2).streamsText, "2 streams")
        XCTAssertEqual(figures(total: 3).streamsText, "3 streams")
        XCTAssertEqual(figures(total: 12).streamsText, "12 streams")
        XCTAssertEqual(NowPlayingFigures.streamsText(-1), "No streams")
    }

    func testTheCountIsTheServersTotalNotJustTheRowsThatWereRead() {
        // A server can report more sessions than the widget read rows for; the header says how many are live.
        XCTAssertEqual(figures(total: 9, items: Array(WidgetSamples.streams.prefix(2))).streamsText, "9 streams")
    }

    func testTheStreamsStringHasTheOneAndOtherFormsInBothCatalogs() throws {
        // The widget extension has its own catalog, because it cannot read the app's; both say it the same way.
        for path in ["BloemAdmin/Localizable.xcstrings", "BloemAdminWidgets/Localizable.xcstrings"] {
            let data = try Data(contentsOf: SourceTree.root.appendingPathComponent(path))
            let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let strings = try XCTUnwrap(catalog["strings"] as? [String: Any])
            let entry = try XCTUnwrap(strings["%lld streams"] as? [String: Any], path)
            let english = try XCTUnwrap((entry["localizations"] as? [String: Any])?["en"] as? [String: Any], path)
            let plural = try XCTUnwrap((english["variations"] as? [String: Any])?["plural"] as? [String: Any], path)
            func value(_ form: String) -> String? {
                ((plural[form] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
            }
            XCTAssertEqual(value("one"), "%lld stream", path)
            XCTAssertEqual(value("other"), "%lld streams", path)
        }
    }

    func testEveryNewStringIsInTheWidgetCatalog() throws {
        let data = try Data(contentsOf: SourceTree.root.appendingPathComponent("BloemAdminWidgets/Localizable.xcstrings"))
        let strings = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        for key in ["No streams", "Page %lld of %lld", "Previous streams", "More streams", "Show other streams"] {
            XCTAssertNotNil(strings[key], key)
        }
    }

    // MARK: Pager state

    private func plan(rows: Int, page: Int, width: CGFloat = 348, height: CGFloat = 154, pageable: Bool = true) -> WidgetListPlan {
        WidgetListPlanner.plan(
            size: CGSize(width: width, height: height), rows: rows, tiers: NowPlayingTier.tiers,
            maxColumns: 2, page: page, pageable: pageable
        )
    }

    func testAMediumWidgetWithFiveStreamsHasThreePagesOfTwo() {
        let first = plan(rows: 5, page: 0)
        XCTAssertEqual(first.visible, 2)
        XCTAssertEqual(first.pageCount, 3)
        XCTAssertEqual([first.page, first.pageStart, first.shown, first.more], [0, 0, 2, 3])
        XCTAssertFalse(first.hasPreviousPage)
        XCTAssertTrue(first.hasNextPage)

        let second = plan(rows: 5, page: 1)
        XCTAssertEqual([second.page, second.pageStart, second.shown, second.more], [1, 2, 2, 1])
        XCTAssertTrue(second.hasPreviousPage)
        XCTAssertTrue(second.hasNextPage)

        let last = plan(rows: 5, page: 2)
        XCTAssertEqual([last.page, last.pageStart, last.shown, last.more], [2, 4, 1, 0])
        XCTAssertTrue(last.hasPreviousPage)
        XCTAssertFalse(last.hasNextPage)
        XCTAssertEqual(last.cardHeight, first.cardHeight, "the last page keeps the size of the cards")
    }

    func testAPageOutOfRangeIsHeldToTheFirstAndLastPage() {
        XCTAssertEqual(plan(rows: 5, page: 99).page, 2, "streams ended since the page was saved")
        XCTAssertEqual(plan(rows: 5, page: -4).page, 0)
        XCTAssertEqual(plan(rows: 1, page: 3).page, 0)
        XCTAssertEqual(plan(rows: 0, page: 2).page, 0)
        XCTAssertEqual(plan(rows: 0, page: 2).pageCount, 1)
    }

    func testStreamsThatFitAreOnePageWithNoButtons() {
        for rows in 0...2 {
            let p = plan(rows: rows, page: 0)
            XCTAssertEqual(p.pageCount, 1, "\(rows)")
            XCTAssertNil(WidgetPagerState(key: "k", plan: p), "\(rows)")
        }
        XCTAssertNotNil(WidgetPagerState(key: "k", plan: plan(rows: 3, page: 0)))
    }

    func testAListThatIsNotPagedKeepsToItsFirstPage() {
        let p = plan(rows: 5, page: 2, pageable: false)
        XCTAssertEqual([p.page, p.pageStart, p.shown, p.more], [0, 0, 2, 3], "Requests, Libraries and Nodes are not paged")
    }

    func testEveryStreamIsOnExactlyOnePageAtEverySize() {
        let sizes: [(CGFloat, CGFloat)] = [(348, 154), (348, 366), (710, 362)]
        for (width, height) in sizes {
            for rows in 0...13 {
                let first = plan(rows: rows, page: 0, width: width, height: height)
                var seen: [Int] = []
                for page in 0..<first.pageCount {
                    let p = plan(rows: rows, page: page, width: width, height: height)
                    seen += Array(p.pageStart..<(p.pageStart + p.shown))
                    XCTAssertLessThanOrEqual(p.shown, p.visible)
                }
                XCTAssertEqual(seen, Array(0..<rows), "\(width)x\(height) with \(rows) streams")
            }
        }
    }

    func testTheButtonsMoveOneStepAndStopAtTheEnds() {
        let first = WidgetPagerState(key: "k", page: 0, pageCount: 3)
        XCTAssertNil(first.previous)
        XCTAssertEqual(first.next, 1)
        XCTAssertEqual(first.label, "1/3")
        let middle = WidgetPagerState(key: "k", page: 1, pageCount: 3)
        XCTAssertEqual([middle.previous, middle.next], [0, 2])
        let last = WidgetPagerState(key: "k", page: 2, pageCount: 3)
        XCTAssertEqual(last.previous, 1)
        XCTAssertNil(last.next)
        XCTAssertEqual(last.label, "3/3")
    }

    // MARK: Kept page

    func testAPageIsKeptPerServerChoiceAndSize() {
        let all = WidgetPagingKey.nowPlaying(serverID: nil, size: .medium)
        XCTAssertNotEqual(all, WidgetPagingKey.nowPlaying(serverID: nil, size: .large), "a larger widget has other pages")
        XCTAssertNotEqual(all, WidgetPagingKey.nowPlaying(serverID: "home", size: .medium))
        XCTAssertEqual(all, WidgetPagingKey.nowPlaying(serverID: nil, size: .medium))
    }

    func testAPageIsRememberedThenGoesBackToTheFirstAfterFiveMinutes() {
        let key = WidgetPagingKey.nowPlaying(serverID: nil, size: .medium)
        let state = WidgetPagingState().setting(page: 2, for: key, at: t0)
        XCTAssertEqual(state.page(for: key, now: t0), 2)
        XCTAssertEqual(state.page(for: key, now: t0.addingTimeInterval(WidgetPagingState.lifetime - 1)), 2)
        XCTAssertEqual(state.page(for: key, now: t0.addingTimeInterval(WidgetPagingState.lifetime)), 0)
        XCTAssertEqual(state.page(for: "another", now: t0), 0)
        XCTAssertEqual(state.expiries(after: t0), [t0.addingTimeInterval(WidgetPagingState.lifetime)])
        XCTAssertTrue(state.expiries(after: t0.addingTimeInterval(WidgetPagingState.lifetime)).isEmpty)
    }

    func testGoingBackToThePageOneDropsTheEntryAndStaleOnesAreDropped() {
        let a = "now-playing/all/medium", b = "now-playing/home/large"
        var state = WidgetPagingState().setting(page: 1, for: a, at: t0)
        state = state.setting(page: 3, for: b, at: t0.addingTimeInterval(400))
        XCTAssertNil(state.marks[a], "a was five minutes old when b was set")
        XCTAssertEqual(state.marks[b]?.page, 3)
        state = state.setting(page: 0, for: b, at: t0.addingTimeInterval(410))
        XCTAssertTrue(state.marks.isEmpty)
    }

    func testAClockSetBackDoesNotKeepAPageForever() {
        let key = "now-playing/all/medium"
        let state = WidgetPagingState().setting(page: 1, for: key, at: t0.addingTimeInterval(3_600))
        XCTAssertEqual(state.page(for: key, now: t0), 0)
    }

    func testThePageSurvivesTheFileAndAnUnreadableFileMeansTheFirstPage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = FileWidgetPagingStore(directory: folder)
        XCTAssertEqual(store.load(), WidgetPagingState(), "no file yet")

        let key = "now-playing/all/large"
        let saved = try XCTUnwrap(WidgetPageRunner.run(key: key, page: 2, store: store, now: t0))
        XCTAssertEqual(store.load(), saved)
        XCTAssertEqual(store.load().page(for: key, now: t0.addingTimeInterval(10)), 2)

        _ = WidgetPageRunner.run(key: key, page: 0, store: store, now: t0.addingTimeInterval(20))
        XCTAssertEqual(store.load().page(for: key, now: t0.addingTimeInterval(21)), 0)

        try Data("not json".utf8).write(to: folder.appendingPathComponent(FileWidgetPagingStore.fileName))
        XCTAssertEqual(store.load(), WidgetPagingState())
    }

    func testATapWithNoSharedContainerChangesNothingAndNeverCrashes() {
        XCTAssertNil(WidgetPageRunner.run(key: "k", page: 1, store: nil))
        XCTAssertEqual(WidgetPageRunner.run(key: "k", page: -3, store: InMemoryPagingStore(), now: t0)?.marks.count, 0, "a page below the first is the first")
    }

    // MARK: Entry and timeline

    func testALaterEntryKeepsThePageAndTheTimelineHasAnEntryWhereItGoesBack() {
        let key = WidgetPagingKey.nowPlaying(serverID: nil, size: .medium)
        let base = WidgetSamples.entry()
        let entry = SiloEntry(
            date: base.date, snapshot: base.snapshot, live: base.live, serverID: nil, settings: base.settings,
            streams: base.streams, requests: base.requests, libraries: base.libraries, nodes: base.nodes, notice: nil,
            paging: WidgetPagingState().setting(page: 1, for: key, at: base.date)
        )
        XCTAssertEqual(entry.at(base.date.addingTimeInterval(60)).paging, entry.paging)
        let dates = WidgetTimelinePlan.entryDates(.nowPlaying, entry)
        XCTAssertTrue(dates.contains(base.date.addingTimeInterval(WidgetPagingState.lifetime)), "the first page is drawn again")
        let other = WidgetTimelinePlan.entryDates(.requests, entry)
        XCTAssertEqual(other, [entry.date], "only Now playing pages")
    }

    func testThePagingFileIsNotASecretAndHoldsNoNames() throws {
        let key = WidgetPagingKey.nowPlaying(serverID: "srv-1", size: .large)
        let data = try JSONEncoder().encode(WidgetPagingState().setting(page: 1, for: key, at: t0))
        let decoded = try JSONDecoder().decode(WidgetPagingState.self, from: data)
        XCTAssertEqual(Array(decoded.marks.keys), ["now-playing/srv-1/large"], "a server id and a size, nothing else")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("http"))
    }
}

private final class InMemoryPagingStore: WidgetPagingStoring, @unchecked Sendable {
    private var state = WidgetPagingState()
    func load() -> WidgetPagingState { state }
    func save(_ state: WidgetPagingState) throws { self.state = state }
}
