import XCTest
@testable import BloemAdmin

/// Item 3 of the people wave: the queue says plainly when request administration is unavailable, stops asking,
/// and says when what it shows is out of date.
@MainActor
final class RequestQueueAvailabilityTests: XCTestCase {
    private var http: MockHTTPHarness!
    private var client: APIClient!
    private let capabilities = "/api/v2/admin/requests/capabilities"
    private let counts = "/api/v2/admin/requests/counts"
    private let list = "/api/v2/admin/requests"

    override func setUp() async throws {
        http = MockHTTPHarness()
        client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        http.state.stub(path: "/api/v2/admin/users", data: Data(#"{"items":[]}"#.utf8))
    }

    override func tearDown() async throws {
        http.invalidate()
    }

    private func capabilitiesBody(available: Bool) -> Data {
        Data(#"{"revision":"r1","state":"\#(available ? "available" : "unsupported")","available":\#(available),"guarded_configuration":true,"routing":true,"routing_series_status":true,"discover_layout":true,"discover_list_order":true}"#.utf8)
    }

    private let countsBody = Data(#"{"needs_approval":2,"in_progress":3,"failed":1,"done":7}"#.utf8)

    private func page(_ ids: [String]) -> MockHTTPResponse {
        let items = ids.map { RequestsViewModelTests.mediaRequestJSON(id: $0, title: "T\($0)") }.joined(separator: ",")
        return MockHTTPResponse(data: Data(#"{"items":[\#(items)],"page":{"has_more":false}}"#.utf8), status: 200)
    }

    private let unavailable = Data(#"{"type":"https://example.test/problems/dependency_unavailable","title":"Dependency unavailable","status":503,"detail":"The request administration service is not available on this server."}"#.utf8)

    func testTheCapabilitiesDocumentDecodesWhetherRequestAdministrationIsAvailable() async throws {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: false))
        let read = try await client.requestCapabilities()
        XCTAssertFalse(read.available)
        XCTAssertEqual(http.state.requests(path: capabilities).first?.httpMethod, "GET")
    }

    func testACapabilitiesDocumentThatSaysUnavailableAsksForNothingElse() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: false))
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertTrue(model.isUnavailable)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertNil(model.loadFailure, "this is not a failure to retry")
        XCTAssertTrue(http.state.requests(path: counts).isEmpty)
        XCTAssertTrue(http.state.requests(path: list).isEmpty)
        XCTAssertFalse(model.shouldPoll)
    }

    func testAnUnavailableAnswerFromTheQueueAlsoMeansUnavailable() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: unavailable, status: 503)
        http.state.stub(path: list, data: unavailable, status: 503)
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertTrue(model.isUnavailable)
        XCTAssertNil(model.loadFailure)
        XCTAssertFalse(model.shouldPoll)
    }

    func testAnOlderServerWithoutTheCapabilitiesRouteIsAskedAboutTheQueueDirectly() async {
        http.state.stub(path: capabilities, data: Data(), status: 404)
        http.state.stub(path: counts, data: countsBody)
        http.state.stubSequence(path: list, responses: [page(["1", "2"])])
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertFalse(model.isUnavailable)
        XCTAssertEqual(model.requests.map(\.id), ["1", "2"])
        XCTAssertTrue(model.shouldPoll)
    }

    func testRefreshingAnUnavailableQueueSendsNothing() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: false))
        let model = RequestQueueViewModel()
        await model.load(client: client)
        let before = http.state.requestLog.count

        await model.refresh(client: client)

        XCTAssertEqual(http.state.requestLog.count, before, "polling stopped")
    }

    func testPullingToRefreshAsksAgainAndRecoversWhenTheServiceComesBack() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: false))
        let model = RequestQueueViewModel()
        await model.load(client: client)
        XCTAssertTrue(model.isUnavailable)

        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: countsBody)
        http.state.stubSequence(path: list, responses: [page(["1"])])
        await model.load(client: client)

        XCTAssertFalse(model.isUnavailable)
        XCTAssertEqual(model.requests.map(\.id), ["1"])
        XCTAssertTrue(model.shouldPoll)
    }

    func testRowsStillLoadWhenTheCountsCannotBeRead() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: Data(), status: 500)
        http.state.stubSequence(path: list, responses: [page(["1"])])
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertEqual(model.requests.map(\.id), ["1"])
        XCTAssertNil(model.loadFailure)
        XCTAssertNil(model.counts)
        XCTAssertEqual(model.view, .needsApproval, "the web opens on Needs approval when it cannot tell")
    }

    func testALostSignInOrRightOnTheCountsStopsTheLoadLikeAnyOtherPage() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: Data(#"{"error":"forbidden","message":"No"}"#.utf8), status: 403)
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertEqual(model.loadFailure?.kind, .forbidden, "the page says No access, not an empty queue")
        XCTAssertTrue(http.state.requests(path: list).isEmpty, "there is nothing to read the rows with")
        XCTAssertFalse(model.isUnavailable)

        http.state.stub(path: counts, data: Data(#"{"error":"unauthorized","message":"Sign in"}"#.utf8), status: 401)
        await model.load(client: client)
        XCTAssertEqual(model.loadFailure?.kind, .signedOut)
    }

    func testAFailedRefreshKeepsTheRowsAndSaysWhenTheyWereRead() async {
        let readAt = Date(timeIntervalSince1970: 1_794_000_000)
        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: countsBody)
        http.state.stubSequence(path: list, responses: [page(["1", "2"]), MockHTTPResponse(data: Data(), status: 500)])
        let model = RequestQueueViewModel(now: { readAt })
        await model.load(client: client)
        XCTAssertFalse(model.isStale)
        XCTAssertNil(model.staleNotice)

        await model.refresh(client: client)

        XCTAssertEqual(model.requests.map(\.id), ["1", "2"], "what was read stays on screen")
        XCTAssertTrue(model.isStale)
        XCTAssertEqual(model.staleNotice, "Couldn't refresh · last updated \(readAt.formatted(date: .omitted, time: .shortened))")
    }

    func testASuccessfulReadClearsTheStaleNotice() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: countsBody)
        http.state.stubSequence(path: list, responses: [page(["1"]), MockHTTPResponse(data: Data(), status: 500), page(["1"])])
        let model = RequestQueueViewModel()
        await model.load(client: client)
        await model.refresh(client: client)
        XCTAssertTrue(model.isStale)

        await model.load(client: client)

        XCTAssertFalse(model.isStale)
        XCTAssertNil(model.staleNotice)
    }

    func testAnEmptyQueueThatCannotLoadIsAFailureNotStaleness() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: countsBody)
        http.state.stub(path: list, data: Data(), status: 500)
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertNotNil(model.loadFailure)
        XCTAssertFalse(model.isStale, "there are no older rows to call stale")
    }

    func testCapabilitiesAreReadOncePerPageNotOnEveryPoll() async {
        http.state.stub(path: capabilities, data: capabilitiesBody(available: true))
        http.state.stub(path: counts, data: countsBody)
        http.state.stubSequence(path: list, responses: [page(["1"]), page(["1"]), page(["1"])])
        let model = RequestQueueViewModel()

        await model.load(client: client)
        await model.refresh(client: client)
        await model.refresh(client: client)

        XCTAssertEqual(http.state.requests(path: capabilities).count, 1)
    }
}
