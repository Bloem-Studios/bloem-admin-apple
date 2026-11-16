import XCTest
@testable import BloemAdmin

@MainActor
final class ServerFanOutTests: XCTestCase {
    private let serverAID = "fanout-srv-A"
    private let serverBID = "fanout-srv-B"
    private let serverCID = "fanout-srv-C"
    // XCTest's synchronous lifecycle overrides are nonisolated. The harness
    // is Sendable and each test-case instance owns exactly one fixture.
    nonisolated private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func makeStore() -> ServerStore {
        ServerStore(
            metadataStore: InMemoryServerMetadataStore(),
            credentialStore: InMemoryCredentialStore()
        )
    }

    /// `MockHTTPHarness` builds a NEW `URLSessionConfiguration.ephemeral`-
    /// backed session per test. Custom-URLProtocol request
    /// delivery for these turns out to run through a SHARED,
    /// limited-concurrency system queue
    /// ("com.apple.CFNetwork.CustomProtocols") — confirmed by direct
    /// instrumentation while root-causing a real cross-test failure this
    /// helper exists to prevent (see git history / MULTISERVER_STAGE1_REPORT
    /// .md's I1/I2 coverage fix-note): a session left un-invalidated after a
    /// test (ARC eventually deallocates it, but not promptly) can starve
    /// that shared queue for the NEXT test's requests, serializing what's
    /// supposed to be genuinely concurrent delivery — which is exactly what
    /// `testFanOutRunsServersConcurrently`'s barrier requires to avoid
    /// deadlocking on itself. Every test that creates a session should call
    /// this helper so the harness releases it
    /// immediately once the test is done with it.
    private func makeInvalidatingSession() -> (session: URLSession, invalidate: () -> Void) {
        (http.session, { self.http.invalidate() })
    }

