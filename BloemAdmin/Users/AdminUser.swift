import Foundation

/// One account from `/api/v2/admin/users`. `id` is an opaque string; the server sends no
/// `playback_allowed`, so this model has none.
struct AdminUser: Decodable, Identifiable, Sendable {
    let id: String
    let username: String
    let email: String
    let role: String
    let enabled: Bool
    let maxStreams: Int?
    let maxTranscodes: Int?
    /// Quota/permission fields also returned by `GET /admin/users`, added
    /// for the "edit an existing user" form. All optional —
    /// decoding tolerates a server response that omits them, and every
    /// caller that constructs an `AdminUser` in tests/previews without these
    /// (there are several) still compiles via the default-`nil` memberwise
    /// init below.
    let downloadAllowed: Bool?
    let requestsAllowed: Bool?
    let transcodeAllowed: Bool?
    let audioTranscodeAllowed: Bool?
    let maxProfiles: Int?
    let effectivePolicy: EffectivePolicy?
    /// False for an account a sign-in provider manages; it then has no password to reset.
    let passwordLogin: Bool
    /// True while the password is a temporary one the person must replace at the next sign-in.
    let passwordChangeRequired: Bool
    /// The server owner is the platform admin; nobody else may change or delete the account.
    let isOwner: Bool
    let accessGroupID: String?
    /// The account's own library allowlist: nil inherits the group's (or the server's), empty means none.
    let libraryIDs: [String]?
    /// Permissions assigned to the account itself; the access group can still block them.
    let permissions: [String]
    let createdAt: Date?
    /// Nil until the account has been active.
    let lastActiveAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, username, email, role, enabled, permissions
        case maxStreams = "max_streams"
        case maxTranscodes = "max_transcodes"
        case downloadAllowed = "download_allowed"
        case requestsAllowed = "requests_allowed"
        case transcodeAllowed = "transcode_allowed"
        case audioTranscodeAllowed = "audio_transcode_allowed"
        case maxProfiles = "max_profiles"
        case effectivePolicy = "effective_policy"
        case passwordLogin = "password_login"
        case passwordChangeRequired = "password_change_required"
        case isOwner = "is_owner"
        case accessGroupID = "access_group_id"
        case libraryIDs = "library_ids"
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
    }

    init(
        id: String, username: String, email: String, role: String, enabled: Bool,
        maxStreams: Int?, maxTranscodes: Int?,
        downloadAllowed: Bool? = nil, requestsAllowed: Bool? = nil,
        transcodeAllowed: Bool? = nil, audioTranscodeAllowed: Bool? = nil,
        maxProfiles: Int? = nil,
        effectivePolicy: EffectivePolicy? = nil,
        passwordLogin: Bool = true, passwordChangeRequired: Bool = false, isOwner: Bool = false,
        accessGroupID: String? = nil, libraryIDs: [String]? = nil, permissions: [String] = [],
        createdAt: Date? = nil, lastActiveAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.email = email
        self.role = role
        self.enabled = enabled
        self.maxStreams = maxStreams
        self.maxTranscodes = maxTranscodes
        self.downloadAllowed = downloadAllowed
        self.requestsAllowed = requestsAllowed
        self.transcodeAllowed = transcodeAllowed
        self.audioTranscodeAllowed = audioTranscodeAllowed
        self.maxProfiles = maxProfiles
        self.effectivePolicy = effectivePolicy
        self.passwordLogin = passwordLogin
        self.passwordChangeRequired = passwordChangeRequired
        self.isOwner = isOwner
        self.accessGroupID = accessGroupID
        self.libraryIDs = libraryIDs
        self.permissions = permissions
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        email = try container.decode(String.self, forKey: .email)
        role = try container.decode(String.self, forKey: .role)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        maxStreams = try container.decodeIfPresent(Int.self, forKey: .maxStreams)
        maxTranscodes = try container.decodeIfPresent(Int.self, forKey: .maxTranscodes)
        downloadAllowed = try container.decodeIfPresent(Bool.self, forKey: .downloadAllowed)
        requestsAllowed = try container.decodeIfPresent(Bool.self, forKey: .requestsAllowed)
        transcodeAllowed = try container.decodeIfPresent(Bool.self, forKey: .transcodeAllowed)
        audioTranscodeAllowed = try container.decodeIfPresent(Bool.self, forKey: .audioTranscodeAllowed)
        maxProfiles = try container.decodeIfPresent(Int.self, forKey: .maxProfiles)
        effectivePolicy = try container.decodeIfPresent(EffectivePolicy.self, forKey: .effectivePolicy)
        passwordLogin = try container.decodeIfPresent(Bool.self, forKey: .passwordLogin) ?? true
        passwordChangeRequired = try container.decodeIfPresent(Bool.self, forKey: .passwordChangeRequired) ?? false
        isOwner = try container.decodeIfPresent(Bool.self, forKey: .isOwner) ?? false
        accessGroupID = try container.decodeIfPresent(String.self, forKey: .accessGroupID)
        libraryIDs = try container.decodeIfPresent([String].self, forKey: .libraryIDs)
        permissions = try container.decodeIfPresent([String].self, forKey: .permissions) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt)
        lastActiveAt = try container.decodeIfPresent(Date.self, forKey: .lastActiveAt)
    }

    /// The role as shown: the owner is labelled "owner" rather than "admin".
    var roleLabel: String { isOwner ? "owner" : role }
}

