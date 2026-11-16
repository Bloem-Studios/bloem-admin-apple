import Foundation
@testable import BloemAdmin

struct MockHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int
    let headers: [String: String]
    let transportError: URLError.Code?

    init(data: Data = Data(), status: Int = 200, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = status
        self.headers = headers
        self.transportError = nil
    }

    init(json: Any, status: Int = 200, headers: [String: String] = [:]) {
        do {
            self.data = try JSONSerialization.data(withJSONObject: json)
        } catch {
            preconditionFailure("Invalid mock JSON fixture: \(error)")
        }
        self.statusCode = status
        self.headers = headers
        self.transportError = nil
    }

    init(transportError: URLError.Code) {
        self.data = Data()
        self.statusCode = 0
        self.headers = [:]
        self.transportError = transportError
    }
}

enum MockHTTPCompletionOutcome: Equatable, Sendable {
    case response
    case failure(URLError.Code?)
}

/// Test-only shared mutable state is protected by `lock`; the small static
/// routing registry is protected by `registryLock`. No stored fixture or
/// request value is read or written outside those lock invariants.
final class MockHTTPState: @unchecked Sendable {
    typealias ResponseTuple = (data: Data, status: Int)

    private struct PendingResponse {
        let protocolInstance: MockHTTPURLProtocol
        let request: URLRequest
        let response: MockHTTPResponse
        let delay: TimeInterval
        let held: Bool
    }

