import SwiftUI
import XCTest
@testable import BloemAdmin

/// Every state of a data widget, from the spec: loading, signed out, can't reach, not available, empty, and
/// content that says when it is old.
final class WidgetBoardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func feed(
        _ id: String = "a", name: String = "Home", condition: FeedCondition = .current,
        items: [RequestItem] = [], total: Int? = nil, asOf: Date?? = nil
    ) -> ServerFeed<RequestItem> {
        let time: Date? = asOf ?? (condition == .current ? now : nil)
        return ServerFeed(serverID: id, serverName: name, condition: condition, items: items, total: total, asOf: time)
    }

    private func item(_ id: String = "r1") -> RequestItem {
        RequestItem(id: id, serverID: "a", serverName: "Home", title: "Dune", requester: "Maya", createdAt: now)
    }

    private func board(_ feeds: [ServerFeed<RequestItem>], placeholder: Bool = false) -> WidgetBoard<RequestItem> {
        WidgetBoard(title: "All servers", serverID: nil, feeds: feeds, isPlaceholder: placeholder)
    }

    func testAPlaceholderIsLoading() {
        XCTAssertEqual(board([feed()], placeholder: true).state(now: now).phase, .loading)
    }

    func testNoSavedServerSaysSoAndOffersToAddOne() {
        XCTAssertEqual(board([]).state(now: now).phase, .noServers)
    }

    func testAServerNotReadYetIsLoading() {
        let unread = feed(condition: .current, asOf: .some(nil))
        XCTAssertEqual(board([unread]).state(now: now).phase, .loading)
    }

    func testSignedOutEverywhereIsSignedOut() {
        let state = board([feed("a", condition: .signedOut), feed("b", name: "Office", condition: .signedOut)]).state(now: now)
        XCTAssertEqual(state.phase, .signedOut)
        XCTAssertNil(state.updatedAt)
    }

    func testAFeatureMissingEverywhereIsNotAvailable() {
        XCTAssertEqual(board([feed(condition: .unavailable)]).state(now: now).phase, .unavailable)
    }

    func testNothingReadAndNobodyAnsweringNamesTheServer() {
        let state = board([feed("a", name: "Home", condition: .unreachable)]).state(now: now)
        XCTAssertEqual(state.phase, .unreachable(serverName: "Home"))
        XCTAssertEqual(state.unreachableNames, ["Home"])
    }

    func testCurrentDataWithNothingInItIsEmpty() {
        let state = board([feed(items: [], total: 0)]).state(now: now)
        XCTAssertEqual(state.phase, .empty)
        XCTAssertNil(state.updatedAt)
    }

    func testCurrentDataIsContentAndNeverLabelledOld() {
        let state = board([feed(items: [item()], total: 1)]).state(now: now)
        XCTAssertEqual(state.phase, .content)
        XCTAssertNil(state.updatedAt)
        XCTAssertTrue(state.unreachableNames.isEmpty)
    }

    func testDataOlderThanItsRefreshWindowSaysWhenItWasRead() {
        let old = now.addingTimeInterval(-(WidgetBoard<RequestItem>.freshness + 60))
        let state = board([feed(items: [item()], total: 1, asOf: .some(old))]).state(now: now)
        XCTAssertEqual(state.phase, .content)
        XCTAssertEqual(state.updatedAt, old, "nothing is ever shown as current when it is not")
    }

    func testAServerThatStoppedAnsweringKeepsItsLastDataWithItsTime() {
        let at = now.addingTimeInterval(-300)
        let state = board([feed(condition: .unreachable, items: [item()], total: 1, asOf: .some(at))]).state(now: now)
        XCTAssertEqual(state.phase, .content)
        XCTAssertEqual(state.unreachableNames, ["Home"])
        XCTAssertEqual(state.updatedAt, at)
    }

    func testOneServerDownWhileAnotherAnswersListsTheDownOneAndDatesItsData() {
        let at = now.addingTimeInterval(-600)
        let down = feed("a", name: "Home", condition: .unreachable, items: [item("r1")], total: 1, asOf: .some(at))
        let up = feed("b", name: "Office", items: [item("r2")], total: 1)
        let state = board([down, up]).state(now: now)
        XCTAssertEqual(state.phase, .content)
        XCTAssertEqual(state.unreachableNames, ["Home"])
        XCTAssertEqual(state.updatedAt, at)
    }

    func testALockedPhoneKeepsFreshDataWithoutALabel() {
        let at = now.addingTimeInterval(-300)
        let state = board([feed(condition: .deviceLocked, items: [item()], total: 1, asOf: .some(at))]).state(now: now)
        XCTAssertEqual(state.phase, .content)
        XCTAssertNil(state.updatedAt)
        XCTAssertTrue(state.unreachableNames.isEmpty)
    }

    func testALockedPhoneStillDatesDataThatHasGoneOld() {
        let old = now.addingTimeInterval(-3 * 3600)
        let state = board([feed(condition: .deviceLocked, items: [item()], total: 1, asOf: .some(old))]).state(now: now)
        XCTAssertEqual(state.updatedAt, old)
    }

    func testTotalsAddUpAcrossServersAndAreNilWhenNobodyHasOne() {
        let a = feed("a", items: [item()], total: 3)
        let b = feed("b", name: "Office", items: [], total: 2)
        XCTAssertEqual(board([a, b]).total, 5)
        XCTAssertNil(board([feed("a", condition: .signedOut)]).total)
    }

    func testTheUpdatedLineUsesThePersonsClockFormat() {
        let zone = TimeZone(identifier: "UTC")!
        let midnight: TimeInterval = 1_799_971_200
        let date = Date(timeIntervalSince1970: midnight + 14 * 3600 + 32 * 60)
        let text = WidgetTime.clock(date, locale: Locale(identifier: "en_GB"), timeZone: zone)
        XCTAssertEqual(text, "14:32")
    }

    func testAgesAreShortAndNeverNegative() {
        XCTAssertEqual(WidgetTime.age(from: now.addingTimeInterval(10), now: now), "now")
        XCTAssertEqual(WidgetTime.age(from: now.addingTimeInterval(-5 * 60), now: now), "5m")
        XCTAssertEqual(WidgetTime.age(from: now.addingTimeInterval(-3 * 3600), now: now), "3h")
        XCTAssertEqual(WidgetTime.age(from: now.addingTimeInterval(-2 * 86_400), now: now), "2d")
        XCTAssertNil(WidgetTime.age(from: nil, now: now))
    }

    func testFeedsKeepTheLastDataWhenTheServerCannotBeAsked() {
        let server = WidgetServer(id: "a", name: "Home", origin: URL(string: "https://home.example.test"))
        let prior = feed(items: [item()], total: 1)
        typealias Loaded = WidgetFetcher.Loaded<RequestItem>
        let down = WidgetFetcher.feed(for: server, prior: prior, outcome: WidgetFetcher.CallOutcome<Loaded>.unreachable, at: now)
        XCTAssertEqual(down.condition, .unreachable)
        XCTAssertEqual(down.items.count, 1)
        XCTAssertEqual(down.asOf, prior.asOf)
        let locked = WidgetFetcher.feed(for: server, prior: prior, outcome: WidgetFetcher.CallOutcome<Loaded>.deviceLocked, at: now)
        XCTAssertEqual(locked.condition, .deviceLocked)
        let signedOut = WidgetFetcher.feed(for: server, prior: prior, outcome: WidgetFetcher.CallOutcome<Loaded>.signedOut, at: now)
        XCTAssertEqual(signedOut.condition, .signedOut)
        XCTAssertTrue(signedOut.items.isEmpty, "a signed-out server's old data is not shown")
        XCTAssertNil(signedOut.asOf)
    }

    func testTheCacheBuildsABoardInTheSavedOrderAndFollowsRenames() {
        var cache = WidgetDataCache()
        cache.requests["b"] = feed("b", name: "Old name", items: [item("r2")], total: 1)
        let snapshot = AdminSnapshot(generatedAt: now, servers: [
            SnapshotServer(id: "a", name: "Home"), SnapshotServer(id: "b", name: "Office"),
        ])
        let all = cache.board(\.requests, snapshot: snapshot, serverID: nil)
        XCTAssertEqual(all.feeds.map(\.serverID), ["a", "b"])
        XCTAssertEqual(all.feeds[1].serverName, "Office")
        XCTAssertEqual(all.title, "All servers")
        XCTAssertEqual(all.state(now: now).phase, .content, "a server with no feed yet does not hide the one that has")
        let one = cache.board(\.requests, snapshot: snapshot, serverID: "b")
        XCTAssertEqual(one.title, "Office")
        XCTAssertEqual(one.serverID, "b")
        let gone = cache.board(\.requests, snapshot: snapshot, serverID: "zzz")
        XCTAssertEqual(gone.feeds.count, 2, "a server that is no longer saved shows all servers")
    }

    func testKeepOnlyDropsServersThatAreNoLongerSaved() {
        var cache = WidgetDataCache()
        cache.requests["a"] = feed("a")
        cache.requests["gone"] = feed("gone")
        cache.notice = WidgetActionNotice(requestID: "r", serverID: "gone", text: "x", at: now)
        cache.keepOnly(serverIDs: ["a"])
        XCTAssertEqual(Set(cache.requests.keys), ["a"])
        XCTAssertNil(cache.notice)
    }

    func testAFailedActionsNoteExpires() {
        var cache = WidgetDataCache()
        cache.notice = WidgetActionNotice(requestID: "r", serverID: "a", text: "Couldn't approve, open the app", at: now)
        XCTAssertNotNil(cache.notice(now: now.addingTimeInterval(60)))
        XCTAssertNil(cache.notice(now: now.addingTimeInterval(WidgetDataCache.noticeLifetime + 1)))
    }

    func testTheDataFileRoundTripsAndAnUnreadableOneIsEmpty() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWidgetDataStore(directory: directory)
        XCTAssertEqual(store.load(), WidgetDataCache())
        var cache = WidgetDataCache()
        cache.requests["a"] = feed(items: [item()], total: 1)
        try store.save(cache)
        XCTAssertEqual(store.load(), cache)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(FileWidgetDataStore.fileName))
        XCTAssertEqual(store.load(), WidgetDataCache())
    }
}
