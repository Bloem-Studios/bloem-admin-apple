import XCTest
@testable import BloemAdmin

private final class FakePathSource: NetworkPathSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var starts = 0
    private var stops = 0
    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var running: Bool { lock.withLock { handler != nil } }

    func start(onChange: @escaping @Sendable () -> Void) {
        lock.withLock {
            starts += 1
            handler = onChange
        }
    }

    func stop() {
        lock.withLock {
            stops += 1
            handler = nil
        }
    }

    func change() { lock.withLock { handler }?() }
}

/// One connection per server, driven by the scenes: open while any scene is active, the network monitor
/// only while it is.
@MainActor
final class LiveHubTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let clock = TestLiveClock()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func hub(_ path: FakePathSource = FakePathSource()) -> (LiveHub, FakePathSource, ScriptedEndpoint) {
        let script = ScriptedEndpoint([.fail(.connection)])
        let hub = LiveHub(pathSource: path)
        let clock = clock
        hub.makeConnection = { _ in LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 }) }
        return (hub, path, script)
    }

    func testOneConnectionPerServerWhoeverAsks() {
        let (hub, _, _) = hub()
        let a = APIClient(baseURL: URL(string: "https://a.test")!, accessToken: "1", session: http.session)
        let again = APIClient(baseURL: URL(string: "https://a.test")!, accessToken: "2", session: http.session)
        let b = APIClient(baseURL: URL(string: "https://b.test")!, accessToken: "1", session: http.session)

        XCTAssertTrue(hub.connection(for: a) === hub.connection(for: again), "a refreshed sign-in reuses the connection")
        XCTAssertFalse(hub.connection(for: a) === hub.connection(for: b))
        XCTAssertEqual(hub.connectionCount, 2)
    }

    func testTheNetworkMonitorRunsOnlyWhileASceneIsActive() {
        let (hub, path, _) = hub()
        let one = AppSceneID()
        let two = AppSceneID()
        XCTAssertFalse(path.running)

        hub.sceneChanged(one, phase: .active)
        hub.sceneChanged(two, phase: .active)
        XCTAssertTrue(path.running)
        XCTAssertEqual(path.startCount, 1)

        hub.sceneChanged(one, phase: .background)
        XCTAssertTrue(path.running, "another scene is still on screen")
        hub.sceneChanged(two, phase: .inactive)
        XCTAssertTrue(path.running, "inactive is not leaving")
        hub.sceneChanged(two, phase: .background)
        XCTAssertFalse(path.running)
        XCTAssertEqual(path.stopCount, 1)
    }

    func testConnectionsFollowTheScenesAndAPathChangeReconnectsThem() async {
        let (hub, path, script) = hub()
        let client = APIClient(baseURL: URL(string: "https://a.test")!, accessToken: "1", session: http.session)
        let connection = hub.connection(for: client)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 0, "no scene is active")

        let scene = AppSceneID()
        hub.sceneChanged(scene, phase: .active)
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 1)

        path.change()
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 2, "the path changed: reconnect at once")

        hub.sceneChanged(scene, phase: .background)
        await clock.advance(11)
        let whenItStopped = script.attempts
        path.change()
        await clock.advance(600)
        XCTAssertEqual(script.attempts, whenItStopped, "in the background nothing connects")
        XCTAssertEqual(clock.pendingCount, 0)
        subscription.cancel()
    }

    func testAConnectionMadeLaterStartsInTheCurrentForegroundState() async {
        let (hub, _, script) = hub()
        hub.sceneChanged(AppSceneID(), phase: .active)
        let client = APIClient(baseURL: URL(string: "https://late.test")!, accessToken: "1", session: http.session)
        let subscription = hub.connection(for: client).subscribe([.tasks])
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 1)
        subscription.cancel()
    }
}
