import Foundation

extension APIClient {
    /// The list route allows at most 50 per page.
    static let apiKeyPageLimit = 50

    /// One page of the server's API keys, newest first (`GET /api/v2/admin/api-keys`). `cursor` is the previous
    /// page's `next_cursor`; nil asks for the first. The rows carry no secret, only a short prefix.
    func apiKeysPage(cursor: String?) async throws -> APICollection<AdminAPIKey> {
        var query = ["limit": String(Self.apiKeyPageLimit)]
        if let cursor { query["cursor"] = cursor }
        return try await getCollection("/api/v2/admin/api-keys", query: query)
    }

    /// A key's current version, the `ETag` of `GET /api/v2/admin/api-keys/{id}`. The list carries none, and a
    /// revoke must name the version it means to delete.
    func apiKeyVersion(id: String) async throws -> String? {
        let (_, validator): (EmptyResponse, String?) = try await getWithValidator("/api/v2/admin/api-keys/\(APIPath.segment(id))")
        return validator
    }

    /// Revokes a key at once, for good (`DELETE /api/v2/admin/api-keys/{id}` with `If-Match`). A key that changed
    /// since `validator` was read is refused with 412.
    func deleteAPIKey(id: String, validator: String) async throws {
        try await deleteConditional("/api/v2/admin/api-keys/\(APIPath.segment(id))", validator: validator)
    }
}
