import XCTest
@testable import BloemAdmin

/// The check is one unauthenticated GET /api/v1/health. These tests use a stand-in transport only.
final class HealthProbeTests: XCTestCase {
    private let base = URL(string: "https://media.example.test")!

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests_: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { requests_ } }
        func record(_ request: URLRequest) { lock.withLock { requests_.append(request) } }
    }

    private static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://media.example.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private func probe(
        _ outcome: @escaping @Sendable () throws -> URLResponse, recorder: Recorder = Recorder()
    ) -> HealthProbe {
        HealthProbe(timeout: 7) { request in
            recorder.record(request)
            return (Data(), try outcome())
        }
    }

    // MARK: The request

    func testRequestIsAPlainGetWithNoCredentials() async {
        let recorder = Recorder()
        let result = await probe({ Self.response(200) }, recorder: recorder).check(baseURL: base)
        XCTAssertEqual(result, .up)
        let request = try? XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request?.url?.absoluteString, "https://media.example.test/api/v1/health")
        XCTAssertEqual(request?.httpMethod, "GET")
        XCTAssertEqual(request?.timeoutInterval, 7)
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request?.httpShouldHandleCookies, false)
        XCTAssertNil(request?.httpBody)
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testRequestKeepsTheServersPort() {
        let request = HealthProbe.request(baseURL: URL(string: "https://nas.example.test:8443")!, timeout: 10)
        XCTAssertEqual(request.url?.absoluteString, "https://nas.example.test:8443/api/v1/health")
    }

    // MARK: Answers

    func testAnyAnswerBelowFiveHundredMeansTheServerIsUp() async {
        for status in [200, 204, 301, 401, 403, 404] {
            let result = await probe({ Self.response(status) }).check(baseURL: base)
            XCTAssertEqual(result, .up, "\(status)")
        }
    }

    func testAServerErrorMeansDown() async {
        for status in [500, 502, 503, 504] {
            let result = await probe({ Self.response(status) }).check(baseURL: base)
            XCTAssertEqual(result, .down(.serverError(status)))
        }
    }

    func testAnAnswerThatIsNotHTTPMeansDown() async {
        let result = await probe({ URLResponse() }).check(baseURL: base)
        XCTAssertEqual(result, .down(.other))
    }

    // MARK: Failures

    func testTransportFailuresAreClassified() async {
        let cases: [(URLError.Code, HealthProbeResult)] = [
            (.timedOut, .down(.timedOut)),
            (.cannotConnectToHost, .down(.cannotConnect)),
            (.cannotFindHost, .down(.cannotConnect)),
            (.dnsLookupFailed, .down(.cannotConnect)),
            (.networkConnectionLost, .down(.cannotConnect)),
            (.secureConnectionFailed, .down(.secureConnection)),
            (.serverCertificateUntrusted, .down(.secureConnection)),
            (.serverCertificateHasBadDate, .down(.secureConnection)),
            (.badServerResponse, .down(.other)),
        ]
        for (code, expected) in cases {
            let result = await probe({ throw URLError(code) }).check(baseURL: base)
            XCTAssertEqual(result, expected, "\(code.rawValue)")
        }
    }

    func testAPhoneThatCannotReachTheInternetSaysNothingAboutTheServer() async {
        for code: URLError.Code in [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive, .cancelled] {
            let result = await probe({ throw URLError(code) }).check(baseURL: base)
            XCTAssertEqual(result, .inconclusive, "\(code.rawValue)")
        }
        let cancelled = await probe({ throw CancellationError() }).check(baseURL: base)
        XCTAssertEqual(cancelled, .inconclusive)
    }

    func testFailureNamesAreShortAndPlain() {
        XCTAssertEqual(HealthFailure.timedOut.summary, "timed out")
        XCTAssertEqual(HealthFailure.cannotConnect.summary, "could not connect")
        XCTAssertEqual(HealthFailure.secureConnection.summary, "secure connection failed")
        XCTAssertEqual(HealthFailure.serverError(503).summary, "server error 503")
        XCTAssertEqual(HealthFailure.other.summary, "no usable answer")
    }
}
