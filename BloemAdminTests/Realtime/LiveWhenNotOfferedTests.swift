import XCTest
@testable import BloemAdmin

/// What a screen does while its socket works but the server does not serve its channel: a screen that kept a pace
/// of its own keeps exactly that, a screen that kept none stays silent, and the rest read once a minute as before.
/// With no socket at all every screen falls back to once a minute.
@MainActor
final class LiveWhenNotOfferedTests: XCTestCase {
    private let clock = TestLiveClock()
    /// Not 60, which the watchdog also sleeps on, so "the minute loop is running" can be told from it.
    private static let minute: TimeInterval = 77

    private static var timings: LiveTimings {
        var timings = LiveTimings()
        timings.fallbackInterval = minute
        return timings
    }

    private func connection(_ steps: [ScriptedEndpoint.Step], clock: TestLiveClock? = nil) -> LiveConnection {
        let made = LiveConnection(endpoint: ScriptedEndpoint(steps).endpoint, timings: Self.timings, clock: clock ?? self.clock, jitter: { 1 })
        made.setForeground(true)
        return made
    }

    /// The server says hello and offers nothing this screen subscribes to.
    private func notServed(_ socket: FakeLiveSocket) async {
        socket.push(LiveFrames.hello(["sessions"]))
        await TestLiveClock.settle()
    }

    private final class Counts {
        var initial = 0
        var batches: [[LiveSignal]] = []
        var reads: Int { initial + batches.count }
    }

    /// A screen on `.orgStreams` against a server whose hello offers only `sessions`, so the channel is not served.
    private func screen(
        _ policy: LiveWhenNotOffered, socket: FakeLiveSocket = FakeLiveSocket(), connection: LiveConnection? = nil, counts: Counts = Counts()
    ) async -> (Task<Void, Never>, LiveConnection, FakeLiveSocket, Counts) {
        let live = connection ?? self.connection([.socket(socket)])
        let running = Task { @MainActor in
            await LiveRefreshDriver.run(
                connection: live, channels: [.orgStreams], whenNotOffered: policy, clock: clock,
                initial: { counts.initial += 1 }, onSignals: { counts.batches.append($0) }
            )
        }
        await TestLiveClock.settle()
        return (running, live, socket, counts)
    }

    func testAScreenWithAPaceOfItsOwnKeepsExactlyThatPace() async {
        let (running, connection, socket, counts) = await screen(.every(10))
        await notServed(socket)
        XCTAssertEqual(connection.unavailableChannels, [.orgStreams])
        XCTAssertEqual(counts.reads, 1, "the read on open")

        await clock.advance(35)

        XCTAssertEqual(counts.reads, 4, "the open, then a read at 10, 20 and 30 seconds")
        XCTAssertTrue(clock.sleeps.contains(10))
        XCTAssertFalse(clock.sleeps.contains(Self.minute), "the minute loop is not running for it")
        running.cancel()
        await running.value
    }

    func testAScreenThatKeptNoTimerGetsNone() async {
        let (running, _, socket, counts) = await screen(.readOnOpenOnly)
        await notServed(socket)

        for _ in 0..<60 { await clock.advance(60) }

        XCTAssertEqual(counts.reads, 1, "an hour with a server that does not serve the channel: only the read on open")
        XCTAssertEqual(clock.pendingCount, 0, "no timer exists at all")
        running.cancel()
        await running.value
    }

    func testTheDefaultStaysOnceAMinute() async {
        let (running, _, socket, counts) = await screen(.slowPoll)
        await notServed(socket)

        await clock.advance(160)

        XCTAssertEqual(counts.reads, 3, "the open, then a read after each minute of its own, as before")
        XCTAssertTrue(clock.sleeps.contains(Self.minute))
        running.cancel()
        await running.value
    }

    func testWithTheSocketDownEveryScreenFallsBackToOnceAMinute() async {
        for policy in [LiveWhenNotOffered.readOnOpenOnly, .every(10), .slowPoll] {
            let clock = TestLiveClock()
            let counts = Counts()
            let connection = self.connection([.fail(.connection)], clock: clock)
            let running = Task { @MainActor in
                await LiveRefreshDriver.run(
                    connection: connection, channels: [.orgStreams], whenNotOffered: policy, clock: clock,
                    initial: { counts.initial += 1 }, onSignals: { counts.batches.append($0) }
                )
            }
            await TestLiveClock.settle()

            await clock.advance(200)

            XCTAssertGreaterThanOrEqual(counts.reads, 3, "\(policy): the open and the minute reads once three attempts have failed")
            XCTAssertLessThanOrEqual(counts.reads, 4, "\(policy): never faster than once a minute")
            XCTAssertTrue(clock.sleeps.contains(Self.minute), "\(policy): the minute loop runs")
            XCTAssertFalse(clock.sleeps.contains(10), "\(policy): the screen's own pace does not apply without a socket")
            running.cancel()
            await running.value
        }
    }

    func testAChannelTheServerServesIsNeverPolledWhateverTheScreenWouldDoOtherwise() async {
        let (running, connection, socket, counts) = await screen(.every(10))
        await socket.goLive(available: ["org.streams"])
        XCTAssertEqual(connection.state, .live)
        let afterConnect = counts.reads

        for _ in 0..<30 { await clock.advance(60) }

        XCTAssertEqual(counts.reads, afterConnect, "thirty minutes connected with nothing changing: not one read")
        XCTAssertFalse(clock.sleeps.contains(10))
        running.cancel()
        await running.value
    }

    func testNothingIsReadInTheBackgroundAndTheScreenCatchesUpOnReturn() async {
        let first = FakeLiveSocket()
        let second = FakeLiveSocket()
        let connection = self.connection([.socket(first), .socket(second)])
        let (running, _, _, counts) = await screen(.every(10), socket: first, connection: connection)
        await notServed(first)
        await clock.advance(25)
        XCTAssertEqual(counts.reads, 3)

        connection.setForeground(false)
        await TestLiveClock.settle()
        await clock.advance(3600)

        XCTAssertEqual(counts.reads, 3, "an hour away: not one read")
        XCTAssertEqual(clock.pendingCount, 0)

        connection.setForeground(true)
        await TestLiveClock.settle()
        await notServed(second)
        await clock.advance(12)
        XCTAssertGreaterThan(counts.reads, 3, "back in front the pace resumes")
        running.cancel()
        await running.value
    }

    func testLeavingTheScreenStopsItsTimer() async {
        let (running, _, socket, counts) = await screen(.every(10))
        await notServed(socket)
        await clock.advance(15)
        let before = counts.reads

        running.cancel()
        await running.value
        await clock.advance(120)

        XCTAssertEqual(counts.reads, before)
        XCTAssertEqual(clock.pendingCount, 0)
    }
}
