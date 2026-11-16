import XCTest
@testable import BloemAdmin

final class RequestAvailabilityTests: XCTestCase {
    func testAServerWithoutTheRequestServiceIsUnavailableAndStopsPolling() {
        let error = APIError(statusCode: 503, code: "dependency_unavailable", message: "The request administration service is not available on this server.")
        XCTAssertTrue(RequestAvailability.isUnavailable(error))
        XCTAssertTrue(RequestAvailability.stopsPolling(error))
    }

    func testLostRightsStopPollingButAreNotUnavailability() {
        let error = APIError(statusCode: 403, code: "permission_denied", message: "Not allowed.")
        XCTAssertFalse(RequestAvailability.isUnavailable(error))
        XCTAssertTrue(RequestAvailability.stopsPolling(error))
    }

    func testAServerThatIsRestartingIsWorthAskingAgain() {
        XCTAssertFalse(RequestAvailability.stopsPolling(APIError(statusCode: 503, message: "Try again soon.")))
        XCTAssertFalse(RequestAvailability.stopsPolling(APIError(statusCode: 500, code: "internal_error", message: "Oops.")))
        XCTAssertFalse(RequestAvailability.stopsPolling(URLError(.timedOut)))
    }
}

@MainActor
final class RequestBadgeModelTests: XCTestCase {
    private var http: MockHTTPHarness!
    private var otherHTTP: MockHTTPHarness!
    private var client: APIClient!
    private var otherClient: APIClient!
    private let counts = "/api/v2/admin/requests/counts"

    override func setUp() async throws {
        http = MockHTTPHarness()
        otherHTTP = MockHTTPHarness()
        client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        otherClient = APIClient(baseURL: URL(string: "https://other.test")!, accessToken: nil, session: otherHTTP.session)
    }

    override func tearDown() async throws {
        http.invalidate()
        otherHTTP.invalidate()
    }

