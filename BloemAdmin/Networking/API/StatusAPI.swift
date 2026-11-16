import Foundation

/// Health-endpoint identity shape for `GET /api/v1/health`. Every field is
/// `omitempty` server-side, so all are optional here.
struct ServerHealth: Decodable, Sendable {
    let status: String?
    let serverName: String?
    let serverID: String?

    enum CodingKeys: String, CodingKey {
        case status
        case serverName = "server_name"
        case serverID = "server_id"
    }
}

extension APIClient {
    /// `GET /api/v1/health` (public; the one v1 route still used).
    func health() async throws -> ServerHealth {
        try await get("/api/v1/health")
    }

    /// `GET /api/v2/admin/server/status`; also the administrator-access probe.
    func serverStatus() async throws -> ServerStatus {
        try await get("/api/v2/admin/server/status")
    }

    /// `GET /api/v2/admin/stats`. `refresh=true` only when forced (pull to refresh), never on a poll.
    func adminStats(forceRefresh: Bool = false) async throws -> AdminStats {
        try await get("/api/v2/admin/stats", query: forceRefresh ? ["refresh": "true"] : [:])
    }

    /// `GET /api/v2/admin/system/resources`; declares no query parameters.
    func systemResources() async throws -> SystemResources {
        try await get("/api/v2/admin/system/resources")
    }

    /// `POST /api/v2/admin/server/restart`. The contract's body is required and may be empty, so
    /// `{}` is sent. The 202 answer says whether this request started the restart or one was already
    /// pending; the new process shows up through `serverStatus()`.
    func requestServerRestart() async throws -> RestartReceipt {
        try await post("/api/v2/admin/server/restart", body: EmptyBody())
    }
}
