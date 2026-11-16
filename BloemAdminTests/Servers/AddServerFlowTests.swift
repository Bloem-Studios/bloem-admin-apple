import XCTest
@testable import BloemAdmin

/// Step one checks a finished address by itself once typing pauses; Continue checks at once.
@MainActor
final class AddServerFlowTests: XCTestCase {
    /// Stands in for the pause in typing: the automatic check waits here until the test opens it.
    actor Gate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            if isOpen { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            isOpen = true
            waiters.forEach { $0.resume() }
            waiters.removeAll()
        }
    }

    private func makeHarness() -> MockHTTPHarness {
        let http = MockHTTPHarness()
        http.state.stub(path: "/api/v1/health", json: ["status": "ok", "server_name": "Home Server"])
        http.state.stub(path: "/api/v2/system/identity", json: ["server_id": "srv-1"])
        http.state.stub(path: "/api/v2/auth/providers", json: AdminLoginOAuthTests.providersFixture)
        return http
    }

    private func makeFlow(_ http: MockHTTPHarness, gate: Gate) -> AddServerFlow {
        AddServerFlow(
            store: makeIsolatedServerStore(),
            browser: FakeOAuthBrowser { _ in .cancelled },
            session: http.session,
            pause: { await gate.wait() }
        )
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func waitForStepChange(_ flow: AddServerFlow) async {
        for _ in 0..<200 where flow.step == .server {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func testAFinishedAddressIsCheckedAfterThePauseWithoutContinue() async throws {
        let http = makeHarness()
        defer { http.invalidate() }
        let gate = Gate()
        let flow = makeFlow(http, gate: gate)

        flow.addressChanged("example.test")
        await settle()
        XCTAssertTrue(http.state.requestLog.isEmpty, "nothing is asked during the pause")
        XCTAssertFalse(flow.isBusy, "not busy during the pause")

        await gate.open()
        await waitForStepChange(flow)
        guard case .signIn(let discovery) = flow.step else { return XCTFail("still on \(flow.step)") }
        XCTAssertEqual(discovery.baseURL.absoluteString, "https://example.test")
        XCTAssertFalse(flow.isBusy)
    }

    func testAnUnfinishedAddressIsNotCheckedByItself() async {
        let http = makeHarness()
        defer { http.invalidate() }
        let gate = Gate()
        await gate.open()
        let flow = makeFlow(http, gate: gate)

        for address in ["", "example", "example.t", "localhost", "10.0.0.5", "http://example.test", "example.test/admin"] {
            flow.addressChanged(address)
        }
        await settle()
        XCTAssertTrue(http.state.requestLog.isEmpty)
        XCTAssertEqual(flow.step, .server)
        XCTAssertNil(flow.errorMessage)
    }

    func testContinueChecksAtOnceWithoutThePause() async {
        let http = makeHarness()
        defer { http.invalidate() }
        let flow = makeFlow(http, gate: Gate())

        await flow.continueToSignIn(address: "example.test")

        guard case .signIn = flow.step else { return XCTFail("still on \(flow.step)") }
    }

    func testEditingDuringACheckDropsItsAnswer() async {
        let http = makeHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "/api/v1/health",
            response: MockHTTPResponse(json: ["status": "ok", "server_name": "Home Server"]),
            delayUntilReleased: true
        )
        let gate = Gate()
        await gate.open()
        let flow = makeFlow(http, gate: gate)

        flow.addressChanged("example.test")
        await http.state.waitForRequest(path: "/api/v1/health")
        XCTAssertTrue(flow.isBusy)

        flow.addressChanged("example.t")
        XCTAssertFalse(flow.isBusy)
        http.state.releaseResponses(matching: "/api/v1/health")
        await settle()

        XCTAssertEqual(flow.step, .server)
        XCTAssertNil(flow.errorMessage)
        XCTAssertFalse(flow.isBusy)
    }

    func testAFailedAutomaticCheckShowsItsMessageAndAnEditClearsIt() async {
        let http = makeHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/system/identity", json: ["type": "https://api.bloem.test/problems/not-found", "title": "Not Found", "status": 404, "detail": "no route"], status: 404)
        let gate = Gate()
        await gate.open()
        let flow = makeFlow(http, gate: gate)

        flow.addressChanged("example.test")
        for _ in 0..<200 where flow.errorMessage == nil { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(flow.errorMessage)
        XCTAssertEqual(flow.step, .server)

        flow.addressChanged("example.tes")
        XCTAssertNil(flow.errorMessage)
    }

    func testChangeServerDoesNotCheckTheSameAddressAgain() async {
        let http = makeHarness()
        defer { http.invalidate() }
        let gate = Gate()
        await gate.open()
        let flow = makeFlow(http, gate: gate)

        await flow.continueToSignIn(address: "example.test")
        flow.changeServer()
        await settle()

        XCTAssertEqual(flow.step, .server)
        XCTAssertEqual(http.state.requestLog.filter { $0.url?.path == "/api/v1/health" }.count, 1)
    }
}
