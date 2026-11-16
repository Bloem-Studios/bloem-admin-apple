import Foundation

/// `GET/PUT /api/v2/admin/request-settings` (server:internal/apiv2/admin_requests.go): the server-wide
/// defaults for media requests.
struct RequestSettings: Codable, Equatable, Sendable {
    var requestsEnabled: Bool
    /// How many titles one account may request in the window; 0 means only accounts with a limit of their own.
    var globalMaxRequests: Int
    var globalWindowDays: Int
    /// Requests approve themselves; off, an admin approves each.
    var globalAutoApprovalEnabled: Bool
    /// Every request also asks for a 4K version.
    var forceDualQuality: Bool
    /// Adding a title the library lacks to a watchlist also requests it. Absent on an older server.
    var watchlistRequests: Bool?

    enum CodingKeys: String, CodingKey {
        case requestsEnabled = "requests_enabled"
        case globalMaxRequests = "global_max_requests"
        case globalWindowDays = "global_window_days"
        case globalAutoApprovalEnabled = "global_auto_approval_enabled"
        case forceDualQuality = "force_dual_quality"
        case watchlistRequests = "watchlist_requests"
    }
}

extension APIClient {
    /// `GET /api/v2/admin/request-settings` with the `ETag` that guards the write.
    func requestSettings() async throws -> (settings: RequestSettings, validator: String?) {
        let (settings, validator): (RequestSettings, String?) = try await getWithValidator("/api/v2/admin/request-settings")
        return (settings, validator)
    }

    /// `PUT /api/v2/admin/request-settings` with `If-Match`; never replayed. A 412 means the settings
    /// changed since `validator` was read. Answers the saved settings and their new `ETag`.
    func updateRequestSettings(_ settings: RequestSettings, validator: String) async throws -> (settings: RequestSettings, validator: String?) {
        let (saved, tag): (RequestSettings, String?) = try await putConditionalDecodingWithValidator(
            "/api/v2/admin/request-settings", body: settings, validator: validator
        )
        return (saved, tag)
    }
}
