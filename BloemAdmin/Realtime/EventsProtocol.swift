import Foundation

/// Where one server's live connection stands, as a screen shows it. Android's `RealtimeState`.
enum RealtimeState: Equatable, Sendable {
    case connecting
    case live
    case reconnecting
    /// No socket (the server has none, or it refused the channel); the screen is read at most once a minute.
    case unavailable
    case signInRequired

    var label: String {
        switch self {
        case .connecting: String(localized: "Connecting")
        case .live: String(localized: "Live")
        case .reconnecting: String(localized: "Reconnecting")
        case .unavailable: String(localized: "Unavailable")
        case .signInRequired: String(localized: "Sign in to continue")
        }
    }
}

/// Why a socket attempt ended. Android's `SessionFailure`, plus `accessChanged`: the server closed the
/// socket because the access it was opened under changed while the login stays valid, so the app asks
/// for a new ticket and reconnects.
enum SessionFailure: Equatable, Sendable {
    case signInRequired
    case unsupported
    case protocolViolation
    case connection
    case deadline
    case accessChanged

    /// The caption under the state label; nil where the label says it all.
    var message: String? {
        switch self {
        case .signInRequired: String(localized: "Sign in again to restore administrator access")
        case .unsupported: String(localized: "Live updates unavailable, sessions refresh every minute")
        case .protocolViolation: String(localized: "Live updates could not be read, reconnecting and checking sessions")
        case .connection: String(localized: "Connection lost, reconnecting and checking sessions")
        case .deadline: String(localized: "Live updates timed out, reconnecting and checking sessions")
        case .accessChanged: nil
        }
    }
}

/// One attempt's failure. It keeps no upstream payload, header or ticket; `authError` is only the
/// sign-in problem the server's own answer to the ticket request was (401 or 403), so the owner can
/// tell the session state about it.
struct SessionTransportError: Error {
    let failure: SessionFailure
    let authError: APIError?

    init(_ failure: SessionFailure, authError: APIError? = nil) {
        self.failure = failure
        self.authError = authError
    }
}

extension SessionTransportError: CustomStringConvertible {
    var description: String { "Live transport: \(failure)" }
}

/// What the app needs from a frame of `silo.events.v2`. Snapshots and events are only cues: their
/// payloads are checked for structure and dropped, and the screen re-reads the REST endpoint it shows.
enum EventsFrame: Equatable, Sendable {
    case hello(available: Set<LiveChannel>)
    case subscribed(requestID: String, accepted: Set<LiveChannel>, rejected: Set<LiveChannel>)
    case snapshot(LiveChannel)
    case event(LiveChannel)
    case accessChanged
    case ignored
}

enum EventsProtocol {
    static let name = "silo.events.v2"

    /// A `subscribe` frame. On Silo it replaces the connection's whole set of channels and answers a fresh
    /// snapshot for each one it accepts; there is no `unsubscribe`.
    static func subscribe(requestID: String, channels: Set<LiveChannel>) -> String {
        let object: [String: Any] = [
            "type": "subscribe", "request_id": requestID, "channels": channels.map(\.rawValue).sorted(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ text: String) throws -> EventsFrame {
        do {
            guard let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw SessionTransportError(.protocolViolation)
            }
            switch try string(frame, "type") {
            case "hello":
                guard let schema = frame["schema_version"] as? NSNumber, !isBool(schema), schema.intValue == 1,
                      try string(frame, "required_action") == "subscribe" else {
                    throw SessionTransportError(.protocolViolation)
                }
                return .hello(available: Set(try strings(frame, "available_channels").compactMap(LiveChannel.init(rawValue:))))
            case "subscribed":
                let requestID = try string(frame, "request_id")
                var rejected = Set<LiveChannel>()
                for case let item as [String: Any] in (frame["rejected"] as? [Any]) ?? [] {
                    if let channel = (item["channel"] as? String).flatMap(LiveChannel.init(rawValue:)) { rejected.insert(channel) }
                }
                let accepted = Set(try strings(frame, "channels").compactMap(LiveChannel.init(rawValue:)))
                return .subscribed(requestID: requestID, accepted: accepted, rejected: rejected)
            case "snapshot":
                guard let channel = LiveChannel(rawValue: try string(frame, "channel")) else { return .ignored }
                try checkTimestamp(frame)
                guard frame["data"] != nil else { throw SessionTransportError(.protocolViolation) }
                return .snapshot(channel)
            case "event":
                guard let channel = LiveChannel(rawValue: try string(frame, "channel")) else { return .ignored }
                try checkTimestamp(frame)
                guard !(try string(frame, "event")).isEmpty, !(try string(frame, "event_id")).isEmpty else {
                    throw SessionTransportError(.protocolViolation)
                }
                return .event(channel)
            case "access_changed":
                return .accessChanged
            case "error":
                throw SessionTransportError(.protocolViolation)
            default:
                return .ignored
            }
        } catch let error as SessionTransportError {
            throw error
        } catch {
            // Parsing errors can embed raw payload values. Never retain them.
            throw SessionTransportError(.protocolViolation)
        }
    }

    private static func string(_ frame: [String: Any], _ key: String) throws -> String {
        guard let value = frame[key] as? String else { throw SessionTransportError(.protocolViolation) }
        return value
    }

    private static func strings(_ frame: [String: Any], _ key: String) throws -> [String] {
        guard let values = frame[key] as? [Any] else { throw SessionTransportError(.protocolViolation) }
        return try values.map {
            guard let value = $0 as? String else { throw SessionTransportError(.protocolViolation) }
            return value
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

    private static func checkTimestamp(_ frame: [String: Any]) throws {
        let text = try string(frame, "timestamp")
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard plain.date(from: text) != nil || fractional.date(from: text) != nil else {
            throw SessionTransportError(.protocolViolation)
        }
    }
}
