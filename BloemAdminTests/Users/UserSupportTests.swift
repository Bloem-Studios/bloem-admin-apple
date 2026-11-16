import XCTest
@testable import BloemAdmin

/// Helping a locked-out person back in from the User page: a reset link to hand over, and a temporary password.
@MainActor
final class UserResetLinkTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let capabilitiesPath = "/api/v2/admin/users/capabilities"
    private let resetPath = "/api/v2/admin/users/42/password-reset"
    private let secretURL = "https://media.example.test/reset-password#SECRET-TOKEN-7f3a"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func makeModel(_ overrides: [String: Any] = [:]) throws -> PasswordResetViewModel {
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
        let user = try UserFixtures.decoded(UserFixtures.user(overrides: overrides))
        return PasswordResetViewModel(user: user, admin: UserAdmin(viewModel: UsersViewModel(), client: client, sessionState: nil))
    }

    private func stubCapabilities(link: Bool = true, email: Bool = false) {
        http.state.stub(path: capabilitiesPath, json: ["available": true, "password_reset_link": link, "password_reset_email": email])
    }

    private func stubLink(url: String? = nil) {
        var body: [String: Any] = ["delivery": "link", "delivery_status": "not_requested", "expires_at": "2026-01-02T03:04:05.678Z"]
        body["reset_url"] = url ?? secretURL
        http.state.stub(path: resetPath, json: body, status: 201)
    }

    private func dumped(_ value: Any) -> String {
        var text = ""
        dump(value, to: &text)
        return text
    }

    func testALinkIsOnlyOfferedWhenTheServerCanMakeOneAndTheAccountCanUseOne() async throws {
        stubCapabilities(link: true)
        let model = try makeModel()
        XCTAssertFalse(model.canCreateLink, "not before the capability is read")
        await model.load()
        XCTAssertTrue(model.isLinkAvailable)
        XCTAssertTrue(model.canCreateLink)

        stubCapabilities(link: false)
        let withoutLinks = try makeModel()
        await withoutLinks.load()
        XCTAssertFalse(withoutLinks.canCreateLink)

        stubCapabilities(link: true)
        let disabled = try makeModel(["enabled": false])
        await disabled.load()
        XCTAssertFalse(disabled.canCreateLink, "the server refuses a link for a disabled account")

        let external = try makeModel(["password_login": false])
        await external.load()
        XCTAssertFalse(external.canCreateLink, "an account without password sign-in gets a temporary password instead")
    }

    func testCreateLinkAsksForDeliveryLinkOnceAndShowsTheLink() async throws {
        stubCapabilities()
        stubLink()
        let model = try makeModel()
        await model.load()

        await model.createLink()
        await model.createLink()

        let sent = try XCTUnwrap(http.state.body(path: resetPath, requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent) as? [String: String], ["delivery": "link"])
        XCTAssertEqual(http.state.requests(path: resetPath).count, 1, "an uncertain result is never sent twice by the app")
        XCTAssertEqual(model.link?.url, secretURL)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(model.link?.expiresAt, formatter.date(from: "2026-01-02T03:04:05.678Z"))
        XCTAssertFalse(model.canCreateLink)
        XCTAssertFalse(model.canSend, "one reset per time the sheet is open")
        XCTAssertNil(model.errorMessage)
    }

    func testForgettingTheLinkLeavesNothingOfIt() async throws {
        stubCapabilities()
        stubLink()
        let model = try makeModel()
        await model.load()
        await model.createLink()
        XCTAssertNotNil(model.link)

        model.forgetLink()

        XCTAssertNil(model.link)
        XCTAssertNil(model.receipt)
        XCTAssertFalse(dumped(model).contains("SECRET-TOKEN"), "the model holds no copy of the link")
    }

    func testTheLinkNeverReachesALogOrADump() async throws {
        stubCapabilities()
        stubLink()
        let model = try makeModel()
        await model.load()
        await model.createLink()
        let link = try XCTUnwrap(model.link)

        for text in [String(describing: link), String(reflecting: link), dumped(link), "\(link)"] {
            XCTAssertFalse(text.contains("SECRET-TOKEN"), "printing the link must not print the secret: \(text)")
        }
        let receipt = try JSONDecoder.iso8601.decode(
            PasswordResetReceipt.self,
            from: Data(#"{"delivery":"link","delivery_status":"not_requested","reset_url":"\#(secretURL)","expires_at":"2026-01-02T03:04:05.678Z"}"#.utf8)
        )
        XCTAssertEqual(receipt.resetURL, secretURL, "it is decoded for the sheet to show")
        for text in [String(describing: receipt), String(reflecting: receipt), dumped(receipt)] {
            XCTAssertFalse(text.contains("SECRET-TOKEN"), "nor does the receipt it came in: \(text)")
        }
    }

    func testAnAnswerWithoutALinkIsSaidPlainly() async throws {
        stubCapabilities()
        http.state.stub(path: resetPath, json: ["delivery": "link", "delivery_status": "not_requested", "expires_at": "2026-01-02T03:04:05.678Z"], status: 201)
        let model = try makeModel()
        await model.load()

        await model.createLink()

        XCTAssertNil(model.link)
        XCTAssertEqual(model.errorMessage, "The server didn't return a link. Close this and create another one.")
    }

    func testARefusalShowsTheServersReasonAndShowsNoLink() async throws {
        stubCapabilities()
        http.state.stub(
            path: resetPath,
            data: Data(#"{"type":"https://example.test/problems/conflict","title":"Conflict","status":409,"detail":"The account is disabled."}"#.utf8),
            status: 409
        )
        let model = try makeModel()
        await model.load()

        await model.createLink()

        XCTAssertNil(model.link)
        XCTAssertEqual(model.errorMessage, "The account is disabled.")
    }

    func testAnEmailedResetStillWorksAndCarriesNoLink() async throws {
        stubCapabilities(link: true, email: true)
        http.state.stub(path: resetPath, json: ["delivery": "email", "delivery_status": "sent", "expires_at": "2026-01-02T03:04:05.678Z"], status: 201)
        let model = try makeModel()
        await model.load()

        await model.send()

        XCTAssertEqual(model.receipt?.deliveryStatus, "sent")
        XCTAssertNil(model.receipt?.resetURL)
        XCTAssertNil(model.link)
        let sent = try XCTUnwrap(http.state.body(path: resetPath, requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: sent) as? [String: String], ["delivery": "email"])
    }
}

final class UserTemporaryPasswordTests: XCTestCase {
    private func user(role: String = "user", enabled: Bool = true, owner: Bool = false, passwordLogin: Bool = true) -> AdminUser {
        AdminUser(
            id: "2", username: "name", email: "n@example.test", role: role, enabled: enabled,
            maxStreams: nil, maxTranscodes: nil, passwordLogin: passwordLogin, isOwner: owner
        )
    }

    func testATemporaryPasswordIsOfferedOnEveryEnabledAccountTheAdminMayManage() {
        let admin = Viewer(id: "1", isOwner: false)
        XCTAssertTrue(UserActions.resolve(for: user(passwordLogin: true), viewer: admin).canSetPassword, "a password account too")
        XCTAssertTrue(UserActions.resolve(for: user(passwordLogin: false), viewer: admin).canSetPassword)
        XCTAssertFalse(UserActions.resolve(for: user(enabled: false), viewer: admin).canSetPassword, "enable the account first")
        XCTAssertFalse(UserActions.resolve(for: user(role: "admin"), viewer: admin).canSetPassword, "only the owner changes another admin")
        XCTAssertTrue(UserActions.resolve(for: user(role: "admin"), viewer: Viewer(id: "9", isOwner: true)).canSetPassword)
    }

    func testATemporaryPasswordNeverReachesALogOrADumpOnItsWayToTheServer() {
        let request = SetPasswordRequest(password: "hunter2-secret-pw", requireChange: true)
        var dumped = ""
        dump(request, to: &dumped)

        for text in [String(describing: request), String(reflecting: request), "\(request)", dumped] {
            XCTAssertFalse(text.contains("hunter2-secret-pw"), "printing the request must not print the password: \(text)")
        }
        let body = try? JSONEncoder().encode(request)
        XCTAssertTrue(body.map { String(decoding: $0, as: UTF8.self).contains("hunter2-secret-pw") } ?? false, "it is still sent in the body")
    }

    func testTheSheetSaysWhatSettingAPasswordDoesForThatAccount() {
        XCTAssertEqual(SetPasswordCopy.title(hasPasswordSignIn: true), "Set a temporary password")
        XCTAssertEqual(SetPasswordCopy.title(hasPasswordSignIn: false), "Set a password")
        XCTAssertTrue(SetPasswordCopy.intro(hasPasswordSignIn: true, name: "bob").contains("replaces"))
        XCTAssertTrue(SetPasswordCopy.intro(hasPasswordSignIn: false, name: "bob").contains("turns password sign-in back on"))
    }
}
