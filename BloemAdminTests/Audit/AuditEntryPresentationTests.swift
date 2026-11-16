import XCTest
@testable import BloemAdmin

/// What an audit row leads with: the action and its before and after lines (the web's AuditLogRow),
/// then METHOD and path. `changes` carry JSON-encoded values.
final class AuditEntryPresentationTests: XCTestCase {
    private func entry(_ extra: String = "") throws -> AuditLogEntry {
        let json = #"{"id":"9","timestamp":"2026-11-14T21:42:10.250Z","client_ip":"192.0.2.10","method":"PUT","path":"/api/v2/admin/users/42","path_pattern":"/api/v2/admin/users/{id}","status_code":204,"duration_ms":38,"user_id":"7","session_id":"sess-1","playback_session_id":"ps_1","request_id":"req-5","node_id":"node-a","user_agent":"Bloem Admin/1.0"\#(extra)}"#
        return try JSONDecoder.iso8601.decode(AuditLogEntry.self, from: Data(json.utf8))
    }

    func testDecodesActionTargetAndChanges() throws {
        let row = try entry(#","action":"user.update","target_type":"user","target_id":"42","changes":[{"field":"role","before":"\"user\"","after":"\"admin\""},{"field":"max_streams","after":"3"}]"#)
        XCTAssertEqual(row.action, "user.update")
        XCTAssertEqual(row.targetType, "user")
        XCTAssertEqual(row.targetID, "42")
        XCTAssertEqual(row.changes.count, 2)
        XCTAssertEqual(row.changes[0].field, "role")
        XCTAssertNil(row.changes[1].before)
    }

    func testNoChangesDecodesAsEmpty() throws {
        XCTAssertTrue(try entry().changes.isEmpty)
    }

    func testHeadlineIsTheActionOrHTTPRequest() throws {
        XCTAssertEqual(try entry(#","action":"user.update""#).headline, "user.update")
        XCTAssertEqual(try entry().headline, "HTTP request")
    }

    func testRequestLineIsMethodAndPath() throws {
        XCTAssertEqual(try entry().requestLine, "PUT /api/v2/admin/users/42")
    }

    func testChangeLineShowsBeforeAndAfterWithoutJSONQuotes() throws {
        let row = try entry(#","target_type":"user","changes":[{"field":"max_streams","before":"2","after":"3"},{"field":"role","before":"\"user\"","after":"\"admin\""}]"#)
        XCTAssertEqual(row.changes.map { $0.line(targetType: row.targetType) }, ["max streams: 2 → 3", "role: user → admin"])
    }

    func testAbsentAndNullValuesAreNamed() throws {
        XCTAssertEqual(AuditChange(field: "note", before: nil, after: "\"hi\"").line(targetType: "user"), "note: absent → hi")
        XCTAssertEqual(AuditChange(field: "max_streams", before: "3", after: "null").line(targetType: "user"), "max streams: 3 → inherit")
        XCTAssertEqual(AuditChange(field: "access_group_id", before: "5", after: "null").line(targetType: "user"), "access group id: 5 → none")
        XCTAssertEqual(AuditChange(field: "library_ids", before: "[1,2]", after: "null").line(targetType: "access_group"), "library ids: 1, 2 → all libraries")
        XCTAssertEqual(AuditChange(field: "scopes", before: "[]", after: "[\"read\"]").line(targetType: "api_key"), "scopes: full access → read")
        XCTAssertEqual(AuditChange(field: "tags", before: "[]", after: "[\"a\",\"b\"]").line(targetType: "user"), "tags: none → a, b")
    }

    func testNeitherSideRecordedSaysChanged() {
        XCTAssertEqual(AuditChange(field: "password", before: nil, after: nil).line(targetType: "user"), "password: changed")
    }

    func testProfilePINIsShownAsSetOrCleared() {
        XCTAssertEqual(AuditChange(field: "pin", before: "false", after: "true").line(targetType: "profile"), "pin: not set → set")
        XCTAssertEqual(AuditChange(field: "pin", before: nil, after: "true").line(targetType: "profile"), "pin: set")
        XCTAssertEqual(AuditChange(field: "pin", before: nil, after: "false").line(targetType: "profile"), "pin: cleared")
        XCTAssertEqual(AuditChange(field: "pin", before: "true", after: "true").line(targetType: "profile"), "pin: changed")
    }

    func testTargetLabel() throws {
        XCTAssertEqual(try entry(#","target_type":"access_group","target_id":"3""#).targetLabel, "access group #3")
        XCTAssertEqual(try entry(#","target_type":"api_key","target_id":"3""#).targetLabel, "API key #3")
        XCTAssertNil(try entry().targetLabel)
    }

    func testDetailTextHidesClientIPAndUserAgentWhenNotAllowed() throws {
        let row = try entry(#","action":"user.update","changes":[{"field":"role","before":"\"user\"","after":"\"admin\""}]"#)
        let shown = row.detailText(showsClientIP: true)
        XCTAssertTrue(shown.contains("Client IP: 192.0.2.10"), shown)
        XCTAssertTrue(shown.contains("User agent: Bloem Admin/1.0"), shown)
        XCTAssertTrue(shown.contains("Request ID: req-5"), shown)
        XCTAssertTrue(shown.contains("role: user → admin"), shown)
        XCTAssertTrue(shown.contains("Duration: 38 ms"), shown)
        XCTAssertFalse(row.detailText(showsClientIP: false).contains("192.0.2.10"))
    }
}
