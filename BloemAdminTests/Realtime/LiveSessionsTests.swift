import XCTest
@testable import BloemAdmin

/// Now playing on the shared live connection: a read on open, a read on each `sessions` cue, a read at most
/// once a minute while the socket is down, and nothing else.
@MainActor
final class LiveSessionsTests: XCTestCase {
    private let clock = TestLiveClock()

    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var script: [Result<[AdminSession], Error>]
        private var calls = 0
        init(_ script: [Result<[AdminSession], Error>] = []) { self.script = script }
        var count: Int { lock.withLock { calls } }
        func next() throws -> [AdminSession] {
            let result: Result<[AdminSession], Error>? = lock.withLock {
                calls += 1
                return script.isEmpty ? nil : script.removeFirst()
            }
            return try (result ?? .success([])).get()
        }
    }

    private func row(_ id: String) -> AdminSession {
        AdminSession(
            sessionID: id, username: "alex", mediaTitle: "Title \(id)", mediaType: "movie", playMethod: "directplay",
            positionSeconds: 0, fileDuration: 60, isPaused: false, clientName: "App"
        )
    }

    private func make(_ steps: [ScriptedEndpoint.Step], reads: Reads) -> (LiveSessions, LiveConnection) {
        let connection = LiveConnection(endpoint: ScriptedEndpoint(steps).endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let live = LiveSessions(connection: connection, read: { try reads.next() }, clock: clock)
        return (live, connection)
    }

    func testItReadsOnOpenAndOnEachCueAndNeverOtherwise() async {
        let socket = FakeLiveSocket()
        let reads = Reads([.success([row("a")]), .success([row("a"), row("b")]), .success([row("b")])])
        let (live, _) = make([.socket(socket)], reads: reads)

        let running = Task { await live.run() }
        await TestLiveClock.settle()
        XCTAssertEqual(live.sessions?.map(\.sessionID), ["a"], "the read on open")
        XCTAssertEqual(live.state, .connecting)

        await socket.goLive()
        XCTAssertEqual(live.state, .live)
        await TestLiveClock.settle()
        XCTAssertEqual(live.sessions?.map(\.sessionID), ["a", "b"], "the snapshot is a cue to read the REST list")

        await clock.advance(300)
        XCTAssertEqual(reads.count, 2, "five quiet minutes cost no read")

        socket.push(LiveFrames.event("sessions", name: "sessions.replaced"))
        await TestLiveClock.settle()
        XCTAssertEqual(live.sessions?.map(\.sessionID), ["b"])
        XCTAssertEqual(reads.count, 3)

        running.cancel()
        await running.value
    }

    func testWhileTheSocketIsDownItReadsAtMostOnceAMinute() async {
        let reads = Reads()
        let (live, connection) = make([.fail(.connection)], reads: reads)
        let running = Task { await live.run() }
        await TestLiveClock.settle()
        await clock.advance(3.5)
        XCTAssertEqual(reads.count, 1, "only the read on open so far")
        XCTAssertEqual(live.state, .reconnecting)
        XCTAssertEqual(live.failure, .connection)
        XCTAssertEqual(connection.consecutiveFailures, 3)

        await clock.advance(61)
        XCTAssertEqual(reads.count, 2)
        await clock.advance(30)
        XCTAssertEqual(reads.count, 2, "not more than once a minute")
        await clock.advance(40)
        XCTAssertEqual(reads.count, 3)

        running.cancel()
        await running.value
    }

    func testAServerWithoutASocketSaysSoAndReadsEveryMinute() async {
        let reads = Reads()
        let (live, _) = make([.fail(.unsupported)], reads: reads)
        let running = Task { await live.run() }
        await TestLiveClock.settle()

        XCTAssertEqual(live.state, .unavailable)
        XCTAssertEqual(live.failure, .unsupported)
        XCTAssertEqual(SessionFailure.unsupported.message, "Live updates unavailable, sessions refresh every minute")
        await clock.advance(61)
        XCTAssertEqual(reads.count, 2)

        running.cancel()
        await running.value
    }

    func testWhenTheSessionsChannelIsNotOfferedItIsUnavailableNotLive() async {
        let socket = FakeLiveSocket()
        let reads = Reads()
        let (live, _) = make([.socket(socket)], reads: reads)
        let running = Task { await live.run() }
        await TestLiveClock.settle()
        socket.push(LiveFrames.hello(["catalog"]))
        await TestLiveClock.settle()

        XCTAssertEqual(live.state, .unavailable)
        XCTAssertEqual(live.failure, .unsupported)

        running.cancel()
        await running.value
    }

    func testALostSignInOnTheListEndsItAndClearsTheRows() async {
        let socket = FakeLiveSocket()
        let reads = Reads([.success([row("a")]), .failure(APIError(statusCode: 401, message: "no"))])
        let (live, _) = make([.socket(socket)], reads: reads)
        let running = Task { await live.run() }
        await TestLiveClock.settle()
        await socket.goLive()
        await TestLiveClock.settle()

        XCTAssertEqual(live.state, .signInRequired)
        XCTAssertNil(live.sessions)
        await running.value
    }

    func testAFailedReadKeepsTheLastRowsBesideTheError() async {
        let socket = FakeLiveSocket()
        let reads = Reads([.success([row("a")]), .failure(APIError(statusCode: 500, message: "down"))])
        let (live, _) = make([.socket(socket)], reads: reads)
        let running = Task { await live.run() }
        await TestLiveClock.settle()
        await socket.goLive()
        await TestLiveClock.settle()

        XCTAssertEqual(live.sessions?.map(\.sessionID), ["a"])
        XCTAssertNotNil(live.readFailure)

        running.cancel()
        await running.value
    }

    func testCancellingTheRunEndsTheSubscriptionSoTheSocketCanClose() async {
        let socket = FakeLiveSocket()
        let (live, connection) = make([.socket(socket)], reads: Reads())
        let running = Task { await live.run() }
        await TestLiveClock.settle()
        await socket.goLive()
        XCTAssertEqual(connection.subscriberCount, 1)

        running.cancel()
        await running.value
        XCTAssertEqual(connection.subscriberCount, 0)
        await clock.advance(11)
        XCTAssertTrue(socket.isClosed)
    }
}
