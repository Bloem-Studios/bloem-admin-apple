import XCTest
@testable import BloemAdmin

final class RestartStatusTests: XCTestCase {
    private func status(
        required: Bool = true, requested: Bool = false, reason: String? = nil, reasons: [String] = [],
        startedAt: String = "2026-11-14T08:00:00.000Z"
    ) -> ServerStatus {
        ServerStatus(
            startedAt: startedAt, restartRequired: required, restartRequested: requested,
            restartRequiredReason: reason, restartRequiredReasons: reasons
        )
    }

    func testASettingReasonBecomesThatSettingsLabel() {
        let labels = RestartStatus.reasonLabels(for: status(reasons: ["setting:playback.hw_accel", "setting:server.public_url"]))
        XCTAssertEqual(labels, ["Hardware acceleration", "Public URL"])
    }

    func testAnUnnamedSettingKeyIsMadeReadable() {
        XCTAssertEqual(RestartStatus.label(forReason: "setting:scanner.file_removal_grace"), "Scanner file removal grace")
    }

    func testAnotherReasonSlugIsMadeReadable() {
        XCTAssertEqual(RestartStatus.label(forReason: "jellyfin_compat"), "Jellyfin compat")
    }

    func testRepeatedReasonsAreListedOnceInOrder() {
        let labels = RestartStatus.reasonLabels(for: status(reasons: ["setting:server.public_url", "setting:playback.hw_accel", "setting:server.public_url"]))
        XCTAssertEqual(labels, ["Public URL", "Hardware acceleration"])
    }

    func testServerThatSendsOnlyTheSingleReasonIsReadTheSame() {
        XCTAssertEqual(RestartStatus.reasonLabels(for: status(reason: "setting:server.log_level")), ["Log level"])
        XCTAssertEqual(RestartStatus.reasonLabels(for: status(reason: "")), [])
    }

    func testTheListOfReasonsWinsOverTheSingleOne() {
        XCTAssertEqual(
            RestartStatus.reasonLabels(for: status(reason: "setting:server.log_level", reasons: ["setting:server.public_url"])),
            ["Public URL"]
        )
    }

    func testSummaryNamesWhatWaits() {
        XCTAssertEqual(RestartStatus.summary(for: status(required: false)), "Not needed")
        XCTAssertEqual(RestartStatus.summary(for: status(reasons: [])), "Needed")
        XCTAssertEqual(RestartStatus.summary(for: status(reasons: ["setting:server.public_url"])), "Needed for Public URL")
        XCTAssertEqual(RestartStatus.summary(for: status(requested: true)), "Restart in progress")
    }

    func testUptimeIsReadFromTheStartTime() {
        let started = ISO8601DateFormatter().date(from: "2026-11-11T08:00:00Z")!
        let now = started.addingTimeInterval(3 * 86_400 + 4 * 3600 + 30)
        XCTAssertEqual(RestartStatus.uptime(for: status(startedAt: "2026-11-11T08:00:00.000Z"), now: now), "3d 4h")
        XCTAssertEqual(RestartStatus.uptime(for: status(startedAt: "not a date"), now: now), "—")
    }

    func testTheConfirmationSaysActiveStreamsWillBeInterrupted() {
        XCTAssertTrue(RestartStatus.confirmationMessage.contains("Active streams will be interrupted"))
        XCTAssertTrue(RestartStatus.confirmationMessage.contains("service manager"))
        XCTAssertFalse(RestartStatus.confirmationMessage.hasSuffix("."))
    }

    func testReceiptNotices() {
        XCTAssertEqual(RestartStatus.receiptNotice(RestartReceipt(status: "restart_requested")), "Restart requested")
        XCTAssertEqual(RestartStatus.receiptNotice(RestartReceipt(status: "restart_requested", notifiedSessions: 2)), "Restart requested. 2 streams were told")
        XCTAssertEqual(RestartStatus.receiptNotice(RestartReceipt(status: "already_requested")), "A restart is already in progress")
    }

    func testStatusDecodesTheServersReasonsAndRestartTime() throws {
        let json = #"{"started_at":"2026-11-14T08:00:00.000Z","restart_required":true,"restart_required_at":"2026-11-14T09:30:00.000Z","restart_required_reason":"setting:server.public_url","restart_required_reasons":["setting:server.public_url","setting:playback.hw_accel"],"restart_mark_count":2,"restart_requested":false,"health":{}}"#
        let decoded = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.restartRequiredReasons, ["setting:server.public_url", "setting:playback.hw_accel"])
        XCTAssertNotNil(decoded.restartRequiredDate)
        XCTAssertNotNil(decoded.startedDate)
    }

    func testStatusWithoutReasonsStillDecodes() throws {
        let json = #"{"started_at":"2026-11-14T08:00:00Z","restart_required":false,"restart_requested":false}"#
        let decoded = try JSONDecoder().decode(ServerStatus.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.restartRequiredReasons, [])
        XCTAssertNil(decoded.restartRequiredAt)
        XCTAssertNotNil(decoded.startedDate)
    }

    func testHumanizedReasonFormatting() {
        XCTAssertEqual(status(reason: "jellyfin_compat").humanizedRestartRequiredReason, "Jellyfin compat")
        XCTAssertEqual(status(reason: "config").humanizedRestartRequiredReason, "Config")
        XCTAssertNil(status(reason: nil).humanizedRestartRequiredReason)
        XCTAssertNil(status(reason: "").humanizedRestartRequiredReason)
    }
}
