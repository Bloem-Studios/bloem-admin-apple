import XCTest
@testable import BloemAdmin

@MainActor
final class StreamsViewModelTests: XCTestCase {
    /// A v2 `AdminPlaybackSession` carrying every field the schema lists as required.
    static func sessionObject(
        id: String = "s1",
        username: String = "mchan969",
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        var object: [String: Any] = [
            "session_id": id, "user_id": "86", "username": username, "profile_id": "1",
            "media_file_id": "9", "requested_media_file_id": "9",
            "media_title": "The Real Housewives of Miami", "media_type": "series",
            "play_method": "direct", "reporting_node": "node-1", "file_duration": 2600,
            "started_at": "2026-11-13T10:00:00.000Z", "updated_at": "2026-11-13T10:02:49.000Z",
            "position_seconds": 169.71, "is_paused": false, "has_playback_control": true,
            "stream_location": "local", "audio_track_index": 0, "transcode_audio": false,
            "stream_bitrate_kbps": NSNull(), "target_bitrate_kbps": NSNull(),
            "source_bitrate_kbps": NSNull(), "source_audio_channels": NSNull(),
            "client_name": "Silo Android",
        ]
        for (key, value) in extra { object[key] = value }
        return object
    }

    static func sessionsData(_ items: [[String: Any]], page: [String: Any]? = ["has_more": false]) -> Data {
        var body: [String: Any] = ["items": items]
        if let page { body["page"] = page }
        return try! JSONSerialization.data(withJSONObject: body)
    }

    static let receipt = Data(#"{"command_id":"c","sequence":1,"outcome":"applied","delivery":"dispatched"}"#.utf8)

    private func problem(status: Int, type: String, detail: String) -> Data {
        Data(#"{"type":"https://example.test/problems/\#(type)","title":"t","status":\#(status),"detail":"\#(detail)"}"#.utf8)
    }

    private func requestBody(_ http: MockHTTPHarness) throws -> [String: Any] {
        let data = try XCTUnwrap(http.state.capturedBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testLoadDecodesSessions() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Self.sessionsData([Self.sessionObject()])
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        await viewModel.load(client: client)

        XCTAssertEqual(viewModel.sessions.count, 1)
        XCTAssertEqual(viewModel.sessions.first?.username, "mchan969")
        XCTAssertNil(viewModel.errorMessage)
        // The v2 schema marks video_decision/audio_decision optional. Absent here, they stay nil
        // and the row derives each decision from play_method, as the web does.
        XCTAssertNil(viewModel.sessions.first?.videoDecision)
        XCTAssertNil(viewModel.sessions.first?.audioDecision)
        XCTAssertEqual(viewModel.sessions.first?.videoStreamDecision, .direct)
        XCTAssertEqual(viewModel.sessions.first?.audioStreamDecision, .direct)
        XCTAssertNil(viewModel.sessions.first?.seriesName)
        XCTAssertNil(viewModel.sessions.first?.streamBitrateKbps)
    }

    /// Decode coverage for the richer technical/episode fields added
    /// alongside the "Message client" feature — all `omitempty` on the wire
    /// per the real server, so this fixture includes every one of them
    /// present at once.
    func testLoadDecodesRichTechnicalAndEpisodeFields() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Self.sessionsData([Self.sessionObject(extra: [
            "media_title": "Pilot", "media_type": "episode", "play_method": "transcode",
            "position_seconds": 120.5, "file_duration": 1800, "client_name": "Silo tvOS",
            "stream_bitrate_kbps": 5000, "video_decision": "transcode", "audio_decision": "transcode",
            "effective_play_method": "transcode", "transcode_hw_accel": "nvenc",
            "source_video_resolution": "1920x1080", "source_video_codec": "h264",
            "target_resolution": "1280x720", "target_video_codec": "h264",
            "source_audio_codec": "aac", "target_audio_codec": "aac",
            "series_name": "Some Show", "episode_name": "Pilot", "season_number": 1, "episode_number": 1,
        ])])
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        await viewModel.load(client: client)

        let decoded = try XCTUnwrap(viewModel.sessions.first)
        XCTAssertEqual(decoded.streamBitrateKbps, 5000)
        XCTAssertEqual(decoded.videoDecision, "transcode")
        XCTAssertEqual(decoded.audioDecision, "transcode")
        XCTAssertEqual(decoded.effectivePlayMethod, "transcode")
        XCTAssertEqual(decoded.transcodeHWAccel, "nvenc")
        XCTAssertEqual(decoded.sourceVideoResolution, "1920x1080")
        XCTAssertEqual(decoded.sourceVideoCodec, "h264")
        XCTAssertEqual(decoded.targetResolution, "1280x720")
        XCTAssertEqual(decoded.targetVideoCodec, "h264")
        XCTAssertEqual(decoded.sourceAudioCodec, "aac")
        XCTAssertEqual(decoded.targetAudioCodec, "aac")
        XCTAssertEqual(decoded.seriesName, "Some Show")
        XCTAssertEqual(decoded.episodeName, "Pilot")
        XCTAssertEqual(decoded.seasonNumber, 1)
        XCTAssertEqual(decoded.episodeNumber, 1)
    }

    /// `sendMessage` success path: decodes the 202 response and clears
    /// `actionErrorMessage`, mirroring `testStopPostsToStopEndpointAndReloads`'s
    /// request-shape assertions for the sibling actions.
    func testSendMessagePostsToMessageEndpointAndReturnsResponse() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"command_id":"cmd-1","sequence":1,"outcome":"applied","delivery":"dispatched"}"#.utf8)
        http.state.responseStatus = 202

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "mchan969", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: "Silo Android")

