import XCTest
@testable import BloemAdmin

/// The shared live connection's rules from `bloem-staff-live.md`: foreground only, backoff with jitter,
/// reconnect at once on a path change, the 60 s watchdog, channel reference counting, resync, and the
/// fallback after three failed connects. Time and the socket are injected, so a minute takes milliseconds.
@MainActor
final class LiveConnectionTests: XCTestCase {
    private var clock = TestLiveClock()

    private func make(
        _ steps: [ScriptedEndpoint.Step], jitter: Double = 1, timings: LiveTimings = LiveTimings()
    ) -> (LiveConnection, ScriptedEndpoint) {
        let script = ScriptedEndpoint(steps)
        let connection = LiveConnection(endpoint: script.endpoint, timings: timings, clock: clock, jitter: { jitter })
        return (connection, script)
    }

    /// A connection in the foreground, subscribed to `channels`, with one live socket.
    private func live(
        channels: Set<LiveChannel> = [.scans], timings: LiveTimings = LiveTimings()
    ) async -> (LiveConnection, ScriptedEndpoint, FakeLiveSocket, LiveSubscription) {
        let socket = FakeLiveSocket()
        let (connection, script) = make([.socket(socket)], timings: timings)
        connection.setForeground(true)
        let subscription = connection.subscribe(channels)
        await TestLiveClock.settle()
        await socket.goLive()
        XCTAssertEqual(connection.state, .live)
        return (connection, script, socket, subscription)
    }

    // MARK: Foreground

    func testNothingConnectsUntilTheAppIsInTheForegroundAndAScreenWantsAChannel() async {
        let socket = FakeLiveSocket()
        let (connection, script) = make([.socket(socket)])

        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 0, "a background app holds no socket")