    func testFanOutMapsEachServerToItsOwnSuccessResult() async throws {
        let store = makeStore()
        try store.updateToken("tok-a", forServerID: serverAID)
        try store.updateToken("tok-b", forServerID: serverBID)
        let serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://server-a.test")!, displayName: "Server A")
        let serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://server-b.test")!, displayName: "Server B")

        http.state.hostOverrides = [
            "server-a.test": (Data(#"[{"session_id":"a1","user_id":1,"username":"alice","media_title":"A Movie","media_type":"movie","play_method":"direct","position_seconds":0,"file_duration":100,"is_paused":false,"client_name":"c"}]"#.utf8), 200),
            "server-b.test": (Data(#"[{"session_id":"b1","user_id":2,"username":"bob","media_title":"B Movie","media_type":"movie","play_method":"direct","position_seconds":0,"file_duration":100,"is_paused":false,"client_name":"c"}]"#.utf8), 200),
        ]

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }
        let results = await fanOut(servers: [serverA, serverB], store: store, session: session) { _, client in
            try await client.get("/api/v1/admin/sessions") as [AdminSession]
        }

        XCTAssertEqual(results.count, 2)
        // Order matches the input `servers` array, not completion order.
        XCTAssertEqual(results[0].server.id, serverAID)
        XCTAssertEqual(results[1].server.id, serverBID)

        guard case .success(let sessionsA) = results[0].result else { return XCTFail("expected server A to succeed") }
        guard case .success(let sessionsB) = results[1].result else { return XCTFail("expected server B to succeed") }
        // Each server's own distinct response, not swapped or merged.
        XCTAssertEqual(sessionsA.first?.username, "alice")
        XCTAssertEqual(sessionsB.first?.username, "bob")
    }

    func testFanOutProducesFailureForServerWithNoStoredToken() async {
        let store = makeStore()
        // Deliberately no token written for this server.
        let server = AdminServer(id: serverAID, baseURL: URL(string: "https://server-a.test")!, displayName: "Server A")

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }
        let results = await fanOut(servers: [server], store: store, session: session) { _, client in
            try await client.get("/api/v1/admin/sessions") as [AdminSession]
        }

        XCTAssertEqual(results.count, 1)
        guard case .failure(let error) = results[0].result else { return XCTFail("expected failure for a server with no stored token") }
        XCTAssertEqual(error.kind, .signedOut)
        XCTAssertEqual(error.recoveryAction, .signIn)
    }

    func testServerSectionFailureClassifiesEveryRecoveryCategory() {
        let decodeError = DecodingError.typeMismatch(
            String.self,
            .init(codingPath: [], debugDescription: "Expected a string")
        )
        let cases: [(Error, ServerSectionFailure.Kind, ServerRecoveryAction)] = [
            (APIError(statusCode: 401, message: "Expired"), .signedOut, .signIn),
            (APIError(statusCode: 403, message: "Forbidden"), .forbidden, .none),
            (URLError(.notConnectedToInternet), .connectivity, .retry),
            (decodeError, .incompatibleResponse, .retry),
            (APIError(statusCode: 503, message: "Unavailable"), .serverFailure, .retry),
        ]

        for (error, expectedKind, expectedAction) in cases {
            let failure = ServerSectionFailure.classify(error, fallback: "Could not load section.")
            XCTAssertEqual(failure.kind, expectedKind)
            XCTAssertEqual(failure.recoveryAction, expectedAction)
            XCTAssertEqual(failure.requestsCredentials, expectedAction == .signIn)
        }
    }

    /// The mixed case item 4 depends on: one server succeeds, a sibling
    /// server's request is rejected (401) — both outcomes must land on the
    /// RIGHT server, and the failing server must not prevent the succeeding
    /// one's result from coming back.
    func testFanOutMixedSuccessAndFailureAttributesEachOutcomeToItsOwnServer() async {
        let store = makeStore()
        try? store.updateToken("tok-a", forServerID: serverAID)
        try? store.updateToken("tok-b", forServerID: serverBID)
        let serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://server-a.test")!, displayName: "Server A")
        let serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://server-b.test")!, displayName: "Server B")

        http.state.hostOverrides = [
            "server-a.test": (Data("[]".utf8), 200),
            "server-b.test": (Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8), 401),
        ]

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }
        let results = await fanOut(servers: [serverA, serverB], store: store, session: session) { _, client in
            try await client.get("/api/v1/admin/sessions") as [AdminSession]
        }

        guard case .success = results[0].result else { return XCTFail("expected server A to succeed") }
        guard case .failure(let failure) = results[1].result else { return XCTFail("expected server B to fail") }
        XCTAssertEqual(failure.kind, .signedOut)
        XCTAssertEqual(failure.message, "Token expired")
    }

    /// Deterministic proof of CONCURRENT (not sequential) execution: each
    /// mock response blocks until ALL THREE servers' requests are
    /// simultaneously in flight before any of them is allowed to complete.
    /// A sequential implementation would deadlock the first request
    /// waiting on siblings that are never issued, timing this test out
    /// instead of letting it pass. (This is also why every OTHER test in
    /// this file invalidates its session promptly via
    /// `makeInvalidatingSession()` — an un-invalidated sibling session can
    /// starve the shared custom-protocol delivery queue this test's barrier
    /// depends on for genuine 3-way concurrency; see that helper's doc
    /// comment.)
    func testFanOutRunsServersConcurrently() async {
        let store = makeStore()
        try? store.updateToken("tok-a", forServerID: serverAID)
        try? store.updateToken("tok-b", forServerID: serverBID)
        try? store.updateToken("tok-c", forServerID: serverCID)
        let servers = [
            AdminServer(id: serverAID, baseURL: URL(string: "https://server-a.test")!, displayName: "Server A"),
            AdminServer(id: serverBID, baseURL: URL(string: "https://server-b.test")!, displayName: "Server B"),
            AdminServer(id: serverCID, baseURL: URL(string: "https://server-c.test")!, displayName: "Server C"),
        ]
        http.state.responseData = Data("[]".utf8)
        http.state.responseStatus = 200
        http.state.requiredConcurrentStarts = 3

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }
        let results = await fanOut(servers: servers, store: store, session: session) { _, client in
            try await client.get("/api/v1/admin/sessions") as [AdminSession]
        }

