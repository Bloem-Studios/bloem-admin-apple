import XCTest
@testable import BloemAdmin

/// The Playback history filters and the query they send (`user_id`, `profile_id`, `completed` on
/// `GET /api/v2/admin/playback-history`).
final class HistoryFilterTests: XCTestCase {
    func testAnEmptyFilterSendsNothing() {
        XCTAssertTrue(HistoryFilter().isEmpty)
        XCTAssertEqual(HistoryFilter().query, [:])
    }

    func testUserProfileAndCompletionAreSent() {
        let filter = HistoryFilter(userID: " 42 ", profileID: "p1", completion: .partial)
        XCTAssertEqual(filter.query, ["user_id": "42", "profile_id": "p1", "completed": "false"])
        XCTAssertEqual(HistoryFilter(completion: .completed).query, ["completed": "true"])
    }

    func testAProfileNeedsAUser() {
        // The profile list belongs to one user, so a profile alone is dropped.
        XCTAssertEqual(HistoryFilter(profileID: "p1").query, [:])
        XCTAssertEqual(HistoryFilter(profileID: "p1").profileID, "")
    }

    func testEqualFiltersCompareEqualAfterTrimming() {
        XCTAssertEqual(HistoryFilter(userID: " 7"), HistoryFilter(userID: "7"))
        XCTAssertNotEqual(HistoryFilter(userID: "7"), HistoryFilter(userID: "7", completion: .partial))
    }
}
