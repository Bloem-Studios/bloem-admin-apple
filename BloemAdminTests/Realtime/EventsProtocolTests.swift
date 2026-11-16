import XCTest
@testable import BloemAdmin

/// The frames of the server's events socket (silo.events.v2) as the live connection reads them.
final class EventsProtocolTests: XCTestCase {
    private func failure(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> SessionFailure? {
        do {
            _ = try EventsProtocol.decode(text)
            XCTFail("expected a failure", file: file, line: line)
            return nil
        } catch {
            return (error as? SessionTransportError)?.failure
        }
    }

    func testTheSubscribeFrameNamesTheChannelsSortedAndTheRequest() throws {
        let text = EventsProtocol.subscribe(requestID: "live-3", channels: [.tasks, .scans, .sessions])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "subscribe")
        XCTAssertEqual(object["request_id"] as? String, "live-3")
        XCTAssertEqual(object["channels"] as? [String], ["scans", "sessions", "tasks"])
        XCTAssertEqual(EventsProtocol.name, "silo.events.v2")
    }

    func testHelloListsTheChannelsTheAccountMaySubscribeTo() throws {
        let frame = try EventsProtocol.decode(LiveFrames.hello(["catalog", "sessions", "tasks", "plugins"]))
        XCTAssertEqual(frame, .hello(available: [.sessions, .tasks]), "channels this app does not use are ignored")
    }

    func testAPlainAccountsHelloHasNoAdminChannels() throws {
        XCTAssertEqual(try EventsProtocol.decode(LiveFrames.hello(["catalog", "notifications"])), .hello(available: [.notifications]))
    }

    func testHelloWithAnotherSchemaOrActionIsAProtocolFailure() {
        XCTAssertEqual(failure(#"{"type":"hello","schema_version":2,"required_action":"subscribe","available_channels":["sessions"]}"#), .protocolViolation)
        XCTAssertEqual(failure(#"{"type":"hello","schema_version":"1","required_action":"subscribe","available_channels":["sessions"]}"#), .protocolViolation)
        XCTAssertEqual(failure(#"{"type":"hello","schema_version":true,"required_action":"subscribe","available_channels":["sessions"]}"#), .protocolViolation)
        XCTAssertEqual(failure(#"{"type":"hello","schema_version":1,"required_action":"none","available_channels":["sessions"]}"#), .protocolViolation)
        XCTAssertEqual(failure(#"{"type":"hello","schema_version":1,"required_action":"subscribe","available_channels":"sessions"}"#), .protocolViolation)
    }

    func testSubscribedSaysWhichChannelsWereAcceptedAndWhichRefused() throws {
        let frame = try EventsProtocol.decode(LiveFrames.subscribed("live-1", accepted: ["tasks"], rejected: ["scans"]))
        XCTAssertEqual(frame, .subscribed(requestID: "live-1", accepted: [.tasks], rejected: [.scans]))
    }

    func testSubscribedWithoutARequestIdIsAProtocolFailure() {
        XCTAssertEqual(failure(#"{"type":"subscribed","channels":["sessions"]}"#), .protocolViolation)
    }

    func testASnapshotIsACueWhateverItCarries() throws {
        XCTAssertEqual(try EventsProtocol.decode(LiveFrames.snapshot("scans")), .snapshot(.scans))
        let null = #"{"type":"snapshot","channel":"jobs","timestamp":"2026-11-14T10:20:30Z","data":null}"#
        XCTAssertEqual(try EventsProtocol.decode(null), .snapshot(.jobs))
    }

    func testASnapshotNeedsATimestampAndData() {
        XCTAssertEqual(failure(#"{"type":"snapshot","channel":"scans","timestamp":"yesterday","data":[]}"#), .protocolViolation)
        XCTAssertEqual(failure(#"{"type":"snapshot","channel":"scans","timestamp":"2026-11-14T10:20:30Z"}"#), .protocolViolation)
    }

    func testAnEventIsACueOnItsChannel() throws {
        XCTAssertEqual(try EventsProtocol.decode(LiveFrames.event("scans", name: "scan.progress")), .event(.scans))
        XCTAssertEqual(try EventsProtocol.decode(LiveFrames.event("tasks", name: "task.updated")), .event(.tasks))
    }

    func testAnEventWithoutAnIdIsAProtocolFailure() {
        XCTAssertEqual(failure(#"{"type":"event","channel":"scans","event":"x","timestamp":"2026-11-14T10:20:30Z","data":{}}"#), .protocolViolation)
    }

    func testChannelsThisAppDoesNotUseAreIgnored() throws {
        XCTAssertEqual(try EventsProtocol.decode(LiveFrames.event("catalog")), .ignored)
        XCTAssertEqual(try EventsProtocol.decode(LiveFrames.snapshot("user_state")), .ignored)
        XCTAssertEqual(try EventsProtocol.decode(#"{"type":"pong"}"#), .ignored)
    }

    func testAccessChangedAndErrorFrames() throws {
        XCTAssertEqual(try EventsProtocol.decode(LiveFrames.accessChanged), .accessChanged)
        XCTAssertEqual(failure(#"{"type":"error","code":"bad_request","message":"x"}"#), .protocolViolation)
    }

    func testGarbageIsAProtocolFailureThatKeepsNoPayload() {
        XCTAssertEqual(failure("not json"), .protocolViolation)
        XCTAssertEqual(failure("[1,2]"), .protocolViolation)
        XCTAssertEqual(failure(#"{"no_type":1}"#), .protocolViolation)
    }
}
