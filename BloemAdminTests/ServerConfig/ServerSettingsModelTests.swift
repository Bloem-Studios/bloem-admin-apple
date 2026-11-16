import XCTest
@testable import BloemAdmin

/// The server's real contract, read from the server: `GET /settings/effective` sends
/// the `ETag` of the whole settings snapshot; `PUT /settings` takes `{"values":{...}}` with `If-Match`
/// and answers the saved values, `restart_required` and the new `ETag`; a stale tag is 412.
@MainActor
final class ServerSettingsModelTests: XCTestCase {
    private let http = MockHTTPHarness()
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }

    private let effectivePath = "/api/v2/admin/settings/effective"
    private let writePath = "/api/v2/admin/settings"

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func status(restartRequired: Bool = false, reasons: [String] = []) -> MockHTTPResponse {
        MockHTTPResponse(json: [
            "started_at": "2026-11-14T08:00:00.000Z", "restart_required": restartRequired, "restart_requested": false,
            "restart_required_reasons": reasons, "restart_mark_count": reasons.count,
        ])
    }

    private func effective(_ values: [String: String], etag: String) -> MockHTTPResponse {
        MockHTTPResponse(json: values, headers: ["ETag": etag])
    }

    /// Stubs every read the model makes.
    private func stubReads(
        values: [String: String] = ["server.log_level": "info", "server.public_url": ""], etag: String = "\"r1\"",
        restartKeys: [String] = ["server.public_url"], prefixes: [String] = ["jellyfin_compat."],
        configured: [String] = ["email.smtp_password"], managed: [String] = ["clientip.trusted_proxies"]
    ) {
        http.state.stubSequence(path: effectivePath, responses: [effective(values, etag: etag)])
        http.state.stub(path: "/api/v2/admin/settings/restart-keys", json: ["keys": restartKeys, "prefixes": prefixes])
        http.state.stub(path: "/api/v2/admin/settings/sensitive-status", json: ["configured": configured, "managed_by_env": managed])
        http.state.stub(path: "/api/v2/admin/server/status", response: status())
    }

    private func puts() -> [URLRequest] {
        http.state.requestLog.filter { $0.httpMethod == "PUT" && $0.url?.path == writePath }
    }

    /// The `values` of the last write's body.
    private func sentValues(_ request: URLRequest, at index: Int = 0) throws -> [String: String] {
        let body = try XCTUnwrap(http.state.body(path: writePath, requestIndex: index))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: [String: String]])
        return try XCTUnwrap(object["values"])
    }

    private let conflict = MockHTTPResponse(
        data: Data(#"{"type":"https://example.test/problems/precondition_failed","title":"Precondition Failed","status":412,"detail":"Settings changed."}"#.utf8),
        status: 412, headers: ["Content-Type": "application/problem+json"]
    )

    // MARK: Reading

    func testLoadListsEffectiveSettingsSoKeysAtTheirDefaultAppear() async {
        stubReads(values: ["server.log_level": "info", "playback.transcode_enabled": "true"])
        let model = ServerSettingsModel()

        await model.load(client: client)

        XCTAssertEqual(model.value(for: "server.log_level"), "info")
        XCTAssertEqual(model.value(for: "playback.transcode_enabled"), "true")
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.loadFailure)
        let paths = http.state.requestLog.map { $0.url?.path ?? "" }
        XCTAssertTrue(paths.contains(effectivePath))
        XCTAssertFalse(paths.contains("/api/v2/admin/settings"), "the stored-only list is no longer read")
    }

    func testRestartKeysMarkExactKeysAndPrefixes() async {
        stubReads(restartKeys: ["server.public_url"], prefixes: ["jellyfin_compat."])
        let model = ServerSettingsModel()

        await model.load(client: client)

        XCTAssertTrue(model.requiresRestart("server.public_url"))
        XCTAssertTrue(model.requiresRestart("jellyfin_compat.enabled"))
        XCTAssertFalse(model.requiresRestart("server.log_level"))
    }

    func testSecretsShowOnlyWhetherTheyAreSetAndNeverAValue() async {
        stubReads(values: ["email.smtp_host": "smtp.example.test"], configured: ["email.smtp_password"], managed: ["clientip.trusted_proxies"])
        let model = ServerSettingsModel()

        await model.load(client: client)

        XCTAssertTrue(model.isSecretSet("email.smtp_password"))
        XCTAssertFalse(model.isSecretSet("redis.url"))
        XCTAssertEqual(model.value(for: "email.smtp_password"), "")
        XCTAssertTrue(model.isManagedByEnvironment("clientip.trusted_proxies"))
        XCTAssertFalse(model.isManagedByEnvironment("server.public_url"))
    }

    func testSecretStatusFailureDoesNotBlockThePage() async {
        stubReads()
        http.state.stub(path: "/api/v2/admin/settings/sensitive-status", response: MockHTTPResponse(data: Data(), status: 503))
        let model = ServerSettingsModel()

        await model.load(client: client)

        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.sensitiveUnavailable)
    }

    func testEffectiveFailureOnFirstLoadIsATypedFailureWithRetry() async {
        http.state.stub(path: effectivePath, response: MockHTTPResponse(data: Data(#"{"error":"boom","message":"Settings are down"}"#.utf8), status: 500))
        http.state.stub(path: "/api/v2/admin/server/status", response: status())
        let model = ServerSettingsModel()

        await model.load(client: client)

        XCTAssertFalse(model.hasLoaded)
        XCTAssertEqual(model.loadFailure?.message, "Settings are down")
    }

    func testStoredKeysTheCatalogueDoesNotNameAreOtherSettings() async {
        stubReads(values: ["server.log_level": "info", "scanner.workers": "8", "a.custom": "x"])
        let model = ServerSettingsModel()

        await model.load(client: client)

        XCTAssertEqual(model.otherKeys, ["a.custom", "scanner.workers"])
    }

    // MARK: Editing

    func testAnEditThatMatchesTheServerIsNoEdit() async {
        stubReads()
        let model = ServerSettingsModel()
        await model.load(client: client)

        model.setDraft("debug", for: "server.log_level")
        XCTAssertTrue(model.isDirty("server.log_level"))
        XCTAssertEqual(model.value(for: "server.log_level"), "debug")
        XCTAssertEqual(model.dirtyKeys(in: ["server.log_level", "server.public_url"]), ["server.log_level"])

        model.setDraft("info", for: "server.log_level")
        XCTAssertFalse(model.isDirty("server.log_level"))
        XCTAssertFalse(model.hasUnsavedEdits)
    }

    func testASecretEditStaysEvenWhenEmptySoItCanClearTheSecret() async {
        stubReads()
        let model = ServerSettingsModel()
        await model.load(client: client)

        model.setDraft("", for: "email.smtp_password", secret: true)

        XCTAssertTrue(model.isDirty("email.smtp_password"))
        XCTAssertFalse(model.isSecretSet("email.smtp_password"), "a staged clear reads as not set")
    }

    // MARK: Saving

    func testSaveSendsOnlyThePagesEditedKeysInOneWriteWithTheValidator() async throws {
        stubReads()
        http.state.stubSequence(path: writePath, responses: [
            MockHTTPResponse(json: ["values": ["server.log_level": "debug"], "restart_required": false], headers: ["ETag": "\"r2\""]),
        ])
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("debug", for: "server.log_level")
        model.setDraft("https://x.test", for: "server.public_url")

        let outcome = await model.save(keys: ["server.log_level"], client: client)

        XCTAssertEqual(outcome, .saved)
        let request = try XCTUnwrap(puts().first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"r1\"")
        XCTAssertEqual(try sentValues(request), ["server.log_level": "debug"])
        XCTAssertFalse(model.isDirty("server.log_level"))
        XCTAssertTrue(model.isDirty("server.public_url"), "an edit on another page stays")
        XCTAssertEqual(model.value(for: "server.log_level"), "debug")
        XCTAssertEqual(model.baseValidator, "\"r2\"")
    }

    func testSaveNoticeNamesTheSettingsThatNeedARestart() async {
        stubReads()
        http.state.stubSequence(path: writePath, responses: [
            MockHTTPResponse(
                json: ["values": ["server.public_url": "https://x.test"], "restart_required": true, "restart_required_keys": ["server.public_url"]],
                headers: ["ETag": "\"r2\""]
            ),
        ])
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("https://x.test", for: "server.public_url")

        _ = await model.save(keys: ["server.public_url"], client: client)

        XCTAssertEqual(model.lastSave?.restartRequired, true)
        XCTAssertEqual(model.lastSave?.restartLabels, ["Public URL"])
    }

    func testSavingASecretClearsItsEditAndUpdatesWhetherItIsSet() async throws {
        stubReads(configured: [])
        http.state.stubSequence(path: writePath, responses: [
            MockHTTPResponse(json: ["values": ["email.smtp_password": ""], "restart_required": false], headers: ["ETag": "\"r2\""]),
        ])
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("hunter2", for: "email.smtp_password", secret: true)
        XCTAssertTrue(model.isSecretSet("email.smtp_password"))

        let outcome = await model.save(keys: ["email.smtp_password"], client: client)

        XCTAssertEqual(outcome, .saved)
        XCTAssertEqual(try sentValues(XCTUnwrap(puts().first)), ["email.smtp_password": "hunter2"])
        XCTAssertFalse(model.isDirty("email.smtp_password"))
        XCTAssertTrue(model.isSecretSet("email.smtp_password"), "set, though the value never comes back")
        XCTAssertEqual(model.value(for: "email.smtp_password"), "")
    }

    func testStaleValidatorKeepsTheEditsAndOffersTheServersValues() async throws {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["server.log_level": "info"], etag: "\"r1\""),
            effective(["server.log_level": "warn"], etag: "\"r2\""),
        ])
        http.state.stub(path: "/api/v2/admin/settings/restart-keys", json: ["keys": [String](), "prefixes": [String]()])
        http.state.stub(path: "/api/v2/admin/settings/sensitive-status", json: ["configured": [String](), "managed_by_env": [String]()])
        http.state.stub(path: "/api/v2/admin/server/status", response: status())
        http.state.stubSequence(path: writePath, responses: [
            conflict,
            MockHTTPResponse(json: ["values": ["server.log_level": "debug"], "restart_required": false], headers: ["ETag": "\"r3\""]),
        ])
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("debug", for: "server.log_level")

        let outcome = await model.save(keys: ["server.log_level"], client: client)

        XCTAssertEqual(outcome, .conflict)
        XCTAssertTrue(model.showsConflict)
        XCTAssertEqual(model.value(for: "server.log_level"), "debug", "the person's edit stays visible")
        XCTAssertEqual(model.serverValue(for: "server.log_level"), "warn")
        XCTAssertEqual(puts().count, 1)

        model.keepMyChanges()
        XCTAssertFalse(model.showsConflict)
        let again = await model.save(keys: ["server.log_level"], client: client)
        XCTAssertEqual(again, .saved)
        XCTAssertEqual(puts().last?.value(forHTTPHeaderField: "If-Match"), "\"r2\"")
    }

    func testUsingTheServersValuesDropsOnlyTheEditsThatChangedThere() async {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["server.log_level": "info", "server.public_url": ""], etag: "\"r1\""),
            effective(["server.log_level": "warn", "server.public_url": ""], etag: "\"r2\""),
        ])
        http.state.stub(path: "/api/v2/admin/settings/restart-keys", json: ["keys": [String](), "prefixes": [String]()])
        http.state.stub(path: "/api/v2/admin/settings/sensitive-status", json: ["configured": [String](), "managed_by_env": [String]()])
        http.state.stub(path: "/api/v2/admin/server/status", response: status())
        http.state.stubSequence(path: writePath, responses: [conflict])
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("debug", for: "server.log_level")
        model.setDraft("https://x.test", for: "server.public_url")
        _ = await model.save(keys: ["server.log_level", "server.public_url"], client: client)

        model.useServerValues()

        XCTAssertEqual(model.value(for: "server.log_level"), "warn")
        XCTAssertFalse(model.isDirty("server.log_level"))
        XCTAssertTrue(model.isDirty("server.public_url"))
        XCTAssertFalse(model.hasConflict)
    }

    func testARefreshWhileEditingDoesNotMoveTheBaselineAndSaysTheServerChanged() async {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["server.log_level": "info"], etag: "\"r1\""),
            effective(["server.log_level": "error"], etag: "\"r2\""),
        ])
        http.state.stub(path: "/api/v2/admin/settings/restart-keys", json: ["keys": [String](), "prefixes": [String]()])
        http.state.stub(path: "/api/v2/admin/settings/sensitive-status", json: ["configured": [String](), "managed_by_env": [String]()])
        http.state.stub(path: "/api/v2/admin/server/status", response: status())
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("debug", for: "server.log_level")

        await model.load(client: client)

        XCTAssertEqual(model.baseValidator, "\"r1\"")
        XCTAssertEqual(model.latestValidator, "\"r2\"")
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.staleKeys, ["server.log_level"])
        XCTAssertEqual(model.value(for: "server.log_level"), "debug")
    }

    func testARefreshWithNoEditsTakesTheNewSnapshot() async {
        http.state.stubSequence(path: effectivePath, responses: [
            effective(["server.log_level": "info"], etag: "\"r1\""),
            effective(["server.log_level": "error"], etag: "\"r2\""),
        ])
        http.state.stub(path: "/api/v2/admin/settings/restart-keys", json: ["keys": [String](), "prefixes": [String]()])
        http.state.stub(path: "/api/v2/admin/settings/sensitive-status", json: ["configured": [String](), "managed_by_env": [String]()])
        http.state.stub(path: "/api/v2/admin/server/status", response: status())
        let model = ServerSettingsModel()
        await model.load(client: client)

        await model.load(client: client)

        XCTAssertEqual(model.value(for: "server.log_level"), "error")
        XCTAssertEqual(model.baseValidator, "\"r2\"")
        XCTAssertFalse(model.isStale)
    }

    func testBreakGlassRefusalIsExplainedAndTheEditStays() async {
        stubReads(values: ["auth.local_password_login": "true"])
        http.state.stubSequence(path: writePath, responses: [
            MockHTTPResponse(
                data: Data(#"{"type":"https://example.test/problems/break_glass_required","title":"Conflict","status":409,"detail":"x"}"#.utf8),
                status: 409, headers: ["Content-Type": "application/problem+json"]
            ),
        ])
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("false", for: "auth.local_password_login")

        let outcome = await model.save(keys: ["auth.local_password_login"], client: client)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(model.saveError?.hasPrefix("Password sign-in can't be turned off yet") == true)
        XCTAssertTrue(model.isDirty("auth.local_password_login"))
    }

    func testAServerWithoutAValidatorCannotBeWrittenTo() async {
        http.state.stubSequence(path: effectivePath, responses: [MockHTTPResponse(json: ["server.log_level": "info"])])
        http.state.stub(path: "/api/v2/admin/settings/restart-keys", json: ["keys": [String](), "prefixes": [String]()])
        http.state.stub(path: "/api/v2/admin/settings/sensitive-status", json: ["configured": [String](), "managed_by_env": [String]()])
        http.state.stub(path: "/api/v2/admin/server/status", response: status())
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("debug", for: "server.log_level")

        let outcome = await model.save(keys: ["server.log_level"], client: client)

        XCTAssertEqual(outcome, .failed)
        XCTAssertNotNil(model.saveError)
        XCTAssertTrue(puts().isEmpty)
    }

    func testAValidationRefusalShowsTheServersWordsAndKeepsTheEdits() async {
        stubReads()
        http.state.stubSequence(path: writePath, responses: [
            MockHTTPResponse(
                data: Data(#"{"type":"https://example.test/problems/validation_failed","title":"Invalid","status":400,"detail":"server.public_url must be an HTTPS address"}"#.utf8),
                status: 400, headers: ["Content-Type": "application/problem+json"]
            ),
        ])
        let model = ServerSettingsModel()
        await model.load(client: client)
        model.setDraft("ftp://x", for: "server.public_url")

        let outcome = await model.save(keys: ["server.public_url"], client: client)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(model.saveError, "server.public_url must be an HTTPS address")
        XCTAssertTrue(model.isDirty("server.public_url"))
    }

    func testNamedServerPrefixesItsErrors() async {
        stubReads()
        http.state.stubSequence(path: writePath, responses: [MockHTTPResponse(data: Data(#"{"error":"x","message":"No"}"#.utf8), status: 500)])
        let model = ServerSettingsModel(serverName: "Alpha")
        await model.load(client: client)
        model.setDraft("debug", for: "server.log_level")

        _ = await model.save(keys: ["server.log_level"], client: client)

        XCTAssertEqual(model.saveError, "Alpha: No")
    }

    // MARK: Restart

    func testRestartPostsAnEmptyBodyAndSaysWhatHappened() async {
        stubReads()
        http.state.stub(path: "/api/v2/admin/server/restart", response: MockHTTPResponse(
            json: ["status": "restart_requested", "message": "ok", "notified_sessions": 3], status: 202
        ))
        let model = ServerSettingsModel()

        await model.restartServer(client: client)

        XCTAssertEqual(http.state.requestLog.first { $0.url?.path == "/api/v2/admin/server/restart" }?.httpMethod, "POST")
        XCTAssertEqual(model.restartNotice, "Restart requested. 3 streams were told")
        XCTAssertNil(model.restartError)
    }

    func testRestartAlreadyRequestedIsSaidSo() async {
        stubReads()
        http.state.stub(path: "/api/v2/admin/server/restart", response: MockHTTPResponse(
            json: ["status": "already_requested", "message": "", "notified_sessions": 0], status: 202
        ))
        let model = ServerSettingsModel()

        await model.restartServer(client: client)

        XCTAssertEqual(model.restartNotice, "A restart is already in progress")
    }

    func testRestartFailureClearsTheNoticeAndFlagsAnExpiredSession() async {
        http.state.stub(path: "/api/v2/admin/server/restart", response: MockHTTPResponse(data: Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), status: 401))
        let root = AdminSessionState()
        root.setAdministratorToken("admin-token", serverID: "srv-1")
        let scoped = root.scoped(to: "srv-1")
        let sessionClient = APIClient(baseURL: URL(string: "https://example.test")!, credentialProvider: root.credentialProvider(serverID: "srv-1"), session: http.session)
        let model = ServerSettingsModel()

        await model.restartServer(client: sessionClient, sessionState: scoped)

        XCTAssertNil(model.restartNotice)
        XCTAssertEqual(model.restartError, "Token expired")
        XCTAssertTrue(scoped.tokenExpired)
    }

    // MARK: Overlapping loads

    func testAnOlderLoadResolvingLateDoesNotClobberANewerOne() async throws {
        let session = http.session
        let older = APIClient(baseURL: URL(string: "https://cfg-older.test")!, accessToken: nil, session: session)
        let newer = APIClient(baseURL: URL(string: "https://cfg-newer.test")!, accessToken: nil, session: session)
        let keys = Data(#"{"keys":[],"prefixes":[]}"#.utf8)
        let secrets = Data(#"{"configured":[],"managed_by_env":[]}"#.utf8)
        func statusData(_ started: String) -> Data {
            Data(#"{"started_at":"\#(started)","restart_required":false,"restart_requested":false,"restart_mark_count":0}"#.utf8)
        }
        http.state.delayedHosts = ["cfg-older.test": 0.3]
        http.state.hostPathOverrides = [
            "cfg-older.test|\(effectivePath)": (Data(#"{"stale.key":"v"}"#.utf8), 200),
            "cfg-older.test|/api/v2/admin/settings/restart-keys": (keys, 200),
            "cfg-older.test|/api/v2/admin/settings/sensitive-status": (secrets, 200),
            "cfg-older.test|/api/v2/admin/server/status": (statusData("stale"), 200),
            "cfg-newer.test|\(effectivePath)": (Data(#"{"fresh.key":"v"}"#.utf8), 200),
            "cfg-newer.test|/api/v2/admin/settings/restart-keys": (keys, 200),
            "cfg-newer.test|/api/v2/admin/settings/sensitive-status": (secrets, 200),
            "cfg-newer.test|/api/v2/admin/server/status": (statusData("fresh"), 200),
        ]
        let model = ServerSettingsModel()

        let olderTask = Task { await model.load(client: older) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await model.load(client: newer)
        XCTAssertEqual(model.otherKeys, ["fresh.key"])

        await olderTask.value

        XCTAssertEqual(model.otherKeys, ["fresh.key"])
        XCTAssertEqual(model.status?.startedAt, "fresh")
    }
}
