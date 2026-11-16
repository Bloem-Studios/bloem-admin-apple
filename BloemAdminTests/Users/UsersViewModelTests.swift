import XCTest
@testable import BloemAdmin

@MainActor
final class UsersViewModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }
    private let listPath = "/api/v2/admin/users"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func target(id: String = "42") throws -> AdminUser {
        try UserFixtures.decoded(UserFixtures.user(id: id))
    }

    // MARK: - Load

    func testLoadReadsEveryPageWithLimitAndFollowsTheCursor() async throws {
        http.state.stubSequence(path: listPath, responses: [
            UserFixtures.response(UserFixtures.page([UserFixtures.user(id: "1", username: "alice")], next: "c2")),
            UserFixtures.response(UserFixtures.page([UserFixtures.user(id: "2", username: "bob")])),
        ])
        let viewModel = UsersViewModel()

        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.users.map(\.username), ["alice", "bob"])
        XCTAssertEqual(viewModel.users.map(\.id), ["1", "2"])
        let requests = http.state.requests(path: listPath)
        XCTAssertEqual(requests.count, 2)
        let first = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[0].url), resolvingAgainstBaseURL: false)).queryItems
        XCTAssertEqual(first?.map(\.name).sorted(), ["limit"])
        XCTAssertEqual(first?.first?.value, "200")
        let second = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false)).queryItems
        XCTAssertEqual(second?.map(\.name).sorted(), ["cursor", "limit"])
    }

    func testLoadDecodesQuotaPermissionAndPolicyFieldsWithoutPlaybackAllowed() async throws {
        let fixture = UserFixtures.user(overrides: [
            "max_streams": NSNull(), "max_transcodes": 2, "download_allowed": NSNull(),
            "requests_allowed": false, "transcode_allowed": true, "audio_transcode_allowed": false, "max_profiles": 5,
        ])
        http.state.stubSequence(path: listPath, responses: [UserFixtures.response(UserFixtures.page([fixture]))])
        let viewModel = UsersViewModel()

        await viewModel.load(client: client)

        let user = try XCTUnwrap(viewModel.users.first)
        XCTAssertNil(user.maxStreams)
        XCTAssertEqual(user.maxTranscodes, 2)
        XCTAssertNil(user.downloadAllowed, "the stored override is inherited")
        XCTAssertEqual(user.requestsAllowed, false)
        XCTAssertEqual(user.transcodeAllowed, true)
        XCTAssertEqual(user.audioTranscodeAllowed, false)
        XCTAssertEqual(user.maxProfiles, 5)
        XCTAssertEqual(user.effectivePolicy?.maxStreams, 8)
        XCTAssertEqual(user.effectivePolicy?.downloadAllowed, true)
        XCTAssertEqual(user.effectivePolicy?.libraryIDs, ["1", "2"])
    }

    func testListFailureShowsTheServerMessage() async {
        http.state.stubSequence(path: listPath, responses: [MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Boom"}"#.utf8), status: 500)])
        let viewModel = UsersViewModel()

        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.errorMessage, "Boom")
        XCTAssertTrue(viewModel.users.isEmpty)
    }

    func testLoad401FlagsSessionStateTokenExpired() async {
        http.state.stubSequence(path: listPath, responses: [MockHTTPResponse(data: Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), status: 401)])
        let root = AdminSessionState()
        root.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: root.credentialProvider(serverID: "srv-1"),
            session: http.session
        )
        let viewModel = UsersViewModel()
        let sessionState = root.scoped(to: "srv-1")

        await viewModel.load(client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.errorMessage, "Token expired")
    }

    // MARK: - Enable / disable

    func testSetEnabledReadsTheETagRightBeforeAndSendsItAsIfMatch() async throws {
        let path = "/api/v2/admin/users/42"
        http.state.stubSequence(path: path, responses: [
            UserFixtures.response(UserFixtures.user(), etag: "\"u1\""),
            MockHTTPResponse(status: 204),
        ])
        let viewModel = UsersViewModel()

        await viewModel.setEnabled(false, for: try target(), client: client)

        XCTAssertNil(viewModel.actionErrorMessage)
        let requests = http.state.requests(path: path)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Match"), "\"u1\"")
        XCTAssertEqual(http.state.capturedBody, Data(#"{"enabled":false}"#.utf8))
        XCTAssertNil(requests.last?.value(forHTTPHeaderField: "Idempotency-Key"))
    }

    func testSetEnabledWithoutAnETagRefusesTheWrite() async throws {
        let path = "/api/v2/admin/users/42"
        http.state.stubSequence(path: path, responses: [UserFixtures.response(UserFixtures.user())])
        let viewModel = UsersViewModel()

        await viewModel.setEnabled(false, for: try target(), client: client)

        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertEqual(http.state.requests(path: path).map(\.httpMethod), ["GET"])
    }

    func testSetEnabledConflictReloadsOnceShowsAConflictAndDoesNotRetry() async throws {
        let path = "/api/v2/admin/users/42"
        http.state.stubSequence(path: path, responses: [
            UserFixtures.response(UserFixtures.user(), etag: "\"u1\""),
            UserFixtures.conflict,
            MockHTTPResponse(status: 204),
        ])
        http.state.stubSequence(path: listPath, responses: [UserFixtures.response(UserFixtures.page([UserFixtures.user(username: "renamed")]))])
        let viewModel = UsersViewModel()

        await viewModel.setEnabled(false, for: try target(), client: client)

        XCTAssertEqual(http.state.requests(path: path).map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(http.state.requests(path: listPath).count, 1)
        XCTAssertEqual(viewModel.users.first?.username, "renamed")
        XCTAssertTrue(viewModel.actionErrorMessage?.contains("changed") == true)
    }

    func testUserIDIsEncodedAsOnePathSegment() async throws {
        http.state.stubSequence(path: "/api/v2/admin/users/a b/c", responses: [
            UserFixtures.response(UserFixtures.user(id: "a b/c"), etag: "\"u1\""),
            MockHTTPResponse(status: 204),
        ])
        let viewModel = UsersViewModel()

        await viewModel.setEnabled(true, for: try target(id: "a b/c"), client: client)

        let request = try XCTUnwrap(http.state.lastRequest)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/users/a%20b%2Fc")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testAggregateViewModelNamesTheServerInActionErrors() async throws {
        let path = "/api/v2/admin/users/42"
        http.state.stubSequence(path: path, responses: [MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8), status: 403)])
        let viewModel = UsersViewModel(serverName: "Home")

        await viewModel.setEnabled(false, for: try target(), client: client)

        XCTAssertEqual(viewModel.actionErrorMessage, "Home: Not allowed")
    }

    // MARK: - Create

    func testCreateUserPostsTheContractBodyWithDefaultProfile() async throws {
        http.state.stubSequence(path: listPath, responses: [UserFixtures.response(["id": "7"], status: 201)])
        let viewModel = UsersViewModel()

        let succeeded = await viewModel.createUser(username: "newuser", email: "new@example.test", password: "hunter2hunter2", role: "user", client: client)

        XCTAssertTrue(succeeded)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(http.state.lastRequest?.url?.path, listPath)
        let body = try XCTUnwrap(http.state.capturedBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["username", "email", "password", "role", "create_default_profile"])
        XCTAssertEqual(object["username"] as? String, "newuser")
        XCTAssertEqual(object["email"] as? String, "new@example.test")
        XCTAssertEqual(object["password"] as? String, "hunter2hunter2")
        XCTAssertEqual(object["role"] as? String, "user")
        XCTAssertEqual(object["create_default_profile"] as? Bool, true)
    }

    func testCreateUserFailureSetsActionErrorMessageAndLeavesTheList() async throws {
        http.state.stubSequence(path: listPath, responses: [
            UserFixtures.response(UserFixtures.page([UserFixtures.user(id: "1", username: "existing")])),
            MockHTTPResponse(
                data: Data(#"{"type":"https://example.test/problems/conflict","title":"Conflict","status":409,"detail":"Email already in use"}"#.utf8),
                status: 409,
                headers: ["Content-Type": "application/problem+json"]
            ),
        ])
        let viewModel = UsersViewModel()
        await viewModel.load(client: client)

        let succeeded = await viewModel.createUser(username: "dupe", email: "dupe@example.test", password: "hunter2hunter2", role: "user", client: client)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(viewModel.actionErrorMessage, "Email already in use")
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.users.map(\.username), ["existing"])
    }

    // MARK: - Delete

    func testDeleteReadsTheETagRightBeforeAndSendsItAsIfMatch() async throws {
        let path = "/api/v2/admin/users/42"
        http.state.stubSequence(path: path, responses: [
            UserFixtures.response(UserFixtures.user(), etag: "\"u9\""),
            MockHTTPResponse(status: 204),
        ])
        let viewModel = UsersViewModel()

        let succeeded = await viewModel.delete(try target(), client: client)

        XCTAssertTrue(succeeded)
        let requests = http.state.requests(path: path)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "DELETE"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Match"), "\"u9\"")
    }

    func testDeleteWithoutAnETagRefusesAndKeepsTheUser() async throws {
        let path = "/api/v2/admin/users/42"
        http.state.stubSequence(path: path, responses: [UserFixtures.response(UserFixtures.user())])
        let viewModel = UsersViewModel()
        let user = try target()
        viewModel.apply(.success([user]), token: viewModel.beginLoad(), sessionState: nil)

        let succeeded = await viewModel.delete(user, client: client)

        XCTAssertFalse(succeeded)
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertEqual(viewModel.users.count, 1)
        XCTAssertEqual(http.state.requests(path: path).map(\.httpMethod), ["GET"])
    }

    func testDeleteConflictReloadsAndDoesNotRetry() async throws {
        let path = "/api/v2/admin/users/42"
        http.state.stubSequence(path: path, responses: [
            UserFixtures.response(UserFixtures.user(), etag: "\"u1\""),
            UserFixtures.conflict,
            MockHTTPResponse(status: 204),
        ])
        http.state.stubSequence(path: listPath, responses: [UserFixtures.response(UserFixtures.page([UserFixtures.user()]))])
        let viewModel = UsersViewModel()
        let user = try target()

        let succeeded = await viewModel.delete(user, client: client)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(http.state.requests(path: path).map(\.httpMethod), ["GET", "DELETE"])
        XCTAssertEqual(viewModel.users.count, 1)
        XCTAssertNotNil(viewModel.actionErrorMessage)
    }

    func testDeleteReportsFailureWhenRequestFails() async throws {
        http.state.stubSequence(path: "/api/v2/admin/users/42", responses: [
            UserFixtures.response(UserFixtures.user(), etag: "\"u1\""),
            MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Could not delete user"}"#.utf8), status: 500),
        ])
        let viewModel = UsersViewModel()

        let succeeded = await viewModel.delete(try target(), client: client)

        XCTAssertFalse(succeeded)
        XCTAssertEqual(viewModel.actionErrorMessage, "Could not delete user")
    }

    func testSuccessfulDeleteImmediatelyRemovesUserFromCurrentList() async throws {
        http.state.stubSequence(path: "/api/v2/admin/users/42", responses: [
            UserFixtures.response(UserFixtures.user(), etag: "\"u1\""),
            MockHTTPResponse(status: 204),
        ])
        let viewModel = UsersViewModel()
        let user = try target()
        viewModel.apply(.success([user]), token: viewModel.beginLoad(), sessionState: nil)

        let succeeded = await viewModel.delete(user, client: client)

        XCTAssertTrue(succeeded)
        XCTAssertTrue(viewModel.users.isEmpty)
    }

    func testSuccessfulDeleteRejectsOlderInFlightListCompletion() async throws {
        let user = try target()
        http.state.stub(
            path: listPath,
            response: UserFixtures.response(UserFixtures.page([UserFixtures.user()])),
            delayUntilReleased: true
        )
        http.state.stubSequence(path: "/api/v2/admin/users/42", responses: [
            UserFixtures.response(UserFixtures.user(), etag: "\"u1\""),
            MockHTTPResponse(status: 204),
        ])
        let viewModel = UsersViewModel()
        viewModel.apply(.success([user]), token: viewModel.beginLoad(), sessionState: nil)

        let client = self.client
        let staleLoad = Task { await viewModel.load(client: client) }
        await http.state.waitForRequest(path: listPath)

        let succeeded = await viewModel.delete(user, client: client)
        XCTAssertTrue(succeeded)
        XCTAssertTrue(viewModel.users.isEmpty)

        http.state.releaseResponses(matching: listPath)
        await staleLoad.value

        XCTAssertTrue(viewModel.users.isEmpty)
    }

    // MARK: - Client-side search filter

    func testFilteredUsersMatchesUsernameOrEmailCaseInsensitively() async {
        http.state.stubSequence(path: listPath, responses: [UserFixtures.response(UserFixtures.page([
            UserFixtures.user(id: "1", username: "alexdoe", overrides: ["email": "alex@example.test"]),
            UserFixtures.user(id: "2", username: "alice", overrides: ["email": "alice.wonder@example.test"]),
        ]))])
        let viewModel = UsersViewModel()
        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.filteredUsers(matching: "ALEX").map(\.username), ["alexdoe"])
        XCTAssertEqual(viewModel.filteredUsers(matching: "wonder").map(\.username), ["alice"])
        XCTAssertTrue(viewModel.filteredUsers(matching: "nobody").isEmpty)
        XCTAssertEqual(viewModel.filteredUsers(matching: "").count, 2)
        XCTAssertEqual(viewModel.filteredUsers(matching: "   ").count, 2)
    }
}
