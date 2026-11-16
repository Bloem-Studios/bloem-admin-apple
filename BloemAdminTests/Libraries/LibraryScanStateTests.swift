import XCTest
@testable import BloemAdmin

/// What a library row says about its scans: Queued, Running, then how the last one ended.
final class LibraryScanStateTests: XCTestCase {
    private func run(
        _ id: String, library: String = "3", status: String, requested: TimeInterval = 0, started: TimeInterval? = nil,
        completed: TimeInterval? = nil, error: String? = nil
    ) throws -> ScanRun {
        func iso(_ t: TimeInterval) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: Date(timeIntervalSince1970: 1_800_000_000 + t))
        }
        var fields = [
            #""id":"\#(id)""#, #""library_id":"\#(library)""#, #""mode":"library""#, #""trigger":"manual""#,
            #""status":"\#(status)""#, #""requested_at":"\#(iso(requested))""#,
        ]
        if let started { fields.append(#""started_at":"\#(iso(started))""#) }
        if let completed { fields.append(#""completed_at":"\#(iso(completed))""#) }
        if let error { fields.append(#""error_message":"\#(error)""#) }
        return try JSONDecoder.iso8601.decode(ScanRun.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
    }

    func testNothingRunningAndNothingRecentIsIdle() {
        XCTAssertEqual(LibraryScanState.resolve(libraryID: "3", active: [], recent: [], pending: false), .idle)
        XCTAssertNil(LibraryScanState.idle.label)
    }

    func testAnAcceptedRunIsQueued() throws {
        let state = LibraryScanState.resolve(libraryID: "3", active: [try run("a", status: "accepted")], recent: [], pending: false)
        XCTAssertEqual(state, .queued(count: 1))
        XCTAssertEqual(state.label, "Queued")
    }

    func testARunningRunBeatsAQueuedOne() throws {
        let active = [try run("a", status: "accepted"), try run("b", status: "running", started: 5), try run("c", status: "accepted")]
        let state = LibraryScanState.resolve(libraryID: "3", active: active, recent: [], pending: false)
        XCTAssertEqual(state, .running(count: 1, queued: 2))
        XCTAssertEqual(state.label, "Running")
    }

    func testOtherLibrariesRunsDoNotCount() throws {
        let active = [try run("a", library: "9", status: "running", started: 1)]
        XCTAssertEqual(LibraryScanState.resolve(libraryID: "3", active: active, recent: [], pending: false), .idle)
    }

    func testAScanJustAcceptedShowsQueuedBeforeTheServerListsIt() {
        let state = LibraryScanState.resolve(libraryID: "3", active: [], recent: [], pending: true)
        XCTAssertEqual(state, .queued(count: 1))
    }

    func testTheServersOwnRunReplacesThePendingGuess() throws {
        let active = [try run("a", status: "running", started: 1)]
        XCTAssertEqual(LibraryScanState.resolve(libraryID: "3", active: active, recent: [], pending: true), .running(count: 1, queued: 0))
    }

    func testTheLatestFinishedRunWinsWhenNothingIsActive() throws {
        let recent = [
            try run("old", status: "failed", requested: 0, started: 1, completed: 10, error: "root missing"),
            try run("new", status: "completed", requested: 100, started: 101, completed: 160),
            try run("elsewhere", library: "9", status: "failed", requested: 200, started: 201, completed: 220),
        ]
        let state = LibraryScanState.resolve(libraryID: "3", active: [], recent: recent, pending: false)
        guard case .finished(let finished) = state else { return XCTFail("expected a finished state, got \(state)") }
        XCTAssertEqual(finished.id, "new")
        XCTAssertEqual(state.label, "Completed")
    }

    func testAFailedRunShowsFailedAndItsReason() throws {
        let recent = [try run("x", status: "failed", requested: 0, started: 1, completed: 4, error: "root /nas/movies is not reachable")]
        let state = LibraryScanState.resolve(libraryID: "3", active: [], recent: recent, pending: false)
        XCTAssertEqual(state.label, "Failed")
        XCTAssertEqual(state.detail, "root /nas/movies is not reachable")
    }

    func testAStoppedRunSaysStopped() throws {
        let recent = [try run("x", status: "cancelled", requested: 0, started: 1, completed: 4)]
        XCTAssertEqual(LibraryScanState.resolve(libraryID: "3", active: [], recent: recent, pending: false).label, "Stopped")
    }

    func testRecentRunsStillQueuedAreNotTreatedAsFinished() throws {
        // The unfiltered recent list also holds queued and running runs; only the active list decides those.
        let recent = [try run("a", status: "running", requested: 5, started: 6)]
        XCTAssertEqual(LibraryScanState.resolve(libraryID: "3", active: [], recent: recent, pending: false), .idle)
    }
}
