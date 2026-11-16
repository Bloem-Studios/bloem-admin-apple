import XCTest
@testable import BloemAdmin

/// Counts how many calls are in flight at once; read and written on the main actor only.
@MainActor
private final class InFlightCounter {
    private(set) var current = 0
    private(set) var peak = 0
    private(set) var started: [Int] = []

    func enter(_ item: Int) {
        current += 1
        peak = max(peak, current)
        started.append(item)
    }

    func leave() { current -= 1 }
}

@MainActor
final class BulkRequestRunnerTests: XCTestCase {
    func testSendsAtMostFourAtATimeAndAnswersEveryItem() async {
        let counter = InFlightCounter()
        var progress: [Int] = []

        let failures = await BulkRequestRunner.run(
            Array(0..<10),
            perform: { item in
                counter.enter(item)
                try? await Task.sleep(for: .milliseconds(15))
                counter.leave()
                return nil
            },
            onProgress: { done in progress.append(done) }
        )

        XCTAssertEqual(BulkRequestRunner.concurrency, 4)
        XCTAssertEqual(counter.peak, 4, "the web sends four at a time")
        XCTAssertEqual(Set(counter.started), Set(0..<10), "every item was sent")
        XCTAssertEqual(counter.started.count, 10, "and each one once")
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(progress, Array(1...10), "progress counts every answer, in order")
    }

    func testAFailureDoesNotStopTheRestAndKeepsItsReason() async {
        let failures = await BulkRequestRunner.run(
            [0, 1, 2, 3, 4, 5],
            perform: { item in item % 3 == 1 ? "Refused \(item)" : nil },
            onProgress: { _ in }
        )

        XCTAssertEqual(failures.map(\.index).sorted(), [1, 4])
        XCTAssertEqual(failures.first { $0.index == 4 }?.message, "Refused 4")
    }

    func testAnEmptyListSendsNothing() async {
        let counter = InFlightCounter()
        let failures = await BulkRequestRunner.run(
            [Int](), perform: { item in counter.enter(item); return nil }, onProgress: { _ in }
        )
        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(counter.started.isEmpty)
    }
}

@MainActor
final class BulkTriageModelTests: XCTestCase {
    private var http: MockHTTPHarness!
    private var otherHTTP: MockHTTPHarness!
    private var client: APIClient!
    private var otherClient: APIClient!

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

    private func item(_ id: String, server: String? = nil, on use: APIClient? = nil) -> BulkRequestItem {
        BulkRequestItem(
            key: server.map { "\($0)/\(id)" } ?? id, requestID: id, title: "Title \(id)",
            serverID: server, client: use ?? client, sessionState: nil
        )
    }