struct EffectivePolicy: Decodable, Equatable, Sendable {
    let libraryIDs: [String]?
    let maxPlaybackQuality: String
    let maxStreams: Int
    let maxProfiles: Int
    let maxTranscodes: Int
    let transcodeAllowed: Bool
    let audioTranscodeAllowed: Bool
    let downloadAllowed: Bool
    let downloadTranscodeAllowed: Bool
    let requestsAllowed: Bool
    /// Nil when the server states none.
    let permissions: [String]?

    enum CodingKeys: String, CodingKey {
        case libraryIDs = "library_ids"
        case maxPlaybackQuality = "max_playback_quality"
        case maxStreams = "max_streams"
        case maxProfiles = "max_profiles"
        case maxTranscodes = "max_transcodes"
        case transcodeAllowed = "transcode_allowed"
        case audioTranscodeAllowed = "audio_transcode_allowed"
        case downloadAllowed = "download_allowed"
        case downloadTranscodeAllowed = "download_transcode_allowed"
        case requestsAllowed = "requests_allowed"
        case permissions
    }
}

/// Body of `PUT /api/v2/admin/users/{id}` that only flips `enabled`.
struct UpdateUserRequest: Encodable {
    let enabled: Bool?
}

/// Partial-update body for `PUT /api/v2/admin/users/{id}` (Feature 3). Every
/// field is optional/tri-state, matching the real handler's
/// `optionalField[T]` design: a field is only applied server-side when its
/// JSON key is actually present in the body. Swift's synthesized
/// `Encodable` conformance for `Optional` properties already omits the key
/// entirely (via `encodeIfPresent`) rather than encoding `null` when the
/// value is `nil`, so a caller only needs to fill in the fields the admin
/// actually changed and leave the rest `nil` — no custom `encode(to:)`
/// needed.
/// What one field of a partial update does: leave it out, clear the override (JSON null so the
/// field inherits again), or store a value.
enum PolicyChange<Value: Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case clear
    case set(Value)
}

struct UpdateUserQuotasRequest: Encodable, Sendable {
    var maxStreams: Int?
    var maxTranscodes: Int?
    var downloadAllowed: Bool?
    var requestsAllowed: Bool?
    var transcodeAllowed: Bool?
    var audioTranscodeAllowed: Bool?
    var maxProfiles: Int?
    /// `.clear` means no group. Never sent for an admin: the server keeps admins out of groups.
    var accessGroupID: PolicyChange<String> = .unchanged
    /// `.clear` inherits the group's libraries; `.set` stores an explicit list, possibly empty.
    var libraryIDs: PolicyChange<[String]> = .unchanged
    /// The whole assigned set; the server replaces it, so it is only ever `.set`.
    var permissions: PolicyChange<[String]> = .unchanged
    private var inheritedOverrides: Set<CodingKeys> = []

    private enum CodingKeys: String, CodingKey, Hashable {
        case maxStreams = "max_streams"
        case maxTranscodes = "max_transcodes"
        case downloadAllowed = "download_allowed"
        case requestsAllowed = "requests_allowed"
        case transcodeAllowed = "transcode_allowed"
        case audioTranscodeAllowed = "audio_transcode_allowed"
        case maxProfiles = "max_profiles"
        case accessGroupID = "access_group_id"
        case libraryIDs = "library_ids"
        case permissions
    }

