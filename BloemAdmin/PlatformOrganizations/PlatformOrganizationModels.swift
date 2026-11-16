import Foundation

// What the platform's organization routes answer (see the Bloem server's
// OpenAPI document). An organization itself decodes as `OrganizationSummary`, the type the organization
// Overview already uses: the platform list, the detail and the Overview all send the same fields.

struct PlatformOrganizationEnvelope: Decodable, Sendable {
    let organization: OrganizationSummary
}

/// One member of an organization as the platform lists them: the membership, and who the account is.
struct PlatformMembership: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let accountID: Int64
    /// `invited`, `active` or `suspended`.
    let status: String
    /// `admin` or `user`.
    let legacyRole: String
    let securityRevision: Int64
    let email: String
    let username: String

    var isAdministrator: Bool { legacyRole == "admin" }

    /// What a row calls the member: the username, else the email. An account number is never a name.
    var label: String {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? String(localized: "Unnamed account") : address
    }

    enum CodingKeys: String, CodingKey {
        case id, status, email, username
        case accountID = "account_id"
        case legacyRole = "legacy_role"
        case securityRevision = "security_revision"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        accountID = try c.decode(Int64.self, forKey: .accountID)
        status = try c.value(.status, "")
        legacyRole = try c.value(.legacyRole, "user")
        securityRevision = try c.value(.securityRevision, 0)
        email = try c.value(.email, "")
        username = try c.value(.username, "")
    }

    init(id: String, accountID: Int64, status: String, legacyRole: String = "user", securityRevision: Int64 = 0, email: String = "", username: String = "") {
        self.id = id
        self.accountID = accountID
        self.status = status
        self.legacyRole = legacyRole
        self.securityRevision = securityRevision
        self.email = email
        self.username = username
    }
}

struct PlatformMembershipsPage: Decodable, Sendable {
    let memberships: [PlatformMembership]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case memberships
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        memberships = try c.value(.memberships, [PlatformMembership]())
        let cursor = try c.value(.nextCursor, nil as String?)
        nextCursor = (cursor?.isEmpty ?? true) ? nil : cursor
    }
}

// MARK: - Plan

/// What a plan (an entitlement template) lets an account do. `libraryIDs` is nil for every library.
struct EntitlementPolicy: Decodable, Equatable, Sendable {
    let libraryIDs: [Int]?
    let playbackAllowed: Bool
    let maxStreams: Int
    let maxProfiles: Int
    let transcodeAllowed: Bool
    let maxTranscodes: Int
    let downloadAllowed: Bool
    let downloadTranscodeAllowed: Bool
    /// Empty for any quality.
    let maxPlaybackQuality: String
    /// Nil for every permission.
    let allowedPermissions: [String]?
    let requestsAllowed: Bool

    enum CodingKeys: String, CodingKey {
        case libraryIDs = "library_ids"
        case allLibraries = "all_libraries"
        case playbackAllowed = "playback_allowed"
        case maxStreams = "max_streams"
        case maxProfiles = "max_profiles"
        case transcodeAllowed = "transcode_allowed"
        case maxTranscodes = "max_transcodes"
        case downloadAllowed = "download_allowed"
        case downloadTranscodeAllowed = "download_transcode_allowed"
        case maxPlaybackQuality = "max_playback_quality"
        case allowedPermissions = "allowed_permissions"
        case requestsAllowed = "requests_allowed"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let all = try c.value(.allLibraries, false)
        let listed = try c.value(.libraryIDs, nil as [Int]?)
        libraryIDs = all ? nil : listed
        playbackAllowed = try c.value(.playbackAllowed, true)
        maxStreams = try c.value(.maxStreams, 0)
        maxProfiles = try c.value(.maxProfiles, 0)
        transcodeAllowed = try c.value(.transcodeAllowed, true)
        maxTranscodes = try c.value(.maxTranscodes, 0)
        downloadAllowed = try c.value(.downloadAllowed, false)
        downloadTranscodeAllowed = try c.value(.downloadTranscodeAllowed, false)
        maxPlaybackQuality = try c.value(.maxPlaybackQuality, "")
        allowedPermissions = try c.value(.allowedPermissions, nil as [String]?)
        requestsAllowed = try c.value(.requestsAllowed, true)
    }

    init(
        libraryIDs: [Int]? = nil, playbackAllowed: Bool = true, maxStreams: Int = 0, maxProfiles: Int = 0, transcodeAllowed: Bool = true,
        maxTranscodes: Int = 0, downloadAllowed: Bool = false, downloadTranscodeAllowed: Bool = false, maxPlaybackQuality: String = "",
        allowedPermissions: [String]? = nil, requestsAllowed: Bool = true
    ) {
        self.libraryIDs = libraryIDs
        self.playbackAllowed = playbackAllowed
        self.maxStreams = maxStreams
        self.maxProfiles = maxProfiles
        self.transcodeAllowed = transcodeAllowed
        self.maxTranscodes = maxTranscodes
        self.downloadAllowed = downloadAllowed
        self.downloadTranscodeAllowed = downloadTranscodeAllowed
        self.maxPlaybackQuality = maxPlaybackQuality
        self.allowedPermissions = allowedPermissions
        self.requestsAllowed = requestsAllowed
    }
}

/// An organization's plan: which plan it is on, the limits on the organization, and the default settings the plan gave
/// its members (nil before any plan was applied).
struct OrganizationEntitlement: Decodable, Equatable, Sendable {
    struct ManagedGroup: Decodable, Equatable, Sendable {
        let id: Int64
        let name: String
        let policy: EntitlementPolicy
    }

