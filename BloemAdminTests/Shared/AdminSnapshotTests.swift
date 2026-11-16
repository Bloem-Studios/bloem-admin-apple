import XCTest
@testable import BloemAdmin

/// The small file the app writes for widgets: server names and counts, never a token.
final class AdminSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let a = SnapshotServerInfo(id: "a", name: "Home", origin: URL(string: "https://home.example.test"))
    private let b = SnapshotServerInfo(id: "b", name: "Office", origin: URL(string: "https://office.example.test"))

    // MARK: Mapping

    func testMapsSavedServersInTheirOrder() {
        let snapshot = AdminSnapshot.make(previous: nil, servers: [b, a], reachability: [:], counts: [:], now: now)
        XCTAssertEqual(snapshot.servers.map(\.id), ["b", "a"])
        XCTAssertEqual(snapshot.servers.map(\.name), ["Office", "Home"])
        XCTAssertEqual(snapshot.generatedAt, now)
        XCTAssertEqual(snapshot.version, AdminSnapshot.currentVersion)
        XCTAssertNil(snapshot.servers[0].reachable)
        XCTAssertNil(snapshot.servers[0].activeStreams)
    }

    func testReachabilityAndCountsAreStamped() {
        let snapshot = AdminSnapshot.make(
            previous: nil, servers: [a],
            reachability: ["a": SnapshotReachability(reachable: true, checkedAt: now)],
            counts: ["a": .set(SnapshotCounts(streams: 2, requests: 5))],
            now: now
        )
        let server = snapshot.servers[0]
        XCTAssertEqual(server.reachable, true)
        XCTAssertEqual(server.checkedAt, now)
        XCTAssertEqual(server.activeStreams, 2)
        XCTAssertEqual(server.requestsWaiting, 5)
        XCTAssertEqual(server.countsAt, now)
    }

    func testCountsSurviveAReachabilityOnlyUpdateAndClearWhenAskedTo() {
        let first = AdminSnapshot.make(
            previous: nil, servers: [a], reachability: [:],
            counts: ["a": .set(SnapshotCounts(streams: 2, requests: 5))], now: now
        )
        let later = now.addingTimeInterval(900)
        let second = AdminSnapshot.make(
            previous: first, servers: [a],
            reachability: ["a": SnapshotReachability(reachable: false, checkedAt: later)], counts: [:], now: later
        )
        XCTAssertEqual(second.servers[0].reachable, false)
        XCTAssertEqual(second.servers[0].activeStreams, 2)
        XCTAssertEqual(second.servers[0].countsAt, now, "counts keep the time they were read")

        let third = AdminSnapshot.make(previous: second, servers: [a], reachability: [:], counts: ["a": .clear], now: later)
        XCTAssertNil(third.servers[0].activeStreams)
        XCTAssertNil(third.servers[0].requestsWaiting)
        XCTAssertNil(third.servers[0].countsAt)
        XCTAssertEqual(third.servers[0].reachable, false)
    }

    func testRemovedServersAreDroppedAndRenamedOnesFollowTheSavedName() {
        let first = AdminSnapshot.make(
            previous: nil, servers: [a, b], reachability: [:],
            counts: ["b": .set(SnapshotCounts(streams: 1, requests: 1))], now: now
        )
        let renamed = SnapshotServerInfo(id: "b", name: "Studio", origin: b.origin)
        let second = AdminSnapshot.make(previous: first, servers: [renamed], reachability: [:], counts: [:], now: now)
        XCTAssertEqual(second.servers.map(\.id), ["b"])
        XCTAssertEqual(second.servers[0].name, "Studio")
        XCTAssertEqual(second.servers[0].activeStreams, 1)
    }

    // MARK: What the file holds

    func testTheFileHoldsOnlyNamesAddressesStatusAndCounts() throws {
        let snapshot = AdminSnapshot.make(
            previous: nil, servers: [a],
            reachability: ["a": SnapshotReachability(reachable: true, checkedAt: now)],
            counts: ["a": .set(SnapshotCounts(streams: 1, requests: 2))], now: now
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), ["version", "generatedAt", "servers"])
        let server = try XCTUnwrap((object["servers"] as? [[String: Any]])?.first)
        XCTAssertEqual(
            Set(server.keys),
            ["id", "name", "origin", "reachable", "checkedAt", "activeStreams", "requestsWaiting", "countsAt"]
        )
    }

    // MARK: Reading it back for a widget

    func testSummaryAddsUpFreshCountsOnly() {
        var fresh = SnapshotServer(id: "a", name: "Home")
        fresh.reachable = true
        fresh.activeStreams = 2
        fresh.requestsWaiting = 3
        fresh.countsAt = now.addingTimeInterval(-600)
        var stale = SnapshotServer(id: "b", name: "Office")
        stale.reachable = false
        stale.activeStreams = 4
        stale.requestsWaiting = 9
        stale.countsAt = now.addingTimeInterval(-3 * 3600)
        let unknown = SnapshotServer(id: "c", name: "Cabin")

        let summary = SnapshotSummary(servers: [fresh, stale, unknown], now: now)
        XCTAssertEqual(summary.serverCount, 3)
        XCTAssertEqual(summary.reachableCount, 1)
        XCTAssertEqual(summary.unreachableCount, 1)
        XCTAssertEqual(summary.activeStreams, 2)
        XCTAssertEqual(summary.requestsWaiting, 3)
        XCTAssertTrue(summary.hasLiveStreams)
    }

    func testSummaryWithNoFreshCountsHasNoNumbers() {
        var stale = SnapshotServer(id: "b", name: "Office")
        stale.activeStreams = 4
        stale.requestsWaiting = 9
        stale.countsAt = now.addingTimeInterval(-3 * 3600)
        let summary = SnapshotSummary(servers: [stale], now: now)
        XCTAssertNil(summary.activeStreams)
        XCTAssertNil(summary.requestsWaiting)
        XCTAssertFalse(summary.hasLiveStreams)
    }

    func testNoStreamsIsNotLive() {
        var idle = SnapshotServer(id: "a", name: "Home")
        idle.activeStreams = 0
        idle.requestsWaiting = 0
        idle.countsAt = now
        let summary = SnapshotSummary(servers: [idle], now: now)
        XCTAssertEqual(summary.activeStreams, 0)
        XCTAssertFalse(summary.hasLiveStreams)
    }

    // MARK: The file

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFileStoreRoundTrips() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSnapshotStore(directory: directory)
        XCTAssertNil(store.load())
        let snapshot = AdminSnapshot.make(previous: nil, servers: [a, b], reachability: [:], counts: [:], now: now)
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testFileStoreIgnoresAFileItCannotRead() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSnapshotStore(directory: directory)
        try Data("not json".utf8).write(to: directory.appendingPathComponent(FileSnapshotStore.fileName))
        XCTAssertNil(store.load())

        var future = AdminSnapshot.make(previous: nil, servers: [a], reachability: [:], counts: [:], now: now)
        future.version = AdminSnapshot.currentVersion + 1
        try JSONEncoder().encode(future).write(to: directory.appendingPathComponent(FileSnapshotStore.fileName))
        XCTAssertNil(store.load(), "a newer format is not guessed at")
    }

    func testAppGroupContainerIsAvailableToTheSignedApp() {
        // Needs the App Group entitlement to be applied by the build's signing. It is the check that
        // widgets can share this app's file at all.
        XCTAssertNotNil(AppGroup.containerURL, "the App Group \(AppGroup.identifier) has no container")
    }
}
