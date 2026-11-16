import XCTest
@testable import BloemAdmin

/// The names behind the user and profile pickers of Playback history and Audit: the server's user
/// list (`GET /api/v2/admin/users`) and one user's profiles (`GET /api/v2/admin/users/{id}/profiles`).
@MainActor
final class UserPickerOptionsTests: XCTestCase {
    private func client(_ http: MockHTTPHarness) -> APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
    }

    func testUsersAreListedByNameIgnoringCase() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.pathOverrides = ["/api/v2/admin/users": (try! JSONSerialization.data(withJSONObject: UserFixtures.page([
            UserFixtures.user(id: "3", username: "zed"), UserFixtures.user(id: "1", username: "Alice"), UserFixtures.user(id: "2", username: "bob"),
        ])), 200)]
        let options = UserPickerOptions()
        await options.loadUsers(client: client(http))
        XCTAssertEqual(options.users.map(\.username), ["Alice", "bob", "zed"])
        XCTAssertNil(options.usersFailure)
        XCTAssertEqual(options.userName(forID: "2"), "bob")
        XCTAssertNil(options.userName(forID: "99"))
    }

    func testAFailedUserListSaysWhatHappened() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseStatus = 500
        let options = UserPickerOptions()
        await options.loadUsers(client: client(http))
        XCTAssertTrue(options.users.isEmpty)
        XCTAssertNotNil(options.usersFailure)
    }

    func testProfilesAreReadForOneUser() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.pathOverrides = ["/api/v2/admin/users/42/profiles": (try JSONSerialization.data(withJSONObject: ["items": [["id": "p1", "name": "Living room"], ["id": "p2", "name": "Kids"]]]), 200)]
        let options = UserPickerOptions()
        await options.loadProfiles(userID: "42", client: client(http))
        XCTAssertEqual(options.profiles.map(\.name), ["Living room", "Kids"])
    }

    func testNoUserMeansNoProfilesAndNoRequest() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let options = UserPickerOptions()
        await options.loadProfiles(userID: "42", client: client(http))
        let before = http.state.requestLog.count
        await options.loadProfiles(userID: "", client: client(http))
        XCTAssertTrue(options.profiles.isEmpty)
        XCTAssertEqual(http.state.requestLog.count, before)
    }

    func testProfilesOfAFormerUserAreDiscarded() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.pathOverrides = [
            "/api/v2/admin/users/1/profiles": (try JSONSerialization.data(withJSONObject: ["items": [["id": "a", "name": "One"]]]), 200),
            "/api/v2/admin/users/2/profiles": (try JSONSerialization.data(withJSONObject: ["items": [["id": "b", "name": "Two"]]]), 200),
        ]
        let options = UserPickerOptions()
        let api = client(http)
        let first = Task { await options.loadProfiles(userID: "1", client: api) }
        await Task.yield()
        await options.loadProfiles(userID: "2", client: api)
        await first.value
        XCTAssertEqual(options.profiles.map(\.name), ["Two"])
    }
}
