import Foundation

/// The filters of the Audit page, sent to `GET /api/v2/admin/logs/audit`: the person who made the
/// request (picked by name, sent as their ID) and, for the session summary, one playback session.
struct AuditFilter: Equatable, Sendable {
    var userID: String
    var playbackSessionID: String

    init(userID: String = "", playbackSessionID: String = "") {
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.playbackSessionID = playbackSessionID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool { self == AuditFilter() }

    var query: [String: String] {
        var items: [String: String] = [:]
        if !userID.isEmpty { items["user_id"] = userID }
        if !playbackSessionID.isEmpty { items["playback_session_id"] = playbackSessionID }
        return items
    }
}
