import XCTest
@testable import BloemAdmin

/// How a socket attempt is opened: a fresh single-use ticket in the subprotocol, never in the URL, and what
/// each way the ticket request can fail means for the connection.
@MainActor
final class LiveSocketConnectorTests: XCTestCase {
    private let http = MockHTTPHarness()
    private let ticketPath = "/api/v2/events/ws-ticket"
    private let goodTicket = String(repeating: "a", count: 43)

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(URL, [String])] = []
        func record(_ url: URL, _ protocols: [String]) { lock.withLock { items.append((url, protocols)) } }
        var all: [(URL, [String])] { lock.withLock { items } }
    }

    private func stubTicket(_ ticket: String? = nil, protocolName: String = "silo.events.v2") {
        http.state.stub(path: ticketPath, json: [
            "ticket": ticket ?? goodTicket, "expires_in": 30, "max_connection_seconds": 300, "protocol": protocolName,
        ])
    }

    private func failure(_ body: () async throws -> Void) async -> SessionTransportError? {
        do {
            try await body()
            return nil
        } catch {
            return error as? SessionTransportError
        }
    }

    func testAnAttemptMintsATicketAndOffersItInTheSubprotocolOnly() async throws {
        stubTicket()
        let opened = Opened()
        let socket = FakeLiveSocket()

        _ = try await LiveSocketConnector.connect(client: http.client) { url, protocols in
            opened.record(url, protocols)
            return socket
        }

        let (url, protocols) = try XCTUnwrap(opened.all.first)
        XCTAssertEqual(url.absoluteString, "wss://example.test/api/v2/events/ws")
        XCTAssertEqual(protocols, ["silo.events.v2", "silo.ticket.\(goodTicket)"])
        XCTAssertFalse(url.absoluteString.contains(goodTicket), "the ticket is not in the URL")
        XCTAssertNil(url.query)
    }

    func testEveryAttemptMintsItsOwnTicket() async throws {
        stubTicket()
        for _ in 0..<2 { _ = try await LiveSocketConnector.connect(client: http.client) { _, _ in FakeLiveSocket() } }
        XCTAssertEqual(http.state.requests(path: ticketPath).count, 2)
    }

    func testAServerWithoutTheTicketRouteHasNoSocket() async {
        for status in [404, 405, 501] {
            http.state.stub(path: ticketPath, json: ["status": status, "title": "no"], status: status)
            let error = await failure { _ = try await LiveSocketConnector.connect(client: http.client) { _, _ in FakeLiveSocket() } }
            XCTAssertEqual(error?.failure, .unsupported, "HTTP \(status)")
        }
    }

    func testAnAddressThatIsNotHTTPSHasNoSocket() async {
        let plain = APIClient(baseURL: URL(string: "http://example.test")!, accessToken: nil, session: http.session)
        let error = await failure { _ = try await LiveSocketConnector.connect(client: plain) { _, _ in FakeLiveSocket() } }
        XCTAssertEqual(error?.failure, .unsupported)
        XCTAssertTrue(http.state.requests(path: ticketPath).isEmpty, "no ticket is minted for a socket that cannot open")
    }

    func testARefusedLoginIsSignInRequiredWithTheServersAnswer() async {
        for status in [401, 403] {
            http.state.stub(path: ticketPath, json: ["status": status, "title": "no"], status: status)
            let error = await failure { _ = try await LiveSocketConnector.connect(client: http.client) { _, _ in FakeLiveSocket() } }
            XCTAssertEqual(error?.failure, .signInRequired)
            XCTAssertEqual(error?.authError?.statusCode, status)
        }
    }

    func testAnyOtherFailureIsAConnectionFailure() async {
        http.state.stub(path: ticketPath, json: ["status": 503, "title": "busy"], status: 503)
        let error = await failure { _ = try await LiveSocketConnector.connect(client: http.client) { _, _ in FakeLiveSocket() } }
        XCTAssertEqual(error?.failure, .connection)
    }

    func testATicketOfAnotherProtocolOrShapeIsRefused() async {
        stubTicket(protocolName: "silo.events.v3")
        var error = await failure { _ = try await LiveSocketConnector.connect(client: http.client) { _, _ in FakeLiveSocket() } }
        XCTAssertEqual(error?.failure, .protocolViolation)

        stubTicket("short")
        error = await failure { _ = try await LiveSocketConnector.connect(client: http.client) { _, _ in FakeLiveSocket() } }
        XCTAssertEqual(error?.failure, .protocolViolation)

        stubTicket(String(repeating: "a", count: 42) + "!")
        error = await failure { _ = try await LiveSocketConnector.connect(client: http.client) { _, _ in FakeLiveSocket() } }
        XCTAssertEqual(error?.failure, .protocolViolation)
    }
}
