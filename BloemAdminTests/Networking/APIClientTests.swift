import XCTest
@testable import BloemAdmin

@MainActor
final class APIClientTests: XCTestCase {
    func testProductionSessionUsesEphemeralStorageAndFiniteTimeouts() {
        let session = ProductionSession.make()
        defer { session.invalidateAndCancel() }

        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertFalse(session.configuration.httpShouldSetCookies)
        XCTAssertEqual(session.configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertGreaterThan(session.configuration.timeoutIntervalForRequest, 0)
        XCTAssertLessThanOrEqual(session.configuration.timeoutIntervalForRequest, 30)
        XCTAssertGreaterThanOrEqual(
            session.configuration.timeoutIntervalForResource,
            session.configuration.timeoutIntervalForRequest
        )
        XCTAssertLessThanOrEqual(session.configuration.timeoutIntervalForResource, 60)
    }

    func testProductionSessionRejectsRedirectedLoginRequest() throws {
        let session = ProductionSession.make()
        defer { session.invalidateAndCancel() }
        let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
        let originalURL = try XCTUnwrap(URL(string: "https://media.example.test/api/v1/auth/login"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://attacker.example.test/collect"))
        let task = session.dataTask(with: originalURL)
        defer { task.cancel() }
        let response = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 307,
            httpVersion: nil,
            headerFields: ["Location": redirectedURL.absoluteString]
        ))
        let completionCalled = expectation(description: "redirect decision")
        delegate.urlSession!(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            XCTAssertNil(request)
            completionCalled.fulfill()
        }

        wait(for: [completionCalled], timeout: 1)
    }

    func testGetDecodesSuccessResponse() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"started_at":"2026-01-01T00:00:00Z","restart_required":false,"restart_requested":false}"#.utf8)
        http.state.responseStatus = 200

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok123", session: session)
        let status: TestStatusProbe = try await client.get("/api/v1/admin/server/status")

