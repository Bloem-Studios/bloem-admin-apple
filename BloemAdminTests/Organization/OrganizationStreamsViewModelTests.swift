import XCTest
@testable import BloemAdmin

/// The organization's own streams: every page is read through the pass, the page asks again while it is open,
/// stop and message are sent once, and the Streams page is offered only by a server that serves it.
@MainActor
final class OrganizationStreamsViewModelTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let streams = "\(F.base)/streams"

    func testEveryPageIsReadThroughThePass() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: streams, responses: [
            MockHTTPResponse(data: F.data(F.streams(F.stream(id: "a"), next: "page-2"))),
            MockHTTPResponse(data: F.data(F.streams(F.stream(id: "b")))),
        ])
        let session = try await openedOrganizationSession(http)
        let model = OrganizationStreamsViewModel()

        await model.load(session: session)

        XCTAssertEqual(model.streams.map(\.sessionID), ["a", "b"])
        XCTAssertNil(model.errorMessage)
        let requests = http.state.requests(path: streams)
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer \(F.pass)", "Bearer \(F.pass)"])
        let second = requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        XCTAssertEqual(second.first { $0.name == "cursor" }?.value, "page-2")
        XCTAssertEqual(second.first { $0.name == "limit" }?.value, "100")
    }

    func testTheListIsAskedForAgainWhileThePageIsOpen() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: streams, data: F.data(F.streams(F.stream())))
        let session = try await openedOrganizationSession(http)
        let model = OrganizationStreamsViewModel()

        let polling = Task { await model.poll(session: session, interval: .milliseconds(20)) }
        let deadline = Date().addingTimeInterval(5)
        while http.state.requests(path: streams).count < 3 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        polling.cancel()
        await polling.value
        let asked = http.state.requests(path: streams).count
        try await Task.sleep(for: .milliseconds(80))

        XCTAssertGreaterThanOrEqual(asked, 3)
        XCTAssertLessThanOrEqual(http.state.requests(path: streams).count, asked + 1, "polling stops when the page goes away")
    }

    func testStoppingSaysWhatHappenedAndReadsTheListAgain() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: streams, data: F.data(F.streams(F.stream())))
        http.state.stubSequence(path: "\(streams)/st1/stop", responses: [
            MockHTTPResponse(data: F.data(F.stopResult())),
            MockHTTPResponse(data: F.data(F.stopResult(alreadyRevoked: true))),
            MockHTTPResponse(data: F.data(F.stopResult(notified: false))),
        ])
        let session = try await openedOrganizationSession(http)
        let model = OrganizationStreamsViewModel()
        await model.load(session: session)
        let stream = try XCTUnwrap(model.streams.first)

        await model.stop(session: session, stream: stream)
        XCTAssertEqual(model.notice, "Stream stopped")
        await model.stop(session: session, stream: stream)
        XCTAssertEqual(model.notice, "That stream had already been stopped")
        await model.stop(session: session, stream: stream)
        XCTAssertEqual(model.notice, "Stream stopped. The player wasn't told, so it may play what it already loaded.")

        let stop = try XCTUnwrap(http.state.requests(path: "\(streams)/st1/stop").first)
        XCTAssertEqual(stop.httpMethod, "POST")
        XCTAssertEqual(stop.value(forHTTPHeaderField: "Authorization"), "Bearer \(F.pass)")
        XCTAssertEqual(http.state.requests(path: streams).count, 4, "the list is read again after each stop")
        XCTAssertTrue(model.pendingIDs.isEmpty)
    }

    func testYourOwnStreamIsRefusedInWords() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: streams, data: F.data(F.streams(F.stream())))
        http.state.stub(path: "\(streams)/st1/stop", data: F.data(F.protected("self")), status: 409)
        let session = try await openedOrganizationSession(http)
        let model = OrganizationStreamsViewModel()
        await model.load(session: session)

        await model.stop(session: session, stream: try XCTUnwrap(model.streams.first))

        XCTAssertEqual(model.actionError, "You can't do this to your own account. Change your own password or sign out in the app.")
        XCTAssertNil(session.denial)
    }

    func testAMessageCarriesItsOwnIdentityAndLeavesOutAnEmptyTitle() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: streams, data: F.data(F.streams(F.stream())))
        http.state.stub(path: "\(streams)/st1/message", data: F.data(F.messageReceipt()), status: 202)
        let session = try await openedOrganizationSession(http)
        let model = OrganizationStreamsViewModel(sequencer: PlaybackCommandSequencer(clock: { 7 }))
        await model.load(session: session)

        let failure = await model.sendMessage(session: session, stream: try XCTUnwrap(model.streams.first), title: "  ", message: " Closing soon ")

        XCTAssertNil(failure)
        XCTAssertEqual(model.notice, "Message sent to Sam Rivers · Sam")
        let body = try XCTUnwrap(http.state.body(path: "\(streams)/st1/message", requestIndex: 0))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["message"] as? String, "Closing soon")
        XCTAssertEqual(json["sequence"] as? Int, 7)
        XCTAssertNotNil(UUID(uuidString: json["command_id"] as? String ?? ""), "a canonical UUID")
        XCTAssertNil(json["title"], "an empty title is left out")
    }

    func testAStaleSequenceSaysSoAndTheNextMessageGoesAboveIt() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: streams, data: F.data(F.streams(F.stream())))
        http.state.stubSequence(path: "\(streams)/st1/message", responses: [
            MockHTTPResponse(
                data: F.data(#"{"error":"stale_sequence","message":"The command sequence is behind"}"#), status: 409,
                headers: ["X-Silo-Latest-Sequence": "500"]
            ),
            MockHTTPResponse(data: F.data(F.messageReceipt()), status: 202),
        ])
        let session = try await openedOrganizationSession(http)
        let model = OrganizationStreamsViewModel(sequencer: PlaybackCommandSequencer(clock: { 7 }))
        await model.load(session: session)
        let stream = try XCTUnwrap(model.streams.first)

        let first = await model.sendMessage(session: session, stream: stream, title: "", message: "Hi")
        let second = await model.sendMessage(session: session, stream: stream, title: "", message: "Hi")

        XCTAssertEqual(first, "Another command reached this stream first. Try again.")
        XCTAssertNil(second)
        let retry = try XCTUnwrap(http.state.body(path: "\(streams)/st1/message", requestIndex: 1))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: retry) as? [String: Any])?["sequence"] as? Int, 501)
    }

    func testStreamsIsOfferedOnlyByAServerThatServesIt() {
        XCTAssertFalse(OrganizationPage.offered(.none).contains(.streams))
        let offered = OrganizationPage.offered(SupportCapabilities(streams: .init(list: true)))
        XCTAssertEqual(offered.prefix(3), [.overview, .streams, .people])
        XCTAssertEqual(offered.count, OrganizationPage.allCases.count)
    }
}