        connection.setForeground(true)
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 1)

        subscription.cancel()
    }

    func testAForegroundAppWithNoScreenWantingAChannelHoldsNoSocket() async {
        let (connection, script) = make([.socket(FakeLiveSocket())])
        connection.setForeground(true)
        _ = connection.subscribe([])
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 0)
    }

    func testTheSocketCloses10SecondsAfterTheAppLeavesTheForeground() async {
        let (connection, script, socket, subscription) = await live()

        connection.setForeground(false)
        await clock.advance(9)
        XCTAssertFalse(socket.isClosed, "it stays through the grace period")

        await clock.advance(1.5)
        XCTAssertTrue(socket.isClosed)
        XCTAssertEqual(script.attempts, 1)
        XCTAssertEqual(connection.state, .unavailable)
        subscription.cancel()
    }

    func testComingBackWithinTheGracePeriodKeepsTheSameSocket() async {
        let (connection, script, socket, subscription) = await live()

        connection.setForeground(false)
        await clock.advance(6)
        connection.setForeground(true)
        await clock.advance(30)

        XCTAssertFalse(socket.isClosed)
        XCTAssertEqual(script.attempts, 1)
        XCTAssertEqual(connection.state, .live)
        subscription.cancel()
    }

    func testComingBackAfterTheGracePeriodConnectsAtOnceWithoutBackoff() async {
        let first = FakeLiveSocket()
        let second = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(first), .socket(second)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await first.goLive()

        connection.setForeground(false)
        await clock.advance(20)
        XCTAssertTrue(first.isClosed)

        connection.setForeground(true)
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 2, "no waiting: the app is back")
        subscription.cancel()
    }

    func testTheLastScreenLeavingClosesTheSocketAfterTheGracePeriod() async {
        let (_, _, socket, subscription) = await live()
        subscription.cancel()
        await clock.advance(9)
        XCTAssertFalse(socket.isClosed)
        await clock.advance(2)
        XCTAssertTrue(socket.isClosed)
    }

    func testANewScreenWithinTheGracePeriodReusesTheSocket() async {
        let (connection, script, socket, subscription) = await live()
        subscription.cancel()
        await clock.advance(5)
        let next = connection.subscribe([.scans])
        await clock.advance(30)

        XCTAssertFalse(socket.isClosed)
        XCTAssertEqual(script.attempts, 1)
        next.cancel()
    }

    // MARK: Backoff

    func testReconnectsBackOffExponentiallyUpToAMinuteWithJitter() async {
        var timings = LiveTimings()
        timings.fallbackInterval = 1000
        let (connection, script) = make([.fail(.connection)], timings: timings)
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 1)

        await clock.advance(0.9)
        XCTAssertEqual(script.attempts, 1, "the first retry waits 1 s")
        await clock.advance(0.2)
        XCTAssertEqual(script.attempts, 2)
        await clock.advance(1.8)
        XCTAssertEqual(script.attempts, 2, "then 2 s")
        await clock.advance(0.3)
        XCTAssertEqual(script.attempts, 3)

        await clock.advance(400)
        let waits = clock.sleeps.filter { $0 != 1000 }
        XCTAssertEqual(Array(waits.prefix(8)), [1, 2, 4, 8, 16, 32, 60, 60], "doubling, capped at 60 s")
        subscription.cancel()
    }

    func testTheWaitIsAnywhereFromNothingToTheCeiling() async {
        var timings = LiveTimings()
        timings.fallbackInterval = 1000
        let (connection, _) = make([.fail(.connection)], jitter: 0.25, timings: timings)
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await clock.advance(10)
        XCTAssertEqual(clock.sleeps.first, 0.25, "full jitter: a quarter of the 1 s ceiling")
        subscription.cancel()
    }

    func testANetworkPathChangeReconnectsAtOnceAndSkipsTheBackoff() async {
        let (connection, script) = make([.fail(.connection)])
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 1)
        XCTAssertEqual(connection.state, .reconnecting)

        connection.networkPathChanged()
        await TestLiveClock.settle()

        XCTAssertEqual(script.attempts, 2, "the 1 s wait was cut short")
        subscription.cancel()
    }

    func testANetworkPathChangeReplacesALiveSocket() async {
        let first = FakeLiveSocket()
        let second = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(first), .socket(second)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await first.goLive()

        connection.networkPathChanged()
        await TestLiveClock.settle()

        XCTAssertTrue(first.isClosed)
        XCTAssertEqual(script.attempts, 2)
        subscription.cancel()
    }

    func testANetworkPathChangeWhileInTheBackgroundDoesNothing() async {
        let (connection, script) = make([.fail(.connection)])
        _ = connection.subscribe([.scans])
        connection.networkPathChanged()
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 0)
    }

    func testAServerThatEndsALiveConnectionCleanlyIsReconnectedAtOnce() async {
        let first = FakeLiveSocket()
        let second = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(first), .socket(second)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await first.goLive()
        await clock.advance(300)

        first.serverClose(code: 1000)
        await TestLiveClock.settle()

        XCTAssertEqual(script.attempts, 2, "the server's own limit on a connection is not a failure")
        XCTAssertEqual(connection.consecutiveFailures, 0)
        subscription.cancel()
    }

    func testAnAccessChangeReconnectsAtOnceOnceThenBacksOff() async {
        let first = FakeLiveSocket()
        let second = FakeLiveSocket()
        let third = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(first), .socket(second), .socket(third)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await first.goLive()

        first.push(LiveFrames.accessChanged)
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 2, "a new ticket at once")

        second.push(LiveFrames.hello(["scans"]))
        second.push(LiveFrames.accessChanged)
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 2, "a second one before reaching live waits like any failure")
        await clock.advance(1.5)
        XCTAssertEqual(script.attempts, 3)
        subscription.cancel()
    }

    // MARK: Watchdog

    func testASocketWithNoFrameAndNoPongFor60SecondsIsDeclaredDeadAndReplaced() async {
        let first = FakeLiveSocket()
        first.pingMode = .hang
        let second = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(first), .socket(second)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await first.goLive()

        await clock.advance(59)
        XCTAssertFalse(first.isClosed)
        XCTAssertEqual(script.attempts, 1)

        await clock.advance(3)
        XCTAssertTrue(first.isClosed, "60 s of silence")
        await clock.advance(2)
        XCTAssertEqual(script.attempts, 2)
        subscription.cancel()
    }

    func testAnyFrameFeedsTheWatchdog() async {
        let first = FakeLiveSocket()
        first.pingMode = .hang
        let script = ScriptedEndpoint([.socket(first), .socket(FakeLiveSocket())])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await first.goLive()

        await clock.advance(50)
        first.push(LiveFrames.event("scans"))
        await TestLiveClock.settle()
        await clock.advance(55)
        XCTAssertFalse(first.isClosed, "the frame at 50 s moved the deadline to 110 s")

        await clock.advance(10)
        XCTAssertTrue(first.isClosed)
        subscription.cancel()
    }

    func testPingsKeepAQuietButHealthySocketAlive() async {
        let (connection, script, socket, subscription) = await live()

        await clock.advance(300)

        XCTAssertFalse(socket.isClosed)
        XCTAssertEqual(script.attempts, 1)
        XCTAssertEqual(socket.pingCount, 12, "a ping every 25 s")
        XCTAssertEqual(connection.state, .live)
        subscription.cancel()
    }

    func testAFirstConnectThatNeverSubscribesTimesOutAfter15Seconds() async {
        let socket = FakeLiveSocket()
        let (connection, _) = make([.socket(socket)])
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()

        await clock.advance(15.5)

        XCTAssertTrue(socket.isClosed)
        XCTAssertEqual(connection.failure, .deadline)
        XCTAssertEqual(connection.consecutiveFailures, 1)
        subscription.cancel()
    }

    func testAnotherSubprotocolThanTheOneAskedForIsAProtocolFailure() async {
        let socket = FakeLiveSocket()
        socket.negotiatedProtocol = "something.else"
        let (connection, _) = make([.socket(socket)])
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        socket.push(LiveFrames.hello(["scans"]))
        await TestLiveClock.settle()

        XCTAssertEqual(connection.failure, .protocolViolation)
        subscription.cancel()
    }

    // MARK: Subscriptions

    func testTheSubscribeFrameAsksForExactlyTheChannelsScreensWant() async {
        let socket = FakeLiveSocket()
        let (connection, _) = make([.socket(socket)])
        connection.setForeground(true)
        let a = connection.subscribe([.scans])
        let b = connection.subscribe([.tasks, .jobs])
        await TestLiveClock.settle()
        await socket.goLive()

        XCTAssertEqual(socket.sent.compactMap(LiveFrames.parse).first?.channels, ["jobs", "scans", "tasks"])
        a.cancel()
        b.cancel()
    }

    func testChannelsAreReferenceCountedAcrossScreens() async {
        let (connection, script, socket, first) = await live(channels: [.scans])
        XCTAssertEqual(socket.sent.compactMap(LiveFrames.parse).last?.channels, ["scans"])
        XCTAssertEqual(first.take(), [.resync(.scans)])

        let second = connection.subscribe([.scans, .tasks])
        await TestLiveClock.settle()
        XCTAssertEqual(socket.sent.compactMap(LiveFrames.parse).last?.channels, ["scans", "tasks"], "one frame asks for the union")
        await socket.answerLatestSubscribe()

        // Only the new channel is a resync for the screens: the server repeats every snapshot it has.
        XCTAssertEqual(second.take(), [.resync(.tasks)])
        XCTAssertTrue(first.take().isEmpty)

        second.cancel()
        await TestLiveClock.settle()
        XCTAssertEqual(socket.sent.compactMap(LiveFrames.parse).last?.channels, ["scans"], "tasks is dropped when its screen goes")
        await socket.answerLatestSubscribe()
        XCTAssertTrue(first.take().isEmpty)

        socket.push(LiveFrames.event("tasks"))
        socket.push(LiveFrames.event("scans", id: "e2"))
        await TestLiveClock.settle()
        XCTAssertEqual(first.take(), [.changed(.scans)])

        first.cancel()
        await clock.advance(11)
        XCTAssertTrue(socket.isClosed, "nobody left")
        XCTAssertEqual(script.attempts, 1, "all of it over one socket")
    }

    func testEachScreenHearsOnlyItsOwnChannels() async {
        let (connection, _, socket, scans) = await live(channels: [.scans])
        let tasks = connection.subscribe([.tasks])
        await TestLiveClock.settle()
        await socket.answerLatestSubscribe()
        _ = scans.take()
        _ = tasks.take()

        socket.push(LiveFrames.event("tasks", id: "e5"))
        await TestLiveClock.settle()

        XCTAssertEqual(tasks.take(), [.changed(.tasks)])
        XCTAssertTrue(scans.take().isEmpty)
        scans.cancel()
        tasks.cancel()
    }

    func testEveryConnectIsFollowedByAResyncOfEachChannel() async {
        let first = FakeLiveSocket()
        let second = FakeLiveSocket()
        let script = ScriptedEndpoint([.socket(first), .socket(second)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans, .tasks])
        await TestLiveClock.settle()
        await first.goLive()
        XCTAssertEqual(Set(subscription.take()), [.resync(.scans), .resync(.tasks)], "Silo has no resume: the snapshot is the resync")

        connection.networkPathChanged()
        await TestLiveClock.settle()
        await second.goLive()
        XCTAssertEqual(Set(subscription.take()), [.resync(.scans), .resync(.tasks)])
        subscription.cancel()
    }

    // MARK: Fallback

    func testNothingPollsBeforeThreeConnectsHaveFailed() async {
        var timings = LiveTimings()
        timings.backoffCeiling = 1
        let (connection, script) = make([.fail(.connection)], timings: timings)
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await clock.advance(1.2)
        XCTAssertEqual(script.attempts, 2)
        XCTAssertEqual(connection.consecutiveFailures, 2)

        await clock.advance(1)
        XCTAssertEqual(script.attempts, 3)
        XCTAssertEqual(connection.consecutiveFailures, 3)
        XCTAssertTrue(subscription.take().isEmpty, "the first poll is a minute after the third failure")
        subscription.cancel()
    }

    func testAfterThreeFailedConnectsTheVisibleScreenIsPolledAtMostOnceAMinute() async {
        let (connection, _) = make([.fail(.connection)])
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await clock.advance(3.5)
        XCTAssertEqual(connection.consecutiveFailures, 3)
        XCTAssertTrue(connection.isUnavailable(.scans))

        await clock.advance(55)
        XCTAssertTrue(subscription.take().isEmpty, "not yet a minute")
        await clock.advance(10)
        XCTAssertEqual(subscription.take(), [.fallback])
        await clock.advance(50)
        XCTAssertTrue(subscription.take().isEmpty, "at most once every 60 s")
        await clock.advance(15)
        XCTAssertEqual(subscription.take(), [.fallback])
        subscription.cancel()
    }

    func testThePollingStopsTheMomentTheSocketComesBack() async {
        let socket = FakeLiveSocket()
        let script = ScriptedEndpoint([.fail(.connection), .fail(.connection), .fail(.connection), .fail(.connection), .socket(socket)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await clock.advance(16)
        XCTAssertEqual(script.attempts, 5)
        await socket.goLive()
        _ = subscription.take()

        await clock.advance(600)

        XCTAssertTrue(subscription.take().isEmpty, "no poll once the socket is live")
        XCTAssertEqual(connection.state, .live)
        subscription.cancel()
    }

    func testNothingIsPolledInTheBackground() async {
        let (connection, _) = make([.fail(.connection)])
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()
        await clock.advance(10)
        XCTAssertGreaterThanOrEqual(connection.consecutiveFailures, 3)

        connection.setForeground(false)
        _ = subscription.take()
        await clock.advance(600)

        XCTAssertTrue(subscription.take().isEmpty)
        XCTAssertEqual(clock.pendingCount, 0, "no timer of any kind is left running")
        subscription.cancel()
    }

    func testAServerWithNoSocketIsPolledFromTheStartAtMostOnceAMinute() async {
        let (connection, script) = make([.fail(.unsupported)])
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()

        XCTAssertEqual(script.attempts, 1, "it is not retried on a timer")
        XCTAssertEqual(connection.state, .unavailable)
        XCTAssertEqual(connection.failure, .unsupported)
        await clock.advance(61)
        XCTAssertEqual(subscription.take(), [.fallback])
        await clock.advance(600)
        XCTAssertEqual(script.attempts, 1)

        let another = connection.subscribe([.tasks])
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 2, "a screen that opens asks again")
        another.cancel()
        subscription.cancel()
    }

    func testAChannelTheServerRefusesIsPolledWhileTheOthersStayLive() async {
        let socket = FakeLiveSocket()
        let (connection, _) = make([.socket(socket)])
        connection.setForeground(true)
        let scans = connection.subscribe([.scans])
        let tasks = connection.subscribe([.tasks])
        await TestLiveClock.settle()
        await socket.goLive(available: ["tasks", "sessions"])
        _ = scans.take()
        _ = tasks.take()

        XCTAssertEqual(connection.state, .live)
        XCTAssertTrue(connection.isUnavailable(.scans))
        XCTAssertFalse(connection.isUnavailable(.tasks))
        XCTAssertEqual(connection.realtimeState(for: [.scans]), .unavailable)
        XCTAssertEqual(connection.realtimeState(for: [.tasks]), .live)

        await clock.advance(61)
        XCTAssertEqual(scans.take(), [.fallback])
        XCTAssertTrue(tasks.take().isEmpty, "the screen the socket serves is not polled")
        scans.cancel()
        tasks.cancel()
    }

    func testARefusedSubscribeIsTreatedLikeAMissingChannel() async {
        let socket = FakeLiveSocket()
        let (connection, _) = make([.socket(socket)])
        connection.setForeground(true)
        let scans = connection.subscribe([.scans])
        let tasks = connection.subscribe([.tasks])
        await TestLiveClock.settle()
        await socket.goLive(refuse: ["scans"])
        _ = scans.take()
        _ = tasks.take()

        XCTAssertTrue(connection.isUnavailable(.scans))
        await clock.advance(61)
        XCTAssertEqual(scans.take(), [.fallback])
        scans.cancel()
        tasks.cancel()
    }

    func testAScreenWithNoChannelIsPolledOnlyWhileTheSocketOthersNeedIsDown() async {
        let (connection, _) = make([.fail(.connection)])
        connection.setForeground(true)
        let sessions = connection.subscribe([.sessions])
        let loader = connection.subscribe([])
        await TestLiveClock.settle()
        await clock.advance(3.5)

        await clock.advance(62)

        XCTAssertEqual(loader.take(), [.fallback])
        sessions.cancel()
        loader.cancel()
    }

    func testALostSignInStopsTheConnectionAndTellsTheScreens() async {
        let (connection, script) = make([.fail(.signInRequired)])
        connection.setForeground(true)
        let subscription = connection.subscribe([.scans])
        await TestLiveClock.settle()

        XCTAssertEqual(connection.state, .signInRequired)
        XCTAssertEqual(subscription.take(), [.signInRequired])
        await clock.advance(600)
        XCTAssertEqual(script.attempts, 1, "no retry on a timer")

        connection.setForeground(false)
        connection.setForeground(true)
        await TestLiveClock.settle()
        XCTAssertEqual(script.attempts, 2, "back in the foreground it asks again")
        subscription.cancel()
    }

    // MARK: No polling while connected

    func testNoPollingLoopRunsWhileConnected() async {
        var timings = LiveTimings()
        timings.fallbackInterval = 77
        let (connection, script, socket, subscription) = await live(channels: [.scans, .tasks], timings: timings)
        _ = subscription.take()

        for _ in 0..<10 { await clock.advance(60) }

        XCTAssertEqual(script.attempts, 1, "one socket for ten minutes")
        XCTAssertTrue(subscription.take().isEmpty, "no signal without a frame: nothing ticks")
        XCTAssertFalse(clock.sleeps.contains(77), "the fallback loop never started")
        XCTAssertEqual(clock.pendingCount, 2, "only the socket's own ping and watchdog timers are running")
        XCTAssertEqual(connection.state, .live)
        XCTAssertFalse(socket.isClosed)
        subscription.cancel()
    }
}