    private struct RequestWaiter {
        let id: UUID
        let path: String
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private struct CompletionWaiter {
        let id: UUID
        let path: String
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private static let registryLock = NSLock()
    // Every access is serialized by registryLock. Swift cannot infer that
    // invariant for mutable static storage, so make the synchronization
    // boundary explicit for the test-only URLProtocol router.
    nonisolated(unsafe) private static var registry: [String: MockHTTPState] = [:]

    private let lock = NSLock()
    private var defaultResponse = MockHTTPResponse()
    private var pathResponseOverrides: [String: MockHTTPResponse] = [:]
    private var hostResponseOverrides: [String: MockHTTPResponse] = [:]
    private var hostPathResponseOverrides: [String: MockHTTPResponse] = [:]
    private var hostPathResponseSequences: [String: [MockHTTPResponse]] = [:]
    private var hostResponseDelays: [String: TimeInterval] = [:]
    private var heldPaths: Set<String> = []
    private var heldGetPaths: Set<String> = []
    private var recordedRequests: [URLRequest] = []
    private var recordedBodies: [Data?] = []
    private var completionCounts: [String: Int] = [:]
    private var completionOutcomesByPath: [String: [MockHTTPCompletionOutcome]] = [:]
    private var requestWaiters: [RequestWaiter] = []
    private var completionWaiters: [CompletionWaiter] = []
    private var invalidated = false
    private var concurrentStartCount = 0
    private var barrierParticipants: [PendingResponse] = []
    private var heldParticipants: [PendingResponse] = []

    var responseData: Data {
        get { withLock { defaultResponse.data } }
        set { withLock { defaultResponse = MockHTTPResponse(data: newValue, status: defaultResponse.statusCode, headers: defaultResponse.headers) } }
    }

    var responseStatus: Int {
        get { withLock { defaultResponse.statusCode } }
        set { withLock { defaultResponse = MockHTTPResponse(data: defaultResponse.data, status: newValue, headers: defaultResponse.headers) } }
    }

    var pathOverrides: [String: ResponseTuple] {
        get { withLock { pathResponseOverrides.mapValues { ($0.data, $0.statusCode) } } }
        set { withLock { pathResponseOverrides = newValue.mapValues { MockHTTPResponse(data: $0.data, status: $0.status) } } }
    }

    var hostOverrides: [String: ResponseTuple] {
        get { withLock { hostResponseOverrides.mapValues { ($0.data, $0.statusCode) } } }
        set { withLock { hostResponseOverrides = newValue.mapValues { MockHTTPResponse(data: $0.data, status: $0.status) } } }
    }

    var hostPathOverrides: [String: ResponseTuple] {
        get { withLock { hostPathResponseOverrides.mapValues { ($0.data, $0.statusCode) } } }
        set { withLock { hostPathResponseOverrides = newValue.mapValues { MockHTTPResponse(data: $0.data, status: $0.status) } } }
    }

    var hostPathSequences: [String: [ResponseTuple]] {
        get { withLock { hostPathResponseSequences.mapValues { $0.map { ($0.data, $0.statusCode) } } } }
        set {
            withLock {
                hostPathResponseSequences = newValue.mapValues { queue in
                    queue.map { MockHTTPResponse(data: $0.data, status: $0.status) }
                }
            }
        }
    }

    var delayedHosts: [String: TimeInterval] {
        get { withLock { hostResponseDelays } }
        set { withLock { hostResponseDelays = newValue } }
    }

    var requiredConcurrentStarts: Int {
        get { withLock { concurrentStartCount } }
        set { withLock { concurrentStartCount = newValue } }
    }

    var requestLog: [URLRequest] {
        get { withLock { recordedRequests } }
        set { withLock { recordedRequests = newValue; recordedBodies = Array(repeating: nil, count: newValue.count) } }
    }

    var lastRequest: URLRequest? {
        get { withLock { recordedRequests.last } }
        set {
            withLock {
                if let newValue {
                    recordedRequests.append(newValue)
                    recordedBodies.append(Self.readBody(from: newValue))
                } else {
                    recordedRequests.removeAll()
                    recordedBodies.removeAll()
                }
            }
        }
    }

    var capturedBody: Data? {
        get { withLock { recordedBodies.last ?? nil } }
        set {
            withLock {
                guard !recordedBodies.isEmpty else { return }
                recordedBodies[recordedBodies.count - 1] = newValue
            }
        }
    }

    func stub(path: String, data: Data = Data(), status: Int = 200) {
        withLock { pathResponseOverrides[path] = MockHTTPResponse(data: data, status: status) }
    }

    func stub(path: String, json: Any, status: Int = 200) {
        withLock { pathResponseOverrides[path] = MockHTTPResponse(json: json, status: status) }
    }

    func stub(path: String, response: MockHTTPResponse, delayUntilReleased: Bool = false) {
        withLock {
            pathResponseOverrides[path] = response
            if delayUntilReleased {
                heldPaths.insert(path)
            } else {
                heldPaths.remove(path)
            }
        }
    }

    /// Holds only GET requests to `path` until `releaseResponses(matching:)`; other methods answer normally.
    func holdGETs(path: String) {
        withLock { _ = heldGetPaths.insert(path) }
    }

    func stub(host: String, data: Data = Data(), status: Int = 200) {
        withLock { hostResponseOverrides[host] = MockHTTPResponse(data: data, status: status) }
    }

    func stub(host: String, path: String, data: Data = Data(), status: Int = 200) {
        withLock { hostPathResponseOverrides[Self.hostPathKey(host: host, path: path)] = MockHTTPResponse(data: data, status: status) }
    }

    func stubSequence(path: String, responses: [MockHTTPResponse], host: String = "example.test") {
        withLock { hostPathResponseSequences[Self.hostPathKey(host: host, path: path)] = responses }
    }

    func requests(path: String) -> [URLRequest] {
        withLock { recordedRequests.filter { $0.url?.path == path } }
    }

    func body(path: String, requestIndex: Int) -> Data? {
        withLock {
            let matchingIndices = recordedRequests.indices.filter { recordedRequests[$0].url?.path == path }
            guard matchingIndices.indices.contains(requestIndex) else { return nil }
            return recordedBodies[matchingIndices[requestIndex]]
        }
    }

    func requests(host: String, path: String? = nil) -> [URLRequest] {
        withLock {
            recordedRequests.filter {
                $0.url?.host == host && (path == nil || $0.url?.path == path)
            }
        }
    }

    func completionCount(path: String) -> Int {
        withLock { completionCounts[path, default: 0] }
    }

    func completionOutcomes(path: String) -> [MockHTTPCompletionOutcome] {
        withLock { completionOutcomesByPath[path, default: []] }
    }

    func waitForRequest(path: String, count: Int = 1, onEnqueued: (() -> Void)? = nil) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var enqueued = false
                var resumeImmediately = false
                lock.lock()
                if invalidated
                    || Task.isCancelled
                    || recordedRequests.lazy.filter({ $0.url?.path == path }).count >= count {
                    resumeImmediately = true
                } else {
                    requestWaiters.append(RequestWaiter(
                        id: waiterID,
                        path: path,
                        count: count,
                        continuation: continuation
                    ))
                    enqueued = true
                }
                lock.unlock()
                if enqueued {
                    onEnqueued?()
                } else if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelWaiter(id: waiterID)
        }
    }

