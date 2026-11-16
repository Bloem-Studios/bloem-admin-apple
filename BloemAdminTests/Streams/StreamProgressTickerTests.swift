import XCTest
@testable import BloemAdmin

/// A clock the test drives: every sleep moves time on by the requested amount and counts as a tick,
/// and the sleep after `maxTicks` throws, which ends the ticker's loop deterministically.
@MainActor
final class ScriptedTickClock: StreamTickClock {
    private(set) var current: TimeInterval
    private(set) var sleeps = 0
    private let maxTicks: Int

    init(start: TimeInterval = 1_000, maxTicks: Int) {
        current = start
        self.maxTicks = maxTicks
    }

    func now() -> TimeInterval { current }

    func sleep(for seconds: TimeInterval) async throws {
        guard sleeps < maxTicks else { throw CancellationError() }
        sleeps += 1
        current += seconds
    }

    func advance(by seconds: TimeInterval) { current += seconds }
}

@MainActor
final class StreamProgressTickerTests: XCTestCase {
    func testAPlayingStreamMovesForwardOncePerSecond() async {
        let clock = ScriptedTickClock(maxTicks: 3)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 10, duration: 100, paused: false)
        XCTAssertEqual(ticker.position, 10)

        await ticker.run(ticking: true)

        XCTAssertEqual(clock.sleeps, 3)
        XCTAssertEqual(ticker.position, 13, accuracy: 0.0001)
        XCTAssertEqual(ticker.fraction ?? 0, 0.13, accuracy: 0.0001)
    }

    func testANewReportReplacesTheProjectionInsteadOfAddingToIt() async {
        let clock = ScriptedTickClock(maxTicks: 4)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 10, duration: 100, paused: false)
        await ticker.run(ticking: true)
        XCTAssertEqual(ticker.position, 14, accuracy: 0.0001)

        ticker.report(position: 20, duration: 100, paused: false)
        XCTAssertEqual(ticker.position, 20, accuracy: 0.0001)
    }

    func testAPausedStreamHoldsTheReportedPositionHoweverLongTheClockRuns() async {
        let clock = ScriptedTickClock(maxTicks: 5)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 20, duration: 100, paused: true)
        clock.advance(by: 60)
        await ticker.run(ticking: StreamProgressTicker.shouldTick(paused: true, reduceMotion: false, foreground: true))
        XCTAssertEqual(ticker.position, 20)
        XCTAssertEqual(clock.sleeps, 0)
    }

    func testNothingMovesBetweenReportsUnderReduceMotion() async {
        let clock = ScriptedTickClock(maxTicks: 5)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 10, duration: 100, paused: false)
        await ticker.run(ticking: StreamProgressTicker.shouldTick(paused: false, reduceMotion: true, foreground: true))
        XCTAssertEqual(clock.sleeps, 0)
        XCTAssertEqual(ticker.position, 10)
    }

    func testItTicksOnlyWhilePlayingInFrontWithMotionAllowed() {
        XCTAssertTrue(StreamProgressTicker.shouldTick(paused: false, reduceMotion: false, foreground: true))
        XCTAssertFalse(StreamProgressTicker.shouldTick(paused: true, reduceMotion: false, foreground: true))
        XCTAssertFalse(StreamProgressTicker.shouldTick(paused: false, reduceMotion: true, foreground: true))
        XCTAssertFalse(StreamProgressTicker.shouldTick(paused: false, reduceMotion: false, foreground: false))
    }

    func testAMovingStreamStopsAtTheEndOfTheFile() async {
        let clock = ScriptedTickClock(maxTicks: 120)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 98, duration: 100, paused: false)
        await ticker.run(ticking: true)
        XCTAssertEqual(ticker.position, 100)
        XCTAssertEqual(ticker.fraction, 1)
        XCTAssertEqual(StreamFormat.remainingSeconds(position: ticker.position, duration: 100), 0)
    }

    func testWithoutALengthItMovesAndHasNoFraction() async {
        let clock = ScriptedTickClock(maxTicks: 2)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 61, duration: nil, paused: false)
        await ticker.run(ticking: true)
        XCTAssertEqual(ticker.position, 63, accuracy: 0.0001)
        XCTAssertNil(ticker.fraction)
    }

    func testTimeSpentInTheBackgroundCountsWhenTheTickerResumes() async {
        // The stream kept playing while the app was away; resuming must not rewind to the report.
        let clock = ScriptedTickClock(maxTicks: 1)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 10, duration: 1_000, paused: false)
        await ticker.run(ticking: false)
        clock.advance(by: 30)
        await ticker.run(ticking: true)
        XCTAssertEqual(ticker.position, 41, accuracy: 0.0001)
    }

    func testCancellingStopsTheLoop() async {
        let clock = ScriptedTickClock(maxTicks: .max)
        let ticker = StreamProgressTicker(clock: clock)
        ticker.report(position: 0, duration: nil, paused: false)
        let task = Task { await ticker.run(ticking: true) }
        task.cancel()
        await task.value
        XCTAssertLessThan(clock.sleeps, 5)
    }
}
