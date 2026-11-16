import Foundation

/// One item of `GET /api/v2/admin/logs/app`, the operational log (a different route from the
/// audit trail). Required on the wire: id, timestamp, level, component and message. IDs are
/// strings. `attrs` is free-form JSON; the server keeps request facts there (method, status,
/// duration_ms, path).
struct OperationalLogEntry: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let level: String
    let component: String
    let message: String
    let requestID: String?
    let userID: String?
    let sessionID: String?
    let playbackSessionID: String?
    let clientIP: String?
    let nodeID: String?
    let attrs: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, level, component, message, attrs
        case requestID = "request_id"
        case userID = "user_id"
        case sessionID = "session_id"
        case playbackSessionID = "playback_session_id"
        case clientIP = "client_ip"
        case nodeID = "node_id"
    }
}
