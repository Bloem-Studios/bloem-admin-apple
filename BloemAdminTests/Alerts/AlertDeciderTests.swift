import XCTest
@testable import BloemAdmin

/// Flap suppression: a server is reported down only after two failed checks in a row, and reported back
/// only if it was reported down.
final class AlertDeciderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let quarterHour: TimeInterval = 15 * 60

    private func step(
        _ result: HealthProbeResult, _ state: inout ServerAlertState, at offset: TimeInterval
    ) -> AlertAction {
        let outcome = AlertDecider.apply(result, to: state, at: start.addingTimeInterval(offset))
        state = outcome.state
        return outcome.action
    }

    func testOneFailureAlertsNothing() {
        var state = ServerAlertState()
        XCTAssertEqual(step(.down(.timedOut), &state, at: 0), .none)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertFalse(state.isReportedDown)
    }

    func testTwoFailuresInARowReportTheServerDownOnce() {
        var state = ServerAlertState()
        _ = step(.down(.timedOut), &state, at: 0)
        XCTAssertEqual(
            step(.down(.cannotConnect), &state, at: quarterHour),
            .serverDown(since: start, reason: .cannotConnect)
        )
        XCTAssertTrue(state.isReportedDown)
        // Further failures stay quiet.
        XCTAssertEqual(step(.down(.cannotConnect), &state, at: 2 * quarterHour), .none)
        XCTAssertEqual(step(.down(.cannotConnect), &state, at: 3 * quarterHour), .none)
    }

    func testAnAnswerBetweenTwoFailuresStartsTheCountAgain() {
        var state = ServerAlertState()
        for (index, result) in [
            HealthProbeResult.down(.timedOut), .up, .down(.timedOut), .up, .down(.serverError(503)), .up,
        ].enumerated() {
            XCTAssertEqual(step(result, &state, at: Double(index) * quarterHour), .none, "check \(index)")
        }
        XCTAssertFalse(state.isReportedDown)
        XCTAssertEqual(state.consecutiveFailures, 0)
    }

    func testAnAnswerAfterBeingReportedDownReportsItBackOnce() {
        var state = ServerAlertState()
        _ = step(.down(.timedOut), &state, at: 0)
        _ = step(.down(.timedOut), &state, at: quarterHour)
        XCTAssertEqual(step(.up, &state, at: 2 * quarterHour), .serverBack)
        XCTAssertEqual(step(.up, &state, at: 3 * quarterHour), .none)
        XCTAssertEqual(state, ServerAlertState(lastCheckAt: start.addingTimeInterval(3 * quarterHour)))
        // Going down again needs two failures again.
        XCTAssertEqual(step(.down(.timedOut), &state, at: 4 * quarterHour), .none)
        XCTAssertEqual(
            step(.down(.timedOut), &state, at: 5 * quarterHour),
            .serverDown(since: start.addingTimeInterval(4 * quarterHour), reason: .timedOut)
        )
    }

    func testAnAnswerIsNeverReportedBackWhenNothingWasReportedDown() {
        var state = ServerAlertState()
        XCTAssertEqual(step(.up, &state, at: 0), .none)
        _ = step(.down(.timedOut), &state, at: quarterHour)
        XCTAssertEqual(step(.up, &state, at: 2 * quarterHour), .none)
    }

    func testAPhoneWithNoNetworkChangesNothing() {
        var state = ServerAlertState()
        _ = step(.down(.timedOut), &state, at: 0)
        let before = state
        XCTAssertEqual(step(.inconclusive, &state, at: quarterHour), .none)
        XCTAssertEqual(state, before)
        // The next real failure is the second one.
        XCTAssertEqual(
            step(.down(.timedOut), &state, at: 2 * quarterHour),
            .serverDown(since: start, reason: .timedOut)
        )
    }

    func testFailuresCloserThanAMinuteCountOnce() {
        // Face ID and the notification shade make the app inactive and active again within seconds.
        var state = ServerAlertState()
        XCTAssertEqual(step(.down(.timedOut), &state, at: 0), .none)
        XCTAssertEqual(step(.down(.timedOut), &state, at: 5), .none)
        XCTAssertEqual(step(.down(.timedOut), &state, at: 20), .none)
        XCTAssertEqual(state.consecutiveFailures, 1)
        XCTAssertEqual(
            step(.down(.timedOut), &state, at: 20 * 60),
            .serverDown(since: start, reason: .timedOut)
        )
    }

    func testAnAnswerCountsAtOnceEvenRightAfterAFailure() {
        var state = ServerAlertState()
        _ = step(.down(.timedOut), &state, at: 0)
        _ = step(.down(.timedOut), &state, at: quarterHour)
        XCTAssertEqual(step(.up, &state, at: quarterHour + 10), .serverBack)
    }
}
