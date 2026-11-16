import Foundation

/// The signed-in account (`GET /api/v2/account/me`); only who they are is used.
struct ViewerAccount: Decodable, Equatable, Sendable {
    let id: String
}

/// `GET /api/v2/admin/users/capabilities`. A missing member means the server does not state the
/// capability; `available` defaults to true so a server that omits it does not lock the page.
struct UserCapabilities: Decodable, Equatable, Sendable {
    let available: Bool
    let loginSessions: Bool
    let accountDevices: Bool
    let accountDownloads: Bool
    let watchSummary: Bool
    let passwordResetEmail: Bool
    let passwordResetLink: Bool
    /// Whether an account's profiles can be read and changed (add, rename, PIN, delete) and listed with
    /// `has_pin`, `is_primary` and `is_child`.
    let profileManagement: Bool

    enum CodingKeys: String, CodingKey {
        case available
        case loginSessions = "login_sessions"
        case accountDevices = "account_devices"
        case accountDownloads = "account_downloads"
        case watchSummary = "watch_summary"
        case passwordResetEmail = "password_reset_email"
        case passwordResetLink = "password_reset_link"
        case profileManagement = "profile_management"
    }

    init(
        available: Bool = true, loginSessions: Bool = false, accountDevices: Bool = false,
        accountDownloads: Bool = false, watchSummary: Bool = false,
        passwordResetEmail: Bool = false, passwordResetLink: Bool = false, profileManagement: Bool = false
    ) {
        self.available = available
        self.loginSessions = loginSessions
        self.accountDevices = accountDevices
        self.accountDownloads = accountDownloads
        self.watchSummary = watchSummary
        self.passwordResetEmail = passwordResetEmail
        self.passwordResetLink = passwordResetLink
        self.profileManagement = profileManagement
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        available = try container.decodeIfPresent(Bool.self, forKey: .available) ?? true
        loginSessions = try container.decodeIfPresent(Bool.self, forKey: .loginSessions) ?? false
        accountDevices = try container.decodeIfPresent(Bool.self, forKey: .accountDevices) ?? false
        accountDownloads = try container.decodeIfPresent(Bool.self, forKey: .accountDownloads) ?? false
        watchSummary = try container.decodeIfPresent(Bool.self, forKey: .watchSummary) ?? false
        passwordResetEmail = try container.decodeIfPresent(Bool.self, forKey: .passwordResetEmail) ?? false
        passwordResetLink = try container.decodeIfPresent(Bool.self, forKey: .passwordResetLink) ?? false
        profileManagement = try container.decodeIfPresent(Bool.self, forKey: .profileManagement) ?? false
    }
}

/// `AdminAccountProfile`. `has_pin`, `is_primary` and `is_child` are only sent where the server's
/// `profile_management` capability is on; without it they read as false.
struct UserProfile: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let lastSeenAt: Date?
    let hasPIN: Bool
    let isPrimary: Bool
    let isChild: Bool

    enum CodingKeys: String, CodingKey {
        case id, name
        case lastSeenAt = "last_seen_at"
        case hasPIN = "has_pin"
        case isPrimary = "is_primary"
        case isChild = "is_child"
    }

    init(id: String, name: String, lastSeenAt: Date? = nil, hasPIN: Bool = false, isPrimary: Bool = false, isChild: Bool = false) {
        self.id = id
        self.name = name
        self.lastSeenAt = lastSeenAt
        self.hasPIN = hasPIN
        self.isPrimary = isPrimary
        self.isChild = isChild
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        lastSeenAt = try container.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        hasPIN = try container.decodeIfPresent(Bool.self, forKey: .hasPIN) ?? false
        isPrimary = try container.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? false
        isChild = try container.decodeIfPresent(Bool.self, forKey: .isChild) ?? false
    }

    /// The main profile cannot be removed: the server refuses it, and the way to remove it is to delete the account.
    var canRemove: Bool { !isPrimary }
}

/// `AdminUserWatchSummary`.
struct WatchSummary: Decodable, Equatable, Sendable {
    let days: Int
    let plays: Int
    let completedPlays: Int
    let watchedSeconds: Double
    let lastPlayedAt: Date?

    enum CodingKeys: String, CodingKey {
        case days, plays
        case completedPlays = "completed_plays"
        case watchedSeconds = "watched_seconds"
        case lastPlayedAt = "last_played_at"
    }
}

/// `AdminUserIP`.
struct UserIP: Decodable, Identifiable, Equatable, Sendable {
    let clientIP: String
    let firstSeen: Date
    let lastSeen: Date
    let location: String
    let requestCount: Int

    var id: String { clientIP }

    enum CodingKeys: String, CodingKey {
        case clientIP = "client_ip"
        case firstSeen = "first_seen"
        case lastSeen = "last_seen"
        case location
        case requestCount = "request_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clientIP = try container.decode(String.self, forKey: .clientIP)
        firstSeen = try container.decode(Date.self, forKey: .firstSeen)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        location = try container.decodeIfPresent(String.self, forKey: .location) ?? ""
        requestCount = try container.decodeIfPresent(Int.self, forKey: .requestCount) ?? 0
    }
}

