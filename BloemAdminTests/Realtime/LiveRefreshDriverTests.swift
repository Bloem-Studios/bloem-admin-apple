import XCTest
@testable import BloemAdmin

/// What a visible screen does with its subscription: one read on open, then a read per burst of signals and
/// nothing on a timer. "No polling loop runs while connected" is the second test.
@MainActor
final class LiveRefreshDriverTests: XCTestCase {
    private let clock = TestLiveClock()

    private final class Counts {
        var initial = 0
        var batches: [[LiveSignal]] = []
        var reads: Int { initial + batches.count }
    }

    private func start(
        channels: Set<LiveChannel> = [.scans], socket: FakeLiveSocket = FakeLiveSocket(), counts: Counts = Counts()
    ) async -> (Task<Void, Never>, LiveConnection, FakeLiveSocket, Counts) {
        var timings = LiveTimings()
        timings.fallbackInterval = 77
        let connection = LiveConnection(endpoint: ScriptedEndpoint([.socket(socket)]).endpoint, timings: timings, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let running = Task { @MainActor in
            await LiveRefreshDriver.run(
                connection: connection, channels: channels, clock: clock,
                initial: { counts.initial += 1 },
                onSignals: { counts.batches.append($0) }
            )
        }
        await TestLiveClock.settle()
        return (running, connection, socket, counts)
    }

    func testAScreenReadsOnceWhenItOpens() async {
        let (running, _, _, counts) = await start()
        XCTAssertEqual(counts.initial, 1)
        running.cancel()
        await running.value
    }

    func testNoPollingLoopRunsWhileConnected() async {
        let (running, connection, socket, counts) = await start()
        await socket.goLive()
        let afterConnect = counts.reads
        XCTAssertEqual(afterConnect, 2, "the read on open and the resync after the connect")

        for _ in 0..<30 { await clock.advance(60) }

        XCTAssertEqual(counts.reads, afterConnect, "thirty minutes connected with nothing changing: not one read")
        XCTAssertEqual(connection.state, .live)
        XCTAssertEqual(connection.connectCount, 1)
        XCTAssertFalse(clock.sleeps.contains(77), "no fallback loop exists while the socket is live")
        XCTAssertEqual(clock.pendingCount, 2, "only the socket's own ping and watchdog timers run")
        running.cancel()
        await running.value
    }

    func testAChangeOnTheChannelIsOneRead() async {
        let (running, _, socket, counts) = await start()
        await socket.goLive()
        await clock.advance(2)
        let before = counts.reads

        socket.push(LiveFrames.event("scans", name: "scan.progress"))
        await TestLiveClock.settle()

        XCTAssertEqual(counts.reads, before + 1)
        XCTAssertEqual(counts.batches.last, [.changed(.scans)])
        running.cancel()
        await running.value
    }

    func testABurstOfEventsIsOneReadASecondAtMost() async {
        let (running, _, socket, counts) = await start()
        await socket.goLive()
        await clock.advance(2)
        let before = counts.reads

        socket.push(LiveFrames.event("scans", name: "scan.progress", id: "e0"))
        await TestLiveClock.settle()
        XCTAssertEqual(counts.reads, before + 1, "the first signal reads at once")

        for index in 1..<20 { socket.push(LiveFrames.event("scans", name: "scan.progress", id: "e\(index)")) }
        await TestLiveClock.settle()
        XCTAssertEqual(counts.reads, before + 1, "nineteen more inside the gap wait for it")

        await clock.advance(1.1)
        XCTAssertEqual(counts.reads, before + 2, "the rest collapse into one more read after the gap")
        await clock.advance(5)
        XCTAssertEqual(counts.reads, before + 2)
        running.cancel()
        await running.value
    }

    func testAScreenWithNoChannelNeverOpensASocketAndIsNeverSignalled() async {
        let socket = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(socket)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let counts = Counts()
        let running = Task { @MainActor in
            await LiveRefreshDriver.run(
                connection: connection, channels: [], clock: clock,
                initial: { counts.initial += 1 }, onSignals: { counts.batches.append($0) }
            )
        }
        await TestLiveClock.settle()

        await clock.advance(3600)

        XCTAssertEqual(counts.reads, 1, "history screens read on open and on pull, nothing else")
        XCTAssertEqual(script.attempts, 0)
        XCTAssertEqual(clock.pendingCount, 0)
        running.cancel()
        await running.value
    }

    func testLeavingTheScreenEndsTheSubscription() async {
        let (running, connection, socket, _) = await start()
        await socket.goLive()
        XCTAssertEqual(connection.subscriberCount, 1)

        running.cancel()
        await running.value

        XCTAssertEqual(connection.subscriberCount, 0)
        await clock.advance(11)
        XCTAssertTrue(socket.isClosed)
    }

    func testTheFallbackTickIsASignalToo() async {
        let counts = Counts()
        let connection = LiveConnection(endpoint: ScriptedEndpoint([.fail(.unsupported)]).endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let running = Task { @MainActor in
            await LiveRefreshDriver.run(
                connection: connection, channels: [.tasks], clock: clock,
                initial: { counts.initial += 1 }, onSignals: { counts.batches.append($0) }
            )
        }
        await TestLiveClock.settle()

        await clock.advance(61)

        XCTAssertEqual(counts.batches, [[.fallback]])
        running.cancel()
        await running.value
    }
}
