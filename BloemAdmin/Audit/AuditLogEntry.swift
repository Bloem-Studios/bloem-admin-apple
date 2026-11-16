import Foundation

/// One item of `GET /api/v2/admin/logs/audit`. Required on the wire: id, timestamp, client_ip,
/// method, path, status_code and duration_ms; everything else is optional here. IDs are strings.
struct AuditLogEntry: Decodable, Identifiable, Sendable {
    let id: String
    let timestamp: Date
    let clientIP: String
    /// Absent for unauthenticated requests.
    let userID: String?
    /// Recorded attribution only: present when the request was made while another admin was
    /// impersonating. The app can no longer start impersonation, but old entries still show it.
    let impersonatorUserID: String?
    let sessionID: String?
    let playbackSessionID: String?
    let requestID: String?
    let nodeID: String?
    let method: String
    let path: String
    /// Absent for requests matching no known route (e.g. 404s).
    let pathPattern: String?
    let statusCode: Int
    let userAgent: String?
    let durationMs: Int
    let action: String?
    let targetType: String?
    let targetID: String?
    /// The fields this request changed, before and after; empty for a request that changed nothing
    /// the audit trail describes.
    let changes: [AuditChange]

    enum CodingKeys: String, CodingKey {
        case id, timestamp
        case clientIP = "client_ip"
        case userID = "user_id"
        case impersonatorUserID = "impersonator_user_id"
        case sessionID = "session_id"
        case playbackSessionID = "playback_session_id"
        case requestID = "request_id"
        case nodeID = "node_id"
        case method, path
        case pathPattern = "path_pattern"
        case statusCode = "status_code"
        case userAgent = "user_agent"
        case durationMs = "duration_ms"
        case action
        case targetType = "target_type"
        case targetID = "target_id"
        case changes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        clientIP = try c.decode(String.self, forKey: .clientIP)
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        impersonatorUserID = try c.decodeIfPresent(String.self, forKey: .impersonatorUserID)
        sessionID = try c.decodeIfPresent(String.self, forKey: .sessionID)
        playbackSessionID = try c.decodeIfPresent(String.self, forKey: .playbackSessionID)
        requestID = try c.decodeIfPresent(String.self, forKey: .requestID)
        nodeID = try c.decodeIfPresent(String.self, forKey: .nodeID)
        method = try c.decode(String.self, forKey: .method)
        path = try c.decode(String.self, forKey: .path)
        pathPattern = try c.decodeIfPresent(String.self, forKey: .pathPattern)
        statusCode = try c.decode(Int.self, forKey: .statusCode)
        userAgent = try c.decodeIfPresent(String.self, forKey: .userAgent)
        durationMs = try c.decode(Int.self, forKey: .durationMs)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        targetType = try c.decodeIfPresent(String.self, forKey: .targetType)
        targetID = try c.decodeIfPresent(String.self, forKey: .targetID)
        changes = try c.decodeIfPresent([AuditChange].self, forKey: .changes) ?? []
    }
}

/// One field a request changed (`AdminAuditChange`). `before` and `after` are JSON-encoded values;
/// a side that is nil was not recorded (a field that was added or whose value is not kept).
struct AuditChange: Decodable, Equatable, Sendable {
    let field: String
    let before: String?
    let after: String?
}