/// The fields the Downloads tab uses from `AdminUserDownload`.
struct UserDownload: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let mediaType: String
    let status: String
    let fileSize: Int64
    let quality: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title, status, quality
        case mediaType = "media_type"
        case fileSize = "file_size"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType) ?? ""
        status = try container.decode(String.self, forKey: .status)
        fileSize = try container.decodeIfPresent(Int64.self, forKey: .fileSize) ?? 0
        quality = try container.decodeIfPresent(String.self, forKey: .quality) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}

/// `AdminUserDownloadSummary`.
struct UserDownloadSummary: Decodable, Equatable, Sendable {
    let total: Int
    let completed: Int
    let inProgress: Int
    let failed: Int
    let revoked: Int
    let totalBytes: Int64
    let devices: Int

    enum CodingKeys: String, CodingKey {
        case total, completed, failed, revoked, devices
        case inProgress = "in_progress"
        case totalBytes = "total_bytes"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        total = try container.decode(Int.self, forKey: .total)
        completed = try container.decode(Int.self, forKey: .completed)
        inProgress = try container.decode(Int.self, forKey: .inProgress)
        failed = try container.decode(Int.self, forKey: .failed)
        revoked = try container.decodeIfPresent(Int.self, forKey: .revoked) ?? 0
        totalBytes = try container.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? 0
        devices = try container.decodeIfPresent(Int.self, forKey: .devices) ?? 0
    }
}

/// Body of `PATCH /api/v2/admin/users/{id}/profiles/{profile_id}` that removes the profile's PIN. The server needs an
/// explicit `"pin": null`; leaving the member out changes nothing.
struct ClearProfilePINRequest: Encodable, Sendable {
    private enum CodingKeys: String, CodingKey { case pin }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeNil(forKey: .pin)
    }
}

/// How the server delivers a reset: emailed to the account, or returned once for the admin to hand over.
enum ResetDelivery: String, Sendable {
    case email, link
}

/// `201` body of `POST /api/v2/admin/users/{id}/password-reset`. `reset_url` (only for `delivery: link`) is a
/// bearer credential for the account's password: it is decoded for the sheet to show once, and never printed,
/// logged or dumped.
struct PasswordResetReceipt: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let delivery: String
    let deliveryStatus: String
    let expiresAt: Date
    let resetURL: String?

    enum CodingKeys: String, CodingKey {
        case delivery
        case deliveryStatus = "delivery_status"
        case expiresAt = "expires_at"
        case resetURL = "reset_url"
    }

    var description: String {
        "PasswordResetReceipt(delivery: \(delivery), deliveryStatus: \(deliveryStatus), resetURL: \(resetURL == nil ? "none" : "<redacted>"))"
    }
    var debugDescription: String { description }
    var customMirror: Mirror {
        Mirror(self, children: ["delivery": delivery, "deliveryStatus": deliveryStatus, "expiresAt": expiresAt, "resetURL": resetURL == nil ? "none" : "<redacted>"], displayStyle: .struct)
    }
}

/// A reset link on its way to the admin's screen, to hand to the account's person. Held only while the sheet
/// shows it; `description` and the reflection never carry the link.
struct ResetLinkShown: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let url: String
    let expiresAt: Date

    var description: String { "ResetLinkShown(url: <redacted>)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["url": "<redacted>", "expiresAt": expiresAt], displayStyle: .struct) }
}

struct PasswordResetRequest: Encodable, Sendable {
    var delivery = "email"

    init(delivery: ResetDelivery = .email) {
        self.delivery = delivery.rawValue
    }
}

/// One stored setting of an account (`SettingValue`): `value` is the JSON the apps saved at that scope.
struct UserSettingEntry: Decodable, Identifiable, Equatable, Sendable {
    let key: String
    let scope: String
    let value: JSONValue
    let revision: Int64
    let profileID: String?
    let clientFamily: String?
    let deviceID: String?
    let libraryID: String?
    let seriesID: String?

    var identity: SettingIdentity {
        SettingIdentity(scope: scope, profileID: profileID, clientFamily: clientFamily, deviceID: deviceID, libraryID: libraryID, seriesID: seriesID)
    }

    var id: String { "\(key)|\(identity.query.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "&"))" }

    enum CodingKeys: String, CodingKey {
        case key, scope, value, revision
        case profileID = "profile_id"
        case clientFamily = "client_family"
        case deviceID = "device_id"
        case libraryID = "library_id"
        case seriesID = "series_id"
    }

    init(
        key: String, scope: String, value: JSONValue, revision: Int64 = 0, profileID: String? = nil,
        clientFamily: String? = nil, deviceID: String? = nil, libraryID: String? = nil, seriesID: String? = nil
    ) {
        self.key = key
        self.scope = scope
        self.value = value
        self.revision = revision
        self.profileID = profileID
        self.clientFamily = clientFamily
        self.deviceID = deviceID
        self.libraryID = libraryID
        self.seriesID = seriesID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        scope = try container.decode(String.self, forKey: .scope)
        value = try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        revision = try container.decodeIfPresent(Int64.self, forKey: .revision) ?? 0
        profileID = try container.decodeIfPresent(String.self, forKey: .profileID)
        clientFamily = try container.decodeIfPresent(String.self, forKey: .clientFamily)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        libraryID = try container.decodeIfPresent(String.self, forKey: .libraryID)
        seriesID = try container.decodeIfPresent(String.self, forKey: .seriesID)
    }
}

