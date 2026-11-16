import XCTest
@testable import BloemAdmin

/// A server is a Bloem server when `GET /api/bloem/v2/capabilities` answers with a capabilities document; a plain Silo
/// server answers 404. The answer is asked once per server and remembered for the session.
final class BloemServerDetectorTests: XCTestCase {
    private let capabilities = "/api/bloem/v2/capabilities"
    nonisolated private let http = MockHTTPHarness()

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func client(_ detector: BloemServerDetector?, host: String = "example.test") -> APIClient {
        APIClient(baseURL: URL(string: "https://\(host)")!, accessToken: nil, session: http.session, bloemDetector: detector)
    }

    func testABloemServerIsRecognisedAndAskedOnce() async throws {
        http.state.stubBloemServer(featureTokens: ["organization_support_v1"])
        let detector = BloemServerDetector()
        let client = client(detector)

        let first = try await client.bloemCapabilitiesIfBloem()
        let second = try await client.bloemCapabilitiesIfBloem()
        let isBloem = await client.isBloemServer()

        XCTAssertEqual(first?.offersOrganizationSupport, true)
        XCTAssertEqual(second, first)
        XCTAssertTrue(isBloem)
        XCTAssertEqual(http.state.requests(path: capabilities).count, 1)
        XCTAssertEqual(detector.cachedVerdict(for: client.origin)?.isBloem, true)
    }

    func testAPlainSiloServerIsRecognisedByA404AndAskedOnce() async throws {
        http.state.stubPlainSilo()
        let detector = BloemServerDetector()
        let client = client(detector)

        let first = try await client.bloemCapabilitiesIfBloem()
        let isBloem = await client.isBloemServer()

        XCTAssertNil(first)
        XCTAssertFalse(isBloem)
        XCTAssertEqual(http.state.requests(path: capabilities).count, 1)
        XCTAssertEqual(detector.cachedVerdict(for: client.origin), .plainSilo)
    }

    func testAnHTMLPageAnswering200IsNotABloemServer() async throws {
        http.state.stub(path: capabilities, data: Data("<html><body>hello</body></html>".utf8))
        let client = client(BloemServerDetector())

        let result = try await client.bloemCapabilitiesIfBloem()

        XCTAssertNil(result)
    }

    func testAServerThatCannotBeAskedIsNotRememberedAndIsAskedAgain() async throws {
        http.state.stubSequence(path: capabilities, responses: [
            MockHTTPResponse(data: Data("bad gateway".utf8), status: 502),
            MockHTTPResponse(transportError: .notConnectedToInternet),
            MockHTTPResponse(data: Data("bad gateway".utf8), status: 502),
            MockHTTPResponse(data: Data(#"{"api":"bloem/v2","feature_tokens":[]}"#.utf8)),
        ])
        let detector = BloemServerDetector()
        let client = client(detector)

        for _ in 0..<2 {
            do {
                _ = try await client.bloemCapabilitiesIfBloem()
                XCTFail("an unanswered question must reach the caller")
            } catch {}
        }
        let notBloemMeanwhile = await client.isBloemServer()
        XCTAssertNil(detector.cachedVerdict(for: client.origin), "nothing is remembered from a failure")
        XCTAssertFalse(notBloemMeanwhile, "an unanswered server keeps the extras off")

        let result = try await client.bloemCapabilitiesIfBloem()
        XCTAssertNotNil(result)
    }

    func testPagesAskingAtTheSameTimeShareOneRequest() async throws {
        http.state.stubBloemServer()
        let detector = BloemServerDetector()
        let client = client(detector)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 { group.addTask { await client.isBloemServer() } }
            for await isBloem in group { XCTAssertTrue(isBloem) }
        }

        XCTAssertEqual(http.state.requests(path: capabilities).count, 1)
    }

    func testEachServerHasItsOwnVerdict() async throws {
        http.state.stub(host: "bloem.test", path: capabilities, data: Data(#"{"api":"bloem/v2","feature_tokens":[]}"#.utf8))
        http.state.stub(host: "silo.test", path: capabilities, data: Data("404 page not found".utf8), status: 404)
        let detector = BloemServerDetector()
        let bloem = client(detector, host: "bloem.test")
        let silo = client(detector, host: "silo.test")

        let bloemAnswer = await bloem.isBloemServer()
        let siloAnswer = await silo.isBloemServer()

        XCTAssertTrue(bloemAnswer)
        XCTAssertFalse(siloAnswer)
        XCTAssertTrue(detector.anyKnownBloem(in: [silo.origin, bloem.origin]))
        XCTAssertFalse(detector.anyKnownBloem(in: [silo.origin]))
        XCTAssertFalse(detector.anyKnownBloem(in: [URL(string: "https://never-asked.test")!]), "an unasked server is not Bloem")
    }

    func testForgettingAServerAsksItAgain() async throws {
        http.state.stubPlainSilo()
        let detector = BloemServerDetector()
        let client = client(detector)
        _ = await client.isBloemServer()

        detector.forget(origin: client.origin)
        http.state.stubBloemServer()
        let isBloem = await client.isBloemServer()

        XCTAssertTrue(isBloem)
        XCTAssertEqual(http.state.requests(path: capabilities).count, 2)
    }

    func testAClientWithoutADetectorAsksEveryTime() async throws {
        http.state.stubPlainSilo()
        let client = client(nil)

        _ = await client.isBloemServer()
        _ = await client.isBloemServer()

        XCTAssertEqual(http.state.requests(path: capabilities).count, 2)
    }

    func testTheServerStoreSharesOneDetectorWithEveryClientItBuilds() async throws {
        http.state.stubPlainSilo()
        let store = await MainActor.run { makeIsolatedServerStore() }
        let server = AdminServer.fixture
        let sessionState = await MainActor.run { AdminSessionState() }
        let first = await store.client(for: server, sessionState: sessionState, session: http.session)
        let second = await store.client(for: server, session: http.session)

        _ = await first.isBloemServer()
        _ = await second.isBloemServer()

        XCTAssertEqual(http.state.requests(path: capabilities).count, 1)
    }
}