    func waitForCompletion(path: String, count: Int = 1) async {
        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                var resumeImmediately = false
                lock.lock()
                if invalidated || Task.isCancelled || completionCounts[path, default: 0] >= count {
                    resumeImmediately = true
                } else {
                    completionWaiters.append(CompletionWaiter(
                        id: waiterID,
                        path: path,
                        count: count,
                        continuation: continuation
                    ))
                }
                lock.unlock()
                if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            self.cancelCompletionWaiter(id: waiterID)
        }
    }

    func releaseResponses(matching match: String) {
        let pending: [PendingResponse] = withLock {
            let released = heldParticipants.filter { Self.matches($0.request, match: match) }
            heldParticipants.removeAll { Self.matches($0.request, match: match) }
            return released
        }
        pending.forEach { $0.protocolInstance.deliver($0.response, for: $0.request, after: $0.delay) }
    }

    func resetConcurrencyBarrier() {
        let pendingProtocols: [MockHTTPURLProtocol] = withLock {
            concurrentStartCount = 0
            let protocols = barrierParticipants.map(\.protocolInstance)
            barrierParticipants.removeAll()
            return protocols
        }
        pendingProtocols.forEach { $0.cancelFromState() }
    }

    fileprivate static func register(_ state: MockHTTPState, id: String) {
        registryLock.lock()
        registry[id] = state
        registryLock.unlock()
    }

    fileprivate static func unregister(id: String) {
        registryLock.lock()
        registry[id] = nil
        registryLock.unlock()
    }

    fileprivate static func state(for request: URLRequest) -> MockHTTPState? {
        guard let id = request.value(forHTTPHeaderField: MockHTTPHarness.routingHeader) else { return nil }
        registryLock.lock()
        let state = registry[id]
        registryLock.unlock()
        return state
    }

    fileprivate func begin(_ protocolInstance: MockHTTPURLProtocol, request originalRequest: URLRequest) {
        var visibleRequest = originalRequest
        visibleRequest.setValue(nil, forHTTPHeaderField: MockHTTPHarness.routingHeader)
        let body = Self.readBody(from: visibleRequest)
        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        var ready: [PendingResponse] = []
        var rejectRequest = false

        lock.lock()
        if invalidated {
            rejectRequest = true
        } else {
            recordedRequests.append(visibleRequest)
            recordedBodies.append(body)
            let work = PendingResponse(
                protocolInstance: protocolInstance,
                request: visibleRequest,
                response: responseLocked(for: visibleRequest),
                delay: visibleRequest.url?.host.flatMap { hostResponseDelays[$0] } ?? 0,
                held: visibleRequest.url.map {
                    heldPaths.contains($0.path) || (visibleRequest.httpMethod == "GET" && heldGetPaths.contains($0.path))
                } ?? false
            )
            if concurrentStartCount > 0 {
                barrierParticipants.append(work)
                if barrierParticipants.count >= concurrentStartCount {
                    let participants = barrierParticipants
                    barrierParticipants.removeAll()
                    for participant in participants {
                        if participant.held {
                            heldParticipants.append(participant)
                        } else {
                            ready.append(participant)
                        }
                    }
                }
            } else if work.held {
                heldParticipants.append(work)
            } else {
                ready.append(work)
            }
            requestWaiters.removeAll { waiter in
                let satisfied = recordedRequests.lazy.filter { $0.url?.path == waiter.path }.count >= waiter.count
                if satisfied { waitersToResume.append(waiter.continuation) }
                return satisfied
            }
        }
        lock.unlock()

        if rejectRequest {
            protocolInstance.failBecauseStateIsUnavailable()
            return
        }
        waitersToResume.forEach { $0.resume() }
        ready.forEach { $0.protocolInstance.deliver($0.response, for: $0.request, after: $0.delay) }
    }

    fileprivate func cancel(_ protocolInstance: MockHTTPURLProtocol) {
        var targetCompletion: MockHTTPURLProtocol.FailureCompletion?
        let barrierSiblings: [MockHTTPURLProtocol] = withLock {
            targetCompletion = protocolInstance.claimCancellation()
            heldParticipants.removeAll { $0.protocolInstance === protocolInstance }
            guard barrierParticipants.contains(where: { $0.protocolInstance === protocolInstance }) else {
                return []
            }
            let siblings = barrierParticipants.compactMap { participant in
                participant.protocolInstance === protocolInstance ? nil : participant.protocolInstance
            }
            barrierParticipants.removeAll()
            return siblings
        }
        if let targetCompletion {
            protocolInstance.deliverCancellation(targetCompletion)
        }
        barrierSiblings.forEach { $0.cancelFromState() }
    }

    fileprivate func invalidate() {
        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        var pendingProtocols: [MockHTTPURLProtocol] = []

        lock.lock()
        guard !invalidated else {
            lock.unlock()
            return
        }
        invalidated = true
        waitersToResume = requestWaiters.map(\.continuation) + completionWaiters.map(\.continuation)
        requestWaiters.removeAll()
        completionWaiters.removeAll()
        pendingProtocols = (barrierParticipants + heldParticipants).map(\.protocolInstance)
        barrierParticipants.removeAll()
        heldParticipants.removeAll()
        lock.unlock()

        waitersToResume.forEach { $0.resume() }
        pendingProtocols.forEach { $0.cancelFromState() }
    }

    fileprivate func recordCompletion(for request: URLRequest, outcome: MockHTTPCompletionOutcome) {
        var waitersToResume: [CheckedContinuation<Void, Never>] = []
        lock.lock()
        let path = request.url?.path ?? ""
        completionCounts[path, default: 0] += 1
        completionOutcomesByPath[path, default: []].append(outcome)
        completionWaiters.removeAll { waiter in
            let satisfied = waiter.path == path && completionCounts[path, default: 0] >= waiter.count
            if satisfied { waitersToResume.append(waiter.continuation) }
            return satisfied
        }
        lock.unlock()
        waitersToResume.forEach { $0.resume() }
    }

    private func responseLocked(for request: URLRequest) -> MockHTTPResponse {
        guard let url = request.url else { return defaultResponse }
        let key = Self.hostPathKey(host: url.host ?? "", path: url.path)
        if var sequence = hostPathResponseSequences[key], !sequence.isEmpty {
            let response = sequence.removeFirst()
            hostPathResponseSequences[key] = sequence
            return response
        }
        return hostPathResponseOverrides[key]
            ?? url.host.flatMap { hostResponseOverrides[$0] }
            ?? pathResponseOverrides[url.path]
            ?? defaultResponse
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    private func cancelWaiter(id: UUID) {
        let continuation: CheckedContinuation<Void, Never>? = withLock {
            guard let index = requestWaiters.firstIndex(where: { $0.id == id }) else { return nil }
            return requestWaiters.remove(at: index).continuation
        }
        continuation?.resume()
    }

    private func cancelCompletionWaiter(id: UUID) {
        let continuation: CheckedContinuation<Void, Never>? = withLock {
            guard let index = completionWaiters.firstIndex(where: { $0.id == id }) else { return nil }
            return completionWaiters.remove(at: index).continuation
        }
        continuation?.resume()
    }

    private static func hostPathKey(host: String, path: String) -> String {
        "\(host)|\(path)"
    }

    private static func matches(_ request: URLRequest, match: String) -> Bool {
        request.url?.path == match
            || request.url?.host == match
            || request.url.map { hostPathKey(host: $0.host ?? "", path: $0.path) } == match
    }

    private static func readBody(from request: URLRequest) -> Data? {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class MockHTTPHarness: Sendable {
    static let routingHeader = "X-BloemAdmin-Mock-HTTP-ID"

    let state: MockHTTPState
    let session: URLSession
    let client: APIClient
    private let identifier: String

    init() {
        let identifier = UUID().uuidString
        let state = MockHTTPState()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockHTTPURLProtocol.self]
        configuration.httpAdditionalHeaders = [Self.routingHeader: identifier]
        let session = URLSession(configuration: configuration)
        self.identifier = identifier
        self.state = state
        self.session = session
        self.client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            accessToken: nil,
            session: session
        )
        MockHTTPState.register(state, id: identifier)
    }

    func invalidate() {
        state.invalidate()
        session.invalidateAndCancel()
        MockHTTPState.unregister(id: identifier)
    }

    deinit {
        invalidate()
    }
}

