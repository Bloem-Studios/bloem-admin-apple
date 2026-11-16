import Foundation

enum PlaybackCommand: String, Sendable {
    case pause, resume, stop
}

/// Body of pause, resume and stop. Optional `reason` and `deadline_ms` are not sent.
private struct PlaybackCommandBody: Encodable {
    let commandID: String
    let sequence: Int64

    private enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case sequence
    }
}

private struct SessionMessageBody: Encodable {
    let title: String?
    let message: String
    let commandID: String
    let sequence: Int64

    private enum CodingKeys: String, CodingKey {
        case title, message
        case commandID = "command_id"
        case sequence
    }
}

private struct TerminateBody: Encodable {
    let reason: String?
}

extension APIClient {
    /// Every page of `GET /api/v2/admin/sessions`. The route declares `limit`, `cursor` and
    /// `user_id`; only the first two are used.
    func listSessions() async throws -> [AdminSession] {
        try await readAllPages("/api/v2/admin/sessions")
    }

    /// What one account is playing right now: `GET /api/v2/admin/sessions?user_id=`. Rows of other accounts are
    /// dropped as well, so a server that ignores the filter cannot show the User page someone else's streams.
    func watchingNow(userID: String) async throws -> [AdminSession] {
        let rows: [AdminSession] = try await readAllPages("/api/v2/admin/sessions", query: ["user_id": userID])
        return rows.filter { $0.userID == userID }
    }

    /// `POST /api/v2/admin/sessions/{session_id}/{pause|resume|stop}`.
    func sendPlaybackCommand(
        sessionID: String,
        action: PlaybackCommand,
        identity: PlaybackCommandIdentity
    ) async throws {
        try await post(
            "/api/v2/admin/sessions/\(APIPath.segment(sessionID))/\(action.rawValue)",
            body: PlaybackCommandBody(commandID: identity.commandID, sequence: identity.sequence)
        )
    }

    /// `POST /api/v2/admin/sessions/{session_id}/message`.
    func sendSessionMessage(
        sessionID: String,
        title: String?,
        message: String,
        identity: PlaybackCommandIdentity
    ) async throws -> SessionCommandReceipt {
        try await post(
            "/api/v2/admin/sessions/\(APIPath.segment(sessionID))/message",
            body: SessionMessageBody(
                title: title, message: message, commandID: identity.commandID, sequence: identity.sequence
            )
        )
    }

    /// `POST /api/v2/admin/sessions/{session_id}/terminate`. The body is required; `{}` when no reason.
    func terminateSession(sessionID: String, reason: String? = nil) async throws {
        try await post(
            "/api/v2/admin/sessions/\(APIPath.segment(sessionID))/terminate",
            body: TerminateBody(reason: reason)
        )
    }
}
