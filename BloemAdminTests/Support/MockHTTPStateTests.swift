import XCTest
@testable import BloemAdmin

final class MockHTTPStateTests: XCTestCase {
    private struct Value: Decodable, Sendable {
        let value: String
    }

    func testSessionsWithTheSameOriginRemainIsolated() async throws {
        let first = MockHTTPHarness()
        let second = MockHTTPHarness()
        defer {
            first.invalidate()
            second.invalidate()
        }
        first.state.stub(path: "/value", json: ["value": "first"])
        second.state.stub(path: "/value", json: ["value": "second"])

        async let firstValue: Value = first.client.get("/value")
        async let secondValue: Value = second.client.get("/value")
        let values = try await (firstValue, secondValue)

        XCTAssertEqual([values.0.value, values.1.value], ["first", "second"])
        XCTAssertEqual(first.state.requests(path: "/value").count, 1)
        XCTAssertEqual(second.state.requests(path: "/value").count, 1)
    }

    func testOneHundredConcurrentRequestsAreRecordedExactlyOnce() async {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(path: "/value", json: ["value": "ok"])

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<100 {
                group.addTask {
                    let _: Value? = try? await harness.client.get("/value")
                }
            }
        }

        XCTAssertEqual(harness.state.requests(path: "/value").count, 100)
        XCTAssertEqual(harness.state.completionCount(path: "/value"), 100)
    }

    func testResponsesForTheSameRouteAreConsumedInFIFOOrder() async throws {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stubSequence(path: "/value", responses: [
            MockHTTPResponse(json: ["value": "first"]),
            MockHTTPResponse(json: ["value": "second"]),
        ])

        let first: Value = try await harness.client.get("/value")
        let second: Value = try await harness.client.get("/value")

        XCTAssertEqual([first.value, second.value], ["first", "second"])
    }

    func testRoutingHeaderIsRemovedFromRecordedRequests() async throws {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(path: "/value", json: ["value": "ok"])

        let _: Value = try await harness.client.get("/value")

        XCTAssertNil(harness.state.lastRequest?.value(forHTTPHeaderField: MockHTTPHarness.routingHeader))
    }

    func testCancellingDelayedResponseCompletesExactlyOnce() async throws {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(
            path: "/value",
            response: MockHTTPResponse(json: ["value": "late"]),
            delayUntilReleased: true
        )
        let request = Task {
            try await harness.client.get("/value") as Value
        }
        await harness.state.waitForRequest(path: "/value", count: 1)

        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Expected cancellation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }

        await harness.state.waitForCompletion(path: "/value")
        harness.state.releaseResponses(matching: "/value")
        XCTAssertEqual(harness.state.completionCount(path: "/value"), 1)
    }

    func testCancellingBarrierParticipantBeforeRendezvousCancelsSibling() async {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(path: "/barrier", json: ["value": "unexpected"])
        harness.state.requiredConcurrentStarts = 3
        let first = Task {
            try await harness.client.get("/barrier") as Value
        }
        let second = Task {
            try await harness.client.get("/barrier") as Value
        }
        await harness.state.waitForRequest(path: "/barrier", count: 2)

        second.cancel()
        let siblingCompleted = expectation(description: "barrier sibling completed")
        let siblingObserver = Task {
            let result = await first.result
            siblingCompleted.fulfill()
            return result
        }
        await fulfillment(of: [siblingCompleted], timeout: 0.5)

        first.cancel()
        assertCancelled(await siblingObserver.value)
        assertCancelled(await second.result)
        XCTAssertEqual(harness.state.completionCount(path: "/barrier"), 2)
    }

    func testResettingConcurrencyBarrierCancelsPendingParticipants() async {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(path: "/barrier", json: ["value": "unexpected"])
        harness.state.requiredConcurrentStarts = 3
        let first = Task {
            try await harness.client.get("/barrier") as Value
        }
        let second = Task {
            try await harness.client.get("/barrier") as Value
        }
        await harness.state.waitForRequest(path: "/barrier", count: 2)

        harness.state.resetConcurrencyBarrier()
        let participantsCompleted = expectation(description: "reset participants completed")
        participantsCompleted.expectedFulfillmentCount = 2
        let firstObserver = Task {
            let result = await first.result
            participantsCompleted.fulfill()
            return result
        }
        let secondObserver = Task {
            let result = await second.result
            participantsCompleted.fulfill()
            return result
        }
        await fulfillment(of: [participantsCompleted], timeout: 0.5)

        first.cancel()
        second.cancel()
        assertCancelled(await firstObserver.value)
        assertCancelled(await secondObserver.value)
        XCTAssertEqual(harness.state.completionCount(path: "/barrier"), 2)
    }

    func testTaggedRequestAfterInvalidationFailsClosedWithoutRealTransport() async {
        let harness = MockHTTPHarness()
        let configuration = harness.session.configuration
        guard let identifier = configuration.httpAdditionalHeaders?[MockHTTPHarness.routingHeader] as? String else {
            XCTFail("Expected mock routing identifier")
            harness.invalidate()
            return
        }
        harness.invalidate()

        let racingSession = URLSession(configuration: configuration)
        defer { racingSession.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "https://127.0.0.1:1/value")!)
        request.setValue(identifier, forHTTPHeaderField: MockHTTPHarness.routingHeader)

        do {
            _ = try await racingSession.data(for: request)
            XCTFail("Expected an orphaned routed request to fail")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .unsupportedURL)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTaggedRequestAndInvalidationRaceNeverFallsThroughToRealTransport() async {
        for _ in 0..<20 {
            let harness = MockHTTPHarness()
            harness.state.requiredConcurrentStarts = 2
            let configuration = harness.session.configuration
            guard let identifier = configuration.httpAdditionalHeaders?[MockHTTPHarness.routingHeader] as? String else {
                XCTFail("Expected mock routing identifier")
                harness.invalidate()
                return
            }
            let racingSession = URLSession(configuration: configuration)
            var request = URLRequest(url: URL(string: "https://127.0.0.1:1/value")!)
            request.setValue(identifier, forHTTPHeaderField: MockHTTPHarness.routingHeader)

            let requestTask = Task { try await racingSession.data(for: request) }
            let invalidationTask = Task { harness.invalidate() }
            let result = await requestTask.result
            await invalidationTask.value
            racingSession.invalidateAndCancel()

            switch result {
            case .success:
                XCTFail("A raced mock request unexpectedly succeeded")
            case let .failure(error as URLError):
                XCTAssertTrue(
                    error.code == .cancelled || error.code == .unsupportedURL,
                    "Raced mock request escaped to real transport: \(error)"
                )
            case let .failure(error):
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testCancellingRequestWaiterReturnsPromptly() async {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(path: "/waiter", json: ["value": "cleanup"])
        let waiterEnqueued = expectation(description: "waiter enqueued")
        let waiterReturned = expectation(description: "cancelled waiter returned")
        let waiter = Task {
            await harness.state.waitForRequest(path: "/waiter") {
                waiterEnqueued.fulfill()
            }
            waiterReturned.fulfill()
        }
        await fulfillment(of: [waiterEnqueued], timeout: 0.5)

        waiter.cancel()
        await fulfillment(of: [waiterReturned], timeout: 0.5)

        let _: Value? = try? await harness.client.get("/waiter")
        await waiter.value
    }

    func testHarnessInvalidationReturnsRequestWaitersPromptly() async {
        let harness = MockHTTPHarness()
        let waiterEnqueued = expectation(description: "waiter enqueued")
        let waiterReturned = expectation(description: "invalidated waiter returned")
        let waiter = Task {
            await harness.state.waitForRequest(path: "/never") {
                waiterEnqueued.fulfill()
            }
            waiterReturned.fulfill()
        }
        await fulfillment(of: [waiterEnqueued], timeout: 0.5)

        harness.invalidate()
        await fulfillment(of: [waiterReturned], timeout: 0.5)
        _ = waiter
    }

    func testWaitingAfterHarnessInvalidationReturnsPromptly() async {
        let harness = MockHTTPHarness()
        harness.invalidate()
        let waiterReturned = expectation(description: "post-invalidation waiter returned")

        let waiter = Task {
            await harness.state.waitForRequest(path: "/never")
            waiterReturned.fulfill()
        }

        await fulfillment(of: [waiterReturned], timeout: 0.5)
        _ = waiter
    }

    func testCancellingReleasedDelayedResponsePreventsLateSuccess() async {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(
            path: "/delayed",
            response: MockHTTPResponse(json: ["value": "late"]),
            delayUntilReleased: true
        )
        harness.state.delayedHosts = ["example.test": 0.1]
        let request = Task {
            try await harness.client.get("/delayed") as Value
        }
        await harness.state.waitForRequest(path: "/delayed")

        harness.state.releaseResponses(matching: "/delayed")
        request.cancel()

        assertCancelled(await request.result)
        await harness.state.waitForCompletion(path: "/delayed")
        let delayElapsed = expectation(description: "delayed work deadline elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            delayElapsed.fulfill()
        }
        await fulfillment(of: [delayElapsed], timeout: 0.5)
        XCTAssertEqual(harness.state.completionCount(path: "/delayed"), 1)
        XCTAssertEqual(harness.state.completionOutcomes(path: "/delayed"), [.failure(.cancelled)])
    }

    func testSuccessfulResponseCompletesExactlyOnce() async throws {
        let harness = MockHTTPHarness()
        defer { harness.invalidate() }
        harness.state.stub(path: "/value", json: ["value": "ok"])

        let value: Value = try await harness.client.get("/value")

        XCTAssertEqual(value.value, "ok")
        XCTAssertEqual(harness.state.completionCount(path: "/value"), 1)
    }

    private func assertCancelled<T>(
        _ result: Result<T, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("Expected cancellation", file: file, line: line)
        case let .failure(error as URLError):
            XCTAssertEqual(error.code, .cancelled, file: file, line: line)
        case let .failure(error):
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
