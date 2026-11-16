import XCTest
@testable import BloemAdmin

@MainActor
final class UserDetailViewModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let listPath = "/api/v2/admin/users"
    private let userPath = "/api/v2/admin/users/42"
    private let mePath = "/api/v2/account/me"
    private let capabilitiesPath = "/api/v2/admin/users/capabilities"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func makeClient() -> APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
    }

    private func makeViewModel(serverName: String? = nil, userID: String = "42") -> (UserDetailViewModel, UsersViewModel) {
        let list = UsersViewModel(serverName: serverName)
        let admin = UserAdmin(viewModel: list, client: makeClient(), sessionState: nil)
        return (UserDetailViewModel(admin: admin, userID: userID), list)
    }

    private func read(_ overrides: [String: Any] = [:], etag: String? = "\"e0\"") -> MockHTTPResponse {
        UserFixtures.response(UserFixtures.user(overrides: overrides), etag: etag)
    }

    private func stubSupportingReads(viewer: String = "1", capabilities: [String: Any] = ["available": true]) {
        http.state.stub(path: mePath, json: ["id": viewer])
        http.state.stub(path: capabilitiesPath, json: capabilities)
        http.state.stub(path: listPath, json: UserFixtures.page([UserFixtures.user()]))
    }

    private func methods(_ path: String) -> [String?] {
        http.state.requests(path: path).map(\.httpMethod)
    }

    /// The JSON body of the last PUT to the user's path.
    private func putBody() throws -> [String: Any] {
        let requests = http.state.requests(path: userPath)
        let index = try XCTUnwrap(requests.lastIndex { $0.httpMethod == "PUT" }, "no PUT was sent")
        let data = try XCTUnwrap(http.state.body(path: userPath, requestIndex: index))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Opening

    func testOpeningReadsTheAccountWhoIsLookingAndWhatTheServerSupports() async throws {
        http.state.stubSequence(path: userPath, responses: [read()])
        http.state.stub(path: "/api/v2/admin/users/1", json: UserFixtures.user(id: "1", username: "root", overrides: ["role": "admin", "is_owner": true]))
        stubSupportingReads(capabilities: ["available": true, "account_downloads": true, "login_sessions": true])
        let (model, _) = makeViewModel()

        await model.open()

        XCTAssertEqual(model.user?.username, "alice")
        XCTAssertEqual(model.validator, "\"e0\"")
        XCTAssertEqual(model.viewer, Viewer(id: "1", isOwner: true))
        XCTAssertEqual(model.capabilities?.accountDownloads, true)
        XCTAssertEqual(model.tabs, [.overview, .access, .signIn, .activity, .downloads, .preferences])
        XCTAssertTrue(model.actions.canDelete)
        XCTAssertFalse(model.actions.viewOnly != nil)
    }

    func testDownloadsIsHiddenUnlessTheServerSaysAccountDownloadsExist() async {
        http.state.stubSequence(path: userPath, responses: [read()])
        stubSupportingReads(viewer: "42", capabilities: ["available": true])
        let (model, _) = makeViewModel()

        await model.open()

        XCTAssertFalse(model.tabs.contains(.downloads))
    }

    func testAViewerReadingTheirOwnPageIsNotReadTwice() async {
        http.state.stubSequence(path: userPath, responses: [read(["is_owner": true, "role": "admin"])])
        stubSupportingReads(viewer: "42")
        let (model, _) = makeViewModel()

        await model.open()

        XCTAssertEqual(methods(userPath), ["GET"])
        XCTAssertEqual(model.viewer, Viewer(id: "42", isOwner: true))
        XCTAssertTrue(model.actions.ownAccount)
        XCTAssertFalse(model.actions.canDelete, "your own account cannot be deleted")
    }

    func testNoViewerMeansNoActionsAreOffered() async {
        http.state.stubSequence(path: userPath, responses: [read()])
        http.state.stub(path: mePath, data: Data(#"{"error":"server_error","message":"Boom"}"#.utf8), status: 500)
        http.state.stub(path: capabilitiesPath, json: ["available": true])
        let (model, _) = makeViewModel()

        await model.open()

        XCTAssertNil(model.viewer)
        XCTAssertEqual(model.actions, .none)
        XCTAssertNotNil(model.user)
    }

    func testADeletedAccountReadsAsGone() async {
        http.state.stubSequence(path: userPath, responses: [
            MockHTTPResponse(data: Data(#"{"error":"not_found","message":"No such user"}"#.utf8), status: 404),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()

        await model.open()

        XCTAssertEqual(model.state, .gone)
    }

    func testAFailedReadShowsTheServersMessageAndAFailedReReadKeepsTheAccount() async {
        http.state.stubSequence(path: userPath, responses: [
            MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Boom"}"#.utf8), status: 500),
            read(),
            MockHTTPResponse(data: Data(#"{"error":"server_error","message":"Boom again"}"#.utf8), status: 500),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()

        await model.reload()
        XCTAssertEqual(model.state, .failed("Boom"))

        await model.reload()
        XCTAssertNotNil(model.user)

        await model.reload()
        XCTAssertNotNil(model.user, "a failed re-read leaves the account already on screen")
    }

    // MARK: - Enable, disable, delete

    func testDisableSendsIfMatchFromAFreshReadThenReadsTheAccountAgain() async throws {
        http.state.stubSequence(path: userPath, responses: [
            read(etag: "\"e0\""),
            read(etag: "\"e1\""),
            MockHTTPResponse(status: 204),
            read(["enabled": false], etag: "\"e2\""),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()

        let done = await model.setEnabled(false)

        XCTAssertTrue(done)
        XCTAssertEqual(methods(userPath), ["GET", "GET", "PUT", "GET"])
        let put = try XCTUnwrap(http.state.requests(path: userPath).first { $0.httpMethod == "PUT" })
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-Match"), "\"e1\"")
        XCTAssertEqual(model.user?.enabled, false)
        XCTAssertEqual(model.validator, "\"e2\"")
        XCTAssertNil(model.actionErrorMessage)
    }

    func testA412OnDisableShowsTheConflictAndDoesNotRetry() async {
        http.state.stubSequence(path: userPath, responses: [
            read(),
            read(etag: "\"e1\""),
            UserFixtures.conflict,
            read(["username": "renamed"], etag: "\"e2\""),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()

        let done = await model.setEnabled(false)

        XCTAssertFalse(done)
        XCTAssertEqual(methods(userPath).filter { $0 == "PUT" }.count, 1)
        XCTAssertTrue(model.actionErrorMessage?.contains("changed") == true)
        XCTAssertEqual(model.user?.username, "renamed", "the page shows the server's current account")
    }

    func testDeleteSendsIfMatchAndReportsSuccess() async throws {
        http.state.stubSequence(path: userPath, responses: [read(), read(etag: "\"e1\""), MockHTTPResponse(status: 204)])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()

        let deleted = await model.delete()

        XCTAssertTrue(deleted)
        let request = try XCTUnwrap(http.state.requests(path: userPath).last)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"e1\"")
        XCTAssertEqual(methods(userPath), ["GET", "GET", "DELETE"], "a deleted account is not read again")
    }

    func testDeleteWithoutAnETagIsRefusedBeforeAnythingIsSent() async {
        http.state.stubSequence(path: userPath, responses: [read(), read(etag: nil), read()])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()

        let deleted = await model.delete()

        XCTAssertFalse(deleted)
        XCTAssertNil(http.state.requests(path: userPath).first { $0.httpMethod == "DELETE" })
        XCTAssertNotNil(model.actionErrorMessage)
    }

    // MARK: - The Access & limits save

    func testSavingSendsOnlyTheChangedFieldsWithTheVersionThePageWasReadWith() async throws {
        http.state.stubSequence(path: userPath, responses: [
            read(["max_streams": 3], etag: "\"e0\""),
            MockHTTPResponse(status: 204),
            read(["max_streams": 5], etag: "\"e1\""),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()
        model.editAccess {
            $0.limits.maxStreamsText = "5"
        }
        XCTAssertTrue(model.isAccessDirty)

        await model.saveAccess()

        let put = try XCTUnwrap(http.state.requests(path: userPath).first { $0.httpMethod == "PUT" })
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-Match"), "\"e0\"", "the version the page was read with, not a fresh read")
        XCTAssertEqual(methods(userPath), ["GET", "PUT", "GET"])
        let sent = try putBody()
        XCTAssertEqual(Set(sent.keys), ["max_streams"])
        XCTAssertEqual(sent["max_streams"] as? Int, 5)
        XCTAssertEqual(model.accessOutcome, .saved)
        XCTAssertEqual(model.validator, "\"e1\"")
        XCTAssertFalse(model.isAccessDirty)
        XCTAssertEqual(model.accessDraft.limits.maxStreamsText, "5")
    }

    func testSavingAfterSomeoneElseChangedTheAccountShowsTheConflictAndReloadsTheForm() async throws {
        http.state.stubSequence(path: userPath, responses: [
            read(["max_streams": 3], etag: "\"e0\""),
            UserFixtures.conflict,
            read(["max_streams": 9], etag: "\"e1\""),
            MockHTTPResponse(status: 204),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()
        model.editAccess { $0.limits.maxStreamsText = "5" }

        await model.saveAccess()

        guard case .failed(let message)? = model.accessOutcome else { return XCTFail("expected a conflict message, got \(String(describing: model.accessOutcome))") }
        XCTAssertTrue(message.contains("changed"))
        XCTAssertEqual(model.accessDraft.limits.maxStreamsText, "9", "the form shows the server's values")
        XCTAssertEqual(model.validator, "\"e1\"")
        XCTAssertFalse(model.isAccessDirty)
        XCTAssertEqual(methods(userPath).filter { $0 == "PUT" }.count, 1, "a conflict is never retried")
    }

    func testA428IsAConflictToo() async {
        http.state.stubSequence(path: userPath, responses: [
            read(etag: "\"e0\""),
            MockHTTPResponse(data: Data(#"{"error":"precondition_required","message":"If-Match is required"}"#.utf8), status: 428),
            read(["max_streams": 9], etag: "\"e1\""),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()
        model.editAccess { $0.limits.maxStreamsText = "5" }

        await model.saveAccess()

        guard case .failed(let message)? = model.accessOutcome else { return XCTFail("expected a conflict message") }
        XCTAssertTrue(message.contains("changed"))
        XCTAssertEqual(model.accessDraft.limits.maxStreamsText, "9")
    }

    func testAValidationMessageFromTheServerIsShownAsIsAndKeepsTheEdit() async {
        http.state.stubSequence(path: userPath, responses: [
            read(["max_streams": 3]),
            MockHTTPResponse(data: Data(#"{"error":"validation","message":"max_streams must be at most 100"}"#.utf8), status: 422),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()
        model.editAccess { $0.limits.maxStreamsText = "500" }

        await model.saveAccess()

        XCTAssertEqual(model.accessOutcome, .failed("max_streams must be at most 100"))
        XCTAssertEqual(model.accessDraft.limits.maxStreamsText, "500", "a plain failure keeps what was typed")
        XCTAssertTrue(model.isAccessDirty)
    }

    func testAPageOpenedWithoutAnETagHasNothingToSaveAgainst() async {
        http.state.stubSequence(path: userPath, responses: [read(etag: nil)])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()
        model.editAccess { $0.limits.maxStreamsText = "5" }

        await model.saveAccess()

        XCTAssertNil(model.validator)
        XCTAssertEqual(methods(userPath), ["GET"], "no write is sent without a version")
    }

    func testTheGroupLibrariesAndPermissionsSaveInOneGuardedWrite() async throws {
        http.state.stubSequence(path: userPath, responses: [read(etag: "\"e0\""), MockHTTPResponse(status: 204), read(etag: "\"e1\"")])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()
        model.editAccess {
            $0.access.groupID = "g1"
            $0.access.libraryIDs = ["2", "1"]
            $0.access.permissions = ["watch_live_tv"]
        }

        await model.saveAccess()

        let put = try XCTUnwrap(http.state.requests(path: userPath).first { $0.httpMethod == "PUT" })
        let sent = try putBody()
        XCTAssertEqual(sent["access_group_id"] as? String, "g1")
        XCTAssertEqual(sent["library_ids"] as? [String], ["1", "2"])
        XCTAssertEqual(sent["permissions"] as? [String], ["watch_live_tv"])
        XCTAssertEqual(methods(userPath).filter { $0 == "PUT" }.count, 1)
    }

    func testTheAccessChoicesAreReadWhenAskedNotWhenThePageOpens() async {
        http.state.stubSequence(path: userPath, responses: [read()])
        stubSupportingReads()
        http.state.stub(path: "/api/v2/admin/access-groups", json: UserFixtures.page([["id": "g1", "name": "Family", "member_count": 2]]))
        http.state.stub(path: "/api/v2/libraries", json: UserFixtures.page([["id": "1", "name": "Movies"]]))
        http.state.stub(path: "/api/v2/admin/users/policy-defaults", json: ["admin": ["library_ids": NSNull()], "ungrouped": ["library_ids": ["1"]]])
        let (model, _) = makeViewModel()
        await model.open()
        XCTAssertTrue(http.state.requests(path: "/api/v2/admin/access-groups").isEmpty)

        await model.loadAccessChoices()

        XCTAssertEqual(model.groups.value?.map(\.name), ["Family"])
        XCTAssertEqual(model.libraries.value?.map(\.name), ["Movies"])
        XCTAssertEqual(model.policyDefaults.value?.ungrouped?.libraryIDs, ["1"])
    }

    func testOneFailingChoiceDoesNotHideTheOthers() async {
        http.state.stubSequence(path: userPath, responses: [read()])
        stubSupportingReads()
        http.state.stub(path: "/api/v2/admin/access-groups", data: Data(#"{"error":"server_error","message":"No groups"}"#.utf8), status: 500)
        http.state.stub(path: "/api/v2/libraries", json: UserFixtures.page([["id": "1", "name": "Movies"]]))
        http.state.stub(path: "/api/v2/admin/users/policy-defaults", json: ["admin": ["library_ids": NSNull()]])
        let (model, _) = makeViewModel()
        await model.open()

        await model.loadAccessChoices()

        XCTAssertEqual(model.groups.failure, "No groups")
        XCTAssertEqual(model.libraries.value?.count, 1)
    }

    // MARK: - Set password

    func testSetPasswordGoesToTheServerWithATemporaryFlagAndNeverIntoAnError() async throws {
        http.state.stubSequence(path: userPath, responses: [
            read(["password_login": false]),
            read(["password_login": false], etag: "\"e1\""),
            MockHTTPResponse(data: Data(#"{"error":"validation","message":"Password is too weak"}"#.utf8), status: 422),
            read(["password_login": false], etag: "\"e1\""),
            MockHTTPResponse(status: 204),
            read(["password_login": true, "password_change_required": true], etag: "\"e2\""),
        ])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()

        let refused = await model.setPassword("hunter2hunter2", requireChange: true)
        guard case .failure(let message, let isConflict)? = refused else { return XCTFail("expected a refusal") }
        XCTAssertEqual(message, "Password is too weak")
        XCTAssertFalse(isConflict)
        XCTAssertFalse(message.contains("hunter2"))

        let done = await model.setPassword("hunter2hunter2", requireChange: true)
        XCTAssertEqual(done, .success)
        let put = try XCTUnwrap(http.state.requests(path: userPath).last { $0.httpMethod == "PUT" })
        XCTAssertEqual(put.value(forHTTPHeaderField: "If-Match"), "\"e1\"")
        let sent = try putBody()
        XCTAssertEqual(sent["password"] as? String, "hunter2hunter2")
        XCTAssertEqual(sent["require_password_change"] as? Bool, true)
        XCTAssertEqual(model.user?.passwordChangeRequired, true)
    }

    func testAPermanentPasswordOmitsTheTemporaryFlag() async throws {
        http.state.stubSequence(path: userPath, responses: [read(), read(etag: "\"e1\""), MockHTTPResponse(status: 204), read()])
        stubSupportingReads()
        let (model, _) = makeViewModel()
        await model.open()

        _ = await model.setPassword("hunter2hunter2", requireChange: false)

        let put = try XCTUnwrap(http.state.requests(path: userPath).last { $0.httpMethod == "PUT" })
        XCTAssertEqual(Set(try putBody().keys), ["password"])
    }

    // MARK: - All servers

    func testInAllServersWritesGoToThatServerOnlyAndFailuresNameIt() async throws {
        let session = http.session
        let homeClient = APIClient(baseURL: URL(string: "https://home.test")!, accessToken: "tok", session: session)
        http.state.stubSequence(path: userPath, responses: [
            MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8), status: 403),
        ], host: "home.test")
        http.state.stub(host: "home.test", path: mePath, data: Data(#"{"id":"1"}"#.utf8))
        http.state.stub(host: "home.test", path: capabilitiesPath, data: Data(#"{"available":true}"#.utf8))
        let list = UsersViewModel(serverName: "Home")
        var refreshed = 0
        let admin = UserAdmin(viewModel: list, client: homeClient, sessionState: nil, refreshList: { refreshed += 1 })
        let model = UserDetailViewModel(admin: admin, userID: "42")

        XCTAssertEqual(model.serverName, "Home")
        await model.reload()
        XCTAssertEqual(model.state, .failed("Home: Not allowed"))
        XCTAssertTrue(http.state.requests(host: "other.test").isEmpty)
        XCTAssertEqual(refreshed, 0)
    }

    func testInAllServersASuccessfulWriteRefreshesOnlyThatServersSection() async {
        let homeClient = APIClient(baseURL: URL(string: "https://home.test")!, accessToken: "tok", session: http.session)
        http.state.stubSequence(path: userPath, responses: [
            read(etag: "\"e0\""), read(etag: "\"e1\""), MockHTTPResponse(status: 204), read(["enabled": false], etag: "\"e2\""),
        ], host: "home.test")
        http.state.stub(host: "home.test", path: mePath, data: Data(#"{"id":"42"}"#.utf8))
        http.state.stub(host: "home.test", path: capabilitiesPath, data: Data(#"{"available":true}"#.utf8))
        var refreshed = 0
        let admin = UserAdmin(viewModel: UsersViewModel(serverName: "Home"), client: homeClient, sessionState: nil, refreshList: { refreshed += 1 })
        let model = UserDetailViewModel(admin: admin, userID: "42")
        await model.open()

        let done = await model.setEnabled(false)

        XCTAssertTrue(done)
        XCTAssertEqual(refreshed, 1)
        XCTAssertTrue(http.state.requests(host: "other.test").isEmpty)
        XCTAssertEqual(http.state.requests(host: "home.test", path: userPath).filter { $0.httpMethod == "PUT" }.count, 1)
    }

    // MARK: - Password reset email

    func testResetEmailIsOnlyOfferedWhenTheServerCanSendIt() async throws {
        http.state.stub(path: capabilitiesPath, json: ["available": true, "password_reset_email": true])
        let user = try UserFixtures.decoded()
        let reset = PasswordResetViewModel(user: user, admin: UserAdmin(viewModel: UsersViewModel(), client: makeClient(), sessionState: nil))
        XCTAssertFalse(reset.canSend, "not before the capability is read")

        await reset.load()

        XCTAssertTrue(reset.canSend)
    }

    func testResetEmailIsSubmittedOnceAndAnUncertainResultIsNeverRetriedByTheApp() async throws {
        http.state.stub(path: capabilitiesPath, json: ["available": true, "password_reset_email": true])
        http.state.stub(
            path: "\(userPath)/password-reset",
            json: ["delivery": "email", "delivery_status": "sent", "expires_at": "2026-01-02T03:04:05.678Z"], status: 201
        )
        let reset = PasswordResetViewModel(
            user: try UserFixtures.decoded(),
            admin: UserAdmin(viewModel: UsersViewModel(), client: makeClient(), sessionState: nil)
        )
        await reset.load()

        await reset.send()
        await reset.send()

        XCTAssertEqual(reset.receipt?.deliveryStatus, "sent")
        XCTAssertEqual(http.state.requests(path: "\(userPath)/password-reset").count, 1)
        XCTAssertFalse(reset.canSend)
    }

    func testResetEmailNeedsAnEmailAddress() async throws {
        http.state.stub(path: capabilitiesPath, json: ["available": true, "password_reset_email": true])
        let user = try UserFixtures.decoded(UserFixtures.user(overrides: ["email": ""]))
        let reset = PasswordResetViewModel(user: user, admin: UserAdmin(viewModel: UsersViewModel(), client: makeClient(), sessionState: nil))

        await reset.load()

        XCTAssertFalse(reset.canSend)
    }
}
