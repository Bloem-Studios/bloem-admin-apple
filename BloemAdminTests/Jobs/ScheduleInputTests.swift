import XCTest
import UIKit
@testable import BloemAdmin

@MainActor
final class ScheduleInputTests: XCTestCase {
    func testParseRejectsEmptyInput() {
        XCTAssertEqual(ScheduleIntervalInput.parse(""), .failure(.empty))
    }

    func testParseRejectsNonnumericInput() {
        XCTAssertEqual(ScheduleIntervalInput.parse("every hour"), .failure(.notANumber))
    }

    func testParseRejectsZero() {
        XCTAssertEqual(ScheduleIntervalInput.parse("0"), .failure(.notPositive))
    }

    func testParseRejectsNegativeInput() {
        XCTAssertEqual(ScheduleIntervalInput.parse("-15"), .failure(.notPositive))
    }

    func testParseAcceptsBoundedPositiveMinutes() {
        XCTAssertEqual(ScheduleIntervalInput.parse("15"), .success(15))
    }

    func testParseRejectsOverflowingMinutes() {
        XCTAssertEqual(ScheduleIntervalInput.parse(String(Int.max)), .failure(.outOfRange))
    }

    func testInvalidEnabledIntervalCannotProduceATriggerRemovalPayload() {
        let existing = [TaskTrigger.interval(minutes: 30), .startup]
        let editor = TaskTrigger.scheduleEditorState(from: existing)

        let payload = editor.makePayload(
            startupEnabled: true,
            intervalEnabled: true,
            intervalInput: "not a number",
            triggers: existing
        )

        XCTAssertNil(payload)
    }

    func testMissingIntervalMillisecondsLoadsAsEnabledAndBlocksStartupOnlySave() {
        let existing = [TaskTrigger(type: "interval"), .startup]

        let editor = TaskTrigger.scheduleEditorState(from: existing)

        XCTAssertTrue(editor.intervalEnabled)
        XCTAssertEqual(editor.blockingIssue, .missingIntervalMilliseconds)
        XCTAssertNil(editor.makePayload(
            startupEnabled: false,
            intervalEnabled: true,
            intervalInput: "",
            triggers: existing
        ))
    }

    func testInvalidIntervalLoadsAsEnabledAndBlocksStartupOnlySave() {
        let existing = [TaskTrigger(type: "interval", intervalMs: 90_000), .startup]

        let editor = TaskTrigger.scheduleEditorState(from: existing)

        XCTAssertTrue(editor.intervalEnabled)
        XCTAssertEqual(editor.blockingIssue, .invalidInterval)
        XCTAssertNil(editor.makePayload(
            startupEnabled: false,
            intervalEnabled: true,
            intervalInput: "2",
            triggers: existing
        ))
    }

    func testRepeatedIntervalsLoadAsEnabledAndBlockAmbiguousSave() {
        let existing = [TaskTrigger.interval(minutes: 15), TaskTrigger.interval(minutes: 30), .startup]

        let editor = TaskTrigger.scheduleEditorState(from: existing)

        XCTAssertTrue(editor.intervalEnabled)
        XCTAssertEqual(editor.blockingIssue, .repeatedIntervals)
        XCTAssertNil(editor.makePayload(
            startupEnabled: false,
            intervalEnabled: true,
            intervalInput: "15",
            triggers: existing
        ))
    }

    func testExplicitOnToOffTransitionCanRemoveIncompatibleIntervals() {
        let existing = [TaskTrigger(type: "interval"), .startup]
        let editor = TaskTrigger.scheduleEditorState(from: existing)

        let payload = editor.makePayload(
            startupEnabled: true,
            intervalEnabled: false,
            intervalInput: "",
            triggers: existing
        )

        XCTAssertEqual(payload?.map(\.type), ["startup"])
    }

    func testStartupOnlyEditPreservesValidInterval() {
        let existing = [.startup, TaskTrigger.interval(minutes: 30)]
        let editor = TaskTrigger.scheduleEditorState(from: existing)

        let payload = editor.makePayload(
            startupEnabled: false,
            intervalEnabled: true,
            intervalInput: editor.intervalMinutesText,
            triggers: existing
        )

        XCTAssertEqual(payload, [TaskTrigger.interval(minutes: 30)])
    }

    func testMutationGateRejectsReentryUntilCurrentMutationEnds() {
        var gate = PrivilegedMutationGate()

        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.isActive)
        XCTAssertFalse(gate.begin())

        gate.end()

        XCTAssertFalse(gate.isActive)
        XCTAssertTrue(gate.begin())
    }

    func testMutationGateSynchronouslyLaunchesOnlyTheFirstRepeatedSubmission() {
        var gate = PrivilegedMutationGate()
        var launchedSubmissionIDs: [Int] = []

        XCTAssertTrue(gate.submit { launchedSubmissionIDs.append(1) })
        XCTAssertFalse(gate.submit { launchedSubmissionIDs.append(2) })

        XCTAssertEqual(launchedSubmissionIDs, [1])
        XCTAssertTrue(gate.isActive)
    }

    func testClaimURLWriterUsesLocalOnlyPasteboardWithTenMinuteOrShorterExpiry() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        var capturedItems: [[String: Any]]?
        var capturedOptions: [UIPasteboard.OptionsKey: Any]?
        let writer = LocalOnlyExpiringPasteboardWriter(
            now: { now },
            setItems: { items, options in
                capturedItems = items
                capturedOptions = options
            }
        )

        writer.copy("https://example.test/invitations/claim/secret")

        XCTAssertEqual(capturedItems?.count, 1)
        XCTAssertEqual(capturedItems?.first?[UIPasteboard.typeAutomatic] as? String, "https://example.test/invitations/claim/secret")
        XCTAssertEqual(capturedOptions?[.localOnly] as? Bool, true)
        let expiry = try? XCTUnwrap(capturedOptions?[.expirationDate] as? Date)
        XCTAssertNotNil(expiry)
        if let expiry {
            XCTAssertGreaterThan(expiry, now)
            XCTAssertLessThanOrEqual(expiry.timeIntervalSince(now), 10 * 60)
        }
    }
}