    var isEmpty: Bool {
        maxStreams == nil && maxTranscodes == nil && downloadAllowed == nil
            && requestsAllowed == nil && transcodeAllowed == nil
            && audioTranscodeAllowed == nil && maxProfiles == nil
            && accessGroupID == .unchanged && libraryIDs == .unchanged && permissions == .unchanged
            && inheritedOverrides.isEmpty
    }

    mutating func inheritMaxStreams() { inheritedOverrides.insert(.maxStreams) }
    mutating func inheritMaxTranscodes() { inheritedOverrides.insert(.maxTranscodes) }
    mutating func inheritDownloadAllowed() { inheritedOverrides.insert(.downloadAllowed) }
    mutating func inheritRequestsAllowed() { inheritedOverrides.insert(.requestsAllowed) }
    mutating func inheritTranscodeAllowed() { inheritedOverrides.insert(.transcodeAllowed) }
    mutating func inheritAudioTranscodeAllowed() { inheritedOverrides.insert(.audioTranscodeAllowed) }
    mutating func inheritMaxProfiles() { inheritedOverrides.insert(.maxProfiles) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encode(maxStreams, key: .maxStreams, into: &container)
        try encode(maxTranscodes, key: .maxTranscodes, into: &container)
        try encode(downloadAllowed, key: .downloadAllowed, into: &container)
        try encode(requestsAllowed, key: .requestsAllowed, into: &container)
        try encode(transcodeAllowed, key: .transcodeAllowed, into: &container)
        try encode(audioTranscodeAllowed, key: .audioTranscodeAllowed, into: &container)
        try encode(maxProfiles, key: .maxProfiles, into: &container)
        try encode(accessGroupID, key: .accessGroupID, into: &container)
        try encode(libraryIDs, key: .libraryIDs, into: &container)
        try encode(permissions, key: .permissions, into: &container)
    }

    private func encode<T: Encodable>(
        _ change: PolicyChange<T>,
        key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch change {
        case .unchanged: break
        case .clear: try container.encodeNil(forKey: key)
        case .set(let value): try container.encode(value, forKey: key)
        }
    }

    private func encode<T: Encodable>(
        _ value: T?,
        key: CodingKeys,
        into container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        if inheritedOverrides.contains(key) {
            try container.encodeNil(forKey: key)
        } else {
            try container.encodeIfPresent(value, forKey: key)
        }
    }
}

/// Tri-state UI representation of a nullable server-side permission
/// (`AdminUser.downloadAllowed` etc). A raw `Bool?` defaulting to `false`
/// when unset would make an inherited policy look identical to an explicit
/// denial. This type keeps inheritance a visible third state instead of
/// silently collapsing it into "off."
enum PermissionState: Hashable {
    case inherit
    case off
    case on

    init(_ value: Bool?) {
        switch value {
        case .none: self = .inherit
        case .some(false): self = .off
        case .some(true): self = .on
        }
    }

    var boolValue: Bool? {
        switch self {
        case .inherit: return nil
        case .off: return false
        case .on: return true
        }
    }

    func displayLabel(effectiveValue: Bool?) -> String {
        switch self {
        case .inherit:
            guard let effectiveValue else { return "Inherit" }
            return effectiveValue ? "Inherit (On)" : "Inherit (Off)"
        case .off: return "Off"
        case .on: return "On"
        }
    }
}

/// Pure snapshot of `EditUserQuotasView`'s editable form fields, with no
/// SwiftUI dependency — exists specifically so the "what counts as
/// changed" diffing logic (`UpdateUserQuotasRequest.diff`) is testable
/// without driving the view (review finding I4).
struct EditedUserQuotas: Equatable {
    var maxStreamsText: String
    var maxStreamsInherited: Bool
    var maxTranscodesText: String
    var maxTranscodesInherited: Bool
    var maxProfilesText: String
    var maxProfilesInherited: Bool = false
    var downloadAllowed: PermissionState
    var requestsAllowed: PermissionState
    var transcodeAllowed: PermissionState
    var audioTranscodeAllowed: PermissionState

