import Foundation

/// One login session from `GET /api/v2/admin/users/{user_id}/login-sessions`. The server always
/// sends `id`, `device_name` (empty when unknown), `ip_address` (empty when unknown), the three
/// dates (`last_seen_at` may be null) and `current`; `device_id` and `device_platform` are
/// absent when the client sent none.
struct AuthSession: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let deviceName: String
    let deviceId: String?
    let devicePlatform: String?
    let ipAddress: String
    let createdAt: Date
    let expiresAt: Date
    let lastSeenAt: Date?
    /// True for the login session that made the request listing it.
    let current: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case deviceName = "device_name"
        case deviceId = "device_id"
        case devicePlatform = "device_platform"
        case ipAddress = "ip_address"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case lastSeenAt = "last_seen_at"
        case current
    }
}

/// One device from `GET /api/v2/admin/users/{id}/devices`. Devices are listed only; the API has
/// no way to revoke one.
struct UserDevice: Decodable, Identifiable, Equatable, Sendable {
    let deviceId: String
    let deviceName: String
    let devicePlatform: String
    let lastSeenAt: Date?
    let lastUpdated: Date?
    let overrideCount: Int
    let profiles: [UserDeviceProfile]

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case devicePlatform = "device_platform"
        case lastSeenAt = "last_seen_at"
        case lastUpdated = "last_updated"
        case overrideCount = "override_count"
        case profiles
    }
}

/// A profile that has used a device.
struct UserDeviceProfile: Decodable, Equatable, Sendable {
    let profileId: String
    let profileName: String
    let overrideCount: Int
    let lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case profileId = "profile_id"
        case profileName = "profile_name"
        case overrideCount = "override_count"
        case lastSeenAt = "last_seen_at"
    }
}