        XCTAssertEqual(results.count, 3)
        for sectionResult in results {
            guard case .success = sectionResult.result else { return XCTFail("expected every server to succeed once the barrier released") }
        }
    }

    // MARK: - I1: a hung server must not stall its siblings or the caller

    /// A server that never answers within `timeout` must (a) not delay the
    /// OTHER servers' `onResult` delivery at all, and (b) itself eventually
    /// resolve to a timeout-shaped failure rather than hanging the test.
    /// The harness's per-host delay makes server C's response take far
    /// longer than the fan-out `timeout` used here, but responds promptly
    /// to cancellation (see its doc comment), so this test itself stays
    /// fast regardless.
    func testFanOutBoundsAHungServerWithoutStallingItsSiblings() async {
        let store = makeStore()
        try? store.updateToken("tok-a", forServerID: serverAID)
        try? store.updateToken("tok-b", forServerID: serverBID)
        try? store.updateToken("tok-c", forServerID: serverCID)
        let serverA = AdminServer(id: serverAID, baseURL: URL(string: "https://hung-test-a.test")!, displayName: "Server A")
        let serverB = AdminServer(id: serverBID, baseURL: URL(string: "https://hung-test-b.test")!, displayName: "Server B")
        let serverC = AdminServer(id: serverCID, baseURL: URL(string: "https://hung-test-c.test")!, displayName: "Server C (hung)")

        http.state.responseData = Data("[]".utf8)
        http.state.responseStatus = 200
        // Server C "hangs" for far longer than the fan-out timeout below.
        http.state.delayedHosts = ["hung-test-c.test": 5.0]

        let fastServersArrived = expectation(description: "fast servers' onResult fired")
        fastServersArrived.expectedFulfillmentCount = 2

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }
        let startedAt = Date()
        let results = await fanOut(
            servers: [serverA, serverB, serverC],
            store: store,
            session: session,
            timeout: 0.3,
            onResult: { sectionResult in
                if sectionResult.server.id != self.serverCID {
                    fastServersArrived.fulfill()
                }
            },
            request: { _, client in try await client.get("/api/v1/admin/sessions") as [AdminSession] }
        )

        // (a) The two fast servers' results are delivered almost
        // immediately — well before server C's 5s artificial delay, and
        // even before its own 0.3s timeout would elapse — proving
        // `onResult` genuinely decouples them rather than the caller only
        // finding out once every server (including the hung one) is done.
        await fulfillment(of: [fastServersArrived], timeout: 0.2)

        // (b) The whole call still returns promptly (bounded by the 0.3s
        // timeout, not anywhere near the 5s artificial hang), and server
        // C's own result is a timeout-shaped failure, not a hang.
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2.0, "fanOut must not block anywhere near the hung server's artificial delay")
        XCTAssertEqual(results.count, 3)
        guard let hungResult = results.first(where: { $0.server.id == serverCID }) else {
            return XCTFail("expected a result for the hung server")
        }
        guard case .failure(let error) = hungResult.result else {
            return XCTFail("expected the hung server to time out, not succeed")
        }
        XCTAssertEqual(error.errorDescription, "Request timed out")
    }

    // MARK: - I2: cancellation must never be materialized as a section failure

    /// Cancelling the enclosing Task mid-flight (before any server answers)
    /// must produce NO results at all for the cancelled server — not a
    /// `.failure` masquerading as a real per-server error. `onResult` must
    /// likewise never fire for it.
    func testFanOutDropsCancelledRequestsInsteadOfProducingFailures() async {
        let store = makeStore()
        try? store.updateToken("tok-a", forServerID: serverAID)
        let server = AdminServer(id: serverAID, baseURL: URL(string: "https://server-a.test")!, displayName: "Server A")

        http.state.responseData = Data("[]".utf8)
        http.state.responseStatus = 200
        // Long enough that the request is still in flight when we cancel.
        http.state.delayedHosts = ["server-a.test": 1.0]

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }
        var appliedResults: [ServerSectionResult<[AdminSession]>] = []
        let task = Task { () -> [ServerSectionResult<[AdminSession]>] in
            await fanOut(
                servers: [server],
                store: store,
                session: session,
                timeout: 5,
                onResult: { appliedResults.append($0) },
                request: { _, client in try await client.get("/api/v1/admin/sessions") as [AdminSession] }
            )
        }
        // Let the request actually start before cancelling it.
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let results = await task.value

        XCTAssertTrue(results.isEmpty, "a cancelled fan-out must produce no results at all, not a failure result")
        XCTAssertTrue(appliedResults.isEmpty, "onResult must never fire for a cancelled child")
    }

    // MARK: - resolveClient (Stage 2 review round 2/3, C1/C2): fanOut must
    // use whatever client `resolveClient` supplies instead of always
    // building its own fresh, admin-token-only client via `store.client(for:)`.

    /// The core contract every aggregate view model's `loadAll` depends on:
    /// when `resolveClient` is supplied, `fanOut` must issue its request
    /// against THAT client — not a fresh one it builds itself — even though
    /// `store` still holds a different (here: no) token for this server.
    /// Pre-fix (no `resolveClient` parameter at all, or one that's silently
    /// ignored), this test fails because the outgoing request either 404s
    /// on a missing Authorization header or the server section would come
    /// back with `NotSignedInError` since `store` has no token for this ID.
    func testFanOutUsesResolveClientWhenProvided() async throws {
        let store = makeStore()
        // Deliberately NO token written to `store` for this server — if
        // fanOut fell back to `store.client(for:)`, this would produce a
        // `NotSignedInError` failure section instead of a real request.
        let server = AdminServer(id: serverAID, baseURL: URL(string: "https://server-a.test")!, displayName: "Server A")
        http.state.hostOverrides = ["server-a.test": (Data("[]".utf8), 200)]

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }
        let suppliedClient = APIClient(baseURL: server.baseURL, accessToken: "resolve-client-token", session: session)

        // `store.accessToken(for:)` still gates whether a request is even
        // attempted (see fanOut's "not signed in" short-circuit), so write
        // SOME token there — the point of this test is that the CLIENT used
        // is `suppliedClient`, not that `store` is bypassed entirely.
        try store.updateToken("admin-token-should-not-be-used", forServerID: serverAID)

        let results = await fanOut(
            servers: [server],
            store: store,
            session: session,
            resolveClient: { _ in suppliedClient },
            request: { _, client in try await client.get("/api/v1/admin/sessions") as [AdminSession] }
        )

        XCTAssertEqual(results.count, 1)
        guard case .success = results[0].result else { return XCTFail("expected the request against the supplied client to succeed") }
        XCTAssertEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer resolve-client-token")
        XCTAssertNotEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer admin-token-should-not-be-used")
    }

    /// Companion case: with NO `resolveClient` supplied (every existing
    /// caller of `fanOut` before Stage 2's aggregate-client-sharing work),
    /// the original behavior is preserved exactly — `fanOut` falls back to
    /// building its own client via `store.client(for:)`.
    func testFanOutFallsBackToStoreClientWhenResolveClientIsNil() async throws {
        let store = makeStore()
        try store.updateToken("tok-a", forServerID: serverAID)
        let server = AdminServer(id: serverAID, baseURL: URL(string: "https://server-a.test")!, displayName: "Server A")
        http.state.hostOverrides = ["server-a.test": (Data("[]".utf8), 200)]

        let (session, invalidate) = makeInvalidatingSession()
        defer { invalidate() }

        let results = await fanOut(
            servers: [server],
            store: store,
            session: session,
            request: { _, client in try await client.get("/api/v1/admin/sessions") as [AdminSession] }
        )

        XCTAssertEqual(results.count, 1)
        guard case .success = results[0].result else { return XCTFail("expected success via store's own client") }
        XCTAssertEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok-a")
    }
}
