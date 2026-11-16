import Foundation

extension APIClient {
    /// One page of `GET /api/v2/admin/playback-history` (`limit` up to 200, `cursor`, and the filters
    /// `user_id`, `profile_id` and `completed`). Unset filters and a nil `cursor` are not sent.
    func playbackHistory(filter: HistoryFilter, cursor: String?) async throws -> APICollection<PlaybackHistoryEntry> {
        var query = filter.query
        query["limit"] = String(ActivityViewModel.pageSize)
        if let cursor { query["cursor"] = cursor }
        return try await getCollection("/api/v2/admin/playback-history", query: query)
    }
}
