import XCTest
@testable import BloemAdmin

/// The organization live socket (`bloem-live.v1`) as the dialect `LiveConnection` speaks: what goes out, what comes
/// back, and that a connection built on it behaves like any other.
@MainActor
final class OrganizationLiveSocketTests: XCTestCase {
    private let clock = TestLiveClock()
    private let all = ["org.streams", "org.people", "org.activity"]

    private func make(offered: [String]? = nil, selected: String? = "bloem-live.v1") -> (OrganizationLiveSocket, FakeLiveSocket) {
        let real = FakeLiveSocket()
        real.negotiatedProtocol = selected
        return (OrganizationLiveSocket(socket: real, offered: offered ?? all), real)
    }

    private func text(_ socket: OrganizationLiveSocket) async throws -> String {
        guard case .text(let text) = try await socket.receive() else {
            XCTFail("a binary frame")
            return ""
        }
        return text
    }

    private func frame(_ socket: OrganizationLiveSocket) async throws -> EventsFrame {
        try EventsProtocol.decode(try await text(socket))
    }

    /// `XCTAssertEqual` cannot await inside its autoclosure, so the next frame is read first.
    private func expect(_ socket: OrganizationLiveSocket, _ expected: EventsFrame, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await frame(socket)
        XCTAssertEqual(actual, expected, message, file: file, line: line)
    }

