import XCTest
@testable import BloemAdmin

/// The before-and-after count of timed requests while the dashboard sits open on its main screen
/// (`bloem-staff-live.md`, "Done means"). "Before" replays the loop this change removed, `while: load;
/// sleep 30 s`, with the same view model against the same fixtures, with Now playing already on the socket,
/// which is its best case. "After" runs the screen's real driver over a live connection for five minutes.
@MainActor
final class DashboardRequestRateTests: XCTestCase {
    private let clock = TestLiveClock()
    nonisolated private let http: MockHTTPHarness = {
        let harness = MockHTTPHarness()
        harness.state.pathOverrides = DashboardViewModelTests.healthyRoutes()
        return harness
    }()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private var requestCount: Int { http.state.requestLog.count }

    private final class Loads {
        var started = 0
        var finished = 0
        /// The read on open, which the screen runs before it listens for anything.
        var openFinished = false
    }

    /// Real time a wait may take before the test calls it failed. A wait that is met returns at once, so this
    /// only matters on a Mac that is badly overloaded: it never makes the test slower.
    private let patience: TimeInterval = 60

    func testTheDashboardMakesNoTimedRequestsWhileConnectedAndAtMostOneLoadAMinuteWhenNot() async {
        let minutes = 5.0

        // Before: a load every 30 s for five minutes (the slow tier comes due at five).
        let old = DashboardViewModel()
        var virtualNow = Date(timeIntervalSince1970: 1_800_000_000)
        old.clock = { virtualNow }
        old.beginLiveSessions()
        await old.load(client: http.client)
        let afterOpen = requestCount
        for _ in 0..<10 {
            virtualNow += 30
            await old.load(client: http.client)
        }
        let before = Double(requestCount - afterOpen) / minutes

        // After, socket live: the screen reads once on open, then only what the socket says.
        http.state.requestLog = []
        let model = DashboardViewModel()
        let socket = FakeLiveSocket()
        let connection = LiveConnection(endpoint: ScriptedEndpoint([.socket(socket)]).endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let nowPlaying = connection.subscribe([.sessions])
        let loads = Loads()
        let client = http.client
        let screen = Task { @MainActor in
            await LiveRefreshDriver.run(
                connection: connection, channels: [], clock: clock,
                initial: {
                    model.beginLiveSessions()
                    await model.load(client: client)
                    loads.openFinished = true
                },
                onSignals: { signals in
                    guard signals.contains(.fallback) else { return }
                    loads.started += 1
                    await model.load(client: client)
                    loads.finished += 1
                }
            )
        }
        await TestLiveClock.settle()
        await socket.goLive()
        // The read on open is done when the screen says so, not when its first request has arrived.
        let openedInTime = await waitUntil(patience) { loads.openFinished }
        XCTAssertTrue(openedInTime, "the dashboard finished its read on open")
        let opened = requestCount
        for _ in 0..<Int(minutes) { await clock.advance(60) }
        let afterConnected = Double(requestCount - opened) / minutes
        XCTAssertEqual(loads.started, 0, "connected: not one timed read in five minutes")
        XCTAssertEqual(requestCount, opened, "connected: not one timed request in five minutes")
        screen.cancel()
        await screen.value
        nowPlaying.cancel()

        // After, socket down for good: the visible dashboard is loaded at most once a minute.
        http.state.requestLog = []
        let fallbackModel = DashboardViewModel()
        let down = LiveConnection(endpoint: ScriptedEndpoint([.fail(.connection)]).endpoint, clock: clock, jitter: { 1 })
        down.setForeground(true)
        let downSessions = down.subscribe([.sessions])
        let downLoads = Loads()
        let downScreen = Task { @MainActor in
            await LiveRefreshDriver.run(
                connection: down, channels: [], clock: clock,
                initial: {
                    fallbackModel.beginLiveSessions()
                    await fallbackModel.load(client: client)
                    downLoads.openFinished = true
                },
                onSignals: { signals in
                    guard signals.contains(.fallback) else { return }
                    downLoads.started += 1
                    await fallbackModel.load(client: client)
                    downLoads.finished += 1
                }
            )
        }
        await TestLiveClock.settle()
        let downOpenedInTime = await waitUntil(patience) { downLoads.openFinished }
        XCTAssertTrue(downOpenedInTime, "the dashboard finished its read on open")
        let downOpened = requestCount
        // The schedule is fixed by the virtual clock: three failed connects at 0 s, 1 s and 3 s, then one fallback
        // tick a minute after the third, and one a minute after each tick: at 63, 123, 183 and 243 s. The minute
        // marks fall at 60, 120, 180, 240 and 300 s, so the loads done after each are 0, 1, 2, 3 and 4. The next
        // minute does not start until that tick's read is finished, so a late read cannot swallow the next tick.
        let loadsDoneAfterEachMinute = [0, 1, 2, 3, 4]
        for (minute, due) in loadsDoneAfterEachMinute.enumerated() {
            await clock.advance(60)
            let done = await waitUntil(patience) { downLoads.finished == due && downLoads.started == due }
            XCTAssertTrue(done, "socket down: \(due) fallback reads done after minute \(minute + 1), saw started \(downLoads.started) finished \(downLoads.finished)")
        }
        let afterDown = Double(requestCount - downOpened) / minutes
        XCTAssertLessThanOrEqual(downLoads.started, Int(minutes), "at most one load a minute")
        downScreen.cancel()
        await downScreen.value
        downSessions.cancel()

        let report = String(
            format: "DASHBOARD timed requests per minute, after the open: before %.1f, after (socket live) %.1f, after (socket down) %.1f",
            before, afterConnected, afterDown
        )
        print(report)
        add(XCTAttachment(string: report))
        // Seven fast-tier reads per load, twice a minute, plus the five slow-tier reads once in five minutes.
        XCTAssertEqual(before, 15.0, accuracy: 0.001, "the loop that was removed: " + report)
        XCTAssertEqual(afterConnected, 0, "socket live: " + report)
        // Four fallback loads fit in five minutes (the first comes a minute after the third failed connect).
        XCTAssertEqual(afterDown, 5.6, accuracy: 0.001, "socket down: " + report)
    }
}
