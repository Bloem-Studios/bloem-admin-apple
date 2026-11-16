import XCTest
@testable import BloemAdmin

/// The Logs filters and the query they send to `GET /api/v2/admin/logs/app`
/// (`level`, `q`, `component`, `request_id`, `playback_session_id`).
final class LogFilterTests: XCTestCase {
    func testEmptyFilterSendsNothing() {
        XCTAssertEqual(LogFilter().query, [:])
        XCTAssertTrue(LogFilter().isEmpty)
    }

    func testEveryFilterIsSentTrimmed() {
        let filter = LogFilter(level: " warn ", q: " disk ", component: " ffmpeg ", requestID: " req-1 ", playbackSessionID: " ps_9 ")
        XCTAssertEqual(filter.query, ["level": "warn", "q": "disk", "component": "ffmpeg", "request_id": "req-1", "playback_session_id": "ps_9"])
        XCTAssertFalse(filter.isEmpty)
    }

    func testFiltersCompareEqualAfterTrimming() {
        XCTAssertEqual(LogFilter(component: " ffmpeg"), LogFilter(component: "ffmpeg"))
        XCTAssertNotEqual(LogFilter(component: "ffmpeg"), LogFilter(component: "auth"))
    }

    func testWarnAndErrorIsOneCommaSeparatedLevel() {
        XCTAssertEqual(LogLevelFilter.warnAndError.queryValue, "warn,error")
        XCTAssertEqual(LogLevelFilter.all.queryValue, "")
        XCTAssertEqual(LogLevelFilter.error.queryValue, "error")
        XCTAssertEqual(LogLevelFilter(queryValue: "warn,error"), .warnAndError)
        XCTAssertEqual(LogLevelFilter(queryValue: ""), .all)
    }

    func testFocusOnAPlaybackSessionOptionallyNarrowsToFFmpeg() {
        let logs = LogsFocus(playbackSessionID: "ps_9", ffmpegOnly: false)
        XCTAssertEqual(LogFilter(focus: logs), LogFilter(playbackSessionID: "ps_9"))
        let ffmpeg = LogsFocus(playbackSessionID: "ps_9", ffmpegOnly: true)
        XCTAssertEqual(LogFilter(focus: ffmpeg), LogFilter(component: "ffmpeg", playbackSessionID: "ps_9"))
    }
}