    private func answer(_ needsApproval: Int) -> Data {
        Data(#"{"needs_approval":\#(needsApproval),"in_progress":5,"failed":1,"done":40}"#.utf8)
    }

    private let unavailable = Data(#"{"type":"https://example.test/problems/dependency_unavailable","title":"Dependency unavailable","status":503,"detail":"The request administration service is not available on this server."}"#.utf8)

    func testCountsOneServersNeedsApprovalFromTheCountsRoute() async {
        http.state.stub(path: counts, data: answer(4))
        let badge = RequestBadgeModel()

        await badge.refresh(sources: [RequestBadgeSource(serverID: "a", client: client)])

        XCTAssertEqual(badge.needsApproval, 4)
        XCTAssertEqual(http.state.requests(path: counts).count, 1)
        XCTAssertEqual(http.state.requests(path: counts).first?.httpMethod, "GET")
    }

    func testAllServersAddsTheServersUp() async {
        http.state.stub(path: counts, data: answer(4))
        otherHTTP.state.stub(path: counts, data: answer(3))
        let badge = RequestBadgeModel()

        await badge.refresh(sources: [
            RequestBadgeSource(serverID: "a", client: client), RequestBadgeSource(serverID: "b", client: otherClient),
        ])

        XCTAssertEqual(badge.needsApproval, 7)
    }

    func testAServerThatFailsOnceKeepsItsLastCountAndOthersStillCount() async {
        http.state.stub(path: counts, data: answer(4))
        otherHTTP.state.stub(path: counts, data: answer(3))
        let badge = RequestBadgeModel()
        let sources = [RequestBadgeSource(serverID: "a", client: client), RequestBadgeSource(serverID: "b", client: otherClient)]
        await badge.refresh(sources: sources)

        http.state.stub(path: counts, data: Data(), status: 500)
        otherHTTP.state.stub(path: counts, data: answer(1))
        await badge.refresh(sources: sources)

        XCTAssertEqual(badge.needsApproval, 5, "a's last answer (4) stays while it cannot answer, and b's new one (1) counts")
    }

    func testAServerWithoutRequestAdministrationCountsNothingAndIsNotAskedAgain() async {
        http.state.stub(path: counts, data: unavailable, status: 503)
        otherHTTP.state.stub(path: counts, data: answer(2))
        let badge = RequestBadgeModel()
        let sources = [RequestBadgeSource(serverID: "a", client: client), RequestBadgeSource(serverID: "b", client: otherClient)]

        await badge.refresh(sources: sources)
        await badge.refresh(sources: sources)

        XCTAssertEqual(badge.needsApproval, 2)
        XCTAssertEqual(http.state.requests(path: counts).count, 1, "polling that server stopped after the first answer")
        XCTAssertEqual(otherHTTP.state.requests(path: counts).count, 2)
    }

    func testLostRightsStopPollingToo() async {
        http.state.stub(path: counts, data: Data(#"{"type":"https://example.test/problems/permission_denied","title":"Permission denied","status":403,"detail":"Not allowed."}"#.utf8), status: 403)
        let badge = RequestBadgeModel()
        let sources = [RequestBadgeSource(serverID: "a", client: client)]

        await badge.refresh(sources: sources)
        await badge.refresh(sources: sources)

        XCTAssertEqual(badge.needsApproval, 0)
        XCTAssertEqual(http.state.requests(path: counts).count, 1)
    }

    func testAServerLeavingTheScopeDropsOutOfTheSum() async {
        http.state.stub(path: counts, data: answer(4))
        otherHTTP.state.stub(path: counts, data: answer(3))
        let badge = RequestBadgeModel()
        await badge.refresh(sources: [RequestBadgeSource(serverID: "a", client: client), RequestBadgeSource(serverID: "b", client: otherClient)])

        await badge.refresh(sources: [RequestBadgeSource(serverID: "b", client: otherClient)])

        XCTAssertEqual(badge.needsApproval, 3)
    }

    func testAStoppedServerIsAskedAgainWhenAskedToStartOver() async {
        http.state.stub(path: counts, data: unavailable, status: 503)
        let badge = RequestBadgeModel()
        let sources = [RequestBadgeSource(serverID: "a", client: client)]
        await badge.refresh(sources: sources)

        http.state.stub(path: counts, data: answer(6))
        await badge.refresh(sources: sources, includingStopped: true)

        XCTAssertEqual(badge.needsApproval, 6)
    }

    func testTheRequestsPageCanReportItsOwnCountWithoutAnotherRead() async {
        http.state.stub(path: counts, data: answer(4))
        let badge = RequestBadgeModel()
        await badge.refresh(sources: [RequestBadgeSource(serverID: "a", client: client)])

        badge.record(needsApproval: 1, serverID: "a")

        XCTAssertEqual(badge.needsApproval, 1)
    }

    func testARefreshReadsOnceAndNothingReadsAgainOnItsOwn() async {
        http.state.stub(path: counts, data: answer(1))
        let badge = RequestBadgeModel()
        let source = RequestBadgeSource(serverID: "a", client: client)

        await badge.refresh(sources: [source])
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(http.state.requests(path: counts).count, 1, "the badge has no timer")
        XCTAssertEqual(badge.needsApproval, 1)
    }
}

final class RequestBadgeTextTests: XCTestCase {
    func testTheBadgeShowsTheCountAndSaysItInWords() {
        XCTAssertEqual(RequestBadgeText.visible(3), "3")
        XCTAssertEqual(RequestBadgeText.visible(120), "99+")
        XCTAssertEqual(RequestBadgeText.spoken(1), "1 request needs approval")
        XCTAssertEqual(RequestBadgeText.spoken(3), "3 requests need approval")
    }

    func testNothingWaitingShowsNoBadge() {
        XCTAssertNil(RequestBadgeText.visible(0))
        XCTAssertNil(RequestBadgeText.spoken(0))
    }
}