    private func object(_ text: String?) -> [String: Any] {
        guard let text, let value = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return [:] }
        return value
    }

    private func subscribe(_ socket: OrganizationLiveSocket, _ id: String, _ channels: Set<LiveChannel>) async throws {
        try await socket.send(EventsProtocol.subscribe(requestID: id, channels: channels))
    }

    // MARK: Hello and the protocol

    func testTheHelloListsWhatTheTicketServes() async throws {
        let (socket, _) = make(offered: ["org.people", "org.activity"])
        let hello = try await frame(socket)
        XCTAssertEqual(hello, .hello(available: [.orgPeople, .orgActivity]))
        socket.close()
    }

    func testTheHelloWaitsForTheHandshake() async throws {
        let (socket, real) = make(selected: nil)
        final class Flag: @unchecked Sendable { var value = false }
        let delivered = Flag()
        let reader = Task { @MainActor in
            _ = try? await socket.receive()
            delivered.value = true
        }
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(delivered.value, "the connection checks the subprotocol on the first frame, so nothing is read before it is known")
        real.negotiatedProtocol = "bloem-live.v1"
        let arrived = await waitUntil { delivered.value }
        XCTAssertTrue(arrived)
        reader.cancel()
        socket.close()
    }

    func testOnlyBloemLiveIsAcceptedAsTheSelectedProtocol() {
        let cases: [(selected: String?, expected: String?, why: String)] = [
            ("bloem-live.v1", EventsProtocol.name, "the protocol of the contract"),
            ("silo.events.v2", nil, "a server that selects another protocol is refused"),
            (nil, nil, "no protocol selected"),
        ]
        for (selected, expected, why) in cases {
            let (socket, _) = make(selected: selected)
            XCTAssertEqual(socket.negotiatedProtocol, expected, why)
            socket.close()
        }
    }

    // MARK: To the server

    func testASubscribeSendsOnlyWhatIsNewAndIsAnsweredAtOnce() async throws {
        let (socket, real) = make()
        _ = try await text(socket)  // hello

        try await subscribe(socket, "live-1", [.orgStreams])
        XCTAssertEqual(real.sent.count, 1)
        let sent = object(real.sent.last)
        XCTAssertEqual(sent["op"] as? String, "subscribe")
        XCTAssertEqual(sent["channels"] as? [String], ["org.streams"])
        XCTAssertTrue(sent["resume"] is NSNull, "resume is accepted and ignored; the resync after every subscribe closes any gap")
        try await expect(socket, .subscribed(requestID: "live-1", accepted: [.orgStreams], rejected: []))

        // The server's resync is the connection's snapshot.
        real.push(#"{"op":"resync","seq":1,"channel":"org.streams"}"#)
        try await expect(socket, .snapshot(.orgStreams))

        // Another page adds a channel: only that goes out, and the channel already held is repeated as Silo does, so the
        // connection does not tell its screen twice.
        try await subscribe(socket, "live-2", [.orgStreams, .orgPeople])
        XCTAssertEqual(real.sent.count, 2)
        XCTAssertEqual(object(real.sent.last)["channels"] as? [String], ["org.people"])
        try await expect(socket, .subscribed(requestID: "live-2", accepted: [.orgStreams, .orgPeople], rejected: []))
        try await expect(socket, .snapshot(.orgStreams))
        real.push(#"{"op":"resync","seq":2,"channel":"org.people"}"#)
        try await expect(socket, .snapshot(.orgPeople))

        // A page goes: the channel is let go with an unsubscribe, and nothing else is asked for.
        try await subscribe(socket, "live-3", [.orgPeople])
        XCTAssertEqual(real.sent.count, 3)
        let dropped = object(real.sent.last)
        XCTAssertEqual(dropped["op"] as? String, "unsubscribe")
        XCTAssertEqual(dropped["channels"] as? [String], ["org.streams"])
        try await expect(socket, .subscribed(requestID: "live-3", accepted: [.orgPeople], rejected: []))
        try await expect(socket, .snapshot(.orgPeople))
        socket.close()
    }

    func testNothingIsSentBeforeASubscribe() async throws {
        let (socket, real) = make()
        _ = try await text(socket)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(real.sent.isEmpty)
        socket.close()
    }

    func testAChannelTheTicketDoesNotListIsNeverAskedFor() async throws {
        let (socket, real) = make(offered: ["org.people"])
        _ = try await text(socket)
        try await subscribe(socket, "live-1", [.orgStreams, .orgPeople])
        XCTAssertEqual(object(real.sent.last)["channels"] as? [String], ["org.people"])
        try await expect(socket, .subscribed(requestID: "live-1", accepted: [.orgPeople], rejected: []))
        socket.close()
    }

    // MARK: From the server

    func testChangesAreEventsAndSignalsForOtherChannelsAreDropped() async throws {
        let (socket, real) = make()
        _ = try await text(socket)
        try await subscribe(socket, "live-1", [.orgStreams])
        _ = try await text(socket)

        real.push(#"{"op":"change","seq":3,"channel":"org.streams","id":"s_9f2","rev":"4","kind":"updated"}"#)
        try await expect(socket, .event(.orgStreams))
        real.push(#"{"op":"change","seq":4,"channel":"org.streams","id":"s_9f3","rev":"1","kind":"deleted"}"#)
        try await expect(socket, .event(.orgStreams))
        // Nobody here shows People: its changes and resyncs say nothing to this connection.
        real.push(#"{"op":"change","seq":5,"channel":"org.people","id":"7","rev":"x","kind":"created"}"#)
        try await expect(socket, .ignored)
        real.push(#"{"op":"resync","seq":6,"channel":"org.activity"}"#)
        try await expect(socket, .ignored)
        socket.close()
    }

    func testAHeartbeatAndAnUnknownFrameAreFramesThatSayNothingButProveTheSocketIsAlive() async throws {
        let (socket, real) = make()
        _ = try await text(socket)
        real.push(#"{"op":"heartbeat","seq":9}"#)
        try await expect(socket, .ignored, "it is still a frame, so the connection's watchdog is fed")
        real.push(#"{"op":"future","seq":10}"#)
        try await expect(socket, .ignored)
        socket.close()
    }

    func testAFrameTheClientCannotReadIsAProtocolFailure() async throws {
        for broken in [
            #"{"op":"change","channel":"org.streams"}"#,
            #"{"op":"change","channel":"org.streams","id":"1","kind":"moved"}"#,
            #"{"op":"resync"}"#,
            "not json",
            #"{"channel":"org.streams"}"#,
        ] {
            let (socket, real) = make()
            _ = try await text(socket)
            real.push(broken)
            let passed = try await text(socket)
            XCTAssertThrowsError(try EventsProtocol.decode(passed), broken) { error in
                XCTAssertEqual((error as? SessionTransportError)?.failure, .protocolViolation)
            }
            socket.close()
        }
    }

    func testAnErrorFrameDoesNotLeaveTheConnectionWaitingAndTheChannelIsNotAskedForAgain() async throws {
        let (socket, real) = make()
        _ = try await text(socket)
        try await subscribe(socket, "live-1", [.orgStreams, .orgPeople])
        _ = try await text(socket)
        real.push(#"{"op":"error","code":"unavailable","channel":"org.streams"}"#)
        try await expect(socket, .snapshot(.orgStreams), "answered like a snapshot, so the connection stops waiting for one")

        try await subscribe(socket, "live-2", [.orgStreams, .orgPeople])
        XCTAssertEqual(real.sent.count, 1, "nothing new to ask for: the refused channel stays refused")
        try await expect(socket, .subscribed(requestID: "live-2", accepted: [.orgPeople], rejected: []))
        socket.close()
    }

    // MARK: Close codes

    func testTheCloseCodesOfTheContract() async throws {
        let cases: [(server: Int?, app: Int?)] = [
            (4401, 4001), (4403, 4001), (4408, 4001),   // a new ticket at once: Silo's "access changed"
            (1012, 1012), (1013, 1013), (4429, 4429), (1008, 1008), (nil, nil),
        ]
        for (server, app) in cases {
            let (socket, real) = make()
            _ = try await text(socket)
            real.serverClose(code: server)
            do {
                _ = try await socket.receive()
                XCTFail("the socket was closed")
            } catch {}
            XCTAssertEqual(socket.closeCode, app, "server code \(String(describing: server))")
            socket.close()
        }
    }

    // MARK: On a live connection

    func testALiveConnectionOnTheSocketSignalsResyncsAndChangesAndSurvivesQuietTimes() async throws {
        let (socket, real) = make()
        // A ping that is never answered: only the server's heartbeats can keep the watchdog fed.
        real.pingMode = .hang
        let script = ScriptedEndpoint([.socket(socket)])
        let connection = LiveConnection(endpoint: script.endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.orgStreams])
        let subscribed = await waitUntil { real.sent.count == 1 }
        XCTAssertTrue(subscribed)
        XCTAssertEqual(object(real.sent.last)["op"] as? String, "subscribe")

        real.push(#"{"op":"resync","seq":1,"channel":"org.streams"}"#)
        await TestLiveClock.settle()
        XCTAssertEqual(connection.state, .live)
        XCTAssertEqual(subscription.take(), [.resync(.orgStreams)], "the first resync is the catch-up read")

        real.push(#"{"op":"change","seq":2,"channel":"org.streams","id":"s1","rev":"1","kind":"created"}"#)
        await TestLiveClock.settle()
        XCTAssertEqual(subscription.take(), [.changed(.orgStreams)])

        // A burst the server folded into a resync is a read again, not a repeat of the snapshot.
        real.push(#"{"op":"resync","seq":3,"channel":"org.streams"}"#)
        await TestLiveClock.settle()
        XCTAssertEqual(subscription.take(), [.resync(.orgStreams)])

        // Two minutes of heartbeats every 25 seconds keep the 60-second watchdog fed.
        for _ in 0..<5 {
            await clock.advance(25)
            real.push(#"{"op":"heartbeat","seq":9}"#)
            await TestLiveClock.settle()
        }
        XCTAssertEqual(connection.state, .live)
        XCTAssertEqual(connection.connectCount, 1)
        XCTAssertEqual(script.attempts, 1)
        subscription.cancel()
    }

    func testAConnectionWhoseTicketDoesNotListTheChannelKnowsItIsNotOffered() async throws {
        let (socket, real) = make(offered: ["org.people", "org.activity"])
        let connection = LiveConnection(endpoint: ScriptedEndpoint([.socket(socket)]).endpoint, clock: clock, jitter: { 1 })
        connection.setForeground(true)
        let subscription = connection.subscribe([.orgStreams], whenNotOffered: .readOnOpenOnly)
        await TestLiveClock.settle()
        let unavailable = await waitUntil { connection.unavailableChannels == [.orgStreams] }
        XCTAssertTrue(unavailable)
        XCTAssertTrue(real.sent.isEmpty, "nothing is subscribed that the server does not serve")
        subscription.cancel()
    }
}
