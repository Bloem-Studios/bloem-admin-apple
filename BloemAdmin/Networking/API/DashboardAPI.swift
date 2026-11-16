import Foundation

// The reads behind the web dashboard's widgets. The insight routes take `refresh=true` only when
// the person forced a refresh; automatic polling uses the server's cache.

private func refreshQuery(_ refresh: Bool) -> [String: String] {
    refresh ? ["refresh": "true"] : [:]
}

extension APIClient {
    /// `GET /api/v2/admin/server/status` as the dashboard reads it: uptime, restart flag and the
    /// health summary. `serverStatus()` keeps the Server tab's view of the same route.
    func dashboardStatus() async throws -> DashboardServerStatus {
        try await get("/api/v2/admin/server/status")
    }

    /// `GET /api/v2/admin/system/build`. Fixed for the life of the process.
    func buildInfo() async throws -> BuildInfo {
        try await get("/api/v2/admin/system/build")
    }

    /// Every page of `GET /api/v2/admin/nodes`.
    func listNodes() async throws -> [DashboardNode] {
        try await readAllPages("/api/v2/admin/nodes")
    }

    /// `GET /api/v2/admin/stats/playback-activity`: starts by method, reliability and active
    /// profiles over the last `hours` (1 to 744).
    func playbackActivity(hours: Int, refresh: Bool = false) async throws -> PlaybackActivity {
        try await get(
            "/api/v2/admin/stats/playback-activity",
            query: ["hours": String(min(max(hours, 1), 744))].merging(refreshQuery(refresh)) { $1 }
        )
    }

    /// `GET /api/v2/admin/stats/timeseries`: sampled concurrent streams and egress over the last
    /// `hours` (1 to 744).
    func timeseries(hours: Int, refresh: Bool = false) async throws -> Timeseries {
        try await get(
            "/api/v2/admin/stats/timeseries",
            query: ["hours": String(min(max(hours, 1), 744))].merging(refreshQuery(refresh)) { $1 }
        )
    }

    /// `GET /api/v2/admin/stats/top-activity`: most-played titles and most-active profiles over
    /// the last `days` (1 to 30), at most `limit` of each (1 to 25).
    func topActivity(days: Int, limit: Int, refresh: Bool = false) async throws -> TopActivity {
        try await get(
            "/api/v2/admin/stats/top-activity",
            query: ["days": String(min(max(days, 1), 30)), "limit": String(min(max(limit, 1), 25))]
                .merging(refreshQuery(refresh)) { $1 }
        )
    }

    /// `GET /api/v2/libraries`; this list is not paginated.
    func listLibraries() async throws -> [DashboardLibrary] {
        let collection: APICollection<DashboardLibrary> = try await getCollection("/api/v2/libraries")
        return collection.items
    }

    /// The first page of `GET /api/v2/admin/users` (up to 200). The dashboard sorts them by last
    /// activity and shows the newest few.
    func usersForDashboard() async throws -> [DashboardUser] {
        let collection: APICollection<DashboardUser> = try await getCollection(
            "/api/v2/admin/users",
            query: ["limit": "200"]
        )
        return collection.items
    }

    /// The newest `limit` rows of `GET /api/v2/admin/playback-history` (1 to 200).
    func recentPlayback(limit: Int) async throws -> [RecentPlayback] {
        let collection: APICollection<RecentPlayback> = try await getCollection(
            "/api/v2/admin/playback-history",
            query: ["limit": String(min(max(limit, 1), 200))]
        )
        return collection.items
    }
}
