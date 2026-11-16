import XCTest
@testable import BloemAdmin

@MainActor
final class APIKeysViewModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let listPath = "/api/v2/admin/api-keys"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func makeModel(serverName: String? = nil) -> APIKeysViewModel {
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
        return APIKeysViewModel(client: client, serverName: serverName, sessionState: nil)
    }

    private func key(_ id: String, label: String = "Backup script", scopes: [String] = [], owner: String = "alice", lastUsed: String? = nil, tier: String = "standard") -> [String: Any] {
        var value: [String: Any] = [
            "id": id, "user_id": "3", "label": label, "key_prefix": "bk_\(id)abc", "rate_tier": tier, "scopes": scopes,
            "created_at": "2026-01-02T03:04:05.000Z", "username": owner,
        ]
        if let lastUsed { value["last_used_at"] = lastUsed }
        return value
    }

    private func page(_ ids: [String], next: String? = nil) -> MockHTTPResponse {
        var info: [String: Any] = ["has_more": next != nil]
        if let next { info["next_cursor"] = next }
        return MockHTTPResponse(json: ["items": ids.map { key($0) }, "page": info])
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    private let problem409 = Data(#"{"type":"https://example.test/problems/precondition_failed","title":"Precondition failed","status":412,"detail":"The API key changed; reload before saving."}"#.utf8)

    func testListsKeysWithOwnerScopeAndLastUsed() async throws {
        http.state.stub(path: listPath, json: [
            "items": [
                key("7", label: "CI", scopes: ["library.read", "stats.read"], owner: "alice", lastUsed: "2026-02-03T04:05:06.000Z"),
                key("8", label: "Legacy", owner: "bob", tier: "elevated"),
            ],
            "page": ["has_more": false],
        ])
        let model = makeModel()

        await model.load()

        let keys = try XCTUnwrap(model.keys)
        XCTAssertEqual(keys.map(\.label), ["CI", "Legacy"])
        XCTAssertEqual(keys.map(\.username), ["alice", "bob"])
        XCTAssertEqual(keys[0].scopes, ["library.read", "stats.read"])
        XCTAssertNotNil(keys[0].lastUsedAt)
        XCTAssertNil(keys[1].lastUsedAt)
        XCTAssertEqual(keys[1].rateTier, "elevated")
        let request = try XCTUnwrap(http.state.requests(path: listPath).first)
        XCTAssertEqual(query(request, "limit"), "50")
    }

    func testLoadMoreFollowsTheCursorAndKeepsEarlierRows() async throws {
        http.state.stubSequence(path: listPath, responses: [page(["1", "2"], next: "c1"), page(["2", "3"])])
        let model = makeModel()

        await model.load()
        XCTAssertTrue(model.hasMore)
        await model.loadMore()

        XCTAssertEqual(model.keys?.map(\.id), ["1", "2", "3"], "a repeated key is not listed twice")
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(query(try XCTUnwrap(http.state.requests(path: listPath).last), "cursor"), "c1")
    }

    func testAFailedNextPageKeepsTheKeysShown() async {
        http.state.stubSequence(path: listPath, responses: [page(["1"], next: "c1"), MockHTTPResponse(status: 500)])
        let model = makeModel()
        await model.load()

        await model.loadMore()

        XCTAssertEqual(model.keys?.map(\.id), ["1"])
        XCTAssertTrue(model.moreFailed)
        XCTAssertNil(model.loadFailure)
    }

    func testAServerWithoutKeyAdministrationIsSaidPlainlyWithNothingToRetry() async {
        http.state.stub(
            path: listPath,
            data: Data(#"{"type":"https://example.test/problems/dependency_unavailable","title":"Dependency unavailable","status":503,"detail":"API key administration is unavailable."}"#.utf8),
            status: 503
        )
        let model = makeModel()

        await model.load()

        XCTAssertTrue(model.isUnavailable)
        XCTAssertNil(model.loadFailure)
        XCTAssertTrue(model.hasLoaded)
    }

    func testAFailedLoadIsTypedAndCanBeTriedAgain() async {
        http.state.stub(path: listPath, data: Data(), status: 500)
        let model = makeModel()

        await model.load()

        XCTAssertEqual(model.loadFailure?.kind, .serverFailure)
        XCTAssertFalse(model.isUnavailable)
    }

    func testRevokingReadsTheKeysVersionThenDeletesWithIfMatchAndListsAgain() async throws {
        http.state.stubSequence(path: listPath, responses: [page(["7", "8"]), page(["8"])])
        http.state.stubSequence(path: "\(listPath)/7", responses: [
            MockHTTPResponse(json: key("7"), headers: ["ETag": "\"rev-7\""]),
            MockHTTPResponse(status: 204),
        ])
        let model = makeModel()
        await model.load()
        let target = try XCTUnwrap(model.keys?.first)

        let revoked = await model.revoke(target)

        XCTAssertTrue(revoked)
        let calls = http.state.requests(path: "\(listPath)/7")
        XCTAssertEqual(calls.map(\.httpMethod), ["GET", "DELETE"])
        XCTAssertEqual(calls.last?.value(forHTTPHeaderField: "If-Match"), "\"rev-7\"")
        XCTAssertEqual(model.keys?.map(\.id), ["8"], "the revoked key left the list")
        XCTAssertEqual(model.notice, "Revoked Backup script")
        XCTAssertFalse(model.isBusy(target))
    }

    func testAKeyThatChangedSinceItWasReadIsNotRevokedBlindAndThePageReloads() async throws {
        http.state.stubSequence(path: listPath, responses: [page(["7"]), page(["7"])])
        http.state.stubSequence(path: "\(listPath)/7", responses: [
            MockHTTPResponse(json: key("7"), headers: ["ETag": "\"rev-7\""]),
            MockHTTPResponse(data: problem409, status: 412),
        ])
        let model = makeModel()
        await model.load()

        let revoked = await model.revoke(try XCTUnwrap(model.keys?.first))

        XCTAssertFalse(revoked)
        XCTAssertEqual(model.errorMessage, "This key changed since the list was loaded. Check it and try again.")
        XCTAssertEqual(http.state.requests(path: listPath).count, 2, "the list was read again")
    }

    func testAKeyThatIsAlreadyGoneCountsAsRevokedAndLeavesTheList() async throws {
        http.state.stubSequence(path: listPath, responses: [page(["7"]), page([])])
        http.state.stub(path: "\(listPath)/7", data: Data(#"{"type":"https://example.test/problems/not_found","title":"Not found","status":404,"detail":"API key not found."}"#.utf8), status: 404)
        let model = makeModel()
        await model.load()

        let revoked = await model.revoke(try XCTUnwrap(model.keys?.first))

        XCTAssertTrue(revoked)
        XCTAssertEqual(model.keys?.count, 0)
        XCTAssertEqual(model.notice, "Backup script was already revoked")
    }

    func testWithoutAVersionFromTheServerNothingIsDeleted() async throws {
        http.state.stub(path: listPath, response: page(["7"]))
        http.state.stub(path: "\(listPath)/7", json: key("7"))
        let model = makeModel()
        await model.load()

        let revoked = await model.revoke(try XCTUnwrap(model.keys?.first))

        XCTAssertFalse(revoked)
        XCTAssertEqual(http.state.requests(path: "\(listPath)/7").map(\.httpMethod), ["GET"], "no DELETE without If-Match")
        XCTAssertNotNil(model.errorMessage)
    }

    func testARefusalShowsTheServersReasonWithTheServerNamed() async throws {
        http.state.stubSequence(path: listPath, responses: [page(["7"]), page(["7"])])
        http.state.stub(
            path: "\(listPath)/7",
            data: Data(#"{"type":"https://example.test/problems/permission_denied","title":"Permission denied","status":403,"detail":"Only an administrator may revoke keys."}"#.utf8),
            status: 403
        )
        let model = makeModel(serverName: "Home")
        await model.load()

        let revoked = await model.revoke(try XCTUnwrap(model.keys?.first))

        XCTAssertFalse(revoked)
        XCTAssertEqual(model.errorMessage, "Home: Only an administrator may revoke keys.")
    }

    func testASecondRevokeOfTheSameKeyWhileOneIsRunningIsIgnored() async throws {
        http.state.stub(path: listPath, response: page(["7"]))
        http.state.stub(path: "\(listPath)/7", response: MockHTTPResponse(json: key("7"), headers: ["ETag": "\"rev-7\""]))
        http.state.holdGETs(path: "\(listPath)/7")
        let model = makeModel()
        await model.load()
        let target = try XCTUnwrap(model.keys?.first)

        let first = Task { await model.revoke(target) }
        await http.state.waitForRequest(path: "\(listPath)/7")
        XCTAssertTrue(model.isBusy(target))
        let second = await model.revoke(target)
        http.state.releaseResponses(matching: "\(listPath)/7")
        _ = await first.value

        XCTAssertFalse(second)
    }
}

final class APIKeyTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)

    func testScopesAreNamedAndAKeyWithNoneHasFullAccess() {
        XCTAssertEqual(APIKeyText.scopes([]), "Full access")
        XCTAssertEqual(APIKeyText.scopes(["library.read"]), "1 scope: library.read")
        XCTAssertEqual(APIKeyText.scopes(["a", "b"]), "2 scopes: a, b")
    }

    func testLastUsedSaysNeverOrWhen() {
        XCTAssertEqual(APIKeyText.lastUsed(nil, now: now), "Never used")
        XCTAssertTrue(APIKeyText.lastUsed(now.addingTimeInterval(-7200), now: now).hasPrefix("Last used "))
        let old = now.addingTimeInterval(-90 * 24 * 3600)
        XCTAssertEqual(APIKeyText.lastUsed(old, now: now), "Last used \(old.formatted(date: .abbreviated, time: .omitted))")
    }

    func testOwnerAndRateTierAreSaidInWords() {
        XCTAssertEqual(APIKeyText.owner("alice"), "Owner: alice")
        XCTAssertEqual(APIKeyText.owner(""), "Owner: unknown account")
        XCTAssertNil(APIKeyText.rateTier("standard"))
        XCTAssertEqual(APIKeyText.rateTier("elevated"), "Elevated rate limit")
    }

    func testTheRevokePromptSaysWhatHappensAndThatItCannotBeUndone() {
        XCTAssertEqual(APIKeyText.revokeTitle("CI"), "Revoke CI?")
        XCTAssertTrue(APIKeyText.revokeMessage("CI").contains("stops working at once"))
        XCTAssertTrue(APIKeyText.revokeMessage("CI").contains("can't be undone"))
    }

    func testTheKeysPageIsInTheSingleServerMenuUnderTheConfigureGroupAndNotInAllServers() {
        let page = AdminDestination.apiKeys
        XCTAssertEqual(page.id, "system.api-keys")
        XCTAssertEqual(page.labelText, "API keys")
        XCTAssertEqual(page.descriptionText, "Admin API keys and tier assignment")
        XCTAssertEqual(page.group, .configure)
        for word in ["tokens", "keys", "access", "scopes", "rate limit tier"] {
            XCTAssertTrue(page.keywords.contains(word), word)
        }
        XCTAssertTrue(AdminDestination.singleServer(tenantsVisible: false).contains(page))
        XCTAssertFalse(AdminDestination.allServers.contains(page), "revoking needs one server in view")
    }
}
