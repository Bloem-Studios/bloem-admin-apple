import XCTest
@testable import BloemAdmin

/// A log entry's detail: the fields the route returns (`AdminOperationalLog`), the request facts the
/// server keeps in `attrs` (method, status, duration_ms, path), and the text Copy and Share send.
final class OperationalLogDetailTests: XCTestCase {
    private func entry(_ extra: String = "") throws -> OperationalLogEntry {
        let json = #"{"id":"88","timestamp":"2026-11-14T21:42:10.250Z","level":"error","component":"ffmpeg","message":"muxer failed","request_id":"req-77","user_id":"42","session_id":"sess-1","playback_session_id":"ps_7f3a91c2d4","client_ip":"192.0.2.10","node_id":"node-b","attrs":{"method":"GET","status":502,"duration_ms":1840,"path":"/api/v2/stream","retry":true,"nested":{"a":1}}\#(extra)}"#
        return try JSONDecoder.iso8601.decode(OperationalLogEntry.self, from: Data(json.utf8))
    }

    func testDecodesAttributes() throws {
        let log = try entry()
        XCTAssertEqual(log.attrs?["method"], .string("GET"))
        XCTAssertEqual(log.attrs?["status"], .integer(502))
    }

    func testRequestFactsComeFromAttributes() throws {
        let log = try entry()
        XCTAssertEqual(log.method, "GET")
        XCTAssertEqual(log.statusText, "502")
        XCTAssertEqual(log.durationText, "1840 ms")
        XCTAssertEqual(log.path, "/api/v2/stream")
    }

    func testMissingAttributesAreNil() throws {
        let json = #"{"id":"1","timestamp":"2026-11-14T21:42:10Z","level":"info","component":"app","message":"hi"}"#
        let log = try JSONDecoder.iso8601.decode(OperationalLogEntry.self, from: Data(json.utf8))
        XCTAssertNil(log.attrs)
        XCTAssertNil(log.method)
        XCTAssertNil(log.statusText)
        XCTAssertNil(log.durationText)
        XCTAssertNil(log.path)
    }

    func testIdentifiersFallBackToAttributes() throws {
        let json = #"{"id":"1","timestamp":"2026-11-14T21:42:10Z","level":"info","component":"app","message":"hi","attrs":{"client_ip":"198.51.100.4","session_id":"s-9","playback_session_id":"ps_attr"}}"#
        let log = try JSONDecoder.iso8601.decode(OperationalLogEntry.self, from: Data(json.utf8))
        XCTAssertEqual(log.effectiveClientIP, "198.51.100.4")
        XCTAssertEqual(log.effectiveSessionID, "s-9")
        XCTAssertEqual(log.effectivePlaybackSessionID, "ps_attr")
    }

    func testAttributesTextIsSortedPrettyJSON() throws {
        let text = try XCTUnwrap(try entry().attributesText())
        XCTAssertTrue(text.contains("\"duration_ms\" : 1840"), text)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "duration_ms")).lowerBound, try XCTUnwrap(text.range(of: "status")).lowerBound)
    }

    func testShortIDKeepsTheStartAndEnd() {
        XCTAssertEqual(LogIdentifier.short("ps_7f3a91c2d4e5f6"), "ps_7f3a9…e5f6")
        XCTAssertEqual(LogIdentifier.short("short"), "short")
    }

    func testCopyTextListsTheFieldsAndHidesTheClientIPWhenNotAllowed() throws {
        let log = try entry()
        let shown = log.detailText(showsClientIP: true)
        XCTAssertTrue(shown.contains("Request ID: req-77"), shown)
        XCTAssertTrue(shown.contains("Node: node-b"), shown)
        XCTAssertTrue(shown.contains("Playback session: ps_7f3a91c2d4"), shown)
        XCTAssertTrue(shown.contains("muxer failed"), shown)
        XCTAssertTrue(shown.contains("Client IP: 192.0.2.10"), shown)
        let hidden = log.detailText(showsClientIP: false)
        XCTAssertFalse(hidden.contains("192.0.2.10"))
    }

    func testAttributesCarryingAnIPAreAlsoHiddenWhenNotAllowed() throws {
        let json = #"{"id":"1","timestamp":"2026-11-14T21:42:10Z","level":"info","component":"app","message":"hi","attrs":{"client_ip":"198.51.100.4","remote_addr":"198.51.100.4:5522"}}"#
        let log = try JSONDecoder.iso8601.decode(OperationalLogEntry.self, from: Data(json.utf8))
        XCTAssertFalse(log.detailText(showsClientIP: false).contains("198.51.100.4"))
        XCTAssertNil(log.attributesText(showsClientIP: false)?.range(of: "198.51.100.4"))
    }
}