/// The storage identity of one setting row: the scope and the ids that scope names.
struct SettingIdentity: Equatable, Hashable, Sendable {
    let scope: String
    var profileID: String?
    var clientFamily: String?
    var deviceID: String?
    var libraryID: String?
    var seriesID: String?

    init(scope: String, profileID: String? = nil, clientFamily: String? = nil, deviceID: String? = nil, libraryID: String? = nil, seriesID: String? = nil) {
        self.scope = scope
        self.profileID = profileID
        self.clientFamily = clientFamily
        self.deviceID = deviceID
        self.libraryID = libraryID
        self.seriesID = seriesID
    }

    /// The query of a single-row read, write or delete. Absent ids are left out.
    var query: [String: String] {
        var result = ["scope": scope]
        if let profileID { result["profile_id"] = profileID }
        if let clientFamily { result["client_family"] = clientFamily }
        if let deviceID { result["device_id"] = deviceID }
        if let libraryID { result["library_id"] = libraryID }
        if let seriesID { result["series_id"] = seriesID }
        return result
    }
}

/// One allowed value of an enum setting.
struct SettingOptionDefinition: Decodable, Equatable, Sendable {
    let value: JSONValue
    let label: String?
    let deprecated: Bool

    enum CodingKeys: String, CodingKey { case value, label, deprecated }

    init(value: JSONValue, label: String? = nil, deprecated: Bool = false) {
        self.value = value
        self.label = label
        self.deprecated = deprecated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(JSONValue.self, forKey: .value)
        label = try container.decodeIfPresent(String.self, forKey: .label)
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated) ?? false
    }
}

/// The type of a setting's value, from the settings contract's `value_schema`.
struct SettingValueSchema: Decodable, Equatable, Sendable {
    let type: String
    let nullable: Bool
    let values: [SettingOptionDefinition]
    let minimum: Double?
    let maximum: Double?

    enum CodingKeys: String, CodingKey { case type, nullable, values, minimum, maximum }

    init(type: String = "", nullable: Bool = false, values: [SettingOptionDefinition] = [], minimum: Double? = nil, maximum: Double? = nil) {
        self.type = type
        self.nullable = nullable
        self.values = values
        self.minimum = minimum
        self.maximum = maximum
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        nullable = try container.decodeIfPresent(Bool.self, forKey: .nullable) ?? false
        values = try container.decodeIfPresent([SettingOptionDefinition].self, forKey: .values) ?? []
        minimum = try container.decodeIfPresent(Double.self, forKey: .minimum)
        maximum = try container.decodeIfPresent(Double.self, forKey: .maximum)
    }
}

/// One setting of the settings contract (`GET /api/v2/settings/contract`): its type, scopes,
/// default and wording.
struct SettingDefinition: Decodable, Equatable, Sendable {
    let key: String
    let persistence: String
    let allowedScopes: [String]
    let valueSchema: SettingValueSchema
    let defaultValue: JSONValue?
    let category: String
    let label: String
    let description: String
    let deprecated: Bool

    enum CodingKeys: String, CodingKey {
        case key, persistence, category, label, description, deprecated
        case allowedScopes = "allowed_scopes"
        case valueSchema = "value_schema"
        case defaultValue = "default_value"
    }

    init(
        key: String, persistence: String = "remote", allowedScopes: [String] = [],
        valueSchema: SettingValueSchema = SettingValueSchema(), defaultValue: JSONValue? = nil,
        category: String = "", label: String = "", description: String = "", deprecated: Bool = false
    ) {
        self.key = key
        self.persistence = persistence
        self.allowedScopes = allowedScopes
        self.valueSchema = valueSchema
        self.defaultValue = defaultValue
        self.category = category
        self.label = label
        self.description = description
        self.deprecated = deprecated
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        persistence = try container.decodeIfPresent(String.self, forKey: .persistence) ?? "remote"
        allowedScopes = try container.decodeIfPresent([String].self, forKey: .allowedScopes) ?? []
        valueSchema = try container.decodeIfPresent(SettingValueSchema.self, forKey: .valueSchema) ?? SettingValueSchema()
        defaultValue = try container.decodeIfPresent(JSONValue.self, forKey: .defaultValue)
        category = try container.decodeIfPresent(String.self, forKey: .category) ?? ""
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
        deprecated = try container.decodeIfPresent(Bool.self, forKey: .deprecated) ?? false
    }

    /// The label to show: the contract's wording, else the key.
    var displayLabel: String { label.isEmpty ? key : label }
}

struct SettingsContract: Decodable, Equatable, Sendable {
    let definitions: [SettingDefinition]

    enum CodingKeys: String, CodingKey { case definitions }

    init(definitions: [SettingDefinition]) { self.definitions = definitions }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        definitions = try container.decodeIfPresent([SettingDefinition].self, forKey: .definitions) ?? []
    }
}
