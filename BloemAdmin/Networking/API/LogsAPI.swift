import Foundation

extension APIClient {
    /// One page of `GET /api/v2/admin/logs/audit`. The route declares many filters; this app uses
    /// `user_id`, `playback_session_id`, `limit` and `cursor`. Unset filters are not sent.
    func auditLogs(filter: AuditFilter, cursor: String?, limit: Int) async throws -> APICollection<AuditLogEntry> {
        var query = filter.query
        query["limit"] = String(limit)
        if let cursor { query["cursor"] = cursor }
        return try await getCollection("/api/v2/admin/logs/audit", query: query)
    }

    /// One page of `GET /api/v2/admin/logs/app`, using `level`, `q`, `component`, `request_id`,
    /// `playback_session_id`, `limit` and `cursor`. Unset filters are not sent.
    func operationalLogs(filter: LogFilter, cursor: String?, limit: Int) async throws -> APICollection<OperationalLogEntry> {
        var query = filter.query
        query["limit"] = String(limit)
        if let cursor { query["cursor"] = cursor }
        return try await getCollection("/api/v2/admin/logs/app", query: query)
    }
}
