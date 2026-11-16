import XCTest
@testable import BloemAdmin

/// The Profiles tab in platform mode: add, rename, set or remove a PIN, and delete, through the admin profile routes.
@MainActor
final class UserProfilesViewModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let listPath = "/api/v2/admin/users/42/profiles"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func makeModel(serverName: String? = nil) -> UserProfilesViewModel {
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
        return UserProfilesViewModel(userID: "42", serverName: serverName, client: client, sessionState: nil)
    }

    private func profile(_ id: String, _ name: String, pin: Bool = false, primary: Bool = false, child: Bool = false) -> [String: Any] {
        [
            "id": id, "name": name, "has_pin": pin, "is_primary": primary, "is_child": child,
            "last_seen_at": "2026-02-03T04:05:06.000Z",
        ]
    }

    private func stubList(_ items: [[String: Any]]) {
        http.state.stub(path: listPath, json: ["items": items, "page": ["has_more": false]])
    }

    private func sentBody(_ path: String, at index: Int = 0) throws -> [String: String] {
        let data = try XCTUnwrap(http.state.body(path: path, requestIndex: index))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private func rawBody(_ path: String) throws -> String {
        String(decoding: try XCTUnwrap(http.state.body(path: path, requestIndex: 0)), as: UTF8.self)
    }

    private func methods(_ path: String) -> [String?] { http.state.requests(path: path).map(\.httpMethod) }

    func testListsTheProfilesWithPinPrimaryAndChildStated() async throws {
        stubList([profile("p1", "Main", pin: true, primary: true), profile("p2", "Kids", child: true)])
        let model = makeModel()

        await model.load()

        let profiles = try XCTUnwrap(model.profiles.value)
        XCTAssertEqual(profiles.map(\.name), ["Main", "Kids"])
        XCTAssertEqual(profiles.map(\.hasPIN), [true, false])
        XCTAssertEqual(profiles.map(\.isPrimary), [true, false])
        XCTAssertEqual(profiles.map(\.isChild), [false, true])
        XCTAssertNotNil(profiles[0].lastSeenAt)
    }

    func testAddPostsTheNameAndPinThenReadsTheListAgain() async throws {
        http.state.stubSequence(path: listPath, responses: [
            MockHTTPResponse(json: profile("p3", "Teens", pin: true), status: 201),
            MockHTTPResponse(json: ["items": [profile("p1", "Main", primary: true), profile("p3", "Teens", pin: true)], "page": ["has_more": false]]),
        ])
        let model = makeModel()

        let added = await model.add(name: "  Teens ", pin: "4321")

        XCTAssertTrue(added)
        XCTAssertEqual(try sentBody(listPath), ["name": "Teens", "pin": "4321"])
        XCTAssertEqual(methods(listPath), ["POST", "GET"], "the list is read again after the write")
        XCTAssertEqual(model.notice, "Profile Teens added")
        XCTAssertEqual(model.profiles.value?.map(\.name), ["Main", "Teens"])
    }

    func testAddWithoutAPinSendsNoPin() async throws {
        http.state.stubSequence(path: listPath, responses: [
            MockHTTPResponse(json: profile("p3", "Guest"), status: 201),
            MockHTTPResponse(json: ["items": [profile("p3", "Guest")], "page": ["has_more": false]]),
        ])
        let model = makeModel()

        _ = await model.add(name: "Guest", pin: nil)

        XCTAssertEqual(try sentBody(listPath), ["name": "Guest"])
    }

    func testRenamePatchesOnlyTheName() async throws {
        let path = "\(listPath)/p2"
        stubList([profile("p2", "Teens")])
        http.state.stub(path: path, json: profile("p2", "Teens"))
        let model = makeModel()
        await model.load()
        let kids = UserProfile(id: "p2", name: "Kids")

        let renamed = await model.rename(kids, to: " Teens ")

        XCTAssertTrue(renamed)
        XCTAssertEqual(methods(path), ["PATCH"])
        XCTAssertEqual(try sentBody(path), ["name": "Teens"])
        XCTAssertEqual(model.notice, "Profile renamed to Teens")
    }

    func testSettingAPinPatchesThePin() async throws {
        let path = "\(listPath)/p2"
        stubList([profile("p2", "Kids", pin: true)])
        http.state.stub(path: path, json: profile("p2", "Kids", pin: true))
        let model = makeModel()

        let done = await model.setPIN(UserProfile(id: "p2", name: "Kids"), to: "2468")

        XCTAssertTrue(done)
        XCTAssertEqual(try sentBody(path), ["pin": "2468"])
        XCTAssertEqual(model.notice, "PIN set on Kids")
    }

    func testRemovingAPinSendsAnExplicitNullNotAnOmission() async throws {
        let path = "\(listPath)/p2"
        stubList([profile("p2", "Kids")])
        http.state.stub(path: path, json: profile("p2", "Kids"))
        let model = makeModel()

        let done = await model.clearPIN(UserProfile(id: "p2", name: "Kids", hasPIN: true))

        XCTAssertTrue(done)
        XCTAssertEqual(try rawBody(path), #"{"pin":null}"#)
        XCTAssertEqual(model.notice, "PIN cleared on Kids")
    }

    func testRemovingAProfileDeletesItAndReadsTheListAgain() async throws {
        let path = "\(listPath)/p2"
        stubList([profile("p1", "Main", primary: true)])
        http.state.stub(path: path, data: Data(), status: 204)
        let model = makeModel()

        let done = await model.remove(UserProfile(id: "p2", name: "Kids"))

        XCTAssertTrue(done)
        XCTAssertEqual(methods(path), ["DELETE"])
        XCTAssertEqual(methods(listPath), ["GET"])
        XCTAssertEqual(model.notice, "Profile Kids removed")
        XCTAssertEqual(model.profiles.value?.map(\.name), ["Main"])
    }

    func testTheMainProfileOffersNoRemoval() {
        XCTAssertFalse(UserProfile(id: "p1", name: "Main", isPrimary: true).canRemove, "the server refuses it: delete the account instead")
        XCTAssertTrue(UserProfile(id: "p2", name: "Kids").canRemove)
    }

    func testOnlyTheOwnerMayChangeAnotherAdminsProfilesAndTheServerSaysSo() async throws {
        http.state.stub(
            path: listPath,
            data: Data(#"{"type":"https://example.test/problems/permission_denied","title":"Permission denied","status":403,"detail":"Only the server Owner may change another admin's profiles."}"#.utf8),
            status: 403
        )
        let model = makeModel()

        let done = await model.add(name: "Guest", pin: nil)

        XCTAssertFalse(done)
        XCTAssertEqual(model.errorMessage, "Only the server Owner may change another admin's profiles.")
        XCTAssertNil(model.notice)
    }

    func testAServersNameIsPutInFrontOfAnError() async {
        http.state.stub(path: listPath, data: Data(#"{"type":"https://example.test/problems/conflict","title":"Conflict","status":409,"detail":"A profile with that name already exists."}"#.utf8), status: 409)
        let model = makeModel(serverName: "Home")

        _ = await model.add(name: "Kids", pin: nil)

        XCTAssertEqual(model.errorMessage, "Home: A profile with that name already exists.")
    }

    func testAFailedWriteReadsTheListAgainSoThePageShowsWhatTheServerHolds() async {
        let path = "\(listPath)/p2"
        http.state.stub(path: path, data: Data(), status: 404)
        http.state.stub(path: listPath, json: ["items": [profile("p1", "Main", primary: true)], "page": ["has_more": false]])
        let model = makeModel()

        let done = await model.remove(UserProfile(id: "p2", name: "Kids"))

        XCTAssertFalse(done)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.profiles.value?.map(\.name), ["Main"])
    }

    func testAWriteWhileAnotherIsRunningIsIgnored() async throws {
        let path = "\(listPath)/p2"
        http.state.stub(path: path, response: MockHTTPResponse(json: profile("p2", "Kids")), delayUntilReleased: true)
        stubList([profile("p2", "Kids")])
        let model = makeModel()

        let first = Task { await model.rename(UserProfile(id: "p2", name: "Old"), to: "Kids") }
        await http.state.waitForRequest(path: path)
        let second = await model.rename(UserProfile(id: "p2", name: "Old"), to: "Other")
        http.state.releaseResponses(matching: path)
        let firstResult = await first.value

        XCTAssertFalse(second)
        XCTAssertTrue(firstResult)
        XCTAssertEqual(http.state.requests(path: path).count, 1)
    }

    func testPinsAndNamesFollowTheServersLimits() {
        XCTAssertEqual(ProfileInput.pinProblem(""), .empty)
        XCTAssertNil(ProfileInput.pinProblem("1234"))
        XCTAssertNil(ProfileInput.pinProblem(String(repeating: "9", count: 72)))
        XCTAssertEqual(ProfileInput.pinProblem(String(repeating: "9", count: 73)), .tooLong)
        XCTAssertEqual(ProfileInput.pinProblem(String(repeating: "é", count: 40)), .tooLong, "the limit is 72 bytes, not characters")

        XCTAssertEqual(ProfileInput.nameProblem("   "), .empty)
        XCTAssertNil(ProfileInput.nameProblem(" Kids "))
        XCTAssertNil(ProfileInput.nameProblem(String(repeating: "a", count: 64)))
        XCTAssertEqual(ProfileInput.nameProblem(String(repeating: "a", count: 65)), .tooLong)
    }

    func testTheProfilesTabIsOnlyOfferedWhenTheServerCanManageProfilesAndItSitsSecond() {
        XCTAssertEqual(UserTab.visible(accountDownloads: false, profileManagement: false), [.overview, .access, .signIn, .activity, .preferences])
        XCTAssertEqual(
            UserTab.visible(accountDownloads: true, profileManagement: true),
            [.overview, .profiles, .access, .signIn, .activity, .downloads, .preferences]
        )
        let capabilities = try? JSONDecoder().decode(UserCapabilities.self, from: Data(#"{"available":true,"profile_management":true}"#.utf8))
        XCTAssertEqual(capabilities?.profileManagement, true)
        XCTAssertEqual(try? JSONDecoder().decode(UserCapabilities.self, from: Data(#"{"available":true}"#.utf8)).profileManagement, false)
    }

    func testTheAdminMayManageProfilesWhereTheServerLetsThemWriteTheAccount() {
        func actions(role: String = "user", owner: Bool = false, id: String = "2", viewer: Viewer) -> UserActions {
            UserActions.resolve(
                for: AdminUser(id: id, username: "n", email: "n@example.test", role: role, enabled: true, maxStreams: nil, maxTranscodes: nil, isOwner: owner),
                viewer: viewer
            )
        }
        let admin = Viewer(id: "1", isOwner: false)
        XCTAssertTrue(actions(viewer: admin).canManageProfiles)
        XCTAssertTrue(actions(role: "admin", id: "1", viewer: admin).canManageProfiles, "every account may act on itself")
        XCTAssertFalse(actions(role: "admin", viewer: admin).canManageProfiles, "only the Owner changes another admin's profiles")
        XCTAssertFalse(actions(role: "admin", owner: true, viewer: admin).canManageProfiles)
        XCTAssertTrue(actions(role: "admin", viewer: Viewer(id: "9", isOwner: true)).canManageProfiles)
        XCTAssertFalse(UserActions.none.canManageProfiles)
    }
}
