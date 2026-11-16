import XCTest
@testable import BloemAdmin

final class PlaybackCommandSequencerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int64]
        init(_ values: [Int64]) { self.values = values }
        func next() -> Int64 {
            lock.lock(); defer { lock.unlock() }
            return values.isEmpty ? 0 : values.removeFirst()
        }
    }

    private func makeSequencer(_ values: [Int64]) -> PlaybackCommandSequencer {
        let clock = Clock(values)
        return PlaybackCommandSequencer(clock: { clock.next() })
    }

    func testSequenceFollowsClockAndRisesByAtLeastOnePerSession() {
        let sequencer = makeSequencer([1000, 1000, 999])
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, 1000)
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, 1001)
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, 1002)
    }

    func testSessionsAreSequencedIndependently() {
        let sequencer = makeSequencer([1000, 1000, 1000])
        XCTAssertEqual(sequencer.next(sessionId: "a").sequence, 1000)
        XCTAssertEqual(sequencer.next(sessionId: "b").sequence, 1000)
        XCTAssertEqual(sequencer.next(sessionId: "a").sequence, 1001)
    }

    func testCommandIDIsACanonicalUUIDAndDiffersEachTime() {
        let sequencer = makeSequencer([1, 2])
        let first = sequencer.next(sessionId: "s1").commandID
        let second = sequencer.next(sessionId: "s1").commandID
        XCTAssertEqual(first.count, 36)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertNotEqual(first, second)
    }

    func testObservedLatestSequenceRaisesTheNextOne() {
        let sequencer = makeSequencer([1000, 1000])
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, 1000)
        sequencer.observe(sessionId: "s1", latest: 5000)
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, 5001)
    }

    func testObservingAnOlderSequenceNeverLowersIt() {
        let sequencer = makeSequencer([1000, 10])
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, 1000)
        sequencer.observe(sessionId: "s1", latest: 3)
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, 1001)
    }

    func testSequenceNeverExceedsTwoToThe53MinusOne() {
        let limit: Int64 = 9_007_199_254_740_991
        let sequencer = makeSequencer([Int64.max, 5])
        XCTAssertEqual(sequencer.next(sessionId: "s1").sequence, limit)
        sequencer.observe(sessionId: "s2", latest: Int64.max)
        XCTAssertEqual(sequencer.next(sessionId: "s2").sequence, limit)
    }
}
