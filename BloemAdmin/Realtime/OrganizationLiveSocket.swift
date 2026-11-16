import Foundation

extension LiveEndpoint {
    /// The organization's live socket for `session` (docs/design.md). The pass is the credential:
    /// every attempt mints a fresh ticket with it, and a stale pass is renewed by the session before the mint is asked again.
    static func organization(session: OrganizationSession) -> LiveEndpoint {
        LiveEndpoint { try await OrganizationLiveConnector.connect(session: session) }
    }
}

/// Opens one attempt on the organization live socket: `POST /api/bloem/v2/admin/organization/live/ticket` with the
/// pass, then `GET /api/bloem/v2/organization/live/ws` with the ticket in the subprotocol
/// (`bloem-live.v1, ticket.<ticket>`). The frames belong to `OrganizationLiveSocket`.
enum OrganizationLiveConnector {
    /// Throws a `SessionTransportError`: `signInRequired` when the pass cannot be had or is refused (401, 403, a
    /// lost organization), `unsupported` when the server has no such route (404, 405, 501, or an address that is not
    /// HTTPS), `protocolViolation` for a ticket this client cannot use, `connection` otherwise (429 and 503 included:
    /// they are a failed attempt, so the connection backs off and falls back after three).
    static func connect(
        session: OrganizationSession, openSocket: EventsSocketOpener = URLSessionEventsSocket.open
    ) async throws -> any EventsSocket {
        let (ticket, url) = try await mint(session)
        try Task.checkCancellation()
        guard let url else { throw SessionTransportError(.unsupported) }
        let socket = openSocket(url, [OrganizationLiveProtocol.name, "ticket.\(ticket.ticket)"])
        return OrganizationLiveSocket(socket: socket, offered: ticket.channels)
    }

    private static func mint(_ session: OrganizationSession) async throws -> (OrganizationLiveTicket, URL?) {
        do {
            let (ticket, url) = try await session.read { client in
                (try await client.createOrganizationLiveTicket(), client.organizationLiveSocketURL)
            }
            guard ticket.protocolName == OrganizationLiveProtocol.name, LiveSocketConnector.isTicket(ticket.ticket) else {
                throw SessionTransportError(.protocolViolation)
            }
            return (ticket, url)
        } catch let error as SessionTransportError {
            throw error
        } catch let error as APIError {
            switch error.statusCode {
            case 401, 403: throw SessionTransportError(.signInRequired, authError: error)
            case 404, 405, 501: throw SessionTransportError(.unsupported)
            default: throw SessionTransportError(.connection)
            }
        } catch is OrganizationAccessDenied {
            throw SessionTransportError(.signInRequired)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw SessionTransportError(.connection)
        }
    }
}

/// The organization live socket (`bloem-live.v1`) as the dialect `LiveConnection` already speaks (`silo.events.v2`), so
/// the connection's foreground, backoff, watchdog, fallback and resync rules apply to it unchanged.
///
/// - The ticket lists what the server serves, which is what a `hello` says: one is made up from it first.
/// - A `subscribe` of Silo's replaces the whole set; here only the difference goes out, as `subscribe` and
///   `unsubscribe`. Its answer, `subscribed`, is made up at once, with a snapshot for every channel that was already
///   subscribed (Silo repeats them, and the connection expects them), so a screen is not told twice.
/// - A `resync` is a snapshot, a `change` is an event, a `heartbeat` is a frame that says nothing but proves the socket
///   is alive. The payloads are never read: the screen reads its list through REST. Frames for a channel nobody here
///   subscribed are dropped.
/// - The close codes 4401, 4403 and 4408 become 4001, which is how Silo says the access changed: one new ticket at
///   once, and a back-off if it repeats. The pass is renewed by the next mint.
/// - An `error` frame for a channel (the ticket already lists what is served, so this means a client bug or a race) is
///   answered like a snapshot, so the connection is not left waiting for one; the channel is not asked for again.
final class OrganizationLiveSocket: EventsSocket, @unchecked Sendable {
    private let socket: any EventsSocket
    private let offered: Set<String>
    private let lock = NSLock()
    private var subscribed: Set<String> = []
    private var refused: Set<String> = []
    private let output: AsyncThrowingStream<EventsSocketMessage, Error>.Continuation
    /// Only `receive()` advances it, and a connection reads from one task.
    private var iterator: AsyncThrowingStream<EventsSocketMessage, Error>.Iterator
    private var pump: Task<Void, Never>?
    private var opener: Task<Void, Never>?

    /// Frames of this dialect that are not worth a name.
    private static let timestamp = "1970-01-01T00:00:00Z"
    /// Silo's way of saying the access changed under a valid login.
    private static let accessChangedCode = 4001
    private static let accessCodes: Set<Int> = [4401, 4403, 4408]

    init(socket: any EventsSocket, offered: [String]) {
        self.socket = socket
        self.offered = Set(offered)
        let (stream, continuation) = AsyncThrowingStream<EventsSocketMessage, Error>.makeStream()
        output = continuation
        iterator = stream.makeAsyncIterator()
        pump = Task { [weak self] in await self?.pumpFrames() }
        // The connection checks the selected subprotocol on the first frame it reads, so the made-up hello waits for
        // the handshake. The server says nothing before the first subscribe, so there is no real frame to wait for.
        opener = Task { [weak self] in await self?.openWhenShaken(offered) }
    }

