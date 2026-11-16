import XCTest
@testable import BloemAdmin

/// `GET/PUT /api/v2/admin/request-settings` with `If-Match`
/// (server:internal/apiv2/admin_requests.go:266, 342-383): the answer carries the `ETag` and the body;
/// a stale tag is 412 with the current `ETag`.
@MainActor
final class RequestSettingsModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }
    private let path = "/api/v2/admin/request-settings"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func settings(
        enabled: Bool = true, max: Int = 5, days: Int = 7, auto: Bool = false, dual: Bool = false, watchlist: Bool? = false
    ) -> [String: Any] {
        var json: [String: Any] = [
            "requests_enabled": enabled, "global_max_requests": max, "global_window_days": days,
            "global_auto_approval_enabled": auto, "force_dual_quality": dual,
        ]
        if let watchlist { json["watchlist_requests"] = watchlist }
        return json
    }

    private func answer(_ json: [String: Any], etag: String?) -> MockHTTPResponse {
        MockHTTPResponse(json: json, headers: etag.map { ["ETag": $0] } ?? [:])
    }

    private let conflict = MockHTTPResponse(
        data: Data(#"{"type":"https://example.test/problems/precondition_failed","title":"Precondition Failed","status":412,"detail":"Request settings changed; reload before saving."}"#.utf8),
        status: 412, headers: ["Content-Type": "application/problem+json", "ETag": "\"s2\""]
    )

    private func puts() -> [URLRequest] { http.state.requestLog.filter { $0.httpMethod == "PUT" } }

    func testLoadReadsTheSettingsAndTheirValidator() async {
        http.state.stubSequence(path: path, responses: [answer(settings(max: 9, days: 14, auto: true), etag: "\"s1\"")])
        let model = RequestSettingsModel()

        await model.load(client: client)

        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.draft?.globalMaxRequests, 9)
        XCTAssertEqual(model.draft?.globalWindowDays, 14)
        XCTAssertEqual(model.draft?.globalAutoApprovalEnabled, true)
        XCTAssertEqual(model.baseValidator, "\"s1\"")
        XCTAssertFalse(model.isDirty)
    }

    func testSaveSendsEveryFieldWithIfMatchAndTakesTheNewValidator() async throws {
        http.state.stubSequence(path: path, responses: [
            answer(settings(), etag: "\"s1\""),
            answer(settings(enabled: false, max: 5, days: 7), etag: "\"s2\""),
        ])
        let model = RequestSettingsModel()
        await model.load(client: client)
        model.edit { $0.requestsEnabled = false }
        XCTAssertTrue(model.isDirty)
        XCTAssertTrue(model.canSave)

        let outcome = await model.save(client: client)

        XCTAssertEqual(outcome, .saved)
        let request = try XCTUnwrap(puts().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"s1\"")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(http.state.capturedBody)) as? [String: Any])
        XCTAssertEqual(body["requests_enabled"] as? Bool, false)
        XCTAssertEqual(body["global_max_requests"] as? Int, 5)
        XCTAssertEqual(body["global_window_days"] as? Int, 7)
        XCTAssertEqual(body["global_auto_approval_enabled"] as? Bool, false)
        XCTAssertEqual(body["force_dual_quality"] as? Bool, false)
        XCTAssertEqual(body["watchlist_requests"] as? Bool, false)
        XCTAssertEqual(model.baseValidator, "\"s2\"")
        XCTAssertFalse(model.isDirty)
        XCTAssertTrue(model.didSave)
    }

    func testAnOlderServerWithoutWatchlistSendsNoWatchlistField() async throws {
        http.state.stubSequence(path: path, responses: [
            answer(settings(watchlist: nil), etag: "\"s1\""),
            answer(settings(max: 6, watchlist: nil), etag: "\"s2\""),
        ])
        let model = RequestSettingsModel()
        await model.load(client: client)
        model.edit { $0.globalMaxRequests = 6 }

        _ = await model.save(client: client)

        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(http.state.capturedBody)) as? [String: Any])
        XCTAssertNil(body["watchlist_requests"])
    }

    func testNegativeLimitAndZeroWindowCannotBeSaved() async {
        http.state.stubSequence(path: path, responses: [answer(settings(), etag: "\"s1\"")])
        let model = RequestSettingsModel()
        await model.load(client: client)

        model.edit { $0.globalMaxRequests = -1 }
        XCTAssertEqual(model.limitProblem, "Use a whole number, 0 or more")
        XCTAssertFalse(model.canSave)

        model.edit { $0.globalMaxRequests = 0; $0.globalWindowDays = 0 }
        XCTAssertNil(model.limitProblem)
        XCTAssertEqual(model.windowProblem, "Use at least 1 day")
        XCTAssertFalse(model.canSave)

        model.edit { $0.globalWindowDays = 30 }
        XCTAssertTrue(model.canSave)
    }

    func testStaleValidatorKeepsTheEditsAndOffersTheServersSettings() async {
        // The read, the refused write, then the re-read after the refusal.
        http.state.stubSequence(path: path, responses: [
            answer(settings(max: 5), etag: "\"s1\""),
            conflict,
            answer(settings(max: 20), etag: "\"s2\""),
        ])
        let model = RequestSettingsModel()
        await model.load(client: client)
        model.edit { $0.globalMaxRequests = 3 }

        let outcome = await model.save(client: client)

        XCTAssertEqual(outcome, .conflict)
        XCTAssertTrue(model.showsConflict)
        XCTAssertEqual(model.draft?.globalMaxRequests, 3, "the edit stays visible")
        XCTAssertEqual(model.latest?.globalMaxRequests, 20)
        XCTAssertEqual(puts().count, 1)

        model.keepMyChanges()
        XCTAssertFalse(model.showsConflict)
        XCTAssertEqual(model.baseValidator, "\"s2\"")
    }

    func testUsingTheServersValuesDropsTheEdits() async {
        http.state.stubSequence(path: path, responses: [answer(settings(max: 5), etag: "\"s1\"")])
        let model = RequestSettingsModel()
        await model.load(client: client)
        model.edit { $0.globalMaxRequests = 3 }

        model.discard()

        XCTAssertEqual(model.draft?.globalMaxRequests, 5)
        XCTAssertFalse(model.isDirty)
    }

    func testARefreshWhileEditingKeepsTheBaselineAndSaysTheServerChanged() async {
        http.state.stubSequence(path: path, responses: [
            answer(settings(max: 5), etag: "\"s1\""),
            answer(settings(max: 8), etag: "\"s2\""),
        ])
        let model = RequestSettingsModel()
        await model.load(client: client)
        model.edit { $0.globalMaxRequests = 3 }

        await model.load(client: client)

        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.baseValidator, "\"s1\"")
        XCTAssertEqual(model.draft?.globalMaxRequests, 3)

        model.keepMyChanges()
        XCTAssertFalse(model.isStale)
        XCTAssertEqual(model.baseValidator, "\"s2\"")
    }

    func testRequestAdministrationUnavailableIsShownInTheServersWords() async {
        http.state.stubSequence(path: path, responses: [MockHTTPResponse(
            data: Data(#"{"type":"https://example.test/problems/unavailable","title":"Unavailable","status":503,"detail":"The request administration service is not available"}"#.utf8),
            status: 503, headers: ["Content-Type": "application/problem+json"]
        )])
        let model = RequestSettingsModel()

        await model.load(client: client)

        XCTAssertFalse(model.hasLoaded)
        XCTAssertEqual(model.loadFailure?.message, "The request administration service is not available")
    }

    func testNamedServerPrefixesTheSaveError() async {
        http.state.stubSequence(path: path, responses: [
            answer(settings(), etag: "\"s1\""),
            MockHTTPResponse(data: Data(#"{"error":"x","message":"Not allowed"}"#.utf8), status: 403),
        ])
        let model = RequestSettingsModel(serverName: "Alpha")
        await model.load(client: client)
        model.edit { $0.requestsEnabled = false }

        _ = await model.save(client: client)

        XCTAssertEqual(model.saveError, "Alpha: Not allowed")
    }
}
