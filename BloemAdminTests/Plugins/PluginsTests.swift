import XCTest
@testable import BloemAdmin

/// The Plugins page: installed plugins from `GET /api/v2/admin/plugins/installations`, the web's
/// Needs attention rule, filters and order, and Restart, On/Off and Update.
@MainActor
final class PluginsTests: XCTestCase {
    private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func plugin(
        _ id: String = "p1", pluginID: String = "silo.tmdb", enabled: Bool = true, resident: Bool = true,
        state: String = "running", restarts: Int = 0, lastError: String? = nil, version: String = "1.0.0",
        available: String? = nil, repository: String? = #""repo""#, paused: Bool = false,
        updateFailure: String? = nil, signature: String = "verified", display: String? = nil,
        schema: String = "[]", configs: String = "[]"
    ) throws -> PluginInstallation {
        var json = #"""
        {"id":"\#(id)","plugin_id":"\#(pluginID)","enabled":\#(enabled),"version":"\#(version)","source_kind":"silo",
         "update_policy":"notify","updates_paused":\#(paused),"signature":{"state":"\#(signature)"},
         "runtime":{"resident":\#(resident),"state":"\#(state)","restart_count":\#(restarts)\#(lastError.map { #","last_error":"\#($0)""# } ?? "")},
         "global_config_schema":\#(schema),"global_configs":\#(configs)
        """#
        if let available { json += #","available_version":"\#(available)""# }
        if let repository { json += #","repository_id":\#(repository)"# }
        if let updateFailure { json += #","update_failure":\#(updateFailure)"# }
        if let display { json += #","presentation":{"display_name":"\#(display)","summary":"s","publisher_name":"p"}"# }
        return try JSONDecoder().decode(PluginInstallation.self, from: Data((json + "}").utf8))
    }

    // MARK: Status and Needs attention

    func testAHealthyResidentPluginIsRunningAndNeedsNothing() throws {
        let row = PluginPresentation(try plugin())
        XCTAssertEqual(row.statusText, "Running")
        XCTAssertFalse(row.needsAttention)
    }

    func testAPluginStartedOnUseReadsActive() throws {
        XCTAssertEqual(PluginPresentation(try plugin(resident: false, state: "stopped")).statusText, "Active")
    }

    func testAFailedPluginNeedsAttentionAndShowsItsError() throws {
        let row = PluginPresentation(try plugin(state: "failed", lastError: "exit status 2"))
        XCTAssertEqual(row.statusText, "Failed")
        XCTAssertEqual(row.detail, "exit status 2")
        XCTAssertTrue(row.needsAttention)
    }

    // The quality audit (2026-11-16): "Failed" was drawn like "Running". A failure now carries the failure tone.
    func testTheStatusWordIsSaidInTheToneOfHowSeriousItIs() throws {
        XCTAssertEqual(PluginPresentation(try plugin(state: "failed", lastError: "exit status 2")).statusTone, .failure)
        XCTAssertEqual(PluginPresentation(try plugin(state: "backoff", restarts: 3)).statusTone, .warning)
        XCTAssertEqual(PluginPresentation(try plugin()).statusTone, .positive)
        XCTAssertEqual(PluginPresentation(try plugin(enabled: false, state: "failed")).statusTone, .normal, "a plugin that is off needs nothing")
    }

    func testARestartingResidentPluginNeedsAttention() throws {
        let row = PluginPresentation(try plugin(state: "backoff", restarts: 3))
        XCTAssertEqual(row.statusText, "Restarting (3)")
        XCTAssertTrue(row.needsAttention)
    }

    func testAPluginOffNeverNeedsAttentionEvenWhenItsRuntimeFailed() throws {
        let row = PluginPresentation(try plugin(enabled: false, state: "failed"))
        XCTAssertEqual(row.statusText, "Off")
        XCTAssertFalse(row.needsAttention)
    }

    func testMissingRequiredSettingsNeedSetup() throws {
        let row = PluginPresentation(try plugin(schema: #"[{"key":"api_key","title":"API key","required":true},{"key":"lang","title":"Language","required":false}]"#))
        XCTAssertEqual(row.statusText, "Needs setup")
        XCTAssertEqual(row.detail, "Missing: API key")
        XCTAssertTrue(row.needsAttention)
    }

    func testASavedValueOrSecretCountsAsSetUp() throws {
        let schema = #"[{"key":"api_key","title":"API key","required":true},{"key":"token","title":"Token","required":true}]"#
        let configs = #"[{"key":"api_key","value":{"v":"abc"},"configured_secrets":[]},{"key":"token","value":{},"configured_secrets":["token"]}]"#
        XCTAssertFalse(PluginPresentation(try plugin(schema: schema, configs: configs)).needsAttention)
    }

    func testABlankSavedValueIsNotSetUp() throws {
        let schema = #"[{"key":"api_key","title":"API key","required":true}]"#
        let configs = #"[{"key":"api_key","value":{"v":"  "},"configured_secrets":[]}]"#
        XCTAssertTrue(PluginPresentation(try plugin(schema: schema, configs: configs)).needsAttention)
    }

    func testAFalseOrZeroSavedValueIsSetUp() throws {
        let schema = #"[{"key":"flag","title":"Flag","required":true}]"#
        let configs = #"[{"key":"flag","value":{"v":false},"configured_secrets":[]}]"#
        XCTAssertFalse(PluginPresentation(try plugin(schema: schema, configs: configs)).needsAttention)
    }

    func testARefusedUpdateOrABadSignatureNeedsAttention() throws {
        let failed = PluginPresentation(try plugin(updateFailure: #"{"failed_at":"2026-11-14T00:00:00Z","reason":"signature mismatch","version":"1.2.0"}"#))
        XCTAssertTrue(failed.needsAttention)
        XCTAssertEqual(failed.updateText, "Update to 1.2.0 failed: signature mismatch")
        let invalid = PluginPresentation(try plugin(signature: "invalid"))
        XCTAssertTrue(invalid.needsAttention)
        XCTAssertEqual(invalid.detail, "The release signature did not check out")
    }

    // MARK: Updates

    func testAnUpdateIsOfferedForAnInstalledPluginFromARepository() throws {
        let row = PluginPresentation(try plugin(available: "1.1.0"))
        XCTAssertEqual(row.pendingUpdate, "1.1.0")
        XCTAssertEqual(row.updateText, "Update to 1.1.0 available")
    }

    func testNoUpdateIsOfferedWithoutARepositoryOrWhilePaused() throws {
        XCTAssertNil(PluginPresentation(try plugin(available: "1.1.0", repository: nil)).pendingUpdate)
        let paused = PluginPresentation(try plugin(available: "1.1.0", paused: true))
        XCTAssertNil(paused.pendingUpdate)
        XCTAssertEqual(paused.updateText, "Updates paused")
    }

    // MARK: Actions

    func testRestartIsOfferedToAnEnabledResidentPluginThatIsNotStarting() throws {
        XCTAssertTrue(PluginPresentation(try plugin()).canRestart)
        XCTAssertFalse(PluginPresentation(try plugin(state: "starting")).canRestart)
        XCTAssertFalse(PluginPresentation(try plugin(resident: false)).canRestart)
        XCTAssertFalse(PluginPresentation(try plugin(enabled: false)).canRestart)
    }

    func testOnOffActionTitles() throws {
        XCTAssertEqual(PluginPresentation(try plugin()).toggleActionTitle, "Turn off")
        XCTAssertEqual(PluginPresentation(try plugin(enabled: false)).toggleActionTitle, "Turn on")
    }

    // MARK: Names, filters and order

    func testNameFromThePresentationOrDerivedFromTheID() throws {
        XCTAssertEqual(PluginPresentation(try plugin(display: "The Movie DB")).name, "The Movie DB")
        XCTAssertEqual(PluginPresentation(try plugin(pluginID: "silo.tmdb-provider")).name, "Tmdb Provider")
        XCTAssertEqual(PluginPresentation(try plugin(pluginID: "silo")).name, "silo")
    }

    func testFilters() throws {
        let all = [
            try plugin("a", state: "failed"),
            try plugin("b", available: "2.0.0"),
            try plugin("c", enabled: false),
            try plugin("d"),
        ]
        XCTAssertEqual(PluginFilter.attention.apply(to: all).map(\.id), ["a"])
        XCTAssertEqual(PluginFilter.update.apply(to: all).map(\.id), ["b"])
        XCTAssertEqual(PluginFilter.off.apply(to: all).map(\.id), ["c"])
        XCTAssertEqual(PluginFilter.all.apply(to: all).count, 4)
        XCTAssertEqual(PluginFilter.attention.count(in: all), 1)
    }

    func testProblemsComeFirstThenHealthyThenOffByName() throws {
        let all = [
            try plugin("off", enabled: false, display: "Aaa off"),
            try plugin("fine-b", display: "Bbb"),
            try plugin("fine-a", display: "Aaa"),
            try plugin("backoff", state: "backoff", restarts: 1, display: "Zzz restarting"),
            try plugin("failed", state: "failed", display: "Zzz failed"),
        ]
        XCTAssertEqual(PluginFilter.sorted(all).map(\.id), ["failed", "backoff", "fine-a", "fine-b", "off"])
    }

    func testSearchMatchesNameAndPluginID() throws {
        let all = [try plugin("a", pluginID: "silo.tmdb", display: "Movie database"), try plugin("b", pluginID: "silo.subs", display: "Subtitles")]
        XCTAssertEqual(PluginFilter.search("movie", in: all).map(\.id), ["a"])
        XCTAssertEqual(PluginFilter.search("SUBS", in: all).map(\.id), ["b"])
        XCTAssertEqual(PluginFilter.search("  ", in: all).count, 2)
    }

    // MARK: Reads and writes

    private func listItem(_ id: String) -> [String: Any] {
        ["id": id, "plugin_id": "silo.\(id)", "enabled": true, "version": "1", "source_kind": "silo", "update_policy": "notify",
         "updates_paused": false, "signature": ["state": "verified"], "runtime": ["resident": true, "state": "running", "restart_count": 0]]
    }

    func testLoadReadsEveryPageOfInstallations() async throws {
        http.state.stubSequence(path: "/api/v2/admin/plugins/installations", responses: [
            MockHTTPResponse(json: ["items": [listItem("a")], "page": ["has_more": true, "next_cursor": "c2"]]),
            MockHTTPResponse(json: ["items": [listItem("b")], "page": ["has_more": false]]),
        ])
        let model = SectionModel<[PluginInstallation]>.plugins()

        await model.load(client: http.client)

        XCTAssertEqual(model.payload?.map(\.id), ["a", "b"])
    }

    func testRestartPostsToTheRestartRouteThenReloads() async throws {
        http.state.stub(path: "/api/v2/admin/plugins/installations", json: ["items": [listItem("a")]])
        http.state.stub(path: "/api/v2/admin/plugins/installations/a/restart", json: listItem("a"))
        let model = SectionModel<[PluginInstallation]>.plugins()
        await model.load(client: http.client)

        let done = await model.restart(id: "a", client: http.client)

        XCTAssertTrue(done)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/plugins/installations/a/restart").first?.httpMethod, "POST")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/plugins/installations").count, 2)
    }

    func testTurningOffSendsOnlyEnabledFalse() async throws {
        http.state.stub(path: "/api/v2/admin/plugins/installations", json: ["items": [listItem("a")]])
        http.state.stub(path: "/api/v2/admin/plugins/installations/a", json: listItem("a"))
        let model = SectionModel<[PluginInstallation]>.plugins()
        await model.load(client: http.client)

        let done = await model.setEnabled(false, id: "a", client: http.client)

        XCTAssertTrue(done)
        let put = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/plugins/installations/a").first)
        XCTAssertEqual(put.httpMethod, "PUT")
        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/plugins/installations/a", requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Bool], ["enabled": false])
    }

    func testUpdatePostsToTheUpdateRoute() async throws {
        http.state.stub(path: "/api/v2/admin/plugins/installations", json: ["items": [listItem("a")]])
        http.state.stub(path: "/api/v2/admin/plugins/installations/a/update", json: listItem("a"))
        let model = SectionModel<[PluginInstallation]>.plugins()
        await model.load(client: http.client)

        let done = await model.applyUpdate(id: "a", client: http.client)

        XCTAssertTrue(done)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/plugins/installations/a/update").first?.httpMethod, "POST")
    }

    func testAFailedUpdateSaysWhatTheServerSaidAndDoesNotReload() async throws {
        http.state.stub(path: "/api/v2/admin/plugins/installations", json: ["items": [listItem("a")]])
        http.state.stub(path: "/api/v2/admin/plugins/installations/a/update", json: ["message": "No update is available"], status: 409)
        let model = SectionModel<[PluginInstallation]>.plugins(serverName: "Home")
        await model.load(client: http.client)

        let done = await model.applyUpdate(id: "a", client: http.client)

        XCTAssertFalse(done)
        XCTAssertEqual(model.actionErrorMessage, "Home: No update is available")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/plugins/installations").count, 1)
    }

    func testInstallationIDIsOneEncodedPathSegment() async throws {
        http.state.stub(path: "/api/v2/admin/plugins/installations/a b/restart", json: listItem("a"))
        http.state.stub(path: "/api/v2/admin/plugins/installations", json: ["items": [Any]()])
        let model = SectionModel<[PluginInstallation]>.plugins()

        _ = await model.restart(id: "a b", client: http.client)

        let url = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/plugins/installations/a b/restart").first?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/api/v2/admin/plugins/installations/a%20b/restart")
    }
}