        let response = await viewModel.sendMessage(to: target, title: "Heads up", message: "Please pause soon", client: client, sessionState: nil)

        XCTAssertEqual(response?.commandID, "cmd-1")
        XCTAssertEqual(response?.delivery, "dispatched")
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/sessions/s1/message")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
    }

    /// Client-side guard: a blank message must never reach the network
    /// (the server would 400 with no body), and must leave a distinct
    /// error rather than silently no-op-ing.
    func testSendMessageWithBlankMessageDoesNotCallServer() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data("should not be read".utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "mchan969", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: "Silo Android")
        // Static across the whole test target — cleared here so a prior
        // test's request doesn't make this "no request was sent" assertion
        // vacuously pass/fail on unrelated leftover state.
        http.state.lastRequest = nil

        let response = await viewModel.sendMessage(to: target, title: "", message: "   ", client: client, sessionState: nil)

        XCTAssertNil(response)
        XCTAssertNotNil(viewModel.actionErrorMessage)
        XCTAssertNil(http.state.lastRequest)
    }

    /// 409 `realtime_unavailable`: a real, expected condition (client isn't
    /// connected in real time), so it must surface a message distinct from
    /// the generic failure fallback.
    func testSendMessage409SurfacesClientNotConnectedMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = problem(status: 409, type: "realtime_unavailable", detail: "client is not connected")
        http.state.responseStatus = 409

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "mchan969", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: "Silo Android")

        let response = await viewModel.sendMessage(to: target, title: "", message: "Hello", client: client, sessionState: nil)

        XCTAssertNil(response)
        let message = try? XCTUnwrap(viewModel.actionErrorMessage)
        XCTAssertNotEqual(message, "The message wasn't sent. The player may be offline; try again.")
        XCTAssertNotNil(message)
    }

    /// Generic failure (e.g. 503 playback control not configured) falls
    /// back to the generic message, same convention as every other action.
    func testSendMessageGenericFailureSetsActionErrorMessage() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"unavailable","message":"Playback control is not configured"}"#.utf8)
        http.state.responseStatus = 503

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "mchan969", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: "Silo Android")

        let response = await viewModel.sendMessage(to: target, title: "", message: "Hello", client: client, sessionState: nil)

        XCTAssertNil(response)
        XCTAssertEqual(viewModel.actionErrorMessage, "Playback control is not configured")
    }

    func testStopPostsToStopEndpointAndReloads() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Self.receipt
        http.state.responseStatus = 202

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "mchan969", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: "Silo Android")

        await viewModel.stop(target, client: client)

        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/sessions/s1/stop")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
    }

    /// Regression test for a silent-failure bug: a rejected Stop (e.g. 403)
    /// must leave `errorMessage` set so the caller can surface it. Callers
    /// (StreamDetailView) only reload the list when `errorMessage == nil`;
    /// this test proves the model side of that contract holds — a failed
    /// action's error is never quietly overwritten by an unconditional
    /// follow-up reload.
    func testStopFailureSetsActionErrorMessageAndIsNotClearedByConditionalReload() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"forbidden","message":"Not authorized to stop this session"}"#.utf8)
        http.state.responseStatus = 403

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "mchan969", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: "Silo Android")

        await viewModel.stop(target, client: client)

        // actionErrorMessage, NOT errorMessage — errorMessage drives the
        // list screen's full-screen "Connection lost" overlay, which must
        // stay bound to load() failures only (Finding: action failures were
        // previously conflated with load failures via a shared property).
        XCTAssertEqual(viewModel.actionErrorMessage, "Not authorized to stop this session")
        XCTAssertNil(viewModel.errorMessage)

        // Mirrors the guard used by StreamDetailView's button handlers: only
        // reload when the action succeeded. Because it failed, load() must
        // NOT run, so the error stays visible instead of being silently
        // wiped by a subsequent successful GET.
        if viewModel.actionErrorMessage == nil {
            await viewModel.load(client: client)
        }

        XCTAssertEqual(viewModel.actionErrorMessage, "Not authorized to stop this session")
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/sessions/s1/stop")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "POST")
    }

    /// Feature 3: a 401 on load() must flag the shared session state so
    /// AdminGateView can route the whole tab view back to re-login, in
    /// addition to setting errorMessage as before.
    func testLoad401FlagsSessionStateTokenExpired() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401

        let rootSessionState = AdminSessionState()
        rootSessionState.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: rootSessionState.credentialProvider(serverID: "srv-1"),
            session: session
        )
        let viewModel = StreamsViewModel()
        let sessionState = rootSessionState.scoped(to: "srv-1")

        await viewModel.load(client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.errorMessage, "Token expired")
    }

    /// Same 401 detection, exercised via an action rather than load() — the
    /// mid-session 401 can surface from either path.
    func testStopAction401FlagsSessionStateTokenExpired() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401

        let rootSessionState = AdminSessionState()
        rootSessionState.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: rootSessionState.credentialProvider(serverID: "srv-1"),
            session: session
        )
        let viewModel = StreamsViewModel()
        let sessionState = rootSessionState.scoped(to: "srv-1")
        let target = AdminSession(sessionID: "s1", username: "mchan969", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: "Silo Android")

        await viewModel.stop(target, client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.actionErrorMessage, "Token expired")
    }

    // MARK: v2 contract

    func testLoadReadsEveryPageOfV2Sessions() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/sessions", responses: [
            MockHTTPResponse(data: Self.sessionsData([Self.sessionObject(id: "s1")], page: ["has_more": true, "next_cursor": "c2"])),
            MockHTTPResponse(data: Self.sessionsData([Self.sessionObject(id: "s2")])),
        ])
        let viewModel = StreamsViewModel()
        await viewModel.load(client: http.client)

        XCTAssertEqual(viewModel.sessions.map(\.sessionID), ["s1", "s2"])
        let requests = http.state.requests(path: "/api/v2/admin/sessions")
        XCTAssertEqual(requests.count, 2)
        let second = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(Set(second?.queryItems?.map(\.name) ?? []), ["limit", "cursor"])
    }

    func testPauseResumeStopSendCommandIdentityBody() async throws {
        for action in ["pause", "resume", "stop"] {
            let http = MockHTTPHarness()
            defer { http.invalidate() }
            http.state.responseData = Self.receipt
            http.state.responseStatus = 202
            let viewModel = StreamsViewModel(sequencer: PlaybackCommandSequencer(clock: { 4242 }))
            let target = AdminSession(sessionID: "s1", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)
            switch action {
            case "pause": await viewModel.pause(target, client: http.client)
            case "resume": await viewModel.resume(target, client: http.client)
            default: await viewModel.stop(target, client: http.client)
            }
            XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/sessions/s1/\(action)")
            let body = try requestBody(http)
            XCTAssertEqual(Set(body.keys), ["command_id", "sequence"])
            XCTAssertEqual(body["sequence"] as? Int, 4242)
            XCTAssertNotNil(UUID(uuidString: body["command_id"] as? String ?? ""))
            XCTAssertNil(viewModel.actionErrorMessage)
        }
    }

    func testMessageBodyCarriesTitleMessageAndIdentity() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Self.receipt
        http.state.responseStatus = 202
        let viewModel = StreamsViewModel(sequencer: PlaybackCommandSequencer(clock: { 77 }))
        let target = AdminSession(sessionID: "s1", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)
        _ = await viewModel.sendMessage(to: target, title: " Hi ", message: "Hello", client: http.client)
        let body = try requestBody(http)
        XCTAssertEqual(Set(body.keys), ["title", "message", "command_id", "sequence"])
        XCTAssertEqual(body["title"] as? String, "Hi")
        XCTAssertEqual(body["message"] as? String, "Hello")
        XCTAssertEqual(body["sequence"] as? Int, 77)
    }

    func testMessageWithoutTitleOmitsTitleKey() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Self.receipt
        http.state.responseStatus = 202
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)
        _ = await viewModel.sendMessage(to: target, title: "  ", message: "Hello", client: http.client)
        XCTAssertEqual(Set(try requestBody(http).keys), ["message", "command_id", "sequence"])
    }

    func testTerminateSendsAnEmptyJSONObjectBody() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"session_id":"s1","authority_revoked":true,"already_revoked":false,"durable_state":"stopped","client_notified":true,"delivery":"dispatched"}"#.utf8)
        http.state.responseStatus = 200
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)
        await viewModel.terminate(target, client: http.client)
        XCTAssertEqual(http.state.lastRequest?.url?.path, "/api/v2/admin/sessions/s1/terminate")
        XCTAssertEqual(try requestBody(http).count, 0)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testSessionIDIsEncodedAsOnePathSegment() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Self.receipt
        http.state.responseStatus = 202
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "a b/c?d#e", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)
        await viewModel.pause(target, client: http.client)
        XCTAssertEqual(http.state.lastRequest?.url?.absoluteString, "https://example.test/api/v2/admin/sessions/a%20b%2Fc%3Fd%23e/pause")
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testStale409ObservesLatestSequenceShowsStaleTextAndDoesNotRetry() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/admin/sessions/s1/pause", response: MockHTTPResponse(
            data: problem(status: 409, type: "stale_sequence", detail: "stale"),
            status: 409,
            headers: ["X-Silo-Latest-Sequence": "9000"]
        ))
        let viewModel = StreamsViewModel(sequencer: PlaybackCommandSequencer(clock: { 1000 }))
        let target = AdminSession(sessionID: "s1", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)

        await viewModel.pause(target, client: http.client)

        XCTAssertEqual(viewModel.actionErrorMessage, "Another command reached this stream first. Try again.")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/sessions/s1/pause").count, 1)

        http.state.stub(path: "/api/v2/admin/sessions/s1/pause", data: Self.receipt, status: 202)
        await viewModel.pause(target, client: http.client)
        XCTAssertEqual(try requestBody(http)["sequence"] as? Int, 9001)
        XCTAssertNil(viewModel.actionErrorMessage)
    }

    func testStale409OnMessageShowsStaleTextNotClientNotConnected() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/admin/sessions/s1/message", response: MockHTTPResponse(
            data: problem(status: 409, type: "stale_sequence", detail: "stale"),
            status: 409,
            headers: ["X-Silo-Latest-Sequence": "9000"]
        ))
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)
        let response = await viewModel.sendMessage(to: target, title: "", message: "Hello", client: http.client)
        XCTAssertNil(response)
        XCTAssertEqual(viewModel.actionErrorMessage, "Another command reached this stream first. Try again.")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/sessions/s1/message").count, 1)
    }

    func testConflictWithoutLatestSequenceKeepsTheServerText() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = problem(status: 409, type: "conflict", detail: "Session already ended")
        http.state.responseStatus = 409
        let viewModel = StreamsViewModel()
        let target = AdminSession(sessionID: "s1", username: "u", mediaTitle: "X", mediaType: "series", playMethod: "direct", positionSeconds: 0, fileDuration: 100, isPaused: false, clientName: nil)
        await viewModel.stop(target, client: http.client)
        XCTAssertEqual(viewModel.actionErrorMessage, "Session already ended")
    }

    func testAPIClientExposesLatestSequenceOnlyFor409() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = problem(status: 500, type: "internal", detail: "boom")
        http.state.responseStatus = 500
        http.state.stub(path: "/api/v2/admin/sessions/s1/stop", response: MockHTTPResponse(
            data: problem(status: 500, type: "internal", detail: "boom"), status: 500,
            headers: ["X-Silo-Latest-Sequence": "5"]
        ))
        do {
            try await http.client.sendPlaybackCommand(sessionID: "s1", action: .stop, identity: PlaybackCommandIdentity(commandID: "c", sequence: 1))
            XCTFail("expected failure")
        } catch let error as APIError {
            XCTAssertNil(error.latestSequence)
        } catch { XCTFail("unexpected \(error)") }
    }
}
