import Foundation

/// Opens one socket attempt: `POST /api/v2/events/ws-ticket`, then `GET /api/v2/events/ws` with the ticket in
/// the subprotocol (`silo.events.v2, silo.ticket.<ticket>`). Every attempt mints a fresh single-use ticket.
/// The handshake frames (hello, subscribe) belong to `LiveConnection`.
enum LiveSocketConnector {
    /// Throws a `SessionTransportError`: `signInRequired` (with the 401 or 403) when the ticket request is
    /// refused for the login, `unsupported` when the server has no socket (404, 405, 501, or an address that
    /// is not HTTPS), `protocolViolation` for a ticket this client cannot use, `connection` otherwise.
    static func connect(client: APIClient, openSocket: EventsSocketOpener = URLSessionEventsSocket.open) async throws -> any EventsSocket {
        guard let url = client.eventsSocketURL else { throw SessionTransportError(.unsupported) }
        let ticket = try await mintTicket(client)
        try Task.checkCancellation()
        return openSocket(url, [EventsProtocol.name, "silo.ticket.\(ticket)"])
    }

    private static func mintTicket(_ client: APIClient) async throws -> String {
        do {
            let ticket = try await client.createEventsSocketTicket()
            guard ticket.protocolName == EventsProtocol.name, isTicket(ticket.ticket) else {
                throw SessionTransportError(.protocolViolation)
            }
            return ticket.ticket
        } catch let error as SessionTransportError {
            throw error
        } catch let error as APIError {
            switch error.statusCode {
            case 401, 403: throw SessionTransportError(.signInRequired, authError: error)
            case 404, 405, 501: throw SessionTransportError(.unsupported)
            default: throw SessionTransportError(.connection)
            }
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            throw SessionTransportError(.connection)
        }
    }

    /// A ticket is 43 URL-safe base64 characters.
    static func isTicket(_ text: String) -> Bool {
        text.utf8.count == 43 && text.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }
}
