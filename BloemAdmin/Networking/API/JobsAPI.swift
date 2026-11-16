import Foundation

extension APIClient {
    /// `GET /api/v2/admin/jobs`: background jobs, newest first, one cursor page. `limit` is 1 to 200.
    func adminJobs(cursor: String? = nil, limit: Int = 20) async throws -> APICollection<AdminJob> {
        var query = ["limit": String(limit)]
        if let cursor { query["cursor"] = cursor }
        return try await getCollection("/api/v2/admin/jobs", query: query)
    }
}
