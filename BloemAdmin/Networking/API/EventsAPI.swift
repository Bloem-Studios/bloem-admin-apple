import Foundation

/// `POST /api/v2/events/ws-ticket`: a single-use credential for one realtime handshake (30 s to use,
/// the socket then lives at most `max_connection_seconds`).
struct EventsSocketTicket: Decodable, Sendable, Equatable {
    let ticket: String
    let expiresIn: Int
    let maxConnectionSeconds: Int
    let protocolName: String

    enum CodingKeys: String, CodingKey {
        case ticket
        case expiresIn = "expires_in"
        case maxConnectionSeconds = "max_connection_seconds"
        case protocolName = "protocol"
    }
}

extension APIClient {
    /// The events socket; the ticket rides in the subprotocol, never in the URL.
    private static let eventsSocketPath = "/api/v2/events/ws"

    func createEventsSocketTicket() async throws -> EventsSocketTicket {
        try await postForResult("/api/v2/events/ws-ticket")
    }

    /// `wss://<server><base path>/api/v2/events/ws`, or nil for a server address that is not HTTPS.
    nonisolated var eventsSocketURL: URL? {
        guard var components = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else { return nil }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.scheme = "wss"
        components.percentEncodedPath = basePath + Self.eventsSocketPath
        components.query = nil
        return components.url
    }
}
