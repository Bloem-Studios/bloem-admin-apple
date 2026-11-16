import XCTest
@testable import BloemAdmin

/// A clock the test moves by hand. `sleep` parks until `advance` passes its deadline, so a watchdog of 60 s
/// or a backoff of 32 s runs in milliseconds, and `pendingCount` says how many timers exist right now.
final class TestLiveClock: LiveClock, @unchecked Sendable {
    private struct Waiter {
        let id: Int
        let deadline: TimeInterval
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current: TimeInterval = 0
    private var waiters: [Waiter] = []
    private var nextID = 0
    private var requested: [TimeInterval] = []

    func now() -> TimeInterval { lock.withLock { current } }
    /// Every duration a task asked to sleep, in order.
    var sleeps: [TimeInterval] { lock.withLock { requested } }
    /// Timers waiting right now.
    var pendingCount: Int { lock.withLock { waiters.count } }

    func sleep(for seconds: TimeInterval) async throws {
        let id: Int = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled: Bool = lock.withLock {
                    requested.append(seconds)
                    if Task.isCancelled { return true }
                    waiters.append(Waiter(id: id, deadline: current + max(seconds, 0), continuation: continuation))
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter: Waiter? = lock.withLock {
                guard let index = waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return waiters.remove(at: index)
            }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time forward, waking each timer at its own deadline and letting the tasks it starts run.
    @MainActor
    func advance(_ seconds: TimeInterval) async {
        let target = now() + seconds
        await Self.settle()
        while true {
            let due: Waiter? = lock.withLock {
                let candidates = waiters.indices.filter { waiters[$0].deadline <= target }
                guard let index = candidates.min(by: { waiters[$0].deadline < waiters[$1].deadline }) else { return nil }
                let waiter = waiters.remove(at: index)
                current = max(current, waiter.deadline)
                return waiter
            }
            guard let due else { break }
            due.continuation.resume()
            await Self.settle()
        }
        lock.withLock { current = target }
        await Self.settle()
    }

    /// Lets tasks that are ready run, including ones resumed from another thread.
    @MainActor
    static func settle() async {
        for _ in 0..<30 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 2_000_000)
        for _ in 0..<30 { await Task.yield() }
    }
}

/// A socket the test drives: frames are pushed in, what the app sends is recorded.
final class FakeLiveSocket: EventsSocket, @unchecked Sendable {
    enum PingMode { case pong, hang, fail }

    private let lock = NSLock()
    private var queue: [Result<EventsSocketMessage, Error>] = []
    private var waiter: CheckedContinuation<EventsSocketMessage, Error>?
    private var hungPings: [CheckedContinuation<Void, Error>] = []
    private var closed = false
    private var sentFrames: [String] = []
    private var closeCodeValue: Int?
    private var pings = 0
    private var mode = PingMode.pong
    var negotiatedProtocol: String? = "silo.events.v2"

    var sent: [String] { lock.withLock { sentFrames } }
    var isClosed: Bool { lock.withLock { closed } }
    var closeCode: Int? { lock.withLock { closeCodeValue } }
    var pingCount: Int { lock.withLock { pings } }
    var pingMode: PingMode {
        get { lock.withLock { mode } }
        set { lock.withLock { mode = newValue } }
    }

    func send(_ text: String) async throws { lock.withLock { sentFrames.append(text) } }

    func ping() async throws {
        let current: PingMode = lock.withLock {
            pings += 1
            return mode
        }
        switch current {
        case .pong: return
        case .fail: throw URLError(.networkConnectionLost)
        case .hang:
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyClosed: Bool = lock.withLock {
                    if closed { return true }
                    hungPings.append(continuation)
                    return false
                }
                if alreadyClosed { continuation.resume(throwing: URLError(.cancelled)) }
            }
        }
    }

    func push(_ text: String) { deliver(.success(.text(text))) }

    /// The server closed the socket with `code`; the next receive throws.
    func serverClose(code: Int?) {
        lock.withLock { closeCodeValue = code }
        deliver(.failure(URLError(.networkConnectionLost)))
    }

    private func deliver(_ result: Result<EventsSocketMessage, Error>) {
        let pending: CheckedContinuation<EventsSocketMessage, Error>? = lock.withLock {
            if let waiter {
                self.waiter = nil
                return waiter
            }
            queue.append(result)
            return nil
        }
        pending?.resume(with: result)
    }

