import XCTest
@testable import BloemAdmin

/// These tests follow the server's real contract: `GET /api/v2/admin/settings/{key}` sends no
/// `ETag`, so the validator comes from `GET /api/v2/admin/settings/effective` and guards
/// `PUT /api/v2/admin/settings/{key}` through `If-Match` (server:internal/apiv2/admin_settings_*.go).
@MainActor
final class SettingEditorTests: XCTestCase {
    private let http = MockHTTPHarness()
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }

    private let effectivePath = "/api/v2/admin/settings/effective"
    private let keyPath = "/api/v2/admin/settings/s3.public_bucket"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func effective(_ values: [String: String], etag: String?) -> MockHTTPResponse {
        MockHTTPResponse(json: values, status: 200, headers: etag.map { ["ETag": $0] } ?? [:])
    }

    private func receipt(value: String, restartRequired: Bool = false) -> MockHTTPResponse {
        var json: [String: Any] = ["key": "s3.public_bucket", "value": value]
        if restartRequired { json["restart_required"] = true }
        return MockHTTPResponse(json: json)
    }

    private let conflict = MockHTTPResponse(
        data: Data(#"{"type":"https://example.test/problems/precondition_failed","title":"Precondition Failed","status":412,"detail":"The settings changed."}"#.utf8),
        status: 412,
        headers: ["Content-Type": "application/problem+json"]
    )

    private func putRequests(path: String? = nil) -> [URLRequest] {
        http.state.requestLog.filter { $0.httpMethod == "PUT" && (path == nil || $0.url?.path == path) }
    }

    func testOpenTakesTheValueAndValidatorFromTheEffectiveSettingsRead() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old", "other": "x"], etag: "\"r1\"")])
        let editor = SettingEditor(key: "s3.public_bucket")

        await editor.open(client: client)

        XCTAssertEqual(editor.snapshot?.value, "old")
        XCTAssertEqual(editor.snapshot?.validator, "\"r1\"")
        XCTAssertEqual(editor.draft, "old")
        XCTAssertNil(editor.errorMessage)
    }

    func testOpenNeverReadsTheSingleSettingRoute() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: "\"r1\"")])
        let editor = SettingEditor(key: "s3.public_bucket")

        await editor.open(client: client)

        XCTAssertEqual(http.state.requestLog.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["GET \(effectivePath)"])
    }

    func testAKeyAbsentFromTheEffectiveReadOpensWithAnEmptyValue() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["other": "x"], etag: "\"r1\"")])
        let editor = SettingEditor(key: "s3.public_bucket")

        await editor.open(client: client)

        XCTAssertEqual(editor.snapshot?.value, "")
        XCTAssertEqual(editor.snapshot?.validator, "\"r1\"")
    }

    func testMissingETagRefusesTheEditAndSaysWhatToDo() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: nil)])
        let editor = SettingEditor(key: "s3.public_bucket")

        await editor.open(client: client)

        XCTAssertNil(editor.snapshot)
        XCTAssertEqual(editor.errorMessage, "The server did not send a version for its settings, so this setting cannot be changed safely. Update the server, then try again")
        XCTAssertFalse(editor.canSave)
        let saved = await editor.save(client: client)
        XCTAssertFalse(saved)
        XCTAssertTrue(putRequests().isEmpty)
    }

    func testSaveSendsTheEffectiveETagAsIfMatchWithoutReReadingFirst() async throws {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: "\"r1\"")])
        http.state.stubSequence(path: keyPath, responses: [receipt(value: "new")])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)
        editor.draft = "new"

        let saved = await editor.save(client: client)

        XCTAssertTrue(saved)
        XCTAssertEqual(http.state.requestLog.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["GET \(effectivePath)", "PUT \(keyPath)"])
        XCTAssertEqual(putRequests().first?.value(forHTTPHeaderField: "If-Match"), "\"r1\"")
        XCTAssertEqual(http.state.capturedBody, Data(#"{"value":"new"}"#.utf8))
    }

    func testSaveKeepsTheReceiptAndItsRestartFlag() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: "\"r1\"")])
        http.state.stubSequence(path: keyPath, responses: [receipt(value: "new", restartRequired: true)])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)
        editor.draft = "new"

        _ = await editor.save(client: client)

        XCTAssertEqual(editor.receipt?.key, "s3.public_bucket")
        XCTAssertEqual(editor.receipt?.value, "new")
        XCTAssertEqual(editor.receipt?.restartRequired, true)
    }

    func testReceiptWithoutRestartFlagMeansNoRestartNeeded() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: "\"r1\"")])
        http.state.stubSequence(path: keyPath, responses: [receipt(value: "new")])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)
        editor.draft = "new"

        _ = await editor.save(client: client)

        XCTAssertEqual(editor.receipt?.restartRequired, false)
    }

    func testKeyIsEncodedAsOnePathSegment() async throws {
        http.state.stubSequence(path: effectivePath, responses: [effective(["a b/c": "v"], etag: "\"r1\"")])
        http.state.stub(path: "/api/v2/admin/settings/a b/c", data: Data(#"{"key":"a b/c","value":"w"}"#.utf8))
        let editor = SettingEditor(key: "a b/c")
        await editor.open(client: client)
        editor.draft = "w"

        _ = await editor.save(client: client)

        let request = try XCTUnwrap(putRequests().first)
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.percentEncodedPath, "/api/v2/admin/settings/a%20b%2Fc")
    }

    func testUnchangedDraftCannotBeSaved() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: "\"r1\"")])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)

        XCTAssertFalse(editor.canSave)
        editor.draft = "new"
        XCTAssertTrue(editor.canSave)
    }

    func testStaleETagReReadsAndOffersTheNewValueWhileKeepingTheDraft() async throws {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["s3.public_bucket": "old"], etag: "\"r1\""),
            effective(["s3.public_bucket": "theirs"], etag: "\"r2\""),
        ])
        http.state.stubSequence(path: keyPath, responses: [conflict, receipt(value: "mine")])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)
        editor.draft = "mine"

        let saved = await editor.save(client: client)

        XCTAssertFalse(saved)
        XCTAssertTrue(editor.hasConflict)
        XCTAssertEqual(editor.conflictMessage, "Settings changed on the server")
        XCTAssertEqual(editor.latest?.value, "theirs")
        XCTAssertEqual(editor.draft, "mine")
        XCTAssertFalse(editor.canSave)
        XCTAssertEqual(putRequests().count, 1)

        editor.adoptCurrent()
        XCTAssertFalse(editor.hasConflict)
        XCTAssertEqual(editor.draft, "mine")
        XCTAssertTrue(editor.canSave)

        let savedAgain = await editor.save(client: client)
        XCTAssertTrue(savedAgain)
        XCTAssertEqual(putRequests().last?.value(forHTTPHeaderField: "If-Match"), "\"r2\"")
    }

    func testUsingTheCurrentValueReplacesTheDraftAndTakesTheNewRevision() async {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["s3.public_bucket": "old"], etag: "\"r1\""),
            effective(["s3.public_bucket": "theirs"], etag: "\"r2\""),
        ])
        http.state.stubSequence(path: keyPath, responses: [conflict])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)
        editor.draft = "mine"
        _ = await editor.save(client: client)

        editor.useCurrent()

        XCTAssertEqual(editor.draft, "theirs")
        XCTAssertFalse(editor.hasConflict)
        XCTAssertEqual(editor.snapshot?.validator, "\"r2\"")
        XCTAssertFalse(editor.canSave)
    }

    func testConflictWhoseReReadFailsStillOffersReview() async {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["s3.public_bucket": "old"], etag: "\"r1\""),
            MockHTTPResponse(data: Data(#"{"error":"boom","message":"Down"}"#.utf8), status: 500),
            effective(["s3.public_bucket": "theirs"], etag: "\"r2\""),
        ])
        http.state.stubSequence(path: keyPath, responses: [conflict])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)
        editor.draft = "mine"

        _ = await editor.save(client: client)
        XCTAssertTrue(editor.hasConflict)
        XCTAssertNil(editor.latest)

        await editor.reviewCurrent(client: client)
        XCTAssertEqual(editor.latest?.value, "theirs")
    }

    func testOtherFailureKeepsTheDraftAndShowsTheServerMessage() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: "\"r1\"")])
        http.state.stubSequence(path: keyPath, responses: [
            MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Not authorized to change this setting"}"#.utf8), status: 403),
        ])
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client)
        editor.draft = "mine"

        let saved = await editor.save(client: client)

        XCTAssertFalse(saved)
        XCTAssertFalse(editor.hasConflict)
        XCTAssertEqual(editor.errorMessage, "Not authorized to change this setting")
        XCTAssertEqual(editor.draft, "mine")
    }

    func testSave401FlagsSessionStateTokenExpired() async {
        http.state.stubSequence(path: effectivePath, responses: [effective(["s3.public_bucket": "old"], etag: "\"r1\"")])
        http.state.stubSequence(path: keyPath, responses: [
            MockHTTPResponse(data: Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), status: 401),
        ])
        let root = AdminSessionState()
        root.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: root.credentialProvider(serverID: "srv-1"),
            session: http.session
        )
        let scoped = root.scoped(to: "srv-1")
        let editor = SettingEditor(key: "s3.public_bucket")
        await editor.open(client: client, sessionState: scoped)
        editor.draft = "mine"

        _ = await editor.save(client: client, sessionState: scoped)

        XCTAssertTrue(scoped.tokenExpired)
        XCTAssertEqual(editor.errorMessage, "Token expired")
    }

    func testAggregateEditorNamesTheServerInTitleConflictAndErrors() async {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["s3.public_bucket": "old"], etag: "\"r1\""),
            effective(["s3.public_bucket": "theirs"], etag: "\"r2\""),
            MockHTTPResponse(data: Data(#"{"error":"forbidden","message":"Not allowed"}"#.utf8), status: 403),
        ])
        http.state.stubSequence(path: keyPath, responses: [conflict])
        let editor = SettingEditor(key: "s3.public_bucket", serverName: "Home")
        XCTAssertEqual(editor.title, "Home · s3.public_bucket")
        XCTAssertEqual(SettingEditor(key: "k").title, "k")
        await editor.open(client: client)
        editor.draft = "mine"
        _ = await editor.save(client: client)
        XCTAssertTrue(editor.hasConflict)
        XCTAssertEqual(editor.conflictMessage, "Settings changed on Home")
        await editor.reviewCurrent(client: client)
        XCTAssertEqual(editor.errorMessage, "Home: Not allowed")
    }
}
