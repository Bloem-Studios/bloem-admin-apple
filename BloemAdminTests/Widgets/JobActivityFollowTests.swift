import XCTest
@testable import BloemAdmin

@MainActor
private final class Presenter: AdminJobActivityPresenting {
    var updates: [(String, AdminJobActivityAttributes.Phase, Double?)] = []
    var ended: [AdminJobActivityAttributes.Phase] = []
    func start(_ attributes: AdminJobActivityAttributes, state: AdminJobActivityAttributes.ContentState) -> String? { "activity-1" }
    func update(id: String, state: AdminJobActivityAttributes.ContentState) { updates.append((id, state.phase, state.progress)) }
    func end(id: String, state: AdminJobActivityAttributes.ContentState) { ended.append(state.phase) }
}

/// The scan and backup Live Activity follows the live socket while the app is in the foreground, and
/// nothing reads or ticks in the background.
@MainActor
final class JobActivityFollowTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let clock = TestLiveClock()
    private let backupsPath = "/api/v2/admin/backups"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func overview(progress: Int?) -> Any {
        var object: [String: Any] = [
            "busy": progress != nil, "destination": "default", "destination_available": true, "enabled": true, "encrypted": false,
            "items": [], "keep": 7, "key_check": "k", "key_confirmed": true, "other_server_ids": [], "server_id": "s", "warnings": [],
        ]
        if let progress { object["active"] = ["operation": "backup", "progress": progress] }
        return object
    }

    func testTheFollowedServerIDsAreThoseWithAnActivity() {
        let tracker = AdminJobActivityTracker(presenter: Presenter(), serverName: { _ in "Home" })
        XCTAssertTrue(tracker.followedServerIDs.isEmpty)
        tracker.scanStarted(serverID: "home", libraryID: "l1", libraryName: "Films")
        tracker.backupStarted(serverID: "nas")
        XCTAssertEqual(tracker.followedServerIDs, ["home", "nas"])
    }

    func testABackupActivityMovesWhenTheTasksChannelSaysSoAndNotOtherwise() async throws {
        let presenter = Presenter()
        let tracker = AdminJobActivityTracker(presenter: presenter, serverName: { _ in "Home" })
        tracker.backupStarted(serverID: "home")
        http.state.stub(path: backupsPath, json: overview(progress: 10))
        let socket = FakeLiveSocket()
        let connection = LiveConnection(endpoint: ScriptedEndpoint([.socket(socket)]).endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let client = http.client

        let following = Task { @MainActor in
            await JobActivityFollowing.run(
                servers: [(id: "home", client: client)], tracker: tracker, connection: { _ in connection }, clock: clock
            )
        }
        _ = await waitUntil { presenter.updates.count == 1 }
        XCTAssertEqual(presenter.updates.last?.2, 0.1, "read once when the app is open on it")
        await socket.goLive()
        _ = await waitUntil { presenter.updates.count == 2 }
        await clock.advance(2)
        let readsAfterConnect = http.state.requests(path: backupsPath).count

        await clock.advance(600)
        XCTAssertEqual(http.state.requests(path: backupsPath).count, readsAfterConnect, "ten quiet minutes: no read")

        http.state.stub(path: backupsPath, json: overview(progress: 60))
        socket.push(LiveFrames.event("tasks", name: "task.updated"))
        _ = await waitUntil { presenter.updates.last?.2 == 0.6 }
        XCTAssertEqual(presenter.updates.last?.2, 0.6, "a task event moves the activity")

        following.cancel()
        await following.value
        await clock.advance(11)
        XCTAssertTrue(socket.isClosed, "the follower holds no socket once it stops")
    }

    func testNothingFollowedMeansNoSocketAtAll() async {
        let tracker = AdminJobActivityTracker(presenter: Presenter(), serverName: { _ in "Home" })
        let socket = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(socket)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)

        await JobActivityFollowing.run(servers: [], tracker: tracker, connection: { _ in connection }, clock: clock)

        XCTAssertEqual(script.attempts, 0)
        XCTAssertEqual(tracker.followedCount, 0)
    }
}