    func receive() async throws -> EventsSocketMessage {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<EventsSocketMessage, Error>? = lock.withLock {
                if !queue.isEmpty { return queue.removeFirst() }
                if closed { return .failure(URLError(.cancelled)) }
                waiter = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func close() {
        let (pending, pings): (CheckedContinuation<EventsSocketMessage, Error>?, [CheckedContinuation<Void, Error>]) = lock.withLock {
            closed = true
            defer {
                waiter = nil
                hungPings = []
            }
            return (waiter, hungPings)
        }
        pending?.resume(throwing: URLError(.cancelled))
        for ping in pings { ping.resume(throwing: URLError(.cancelled)) }
    }
}

/// The endpoint a test scripts: each connect takes the next step, then repeats the last one.
final class ScriptedEndpoint: @unchecked Sendable {
    enum Step {
        case socket(any EventsSocket)
        case fail(SessionFailure)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var count = 0

    init(_ steps: [Step]) { self.steps = steps }

    var attempts: Int { lock.withLock { count } }

    var endpoint: LiveEndpoint {
        LiveEndpoint { [self] in try await next() }
    }

    private func next() async throws -> any EventsSocket {
        let step: Step = lock.withLock {
            count += 1
            return steps.count > 1 ? steps.removeFirst() : (steps.first ?? .fail(.connection))
        }
        switch step {
        case .socket(let socket): return socket
        case .fail(let failure): throw SessionTransportError(failure)
        }
    }
}

enum LiveFrames {
    static let timestamp = "2026-11-14T10:20:30.123Z"

    static func hello(_ channels: [String]) -> String {
        let list = channels.map { "\"\($0)\"" }.joined(separator: ",")
        return #"{"type":"hello","schema_version":1,"required_action":"subscribe","available_channels":[\#(list)]}"#
    }

    static func subscribed(_ id: String, accepted: [String], rejected: [String] = []) -> String {
        let list = accepted.map { "\"\($0)\"" }.joined(separator: ",")
        let refused = rejected.map { #"{"channel":"\#($0)","code":"forbidden","message":"no"}"# }.joined(separator: ",")
        return #"{"type":"subscribed","request_id":"\#(id)","channels":[\#(list)],"rejected":[\#(refused)]}"#
    }

    static func snapshot(_ channel: String) -> String {
        #"{"type":"snapshot","channel":"\#(channel)","timestamp":"\#(timestamp)","data":[]}"#
    }

    static func event(_ channel: String, name: String = "changed", id: String = "e1") -> String {
        #"{"type":"event","channel":"\#(channel)","event":"\#(name)","event_id":"\#(id)","timestamp":"\#(timestamp)","data":{}}"#
    }

    static let accessChanged = #"{"type":"access_changed"}"#

    /// The request id and channels of a subscribe frame the app sent.
    static func parse(_ frame: String) -> (id: String, channels: [String])? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(frame.utf8))) as? [String: Any],
              object["type"] as? String == "subscribe",
              let id = object["request_id"] as? String, let channels = object["channels"] as? [String] else { return nil }
        return (id, channels)
    }
}

/// Polls `condition` for up to `timeout` of real time (the fakes resume tasks from other threads).
@MainActor
func waitUntil(_ timeout: TimeInterval = 3, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return condition()
}

extension FakeLiveSocket {
    /// Plays the server's side of the handshake: hello, then (once the app has subscribed) subscribed and a
    /// snapshot for each channel it accepted. Returns the channels accepted.
    @MainActor
    @discardableResult
    func goLive(available: [String] = ["sessions", "scans", "tasks", "jobs", "notifications"], refuse: [String] = []) async -> [String] {
        let before = sent.count
        push(LiveFrames.hello(available))
        _ = await waitUntil { self.sent.count > before }
        guard let last = sent.last, let request = LiveFrames.parse(last) else { return [] }
        let accepted = request.channels.filter { !refuse.contains($0) }
        push(LiveFrames.subscribed(request.id, accepted: accepted, rejected: refuse))
        for channel in accepted { push(LiveFrames.snapshot(channel)) }
        await TestLiveClock.settle()
        return accepted
    }

    /// Answers a later subscribe frame (a new channel was asked for).
    @MainActor
    @discardableResult
    func answerLatestSubscribe(refuse: [String] = []) async -> [String] {
        guard let last = sent.last, let request = LiveFrames.parse(last) else { return [] }
        let accepted = request.channels.filter { !refuse.contains($0) }
        push(LiveFrames.subscribed(request.id, accepted: accepted, rejected: refuse))
        for channel in accepted { push(LiveFrames.snapshot(channel)) }
        await TestLiveClock.settle()
        return accepted
    }
}
