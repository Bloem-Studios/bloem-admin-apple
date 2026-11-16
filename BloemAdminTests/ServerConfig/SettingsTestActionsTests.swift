import XCTest
@testable import BloemAdmin

/// The test actions against the server's real shapes (server:internal/apiv2/admin_email_test_send.go,
/// admin_settings_checks.go, notification_destination_tests.go, external_sign_in.go).
@MainActor
private final class CallCounter {
    var count = 0
}

@MainActor
final class SettingsTestActionsTests: XCTestCase {
    private let http = MockHTTPHarness()
    private var client: APIClient { APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session) }

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func lastBody() throws -> [String: Any] {
        let body = try XCTUnwrap(http.state.capturedBody)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: Email

    func testTestEmailPostsTheRecipientAndReadsTheDeliveryTime() async throws {
        http.state.stub(path: "/api/v2/admin/email/test", json: ["ok": true, "duration_ms": 412])

        let outcome = try await client.sendTestEmail(to: "admin@example.test")

        XCTAssertEqual(try lastBody()["to"] as? String, "admin@example.test")
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(outcome.durationMS, 412)
        XCTAssertEqual(outcome.detail, "412 ms")
    }

    func testTestEmailFailureCarriesTheSMTPReason() async throws {
        http.state.stub(path: "/api/v2/admin/email/test", json: ["ok": false, "duration_ms": 90, "message": "535 authentication failed"])

        let outcome = try await client.sendTestEmail(to: "admin@example.test")

        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.verdict, "Failed")
        XCTAssertEqual(outcome.detail, "535 authentication failed · 90 ms")
    }

    // MARK: Connection checks

    func testConnectionCheckSendsTheUnsavedValuesAndWhichAreDirty() async throws {
        http.state.stub(path: "/api/v2/admin/settings/check/redis", json: ["success": true, "message": "Connected to Redis"])

        let outcome = try await client.checkConnection(kind: "redis", values: ["redis.db": "2"], dirtyKeys: ["redis.db"])

        let body = try lastBody()
        XCTAssertEqual((body["values"] as? [String: String]), ["redis.db": "2"])
        XCTAssertEqual(body["dirty_keys"] as? [String], ["redis.db"])
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(outcome.message, "Connected to Redis")
    }

    func testConnectionCheckFailureIsAResultNotAnError() async throws {
        http.state.stub(path: "/api/v2/admin/settings/check/redis", json: ["success": false, "message": "dial tcp: connection refused"])

        let outcome = try await client.checkConnection(kind: "redis", values: [:], dirtyKeys: [])

        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.message, "dial tcp: connection refused")
    }

    // MARK: Server channels

    func testServerChannelsListReadsLastFailureAndEnabled() async throws {
        http.state.stub(path: "/api/v2/admin/notifications/server-channels", json: [
            "items": [[
                "id": "7", "name": "Ops", "type": "discord", "url_host": "discord.com", "enabled": true,
                "consecutive_failures": 3, "disabled_reason": NSNull(), "last_failure_message": "HTTP 404",
                "last_failure_at": "2026-11-14T09:00:00.000Z", "last_success_at": NSNull(),
            ]],
        ])

        let channels = try await client.notificationServerChannels()

        XCTAssertEqual(channels.map(\.id), ["7"])
        XCTAssertEqual(channels.first?.lastFailureMessage, "HTTP 404")
        XCTAssertEqual(channels.first?.consecutiveFailures, 3)
        XCTAssertNotNil(channels.first?.lastFailureAt)
        XCTAssertNil(channels.first?.lastSuccessAt)
    }

    func testChannelTestPostsToTheChannelAndReadsTheResult() async throws {
        http.state.stub(path: "/api/v2/admin/notifications/server-channels/7/test", json: ["ok": false, "http_status": 404, "duration_ms": 130, "message": "Unknown webhook"])

        let outcome = try await client.testServerChannel(id: "7")

        XCTAssertEqual(http.state.requestLog.last?.httpMethod, "POST")
        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.detail, "Unknown webhook · 130 ms")
    }

    // MARK: Sign-in providers

    private func installation(id: String, pluginID: String, capabilities: [[String: Any]], bindings: [[String: Any]] = []) -> [String: Any] {
        ["id": id, "plugin_id": pluginID, "enabled": true, "capabilities": capabilities, "auth_bindings": bindings]
    }

    func testSignInProvidersKeepOnlyPluginsWithASignInCapabilityAndNotNetworkOnes() async throws {
        http.state.stub(path: "/api/v2/admin/plugins/installations", json: ["items": [
            installation(id: "3", pluginID: "oidc", capabilities: [["type": "auth_provider.v1", "id": "oidc-main", "display_name": "Company SSO", "sign_in_mode": "oauth"]],
                         bindings: [["capability_id": "oidc-main", "enabled": true]]),
            installation(id: "4", pluginID: "tailscale", capabilities: [["type": "auth_provider.v1", "id": "ts", "display_name": "Tailscale", "sign_in_mode": "network"]]),
            installation(id: "5", pluginID: "sonarr", capabilities: [["type": "request_router.v1", "id": "r", "display_name": "Sonarr"]]),
            installation(id: "6", pluginID: "ldap", capabilities: [["type": "auth_provider.v1", "id": "ldap1", "display_name": "", "sign_in_mode": "credentials"]]),
        ]])

        let providers = try await client.signInProviders()

        XCTAssertEqual(providers.map(\.id), ["3", "6"])
        XCTAssertEqual(providers.first?.name, "Company SSO")
        XCTAssertEqual(providers.first?.enabled, true)
        XCTAssertEqual(providers.last?.name, "ldap", "falls back to the plugin id when nothing else names it")
        XCTAssertEqual(providers.last?.enabled, false, "no binding yet means off")
    }

    func testSignInTestPostsTheCapabilityAndReadsEachStep() async throws {
        http.state.stub(path: "/api/v2/admin/plugins/installations/3/auth-binding/test", json: [
            "ok": false, "callback_url": "",
            "steps": [
                ["id": "discovery", "label": "Discovery document reachable", "ok": true, "message": "Loaded the document"],
                ["id": "token", "label": "Token endpoint", "ok": false, "message": "401 invalid client"],
            ],
        ])

        let outcome = try await client.testSignInProvider(SignInProvider(id: "3", name: "Company SSO", capabilityID: "oidc-main", enabled: true))

        XCTAssertEqual(try lastBody()["capability_id"] as? String, "oidc-main")
        XCTAssertFalse(outcome.passed)
        XCTAssertEqual(outcome.steps.map(\.passed), [true, false])
        XCTAssertEqual(outcome.message, "Token endpoint: 401 invalid client")
    }

    func testSignInTestOfAPluginWithoutATestIsAnErrorNotAFailedCheck() async {
        http.state.stub(path: "/api/v2/admin/plugins/installations/3/auth-binding/test", response: MockHTTPResponse(
            data: Data(#"{"type":"https://example.test/problems/conflict","title":"Conflict","status":409,"detail":"This plugin has no connection test"}"#.utf8),
            status: 409, headers: ["Content-Type": "application/problem+json"]
        ))
        let runner = SettingsTestRunner()
        let provider = SignInProvider(id: "3", name: "SSO", capabilityID: "x", enabled: true)

        await runner.run { try await client.testSignInProvider(provider) }

        XCTAssertEqual(runner.state, .failed("This plugin has no connection test"))
    }

    // MARK: Runner

    func testRunnerAnswersPassAndFail() async {
        let runner = SettingsTestRunner()

        await runner.run { TestOutcome(passed: true, message: "ok") }
        XCTAssertEqual(runner.state, .finished(TestOutcome(passed: true, message: "ok")))

        await runner.run { TestOutcome(passed: false, message: "no route") }
        XCTAssertEqual(runner.state, .finished(TestOutcome(passed: false, message: "no route")))
    }

    func testRunnerSaysWhenTheTestCouldNotRunAndNamesTheServer() async {
        let runner = SettingsTestRunner(serverName: "Alpha")

        await runner.run { throw URLError(.notConnectedToInternet) }

        XCTAssertEqual(runner.state, .failed("Alpha: The test could not run. Check your connection and try again"))
    }

    func testRunnerIgnoresASecondTapWhileRunning() async {
        let runner = SettingsTestRunner()
        let calls = CallCounter()
        let first = Task { @MainActor in
            await runner.run {
                calls.count += 1
                try await Task.sleep(nanoseconds: 150_000_000)
                return TestOutcome(passed: true, message: "")
            }
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(runner.state.isRunning)

        await runner.run { calls.count += 1; return TestOutcome(passed: false, message: "") }
        await first.value

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(runner.state, .finished(TestOutcome(passed: true, message: "")))
    }

    func testRunnerResetReturnsToIdle() async {
        let runner = SettingsTestRunner()
        await runner.run { TestOutcome(passed: true, message: "") }
        runner.reset()
        XCTAssertEqual(runner.state, .idle)
    }
}