    /// `silo.events.v2` for the connection when the server selected `bloem-live.v1`; nothing for anything else, which
    /// the connection rejects as a protocol failure.
    var negotiatedProtocol: String? {
        socket.negotiatedProtocol == OrganizationLiveProtocol.name ? EventsProtocol.name : nil
    }

    private func openWhenShaken(_ channels: [String]) async {
        while !Task.isCancelled, socket.negotiatedProtocol == nil {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
        if !Task.isCancelled { output.yield(.text(Self.hello(channels))) }
    }

    var closeCode: Int? {
        guard let code = socket.closeCode else { return nil }
        return Self.accessCodes.contains(code) ? Self.accessChangedCode : code
    }

    func ping() async throws { try await socket.ping() }

    func receive() async throws -> EventsSocketMessage {
        guard let message = try await iterator.next() else { throw URLError(.cancelled) }
        return message
    }

    func close() {
        pump?.cancel()
        opener?.cancel()
        socket.close()
        output.finish(throwing: URLError(.cancelled))
    }

    // MARK: To the server

    /// `LiveConnection` sends Silo's `subscribe`; what goes out is the difference to what is subscribed.
    func send(_ text: String) async throws {
        guard let request = Self.parseSubscribe(text) else {
            try await socket.send(text)
            return
        }
        let change: (add: [String], drop: [String]) = lock.withLock {
            let wanted = Set(request.channels).intersection(offered).subtracting(refused)
            let add = wanted.subtracting(subscribed)
            let drop = subscribed.subtracting(wanted)
            let kept = wanted.intersection(subscribed)
            subscribed = wanted
            // The answer comes before anything the server says about the new channels.
            output.yield(.text(Self.subscribedFrame(request.id, accepted: wanted)))
            for channel in kept.sorted() { output.yield(.text(Self.snapshotFrame(channel))) }
            return (add.sorted(), drop.sorted())
        }
        if !change.drop.isEmpty { try await socket.send(Self.frame(["op": "unsubscribe", "channels": change.drop])) }
        if !change.add.isEmpty { try await socket.send(Self.frame(["op": "subscribe", "channels": change.add, "resume": NSNull()])) }
    }

    // MARK: From the server

    private func pumpFrames() async {
        while !Task.isCancelled {
            do {
                let message = try await socket.receive()
                guard case .text(let text) = message else {
                    output.yield(message)
                    continue
                }
                output.yield(.text(translate(text)))
            } catch {
                output.finish(throwing: error)
                return
            }
        }
    }

    /// One server frame as a frame of Silo's dialect. A frame this client cannot read is passed on as it is, which the
    /// connection rejects as a protocol failure.
    func translate(_ text: String) -> String {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let op = object["op"] as? String else { return text }
        switch op {
        case "change":
            guard let channel = object["channel"] as? String, object["id"] is String,
                  let kind = object["kind"] as? String, ["created", "updated", "deleted"].contains(kind) else { return text }
            return isSubscribed(channel) ? Self.eventFrame(channel) : Self.ignoredFrame
        case "resync":
            guard let channel = object["channel"] as? String else { return text }
            return isSubscribed(channel) ? Self.snapshotFrame(channel) : Self.ignoredFrame
        case "heartbeat":
            return Self.ignoredFrame
        case "error":
            guard let channel = object["channel"] as? String, object["code"] is String else { return text }
            let wasSubscribed: Bool = lock.withLock {
                refused.insert(channel)
                return subscribed.remove(channel) != nil
            }
            return wasSubscribed ? Self.snapshotFrame(channel) : Self.ignoredFrame
        default:
            return Self.ignoredFrame
        }
    }

    private func isSubscribed(_ channel: String) -> Bool { lock.withLock { subscribed.contains(channel) } }

    // MARK: Frames

    static func hello(_ channels: [String]) -> String {
        frame(["type": "hello", "schema_version": 1, "required_action": "subscribe", "available_channels": channels.sorted()])
    }

    static func subscribedFrame(_ requestID: String, accepted: Set<String>) -> String {
        frame(["type": "subscribed", "request_id": requestID, "channels": accepted.sorted()])
    }

    static func snapshotFrame(_ channel: String) -> String {
        frame(["type": "snapshot", "channel": channel, "timestamp": timestamp, "data": [Any]()])
    }

    static func eventFrame(_ channel: String) -> String {
        frame(["type": "event", "channel": channel, "event": "changed", "event_id": "org", "timestamp": timestamp])
    }

    static let ignoredFrame = #"{"type":"ignored"}"#

    private static func frame(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private static func parseSubscribe(_ text: String) -> (id: String, channels: [String])? {
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              object["type"] as? String == "subscribe",
              let id = object["request_id"] as? String, let channels = object["channels"] as? [String] else { return nil }
        return (id, channels)
    }
}
