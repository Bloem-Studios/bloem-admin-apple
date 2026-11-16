import XCTest
@testable import BloemAdmin

/// The Overview's Watching now card, and the last-seen and expiry lines of the Sign-in tab.
@MainActor
final class UserWatchingNowTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let sessionsPath = "/api/v2/admin/sessions"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private var client: APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
    }

    private func session(_ id: String, user: String, title: String = "The Long Film", paused: Bool = false) -> [String: Any] {
        [
            "session_id": id, "user_id": user, "username": "user\(user)", "media_title": title, "media_type": "movie",
            "play_method": "direct_play", "position_seconds": 600.0, "file_duration": 7200, "is_paused": paused,
            "client_name": "Bloem TV", "device_platform": "tv",
        ]
    }

    func testAsksForOneUsersSessionsOnly() async throws {
        http.state.stub(path: sessionsPath, json: ["items": [session("s1", user: "42")], "page": ["has_more": false]])

        let rows = try await client.watchingNow(userID: "42")

        XCTAssertEqual(rows.map(\.sessionID), ["s1"])
        let request = try XCTUnwrap(http.state.requests(path: sessionsPath).first)
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "user_id" }?.value, "42")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    func testRowsOfOtherAccountsAreDroppedEvenIfAnOlderServerIgnoresTheFilter() async throws {
        http.state.stub(path: sessionsPath, json: [
            "items": [session("s1", user: "42"), session("s2", user: "7"), session("s3", user: "42", paused: true)],
            "page": ["has_more": false],
        ])

        let rows = try await client.watchingNow(userID: "42")

        XCTAssertEqual(rows.map(\.sessionID), ["s1", "s3"])
        XCTAssertEqual(rows.map(\.userID), ["42", "42"])
    }

    func testAnIntegerUserIDDecodesLikeAStringOne() async throws {
        let integer = try JSONDecoder().decode(
            AdminSession.self,
            from: JSONSerialization.data(withJSONObject: [
                "session_id": "s9", "user_id": 42, "username": "u", "media_title": "T", "media_type": "movie",
                "play_method": "direct_play", "position_seconds": 0, "file_duration": 10, "is_paused": false,
            ] as [String: Any])
        )
        XCTAssertEqual(integer.userID, "42", "an older server's numeric id still reads")

        let absent = try JSONDecoder().decode(
            AdminSession.self,
            from: JSONSerialization.data(withJSONObject: [
                "session_id": "s9", "username": "u", "media_title": "T", "media_type": "movie",
                "play_method": "direct_play", "position_seconds": 0, "file_duration": 10, "is_paused": false,
            ] as [String: Any])
        )
        XCTAssertNil(absent.userID)
    }

    func testAnEmptyAnswerMeansNotWatching() async throws {
        http.state.stub(path: sessionsPath, json: ["items": [], "page": ["has_more": false]])
        let rows = try await client.watchingNow(userID: "42")
        XCTAssertTrue(rows.isEmpty)
    }

    func testARowSaysWhatIsPlayingOnWhatAndWhetherItIsPausedInWords() throws {
        let data = try JSONSerialization.data(withJSONObject: session("s1", user: "42", title: "Dune", paused: true))
        let row = try JSONDecoder().decode(AdminSession.self, from: data)

        let line = WatchingNowText.line(row)

        XCTAssertEqual(line.title, "Dune")
        XCTAssertEqual(line.status, "Paused")
        XCTAssertTrue(line.detail.contains("Bloem TV"), line.detail)
        XCTAssertTrue(line.detail.contains("10:00"), "the position, as a clock: \(line.detail)")
        XCTAssertEqual(WatchingNowText.line(try JSONDecoder().decode(AdminSession.self, from: JSONSerialization.data(withJSONObject: session("s2", user: "42")))).status, "Playing")
    }

    func testTheCardSaysNothingIsPlayingWhenThereAreNoRows() {
        XCTAssertEqual(WatchingNowText.empty, "Not watching right now")
        XCTAssertEqual(WatchingNowText.heading(count: 0), "Watching now")
        XCTAssertEqual(WatchingNowText.heading(count: 2), "Watching now · 2 streams")
        XCTAssertEqual(WatchingNowText.heading(count: 1), "Watching now · 1 stream")
    }
}

final class UserSessionTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    func testLastSeenSaysWhenOrThatThereWasNoActivity() {
        XCTAssertEqual(UserSessionText.lastSeen(nil, now: now), "No activity since signing in")
        XCTAssertTrue(UserSessionText.lastSeen(now.addingTimeInterval(-3 * 3600), now: now).hasPrefix("Last seen "))
    }

    func testLastSeenTurnsIntoADateAfterThirtyDaysLikeTheWeb() {
        let old = now.addingTimeInterval(-40 * 24 * 3600)
        XCTAssertEqual(UserSessionText.lastSeen(old, now: now), "Last seen \(old.formatted(date: .abbreviated, time: .omitted))")
    }

    func testExpirySaysExpiresOrExpiredAgainstTheClock() {
        let later = now.addingTimeInterval(5 * 24 * 3600)
        let earlier = now.addingTimeInterval(-2 * 24 * 3600)
        XCTAssertEqual(UserSessionText.expiry(later, now: now), "Expires \(later.formatted(date: .abbreviated, time: .omitted))")
        XCTAssertEqual(UserSessionText.expiry(earlier, now: now), "Expired \(earlier.formatted(date: .abbreviated, time: .omitted))")
    }

    func testASessionRowListsTheDeviceFactsInWordsAndHidesIPsWhenAsked() {
        let session = AuthSession(
            id: "ls1", deviceName: "Living room TV", deviceId: nil, devicePlatform: "tv", ipAddress: "203.0.113.7",
            createdAt: now.addingTimeInterval(-10 * 24 * 3600), expiresAt: now.addingTimeInterval(20 * 24 * 3600),
            lastSeenAt: now.addingTimeInterval(-3600), current: true
        )

        let shown = UserSessionText.sessionLines(session, showsIPs: true, now: now)
        let hidden = UserSessionText.sessionLines(session, showsIPs: false, now: now)

        XCTAssertTrue(shown.joined(separator: " | ").contains("203.0.113.7"))
        XCTAssertTrue(shown.joined(separator: " | ").contains("this session"))
        XCTAssertFalse(hidden.joined(separator: " | ").contains("203.0.113.7"))
        XCTAssertTrue(shown.contains { $0.hasPrefix("Last seen ") })
        XCTAssertTrue(shown.contains { $0.hasPrefix("Expires ") })
        XCTAssertTrue(shown.contains { $0.hasPrefix("Created ") })
    }

    func testADeviceRowSaysWhenItWasLastSeen() {
        let seen = UserDevice(deviceId: "d1", deviceName: "TV", devicePlatform: "tv", lastSeenAt: now.addingTimeInterval(-86_400), lastUpdated: nil, overrideCount: 0, profiles: [])
        let never = UserDevice(deviceId: "d2", deviceName: "Phone", devicePlatform: "ios", lastSeenAt: nil, lastUpdated: nil, overrideCount: 0, profiles: [])

        XCTAssertTrue(UserSessionText.deviceLastSeen(seen, now: now).hasPrefix("Last seen "))
        XCTAssertEqual(UserSessionText.deviceLastSeen(never, now: now), "Not seen yet")
    }
}