private final class MockHTTPURLProtocol: URLProtocol {
    fileprivate struct FailureCompletion {
        let work: DispatchWorkItem?
        let request: URLRequest
        let state: MockHTTPState?
        let client: URLProtocolClient?
    }

    private let completionLock = NSLock()
    private var completed = false
    private var pendingWork: DispatchWorkItem?
    private var visibleRequest: URLRequest?
    private var state: MockHTTPState?

    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: MockHTTPHarness.routingHeader) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let state = MockHTTPState.state(for: request) else {
            finish(with: URLError(.unsupportedURL))
            return
        }
        self.state = state
        state.begin(self, request: request)
    }

    override func stopLoading() {
        if let state {
            state.cancel(self)
        } else {
            finish(with: URLError(.cancelled))
        }
    }

    fileprivate func claimCancellation() -> FailureCompletion? {
        claimFailureCompletion()
    }

    fileprivate func deliverCancellation(_ completion: FailureCompletion) {
        completion.work?.cancel()
        deliverFailure(completion, error: URLError(.cancelled))
    }

    fileprivate func cancelFromState() {
        finish(with: URLError(.cancelled))
    }

    fileprivate func failBecauseStateIsUnavailable() {
        finish(with: URLError(.unsupportedURL))
    }

    fileprivate func deliver(_ response: MockHTTPResponse, for request: URLRequest, after delay: TimeInterval) {
        completionLock.lock()
        guard !completed else {
            completionLock.unlock()
            return
        }
        visibleRequest = request
        if delay > 0 {
            let work = DispatchWorkItem { [weak self] in self?.finish(with: response) }
            pendingWork = work
            completionLock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            completionLock.unlock()
            finish(with: response)
        }
    }

    private func finish(with response: MockHTTPResponse) {
        if let transportError = response.transportError {
            finish(with: URLError(transportError))
            return
        }
        completionLock.lock()
        guard !completed else {
            completionLock.unlock()
            return
        }
        completed = true
        pendingWork = nil
        let request = visibleRequest ?? self.request
        let state = self.state
        let client = self.client
        completionLock.unlock()

        state?.recordCompletion(for: request, outcome: .response)
        guard let url = request.url,
              let httpResponse = HTTPURLResponse(
                url: url,
                statusCode: response.statusCode,
                httpVersion: nil,
                headerFields: response.headers
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func finish(with error: Error) {
        guard let completion = claimFailureCompletion() else { return }
        completion.work?.cancel()
        deliverFailure(completion, error: error)
    }

    private func claimFailureCompletion() -> FailureCompletion? {
        completionLock.lock()
        guard !completed else {
            completionLock.unlock()
            return nil
        }
        completed = true
        let work = pendingWork
        pendingWork = nil
        let request = visibleRequest ?? self.request
        let state = self.state
        let client = self.client
        completionLock.unlock()

        return FailureCompletion(work: work, request: request, state: state, client: client)
    }

    private func deliverFailure(_ completion: FailureCompletion, error: Error) {
        completion.state?.recordCompletion(
            for: completion.request,
            outcome: .failure((error as? URLError)?.code)
        )
        completion.client?.urlProtocol(self, didFailWithError: error)
    }
}

extension MockHTTPState {
    /// The capabilities document of a Bloem server (`GET /api/bloem/v2/capabilities`): what makes the app switch the
    /// Bloem extras on.
    func stubBloemServer(featureTokens: [String] = []) {
        let tokens = featureTokens.map { "\"\($0)\"" }.joined(separator: ",")
        stub(path: "/api/bloem/v2/capabilities", data: Data(#"{"api":"bloem/v2","identity_schema":2,"features":{},"media_types":[],"feature_tokens":[\#(tokens)]}"#.utf8))
    }

    /// A plain Silo server: it has no `/api/bloem/` routes, so everything there answers 404 `404 page not found`.
    func stubPlainSilo() {
        let body = Data("404 page not found\n".utf8)
        stub(path: "/api/bloem/v2/capabilities", data: body, status: 404)
        stub(path: "/api/bloem/v2/organizations", data: body, status: 404)
    }
}
