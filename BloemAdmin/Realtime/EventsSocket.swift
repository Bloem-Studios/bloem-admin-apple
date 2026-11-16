import Foundation

enum EventsSocketMessage: Sendable {
    case text(String)
    case data(Data)
}

/// The one WebSocket the sessions source reads. A protocol so the handshake can be tested without a
/// network; `URLSessionEventsSocket` is the real one.
protocol EventsSocket: AnyObject, Sendable {
    /// The subprotocol the server selected; nil until the handshake has completed.
    var negotiatedProtocol: String? { get }
    /// The close code the server sent, once it has closed the socket.
    var closeCode: Int? { get }
    func send(_ text: String) async throws
    /// A WebSocket ping, answered by the server's pong. Throws when the connection is dead. Pong frames are
    /// not delivered to `receive()`, so this is how the watchdog tells a quiet socket from a dead one.
    func ping() async throws
    /// The next frame. Throws when the socket closes, is cancelled or fails.
    func receive() async throws -> EventsSocketMessage
    func close()
}

typealias EventsSocketOpener = @Sendable (_ url: URL, _ subprotocols: [String]) -> any EventsSocket

/// A `URLSessionWebSocketTask` on a session of its own: closing the socket invalidates that session,
/// so it ends this connection and nothing else. The session refuses redirects.
final class URLSessionEventsSocket: NSObject, EventsSocket, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var selectedProtocol: String?
    private var session: URLSession!
    private var task: URLSessionWebSocketTask!

    static let open: EventsSocketOpener = { url, subprotocols in
        URLSessionEventsSocket(url: url, subprotocols: subprotocols, configuration: ProductionSession.socketConfiguration())
    }

    init(url: URL, subprotocols: [String], configuration: URLSessionConfiguration) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        task = session.webSocketTask(with: url, protocols: subprotocols)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()
    }

    /// The delegate's answer, or the handshake response's header when the delegate has not run yet.
    var negotiatedProtocol: String? {
        if let selected = lock.withLock({ selectedProtocol }), !selected.isEmpty { return selected }
        return (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
    }

    var closeCode: Int? { task.closeCode == .invalid ? nil : task.closeCode.rawValue }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func ping() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            task.sendPing { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    func receive() async throws -> EventsSocketMessage {
        switch try await task.receive() {
        case .string(let text): .text(text)
        case .data(let data): .data(data)
        @unknown default: .data(Data())
        }
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.withLock { selectedProtocol = `protocol` }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
