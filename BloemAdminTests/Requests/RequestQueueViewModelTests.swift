import XCTest
@testable import BloemAdmin

@MainActor
final class RequestQueueViewModelTests: XCTestCase {
    private var http: MockHTTPHarness!
    private var client: APIClient!

    override func setUp() async throws {
        http = MockHTTPHarness()
        client = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
        http.state.stub(path: "/api/v2/admin/users", data: Data(#"{"items":[{"id":"68","username":"alex","email":"a@example.test","role":"user","enabled":true}]}"#.utf8))
    }

    override func tearDown() async throws {
        http.invalidate()
    }

    private func counts(needsApproval: Int, inProgress: Int = 3) -> Data {
        Data(#"{"needs_approval":\#(needsApproval),"in_progress":\#(inProgress),"failed":1,"done":7}"#.utf8)
    }

    private func page(_ ids: [String], status: String = "pending", next: String? = nil) -> MockHTTPResponse {
        let items = ids.map { RequestsViewModelTests.mediaRequestJSON(id: $0, title: "T\($0)", status: status) }.joined(separator: ",")
        let pageInfo = next.map { #","page":{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #","page":{"has_more":false}"#
        return MockHTTPResponse(data: Data(#"{"items":[\#(items)]\#(pageInfo)}"#.utf8), status: 200)
    }

    private func query(_ request: URLRequest, _ name: String) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    func testOpensOnNeedsApprovalWhenAnythingWaits() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 2))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page(["1", "2"])])
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertEqual(model.view, .needsApproval)
        XCTAssertEqual(model.counts?.needsApproval, 2)
        XCTAssertEqual(model.requests.map(\.id), ["1", "2"])
        let list = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/requests").last)
        XCTAssertEqual(query(list, "view"), "needs_approval")
        XCTAssertEqual(query(list, "limit"), "50")
        XCTAssertEqual(model.requester(for: model.requests[0]), "alex", "names come from the account list")
    }

    func testOpensOnInProgressWhenNothingWaitsAndKeepsAPickedView() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 0))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page(["1"], status: "approved"), page(["9"], status: "queued")])
        let model = RequestQueueViewModel()

        await model.load(client: client)
        XCTAssertEqual(model.view, .inProgress)

        model.select(view: .failed)
        await model.load(client: client)
        XCTAssertEqual(model.view, .failed)
        let list = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/requests").last)
        XCTAssertEqual(query(list, "view"), "failed")
    }

    func testFiltersGoToTheServer() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 1))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page([])])
        let model = RequestQueueViewModel()
        model.search = "  dune "
        model.mediaFilter = .series
        model.filter(byUser: "68")

        await model.load(client: client)

        let list = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/requests").last)
        XCTAssertEqual(query(list, "q"), "dune")
        XCTAssertEqual(query(list, "media_type"), "series")
        XCTAssertEqual(query(list, "requested_by_user_id"), "68")
        XCTAssertTrue(model.isFiltered)
        XCTAssertTrue(model.requests.isEmpty)
    }

    func testLoadMoreFollowsTheCursorAndKeepsTheRows() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 3))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page(["1", "2"], next: "c1"), page(["2", "3"])])
        let model = RequestQueueViewModel()

        await model.load(client: client)
        XCTAssertEqual(model.nextCursor, "c1")
        await model.loadMore(client: client)

        XCTAssertEqual(model.requests.map(\.id), ["1", "2", "3"], "a repeated row is not shown twice")
        XCTAssertNil(model.nextCursor)
        let second = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/requests").last)
        XCTAssertEqual(query(second, "cursor"), "c1")
        XCTAssertEqual(query(second, "view"), "needs_approval")
    }

    func testAFailedNextPageKeepsTheRowsShown() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 3))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [
            page(["1"], next: "c1"),
            MockHTTPResponse(data: Data(), status: 500),
        ])
        let model = RequestQueueViewModel()

        await model.load(client: client)
        await model.loadMore(client: client)

        XCTAssertEqual(model.requests.map(\.id), ["1"])
        XCTAssertTrue(model.moreFailed)
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedQueueSaysSo() async {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: Data(), status: 500)
        let model = RequestQueueViewModel()

        await model.load(client: client)

        XCTAssertTrue(model.hasLoaded)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAnActionPostsThenReloadsTheView() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 1))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page(["1"]), page([])])
        http.state.stub(path: "/api/v2/admin/requests/1/decline", data: Data(RequestsViewModelTests.mediaRequestJSON(id: "1", title: "T1", outcome: "declined").utf8))
        let model = RequestQueueViewModel()
        await model.load(client: client)

        let ok = await model.perform(.decline, on: model.requests[0], reason: "  duplicate ", client: client)

        XCTAssertTrue(ok)
        XCTAssertNil(model.actionErrorMessage)
        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/requests/1/decline", requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], ["reason": "duplicate"])
        XCTAssertTrue(model.requests.isEmpty, "the declined request left the view")
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/requests").count, 2)
    }

    func testApprovingSendsNoReason() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 1))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page(["1"]), page([])])
        http.state.stub(path: "/api/v2/admin/requests/1/approve", data: Data(RequestsViewModelTests.mediaRequestJSON(id: "1", title: "T1", status: "approved").utf8))
        let model = RequestQueueViewModel()
        await model.load(client: client)

        await model.perform(.approve, on: model.requests[0], reason: "ignored", client: client)

        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/requests/1/approve", requestIndex: 0))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String], [:])
    }

    func testARefusedActionKeepsTheRowAndSaysWhy() async throws {
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 1))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page(["1"])])
        http.state.stub(path: "/api/v2/admin/requests/1/approve", data: Data(#"{"title":"Conflict","status":409,"detail":"Already approved"}"#.utf8), status: 409)
        let model = RequestQueueViewModel()
        await model.load(client: client)

        let ok = await model.perform(.approve, on: model.requests[0], client: client)

        XCTAssertFalse(ok)
        XCTAssertNotNil(model.actionErrorMessage)
        XCTAssertEqual(model.requests.map(\.id), ["1"])
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/requests").count, 1, "no reload after a refusal")
    }

    func testABackgroundRefreshKeepsRowsReadFurtherDown() async throws {
        let first = (1...50).map(String.init)
        http.state.stub(path: "/api/v2/admin/requests/counts", data: counts(needsApproval: 51))
        http.state.stubSequence(path: "/api/v2/admin/requests", responses: [page(first, next: "c1"), page(["51"])])
        let model = RequestQueueViewModel()
        await model.load(client: client)
        await model.loadMore(client: client)
        XCTAssertTrue(model.hasLoadedMore)

        await model.refresh(client: client)

        XCTAssertEqual(model.requests.count, 51)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/requests").count, 2, "only the counts were read again")
    }
}