        XCTAssertEqual(status.restartRequired, false)
        XCTAssertEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer tok123")
    }

    func testHTTPBaseURLRejectsBeforeReadingOrSendingBearerCredential() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/api/v1/admin/server/status",
            json: [
                "started_at": "2026-01-01T00:00:00Z",
                "restart_required": false,
                "restart_requested": false,
            ]
        )
        var providerCalls = 0
        let client = APIClient(
            baseURL: URL(string: "http://legacy.example.test")!,
            credentialProvider: {
                providerCalls += 1
                return RequestCredential(
                    accessToken: "must-not-leave-device",
                    identity: RequestIdentity(serverID: "legacy", principal: .administrator, generation: 1)
                )
            },
            session: http.session
        )

        do {
            let _: TestStatusProbe = try await client.get("/api/v1/admin/server/status")
            XCTFail("expected insecure transport to be rejected")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "insecure_transport")
        } catch {
            XCTFail("expected APIError, got \(error)")
        }

        XCTAssertEqual(providerCalls, 0)
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testGetThrowsAPIErrorOnNon2xx() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = http.session
        http.state.responseData = Data(#"{"error":"invalid_credentials","message":"Invalid username or password"}"#.utf8)
        http.state.responseStatus = 401

        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: session)
        do {
            let _: TestStatusProbe = try await client.get("/api/v1/admin/server/status")
            XCTFail("expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }
    }

    func testCredentialProviderIsReadExactlyOncePerRequest() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/action", data: Data(), status: 204)
        var providerCalls = 0
        let identity = RequestIdentity(serverID: "srv", principal: .administrator, generation: 4)
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: {
                providerCalls += 1
                return RequestCredential(accessToken: "snapshot-token", identity: identity)
            },
            session: http.session
        )

        try await client.post("/action")

        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(http.state.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer snapshot-token")
    }

    func testNon2xxErrorCarriesTheRequestCredentialIdentity() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/action", json: ["message": "expired"], status: 401)
        let identity = RequestIdentity(serverID: "srv", principal: .administrator, generation: 9)
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: {
                RequestCredential(accessToken: "alice-token", identity: identity)
            },
            session: http.session
        )

        do {
            try await client.post("/action")
            XCTFail("expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertEqual(error.requestIdentity, identity)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testFixedTokenErrorHasNoRequestIdentity() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/action", json: ["message": "expired"], status: 401)
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            accessToken: "fixed-token",
            session: http.session
        )

        do {
            try await client.post("/action")
            XCTFail("expected APIError to be thrown")
        } catch let error as APIError {
            XCTAssertNil(error.requestIdentity)
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
    }

    func testTopLevelErrorStillPreservesCodeAndMessage() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/login", json: ["error": "invalid_credentials", "message": "Invalid credentials"], status: 401)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)

        do {
            try await client.post("/login")
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_credentials")
            XCTAssertEqual(error.message, "Invalid credentials")
            XCTAssertNil(error.retryAfter)
        }
    }

    func testProblemJSONFillsCodeFromTypeAndMessageFromDetail() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/value",
            json: [
                "type": "https://siloserver.org/docs/api/v2/problems/not_found",
                "title": "Not found",
                "status": 404,
                "detail": "No operation is registered at this path.",
            ],
            status: 404
        )
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)

        do {
            let _: TestStatusProbe = try await client.get("/value")
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "not_found")
            XCTAssertEqual(error.message, "No operation is registered at this path.")
            XCTAssertFalse(error.isClientUpgradeRequired)
        }
    }

    func testProblemJSONAboutBlankHasNoCodeAndFallsBackToTitle() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/value",
            json: ["type": "about:blank", "title": "Bad Gateway", "status": 502],
            status: 502
        )
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)

        do {
            let _: TestStatusProbe = try await client.get("/value")
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertNil(error.code)
            XCTAssertEqual(error.message, "Bad Gateway")
        }
    }

    func testTombstoneIsAnUpgradeErrorWithLocalizedMessage() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/api/v1/admin/users",
            json: [
                "error": "client_upgrade_required",
                "message": "This server no longer serves /api/v1. Update the app to continue.",
            ],
            status: 410
        )
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)

        do {
            let _: TestStatusProbe = try await client.get("/api/v1/admin/users")
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertTrue(error.isClientUpgradeRequired)
            XCTAssertEqual(error.message, String(localized: "This server needs a newer version of Bloem Admin."))
        }
    }

    func testGoneWithAnotherCodeIsNotAnUpgradeError() {
        XCTAssertFalse(APIError(statusCode: 410, code: "gone", message: "x").isClientUpgradeRequired)
        XCTAssertFalse(APIError(statusCode: 404, code: "client_upgrade_required", message: "x").isClientUpgradeRequired)
    }

    func testPutConditionalSendsIfMatchAndBody() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things/1", data: Data(), status: 204)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)

        try await client.putConditional("/api/v2/things/1", body: ["name": "x"], validator: "\"r1\"")

        let request = try XCTUnwrap(http.state.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"r1\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(http.state.capturedBody, Data(#"{"name":"x"}"#.utf8))
    }

    func testDeleteConditionalSendsIfMatchAndIsNotReplayedAfter401() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things/1", json: ["error": "unauthorized", "message": "denied"], status: 401)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "old", session: http.session)

        do {
            try await client.deleteConditional("/api/v2/things/1", validator: "\"r1\"")
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }

        let requests = http.state.requests(path: "/api/v2/things/1")
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "DELETE")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "If-Match"), "\"r1\"")
    }

    func testPutConditionalIsNotReplayedAfter401() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/things/1", json: ["error": "unauthorized", "message": "denied"], status: 401)
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "old", session: http.session)

        do {
            try await client.putConditional("/api/v2/things/1", body: ["name": "x"], validator: "\"r1\"")
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }
        XCTAssertEqual(http.state.requests(path: "/api/v2/things/1").count, 1)
    }

    func testGetWithValidatorReturnsBodyAndETag() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/api/v2/status",
            response: MockHTTPResponse(
                json: ["started_at": "2026-01-01T00:00:00Z", "restart_required": true, "restart_requested": false],
                headers: ["ETag": "\"r7\""]
            )
        )
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)

        let (status, validator): (TestStatusProbe, String?) = try await client.getWithValidator("/api/v2/status")

        XCTAssertTrue(status.restartRequired)
        XCTAssertEqual(validator, "\"r7\"")
    }

    func testGetWithValidatorWithoutETagReturnsNil() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/status", json: ["restart_required": false])
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)

        let (_, validator): (TestStatusProbe, String?) = try await client.getWithValidator("/api/v2/status")

        XCTAssertNil(validator)
    }

    func testAPIPathSegmentEncodesEverythingOutsideUnreserved() {
        XCTAssertEqual(APIPath.segment("AZaz09-._~"), "AZaz09-._~")
        XCTAssertEqual(APIPath.segment("a/b"), "a%2Fb")
        XCTAssertEqual(APIPath.segment("a?b"), "a%3Fb")
        XCTAssertEqual(APIPath.segment("a#b"), "a%23b")
        XCTAssertEqual(APIPath.segment("a%b"), "a%25b")
        XCTAssertEqual(APIPath.segment("a b"), "a%20b")
        XCTAssertEqual(APIPath.segment("a%2Fb"), "a%252Fb")
        XCTAssertEqual(APIPath.segment(".."), "%2E%2E")
        XCTAssertEqual(APIPath.segment("."), "%2E")
        XCTAssertEqual(APIPath.segment("x/../y"), "x%2F..%2Fy")
    }

    func testEncodedIdsStayOneSegmentInTheRequestURL() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "tok", session: http.session)
        let cases: [(id: String, expected: String)] = [
            ("a/b", "a%2Fb"), ("a?b", "a%3Fb"), ("a#b", "a%23b"), ("a%b", "a%25b"),
            ("..", "%2E%2E"), ("a b", "a%20b"), ("100%", "100%25"), ("a%2Fb", "a%252Fb"),
        ]

        for (id, expected) in cases {
            http.state.requestLog = []
            let _: EmptyResponse = try await client.get("/api/v2/admin/users/\(APIPath.segment(id))/devices")
            XCTAssertEqual(
                http.state.lastRequest?.url?.absoluteString,
                "https://example.test/api/v2/admin/users/\(expected)/devices",
                "id: \(id)"
            )
        }
    }

    func testSendKeepsBaseURLPathAndNeverDoubleEncodes() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = APIClient(baseURL: URL(string: "https://example.test/media/")!, accessToken: nil, session: http.session)

        let _: EmptyResponse = try await client.get("/api/v2/things/a%2Fb", query: ["q": "x y", "empty": ""])

        XCTAssertEqual(
            http.state.lastRequest?.url?.absoluteString,
            "https://example.test/media/api/v2/things/a%2Fb?q=x%20y"
        )
    }

    func testMalformedEncodedPathIsRejectedWithoutSending() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)

        do {
            let _: EmptyResponse = try await client.get("/api/v2/things/100%")
            XCTFail("expected APIError")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "invalid_path")
        } catch {
            XCTFail("expected APIError, got \(error)")
        }
        XCTAssertTrue(http.state.requestLog.isEmpty)
    }

    func testNoImpersonationPathRemains() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Networking
            .deletingLastPathComponent()  // BloemAdminTests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("BloemAdmin")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let file as URL in enumerator where file.pathExtension == "swift" {
            if file.pathComponents.contains("Audit") { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if text.range(of: "impersonat", options: .caseInsensitive) != nil {
                offenders.append(file.lastPathComponent)
            }
        }
        XCTAssertEqual(offenders, [], "impersonation code must stay removed outside Audit/")
    }
}

// Minimal decode target used only to exercise the client in THIS test file.
// Deliberately named distinctly from the real `ServerStatus` Task 9 adds to
// the app module — both would otherwise be visible as bare `ServerStatus`
// inside this test target (which `@testable import`s the app module),
// making every later reference to the name ambiguous.
struct TestStatusProbe: Decodable {
    let restartRequired: Bool
    enum CodingKeys: String, CodingKey { case restartRequired = "restart_required" }
}