    /// The form's starting state when opened against `user` — diffing this
    /// unmodified snapshot against `user` in `UpdateUserQuotasRequest.diff`
    /// must always produce an empty (no-op) request.
    static func initial(from user: AdminUser) -> EditedUserQuotas {
        EditedUserQuotas(
            maxStreamsText: (user.maxStreams ?? user.effectivePolicy?.maxStreams).map(String.init) ?? "",
            maxStreamsInherited: user.maxStreams == nil,
            maxTranscodesText: (user.maxTranscodes ?? user.effectivePolicy?.maxTranscodes).map(String.init) ?? "",
            maxTranscodesInherited: user.maxTranscodes == nil,
            maxProfilesText: (user.maxProfiles ?? user.effectivePolicy?.maxProfiles).map(String.init) ?? "",
            maxProfilesInherited: user.maxProfiles == nil,
            downloadAllowed: PermissionState(user.downloadAllowed),
            requestsAllowed: PermissionState(user.requestsAllowed),
            transcodeAllowed: PermissionState(user.transcodeAllowed),
            audioTranscodeAllowed: PermissionState(user.audioTranscodeAllowed)
        )
    }
}

extension UpdateUserQuotasRequest {
    /// Diffs `edited` against `original` and returns a request containing
    /// ONLY the fields that actually changed — this is a partial-update
    /// endpoint (see the type's doc comment above), so an untouched field
    /// must stay `nil`/omitted, never re-sent as a no-op confirmation of
    /// its current value.
    ///
    /// Numeric fields: an empty text field means "leave unchanged." Text
    /// that fails to parse as an `Int` (e.g. stray non-numeric input) is
    /// also treated as "leave unchanged" rather than crashing or sending
    /// garbage — this app doesn't surface inline validation for that case
    /// (deliberately out of scope, see FEATURE_BATCH_A_REPORT.md), but it
    /// must never misbehave.
    ///
    /// Permission fields: explicit values encode booleans, switching an
    /// existing override to `.inherit` encodes JSON null, and unchanged
    /// inherited fields remain omitted.
    static func diff(from original: AdminUser, to edited: EditedUserQuotas) -> UpdateUserQuotasRequest {
        var request = UpdateUserQuotasRequest()

        if edited.maxStreamsInherited {
            if original.maxStreams != nil { request.inheritMaxStreams() }
        } else if let newMaxStreams = Int(edited.maxStreamsText), newMaxStreams != original.maxStreams {
            request.maxStreams = newMaxStreams
        }
        if edited.maxTranscodesInherited {
            if original.maxTranscodes != nil { request.inheritMaxTranscodes() }
        } else if let newMaxTranscodes = Int(edited.maxTranscodesText), newMaxTranscodes != original.maxTranscodes {
            request.maxTranscodes = newMaxTranscodes
        }
        if edited.maxProfilesInherited {
            if original.maxProfiles != nil { request.inheritMaxProfiles() }
        } else if let newMaxProfiles = Int(edited.maxProfilesText), newMaxProfiles != original.maxProfiles {
            request.maxProfiles = newMaxProfiles
        }

        if edited.downloadAllowed == .inherit, original.downloadAllowed != nil {
            request.inheritDownloadAllowed()
        } else if let newValue = edited.downloadAllowed.boolValue, newValue != original.downloadAllowed {
            request.downloadAllowed = newValue
        }
        if edited.requestsAllowed == .inherit, original.requestsAllowed != nil {
            request.inheritRequestsAllowed()
        } else if let newValue = edited.requestsAllowed.boolValue, newValue != original.requestsAllowed {
            request.requestsAllowed = newValue
        }
        if edited.transcodeAllowed == .inherit, original.transcodeAllowed != nil {
            request.inheritTranscodeAllowed()
        } else if let newValue = edited.transcodeAllowed.boolValue, newValue != original.transcodeAllowed {
            request.transcodeAllowed = newValue
        }
        if edited.audioTranscodeAllowed == .inherit, original.audioTranscodeAllowed != nil {
            request.inheritAudioTranscodeAllowed()
        } else if let newValue = edited.audioTranscodeAllowed.boolValue, newValue != original.audioTranscodeAllowed {
            request.audioTranscodeAllowed = newValue
        }

        return request
    }
}

/// Minimal create-user request body. Deliberately omits the many optional
/// fields the real handler also accepts (permissions, library_ids, quota
/// fields, access_group_id, etc.) — the server defaults those. The contract
/// requires `create_default_profile`; a new account gets its default profile.
struct CreateUserRequest: Encodable {
    let username: String
    let email: String
    let password: String
    let role: String
    var createDefaultProfile = true

    enum CodingKeys: String, CodingKey {
        case username, email, password, role
        case createDefaultProfile = "create_default_profile"
    }
}
