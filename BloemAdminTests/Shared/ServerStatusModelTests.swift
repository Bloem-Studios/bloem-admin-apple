import XCTest
@testable import BloemAdmin

/// What a widget shows, built from the snapshot (and from its own reachability check).
final class ServerStatusModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func server(
        _ id: String, _ name: String, reachable: Bool? = true, streams: Int? = nil, requests: Int? = nil,
        countsAge: TimeInterval = 60
    ) -> SnapshotServer {
        var row = SnapshotServer(id: id, name: name, origin: URL(string: "https://\(id).example.test"))
        row.reachable = reachable
        row.activeStreams = streams
        row.requestsWaiting = requests
        if streams != nil || requests != nil { row.countsAt = now.addingTimeInterval(-countsAge) }
        return row
    }

    private func snapshot(_ servers: [SnapshotServer]) -> AdminSnapshot {
        AdminSnapshot(generatedAt: now, servers: servers)
    }

    // MARK: One server

    func testOneServerShowsItsStatusAndCounts() {
        let model = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", streams: 2, requests: 3), server("b", "Office")]),
            serverID: "a", liveReachability: [:], now: now
        )
        XCTAssertEqual(model.title, "Home")
        XCTAssertEqual(model.rows.map(\.name), ["Home"])
        XCTAssertEqual(model.status, .reachable)
        XCTAssertEqual(model.activeStreams, 2)
        XCTAssertEqual(model.requestsWaiting, 3)
        XCTAssertTrue(model.hasLiveStreams)
        XCTAssertEqual(model.link, DeepLinkRoute(target: .server("a"), pageID: DeepLinkPage.nowPlaying).url)
    }

    func testAServerThatDoesNotAnswerIsNotReachable() {
        let model = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", reachable: false)]), serverID: "a", liveReachability: [:], now: now
        )
        XCTAssertEqual(model.status, .unreachable)
        XCTAssertFalse(model.hasLiveStreams)
    }

    func testTheWidgetsOwnCheckBeatsTheSnapshot() {
        let model = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", reachable: true)]),
            serverID: "a", liveReachability: ["a": false], now: now
        )
        XCTAssertEqual(model.status, .unreachable)
        let recovered = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", reachable: false)]),
            serverID: "a", liveReachability: ["a": true], now: now
        )
        XCTAssertEqual(recovered.status, .reachable)
    }

    func testNeverCheckedIsUnknown() {
        let model = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", reachable: nil)]), serverID: "a", liveReachability: [:], now: now
        )
        XCTAssertEqual(model.status, .unknown)
    }

    func testStaleCountsShowNoNumbers() {
        let model = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", streams: 5, requests: 5, countsAge: 4 * 3600)]),
            serverID: "a", liveReachability: [:], now: now
        )
        XCTAssertNil(model.activeStreams)
        XCTAssertNil(model.requestsWaiting)
        XCTAssertFalse(model.hasLiveStreams)
    }

    func testAServerRemovedSinceFallsBackToAllServers() {
        let model = ServerStatusModel(
            snapshot: snapshot([server("b", "Office")]), serverID: "gone", liveReachability: [:], now: now
        )
        XCTAssertEqual(model.rows.map(\.name), ["Office"])
        XCTAssertEqual(model.title, "All servers")
    }

    // MARK: All servers

    func testAllServersAddsUp() {
        let model = ServerStatusModel(
            snapshot: snapshot([
                server("a", "Home", streams: 2, requests: 3),
                server("b", "Office", reachable: false),
                server("c", "Cabin", streams: 1, requests: 0),
            ]),
            serverID: nil, liveReachability: [:], now: now
        )
        XCTAssertEqual(model.title, "All servers")
        XCTAssertEqual(model.rows.map(\.name), ["Home", "Office", "Cabin"])
        XCTAssertEqual(model.status, .someUnreachable(reachable: 2, of: 3))
        XCTAssertEqual(model.activeStreams, 3)
        XCTAssertEqual(model.requestsWaiting, 3)
        XCTAssertTrue(model.hasLiveStreams)
        XCTAssertEqual(model.link, DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.nowPlaying).url)
    }

    func testAllReachableAndNoneReachable() {
        let up = ServerStatusModel(
            snapshot: snapshot([server("a", "Home"), server("b", "Office")]), serverID: nil, liveReachability: [:], now: now
        )
        XCTAssertEqual(up.status, .reachable)
        let down = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", reachable: false), server("b", "Office", reachable: false)]),
            serverID: nil, liveReachability: [:], now: now
        )
        XCTAssertEqual(down.status, .unreachable)
    }

    func testIdleServersAreNotLive() {
        let model = ServerStatusModel(
            snapshot: snapshot([server("a", "Home", streams: 0, requests: 0)]), serverID: nil, liveReachability: [:], now: now
        )
        XCTAssertEqual(model.activeStreams, 0)
        XCTAssertFalse(model.hasLiveStreams, "the tally dot means a stream is live")
    }

    // MARK: Nothing yet

    func testNoSnapshotMeansNotSetUp() {
        let model = ServerStatusModel(snapshot: nil, serverID: nil, liveReachability: [:], now: now)
        XCTAssertFalse(model.hasServers)
        XCTAssertEqual(model.rows, [])
        XCTAssertEqual(model.status, .unknown)
        XCTAssertEqual(model.link, DeepLinkRoute(target: .allServers, pageID: DeepLinkPage.nowPlaying).url)
    }

    // MARK: What is checked

    func testOnlyHTTPSServersWithAnOriginAreChecked() {
        let secure = server("a", "Home")
        var plain = server("b", "Old")
        plain.origin = nil
        let targets = ServerStatusModel.checkTargets(in: snapshot([secure, plain]), serverID: nil)
        XCTAssertEqual(targets.map(\.id), ["a"])
        XCTAssertEqual(ServerStatusModel.checkTargets(in: snapshot([secure, plain]), serverID: "b").map(\.id), [])
    }
}