    private func body(_ http: MockHTTPHarness, _ path: String, at index: Int = 0) throws -> [String: String] {
        let data = try XCTUnwrap(http.state.body(path: path, requestIndex: index))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private let conflict = Data(#"{"type":"https://example.test/problems/conflict","title":"Conflict","status":409,"detail":"Someone else already answered this request."}"#.utf8)

    func testApprovePostsOnePerRequestWithAnEmptyBodyAndLeavesSelectMode() async throws {
        let model = BulkTriageModel()
        model.beginSelecting()
        model.selectAll(["1", "2", "3"])

        _ = await model.run(.approve, on: [item("1"), item("2"), item("3")], note: "ignored for approvals")

        for id in ["1", "2", "3"] {
            XCTAssertEqual(http.state.requests(path: "/api/v2/admin/requests/\(id)/approve").count, 1)
            XCTAssertEqual(try body(http, "/api/v2/admin/requests/\(id)/approve"), [:], "an approval carries no note")
        }
        XCTAssertFalse(model.isSelecting, "everything went through, so selecting is over")
        XCTAssertTrue(model.selectedKeys.isEmpty)
        XCTAssertEqual(model.progress?.done, 3)
        XCTAssertEqual(model.progress?.failures.isEmpty, true)
        XCTAssertEqual(model.progress?.isRunning, false)
    }

    func testDeclineSendsTheTrimmedNoteToEveryRequestAndNothingWhenBlank() async throws {
        let model = BulkTriageModel()
        _ = await model.run(.decline, on: [item("1"), item("2")], note: "  already in the library \n")
        XCTAssertEqual(try body(http, "/api/v2/admin/requests/1/decline"), ["reason": "already in the library"])
        XCTAssertEqual(try body(http, "/api/v2/admin/requests/2/decline"), ["reason": "already in the library"])

        _ = await model.run(.decline, on: [item("3")], note: "   ")
        XCTAssertEqual(try body(http, "/api/v2/admin/requests/3/decline"), [:])
    }

    func testFailuresStaySelectedWithTheirReasonAndTheRestAreSent() async throws {
        http.state.stub(path: "/api/v2/admin/requests/2/approve", data: conflict, status: 409)
        let model = BulkTriageModel()
        model.beginSelecting()
        model.selectAll(["1", "2", "3"])

        _ = await model.run(.approve, on: [item("1"), item("2"), item("3")], note: nil)

        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/requests/3/approve").count, 1, "one refusal does not stop the others")
        XCTAssertTrue(model.isSelecting, "failed requests are still being worked on")
        XCTAssertEqual(model.selectedKeys, ["2"])
        let progress = try XCTUnwrap(model.progress)
        XCTAssertEqual(progress.total, 3)
        XCTAssertEqual(progress.done, 3)
        XCTAssertEqual(progress.failures.map(\.title), ["Title 2"])
        XCTAssertEqual(progress.failures.first?.message, "Someone else already answered this request.")
    }

    func testEachRequestGoesToItsOwnServerAndTheTouchedServersComeBack() async throws {
        let model = BulkTriageModel()
        let touched = await model.run(
            .approve,
            on: [item("1", server: "a"), item("1", server: "b", on: otherClient), item("2", server: "b", on: otherClient)],
            note: nil
        )

        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/requests/1/approve").count, 1)
        XCTAssertEqual(otherHTTP.state.requests(path: "/api/v2/admin/requests/1/approve").count, 1)
        XCTAssertEqual(otherHTTP.state.requests(path: "/api/v2/admin/requests/2/approve").count, 1)
        XCTAssertEqual(http.state.requests(path: "/api/v2/admin/requests/2/approve").count, 0)
        XCTAssertEqual(touched, ["a", "b"])
    }

    func testSameRequestNumberOnTwoServersKeepsSeparateSelectionKeys() {
        let model = BulkTriageModel()
        model.beginSelecting()
        model.toggle("a/1")
        XCTAssertTrue(model.isSelected("a/1"))
        XCTAssertFalse(model.isSelected("b/1"))
    }

    func testSelectAllThenClearAndToggle() {
        let model = BulkTriageModel()
        model.beginSelecting()
        model.selectAll(["1", "2"])
        XCTAssertEqual(model.selectedKeys, ["1", "2"])
        model.toggle("2")
        XCTAssertEqual(model.selectedKeys, ["1"])
        model.toggle("3")
        XCTAssertEqual(model.selectedKeys, ["1", "3"])
        model.deselectAll()
        XCTAssertTrue(model.selectedKeys.isEmpty)
        XCTAssertTrue(model.isSelecting, "clearing keeps select mode")
    }

    func testLeavingSelectModeForgetsTheSelectionAndTheLastResult() async {
        http.state.stub(path: "/api/v2/admin/requests/1/approve", data: conflict, status: 409)
        let model = BulkTriageModel()
        model.beginSelecting()
        model.selectAll(["1"])
        _ = await model.run(.approve, on: [item("1")], note: nil)
        XCTAssertNotNil(model.progress)

        model.endSelecting()

        XCTAssertFalse(model.isSelecting)
        XCTAssertTrue(model.selectedKeys.isEmpty)
        XCTAssertNil(model.progress)
    }

    func testSelectionChangesAreIgnoredWhileRunning() async throws {
        http.state.stub(path: "/api/v2/admin/requests/1/approve", response: MockHTTPResponse(data: Data(), status: 200), delayUntilReleased: true)
        let model = BulkTriageModel()
        model.beginSelecting()
        model.selectAll(["1"])

        let running = Task { await model.run(.approve, on: [self.item("1")], note: nil) }
        await http.state.waitForRequest(path: "/api/v2/admin/requests/1/approve")
        XCTAssertTrue(model.isRunning)
        XCTAssertEqual(model.progress?.done, 0)

        model.toggle("1")
        model.deselectAll()
        model.endSelecting()
        XCTAssertEqual(model.selectedKeys, ["1"], "the selection holds still while requests are being sent")
        XCTAssertTrue(model.isSelecting)

        http.state.releaseResponses(matching: "/api/v2/admin/requests/1/approve")
        _ = await running.value
        XCTAssertFalse(model.isRunning)
    }

    func testARunWithNothingToSendChangesNothing() async {
        let model = BulkTriageModel()
        let touched = await model.run(.approve, on: [], note: nil)
        XCTAssertTrue(touched.isEmpty)
        XCTAssertNil(model.progress)
    }
}

final class BulkTriageTextTests: XCTestCase {
    func testButtonsNameTheCount() {
        XCTAssertEqual(BulkTriageText.approveButton(count: 12), "Approve 12")
        XCTAssertEqual(BulkTriageText.declineButton(count: 1), "Decline 1")
    }

    func testSelectionSummary() {
        XCTAssertEqual(BulkTriageText.selected(count: 0), "None selected")
        XCTAssertEqual(BulkTriageText.selected(count: 3), "3 selected")
        XCTAssertEqual(BulkTriageText.selectAll(count: 12), "Select all 12 shown")
    }

    func testProgressWhileRunning() {
        XCTAssertEqual(BulkTriageText.running(.approve, done: 3, total: 12), "Approving 3 of 12")
        XCTAssertEqual(BulkTriageText.running(.decline, done: 0, total: 1), "Declining 0 of 1")
    }

    func testResultSaysHowManyWentThroughAndWhatToDoNext() {
        XCTAssertEqual(
            BulkTriageText.result(.approve, total: 12, failed: 3),
            "9 of 12 requests approved. The 3 that failed stay selected, with the reason for each."
        )
        XCTAssertEqual(
            BulkTriageText.result(.decline, total: 2, failed: 1),
            "1 of 2 requests declined. The 1 that failed stays selected, with its reason."
        )
        XCTAssertEqual(BulkTriageText.result(.approve, total: 4, failed: 0), "4 requests approved")
        XCTAssertEqual(BulkTriageText.result(.decline, total: 1, failed: 0), "1 request declined")
    }

    func testDeclinePromptCarriesTheCount() {
        XCTAssertEqual(BulkTriageText.declineTitle(count: 1), "Decline 1 request")
        XCTAssertEqual(BulkTriageText.declineTitle(count: 5), "Decline 5 requests")
        XCTAssertEqual(
            BulkTriageText.declineMessage(count: 5),
            "The requests will be marked declined, and each requester is told. Add an optional note for them."
        )
    }

    func testAFailureLineNamesTheRequestAndTheReason() {
        XCTAssertEqual(BulkTriageText.failureLine(title: "Dune", message: "Already approved."), "Dune: Already approved.")
    }
}