    let templateKey: String
    let templateRevision: Int64
    let managedDefaultGroup: ManagedGroup?
    /// Screens the whole organization may use at once.
    let slots: Int
    /// Conversions the whole organization may run at once.
    let transcodes: Int
    /// An instant as the server wrote it; nil before a plan was applied.
    let lastReconciledAt: String?

    var hasPlan: Bool { !templateKey.isEmpty && templateRevision > 0 }

    private enum CodingKeys: String, CodingKey {
        case templateKey = "template_key"
        case templateRevision = "template_revision"
        case managedDefaultGroup = "managed_default_group"
        case tenantLimits = "tenant_limits"
        case lastReconciledAt = "last_reconciled_at"
    }

    private struct Limits: Decodable {
        let slots: Int
        let transcodes: Int

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            slots = try c.value(.slots, 0)
            transcodes = try c.value(.transcodes, 0)
        }

        enum Keys: String, CodingKey { case slots, transcodes }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateKey = try c.value(.templateKey, "")
        templateRevision = try c.value(.templateRevision, 0)
        managedDefaultGroup = try c.value(.managedDefaultGroup, nil as ManagedGroup?)
        let limits = try c.value(.tenantLimits, Limits?.none)
        slots = limits?.slots ?? 0
        transcodes = limits?.transcodes ?? 0
        let reconciled = try c.value(.lastReconciledAt, nil as String?)
        lastReconciledAt = (reconciled?.isEmpty ?? true) ? nil : reconciled
    }

    init(
        templateKey: String, templateRevision: Int64, managedDefaultGroup: ManagedGroup? = nil, slots: Int = 0, transcodes: Int = 0,
        lastReconciledAt: String? = nil
    ) {
        self.templateKey = templateKey
        self.templateRevision = templateRevision
        self.managedDefaultGroup = managedDefaultGroup
        self.slots = slots
        self.transcodes = transcodes
        self.lastReconciledAt = lastReconciledAt
    }
}

/// One plan the server offers.
struct EntitlementTemplate: Decodable, Identifiable, Equatable, Sendable {
    let key: String
    let name: String
    let revision: Int64
    let policy: EntitlementPolicy

    var id: String { key }

    enum CodingKeys: String, CodingKey { case key, name, revision, policy }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        name = try c.value(.name, "")
        revision = try c.decode(Int64.self, forKey: .revision)
        policy = try c.decode(EntitlementPolicy.self, forKey: .policy)
    }

    init(key: String, name: String, revision: Int64, policy: EntitlementPolicy) {
        self.key = key
        self.name = name
        self.revision = revision
        self.policy = policy
    }
}

struct EntitlementTemplateList: Decodable, Sendable {
    let templates: [EntitlementTemplate]

    enum CodingKeys: String, CodingKey { case templates }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templates = try c.value(.templates, [EntitlementTemplate]())
    }
}

/// What applying a plan would do (a preview) or did (an apply).
struct EntitlementApplyResult: Decodable, Equatable, Sendable {
    let templateKey: String
    let templateRevision: Int64
    let changed: Bool
    let profilesMoved: Int
    let previousTemplateKey: String
    let previousTemplateRevision: Int64
    /// The settings the plan gives members.
    let policy: EntitlementPolicy

    enum CodingKeys: String, CodingKey {
        case changed, policy
        case templateKey = "template_key"
        case templateRevision = "template_revision"
        case profilesMoved = "profiles_moved"
        case previousTemplateKey = "previous_template_key"
        case previousTemplateRevision = "previous_template_revision"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        templateKey = try c.value(.templateKey, "")
        templateRevision = try c.value(.templateRevision, 0)
        changed = try c.value(.changed, false)
        profilesMoved = try c.value(.profilesMoved, 0)
        previousTemplateKey = try c.value(.previousTemplateKey, "")
        previousTemplateRevision = try c.value(.previousTemplateRevision, 0)
        policy = try c.decode(EntitlementPolicy.self, forKey: .policy)
    }

    init(
        templateKey: String, templateRevision: Int64, changed: Bool = true, profilesMoved: Int = 0, previousTemplateKey: String = "",
        previousTemplateRevision: Int64 = 0, policy: EntitlementPolicy
    ) {
        self.templateKey = templateKey
        self.templateRevision = templateRevision
        self.changed = changed
        self.profilesMoved = profilesMoved
        self.previousTemplateKey = previousTemplateKey
        self.previousTemplateRevision = previousTemplateRevision
        self.policy = policy
    }
}

/// The answer to a preview: what would change, and the one-use token that lets the same change be applied.
struct EntitlementPreview: Decodable, Equatable, Sendable {
    let result: EntitlementApplyResult
    let changed: Bool
    let token: String
    /// An instant as the server wrote it: after it the preview must be made again.
    let expiresAt: String?
    let warnings: [String]

    enum CodingKeys: String, CodingKey {
        case result, changed, warnings
        case confirmationToken = "confirmation_token"
        case dryRunToken = "dry_run_token"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        result = try c.decode(EntitlementApplyResult.self, forKey: .result)
        changed = try c.value(.changed, result.changed)
        let confirmation = try c.value(.confirmationToken, "")
        let dryRun = try c.value(.dryRunToken, "")
        token = confirmation.isEmpty ? dryRun : confirmation
        expiresAt = try c.value(.expiresAt, nil as String?)
        warnings = try c.value(.warnings, [String]())
    }

    init(result: EntitlementApplyResult, changed: Bool, token: String, expiresAt: String? = nil, warnings: [String] = []) {
        self.result = result
        self.changed = changed
        self.token = token
        self.expiresAt = expiresAt
        self.warnings = warnings
    }
}
