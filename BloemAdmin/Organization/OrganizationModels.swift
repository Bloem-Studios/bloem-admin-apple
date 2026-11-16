import Foundation

/*
 Wire shapes of the organization routes under /api/bloem/v2/admin/organization, as the server's
 handlers write them (see the Bloem server's
 OpenAPI document). Unknown fields are ignored. Fields the server may leave out or send as null decode
 to a default; a malformed field fails the answer. Strings the server may extend (status, outcome,
 action) are never matched against a closed set when decoding, so one new value cannot fail a whole list.
 */

extension KeyedDecodingContainer {
    /// A field the server may leave out or send as null. A field that is present but malformed (a wrong type, or a
    /// list with one bad row) still fails the answer: an empty list or a default in its place would read as
    /// "nobody" or "no access" instead of "the answer could not be read".
    func value<T: Decodable>(_ key: Key, _ fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

// MARK: - Administrative context pass

struct AdminSessionRequest: Encodable, Equatable, Sendable {
    let scope: String
    let organizationID: String?
    /// Break-glass access to an organization the caller is not a member of (the server Owner only). Left out of
    /// the body when nil, as every ordinary mint is.
    var support: SupportAccessRequest? = nil

    enum CodingKeys: String, CodingKey {
        case scope, support
        case organizationID = "organization_id"
    }
}

/// `support` on the mint: a `reason` opens an access, an `access_id` renews the one this login session opened.
struct SupportAccessRequest: Encodable, Equatable, Sendable {
    var reason: String?
    var accessID: String?

    static func opening(reason: String) -> SupportAccessRequest { SupportAccessRequest(reason: reason, accessID: nil) }
    static func renewing(accessID: String) -> SupportAccessRequest { SupportAccessRequest(reason: nil, accessID: accessID) }

    enum CodingKeys: String, CodingKey {
        case reason
        case accessID = "access_id"
    }
}

struct AdminSessionContext: Decodable, Equatable, Sendable {
    let key: String
    let scope: String
    let organizationID: String?
    let membershipID: String?
    let name: String
    let status: String
    let authority: String
    let policyRevision: Int64
    let securityRevision: Int64
    /// `membership`, or `support` for a pass opened under break-glass access (no membership).
    let accessBasis: String
    let supportAccessID: String?
    let supportExpiresAt: String?

    enum CodingKeys: String, CodingKey {
        case key, scope, name, status, authority
        case organizationID = "organization_id"
        case membershipID = "membership_id"
        case policyRevision = "policy_revision"
        case securityRevision = "security_revision"
        case accessBasis = "access_basis"
        case supportAccessID = "support_access_id"
        case supportExpiresAt = "support_expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        scope = try c.decode(String.self, forKey: .scope)
        organizationID = try c.value(.organizationID, nil as String?)
        membershipID = try c.value(.membershipID, nil as String?)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        authority = try c.decode(String.self, forKey: .authority)
        policyRevision = try c.value(.policyRevision, 0)
        securityRevision = try c.value(.securityRevision, 0)
        accessBasis = try c.value(.accessBasis, "membership")
        let accessID = try c.value(.supportAccessID, nil as String?)
        supportAccessID = (accessID?.isEmpty ?? true) ? nil : accessID
        supportExpiresAt = try c.value(.supportExpiresAt, nil as String?)
    }
}

/// The pass is a bearer credential: it is held in memory only and never printed.
struct AdminSessionResponse: Decodable, Sendable, CustomStringConvertible {
    let accessToken: String
    let expiresAt: String
    let context: AdminSessionContext

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresAt = "expires_at"
        case context
    }

    var description: String { "AdminSessionResponse(access_token: <redacted>, context: \(context.key))" }
}

// MARK: - Overview

struct OrganizationSummary: Decodable, Equatable, Sendable {
    let id: String
    let slug: String
    let name: String
    let status: String
    let ownerAccountID: Int64?
    let policyRevision: Int64
    let isDefault: Bool
    let membershipCount: Int64
    let activeMembershipCount: Int64
    let profileCount: Int64
    let libraryCount: Int64
    let entitlementCount: Int64

    enum CodingKeys: String, CodingKey {
        case id, slug, name, status
        case ownerAccountID = "owner_account_id"
        case policyRevision = "policy_revision"
        case isDefault = "is_default"
        case membershipCount = "membership_count"
        case activeMembershipCount = "active_membership_count"
        case profileCount = "profile_count"
        case libraryCount = "library_count"
        case entitlementCount = "entitlement_count"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.value(.slug, "")
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        ownerAccountID = try c.value(.ownerAccountID, nil as Int64?)
        policyRevision = try c.value(.policyRevision, 0)
        isDefault = try c.value(.isDefault, false)
        membershipCount = try c.value(.membershipCount, 0)
        activeMembershipCount = try c.value(.activeMembershipCount, 0)
        profileCount = try c.value(.profileCount, 0)
        libraryCount = try c.value(.libraryCount, 0)
        entitlementCount = try c.value(.entitlementCount, 0)
    }
}

struct OrganizationOverviewResponse: Decodable, Sendable {
    let organization: OrganizationSummary
}

// MARK: - People

struct ProfileSummary: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let groupID: Int64
    let groupName: String
    let updatedAt: String
    /// The profile's own revision: what a rename, a PIN clear or a removal quotes. Zero from a server that predates
    /// organization support, which offers none of those.
    let revision: Int64
    let hasPIN: Bool
    /// The household's main profile: it cannot be removed.
    let isPrimary: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, revision
        case groupID = "group_id"
        case groupName = "group_name"
        case updatedAt = "updated_at"
        case hasPIN = "has_pin"
        case isPrimary = "is_primary"
    }

    init(
        id: String, name: String, groupID: Int64 = 0, groupName: String = "", updatedAt: String = "",
        revision: Int64 = 0, hasPIN: Bool = false, isPrimary: Bool = false
    ) {
        self.id = id
        self.name = name
        self.groupID = groupID
        self.groupName = groupName
        self.updatedAt = updatedAt
        self.revision = revision
        self.hasPIN = hasPIN
        self.isPrimary = isPrimary
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        groupID = try c.value(.groupID, 0)
        groupName = try c.value(.groupName, "")
        updatedAt = try c.value(.updatedAt, "")
        revision = try c.value(.revision, 0)
        hasPIN = try c.value(.hasPIN, false)
        isPrimary = try c.value(.isPrimary, false)
    }
}

struct PersonSummary: Decodable, Identifiable, Equatable, Sendable {
    static let membershipActive = "active"
    static let membershipSuspended = "suspended"
    static let membershipInvited = "invited"

    let organizationID: String
    let accountID: Int64
    let email: String
    let displayName: String
    let membershipID: String
    /// `invited`, `active` or `suspended`.
    let membershipStatus: String
    let legacyRole: String
    /// The revision a membership or profile write must quote.
    let securityRevision: Int64
    let lastActivity: String?
    let profiles: [ProfileSummary]

    var id: Int64 { accountID }
    var isSuspended: Bool { membershipStatus == Self.membershipSuspended }
    var isActive: Bool { membershipStatus == Self.membershipActive }
    var isAdministrator: Bool { legacyRole == "admin" }
    /// What a list row calls the person: the display name, else the email.
    var label: String {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? email : name
    }

    enum CodingKeys: String, CodingKey {
        case email, profiles
        case organizationID = "organization_id"
        case accountID = "account_id"
        case displayName = "display_name"
        case membershipID = "membership_id"
        case membershipStatus = "membership_status"
        case legacyRole = "legacy_role"
        case securityRevision = "security_revision"
        case lastActivity = "last_activity"
    }

    init(
        organizationID: String = "",
        accountID: Int64,
        email: String = "",
        displayName: String = "",
        membershipID: String = "",
        membershipStatus: String,
        legacyRole: String = "user",
        securityRevision: Int64,
        lastActivity: String? = nil,
        profiles: [ProfileSummary] = []
    ) {
        self.organizationID = organizationID
        self.accountID = accountID
        self.email = email
        self.displayName = displayName
        self.membershipID = membershipID
        self.membershipStatus = membershipStatus
        self.legacyRole = legacyRole
        self.securityRevision = securityRevision
        self.lastActivity = lastActivity
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organizationID = try c.value(.organizationID, "")
        accountID = try c.decode(Int64.self, forKey: .accountID)
        email = try c.value(.email, "")
        displayName = try c.value(.displayName, "")
        membershipID = try c.value(.membershipID, "")
        membershipStatus = try c.decode(String.self, forKey: .membershipStatus)
        legacyRole = try c.value(.legacyRole, "user")
        securityRevision = try c.decode(Int64.self, forKey: .securityRevision)
        lastActivity = try c.value(.lastActivity, nil as String?)
        profiles = try c.value(.profiles, [ProfileSummary]())
    }
}

struct PeoplePage: Decodable, Equatable, Sendable {
    let items: [PersonSummary]
    let nextCursor: String?
    let approximateTotal: Int64

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
        case approximateTotal = "approximate_total"
    }

    init(items: [PersonSummary], nextCursor: String? = nil, approximateTotal: Int64 = 0) {
        self.items = items
        self.nextCursor = nextCursor
        self.approximateTotal = approximateTotal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.value(.items, [PersonSummary]())
        let cursor = try c.value(.nextCursor, nil as String?)
        nextCursor = (cursor?.isEmpty ?? true) ? nil : cursor
        approximateTotal = try c.value(.approximateTotal, 0)
    }
}

struct PersonResponse: Decodable, Sendable {
    let person: PersonSummary
}

struct MembershipStatusUpdate: Encodable, Equatable, Sendable {
    let expectedRevision: Int64
    let status: String

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case status
    }
}

struct ProfileGroupUpdate: Encodable, Equatable, Sendable {
    let expectedRevision: Int64
    let groupID: Int64

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case groupID = "group_id"
    }
}

enum PeopleSort {
    static let name = "name"
    static let email = "email"
    static let recentActivity = "recent_activity"
    static let all = [name, email, recentActivity]
}

/// What the People page asks for. Empty values are left out of the request.
struct PeopleFilter: Equatable, Hashable, Sendable {
    var query: String = ""
    var statuses: Set<String> = []
    var groupID: Int64?
    /// `name` (the server's default), `email` or `recent_activity`.
    var sort: String?
    /// An RFC 3339 instant: only people active since then. The view model fills it in from `activeWithinDays`.
    var activeSince: String?
    /// "Active in the last N days", the way a phone picks it; turned into `activeSince` when the request is made.
    var activeWithinDays: Int?

    /// True when anything narrows the list, so "everyone" is not the answer.
    var isNarrowed: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !statuses.isEmpty || groupID != nil || activeSince != nil || activeWithinDays != nil
    }
}

// MARK: - Access groups

struct OrganizationAccessGroup: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let description: String
    /// nil means every library the organization can use.
    let libraryIDs: [String]?
    let maxPlaybackQuality: String
    let downloadAllowed: Bool
    let downloadTranscodeAllowed: Bool
    let transcodeAllowed: Bool
    let audioTranscodeAllowed: Bool
    let maxStreams: Int64
    let maxTranscodes: Int64
    let maxRemoteStreamBitrateKbps: Int64
    let maxLocalStreamBitrateKbps: Int64
    let maxProfiles: Int64
    /// nil means every assignable permission.
    let allowedPermissions: [String]?
    let requestsAllowed: Bool
    let isDefault: Bool
    /// Only the list route sends it.
    let memberCount: Int64
    let createdAt: String
    let updatedAt: String

    /// The group's id as the number the write routes take.
    var numericID: Int64? { Int64(id) }

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case libraryIDs = "library_ids"
        case maxPlaybackQuality = "max_playback_quality"
        case downloadAllowed = "download_allowed"
        case downloadTranscodeAllowed = "download_transcode_allowed"
        case transcodeAllowed = "transcode_allowed"
        case audioTranscodeAllowed = "audio_transcode_allowed"
        case maxStreams = "max_streams"
        case maxTranscodes = "max_transcodes"
        case maxRemoteStreamBitrateKbps = "max_remote_stream_bitrate_kbps"
        case maxLocalStreamBitrateKbps = "max_local_stream_bitrate_kbps"
        case maxProfiles = "max_profiles"
        case allowedPermissions = "allowed_permissions"
        case requestsAllowed = "requests_allowed"
        case isDefault = "is_default"
        case memberCount = "member_count"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: String, name: String, description: String = "", libraryIDs: [String]? = nil,
        maxPlaybackQuality: String = "", downloadAllowed: Bool = false, downloadTranscodeAllowed: Bool = false,
        transcodeAllowed: Bool = false, audioTranscodeAllowed: Bool = false, maxStreams: Int64 = 0,
        maxTranscodes: Int64 = 0, maxRemoteStreamBitrateKbps: Int64 = 0, maxLocalStreamBitrateKbps: Int64 = 0,
        maxProfiles: Int64 = 0, allowedPermissions: [String]? = nil, requestsAllowed: Bool = false,
        isDefault: Bool = false, memberCount: Int64 = 0, createdAt: String = "", updatedAt: String = ""
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.libraryIDs = libraryIDs
        self.maxPlaybackQuality = maxPlaybackQuality
        self.downloadAllowed = downloadAllowed
        self.downloadTranscodeAllowed = downloadTranscodeAllowed
        self.transcodeAllowed = transcodeAllowed
        self.audioTranscodeAllowed = audioTranscodeAllowed
        self.maxStreams = maxStreams
        self.maxTranscodes = maxTranscodes
        self.maxRemoteStreamBitrateKbps = maxRemoteStreamBitrateKbps
        self.maxLocalStreamBitrateKbps = maxLocalStreamBitrateKbps
        self.maxProfiles = maxProfiles
        self.allowedPermissions = allowedPermissions
        self.requestsAllowed = requestsAllowed
        self.isDefault = isDefault
        self.memberCount = memberCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        description = try c.value(.description, "")
        libraryIDs = try c.value(.libraryIDs, nil as [String]?)
        maxPlaybackQuality = try c.value(.maxPlaybackQuality, "")
        downloadAllowed = try c.value(.downloadAllowed, false)
        downloadTranscodeAllowed = try c.value(.downloadTranscodeAllowed, false)
        transcodeAllowed = try c.value(.transcodeAllowed, false)
        audioTranscodeAllowed = try c.value(.audioTranscodeAllowed, false)
        maxStreams = try c.value(.maxStreams, 0)
        maxTranscodes = try c.value(.maxTranscodes, 0)
        maxRemoteStreamBitrateKbps = try c.value(.maxRemoteStreamBitrateKbps, 0)
        maxLocalStreamBitrateKbps = try c.value(.maxLocalStreamBitrateKbps, 0)
        maxProfiles = try c.value(.maxProfiles, 0)
        allowedPermissions = try c.value(.allowedPermissions, nil as [String]?)
        requestsAllowed = try c.value(.requestsAllowed, false)
        isDefault = try c.value(.isDefault, false)
        memberCount = try c.value(.memberCount, 0)
        createdAt = try c.value(.createdAt, "")
        updatedAt = try c.value(.updatedAt, "")
    }
}

struct AccessGroupsResponse: Decodable, Sendable {
    let groups: [OrganizationAccessGroup]

    enum CodingKeys: String, CodingKey { case groups }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        groups = try c.value(.groups, [OrganizationAccessGroup]())
    }
}

// MARK: - Libraries and entitlements

struct LibraryEntitlement: Decodable, Equatable, Sendable {
    let id: String
    let organizationID: String
    /// `active`, `suspended` or `revoked`.
    let status: String
    /// The revision an entitlement write must quote.
    let securityRevision: Int64

    enum CodingKeys: String, CodingKey {
        case id, status
        case organizationID = "organization_id"
        case securityRevision = "security_revision"
    }

    init(id: String, organizationID: String = "", status: String, securityRevision: Int64) {
        self.id = id
        self.organizationID = organizationID
        self.status = status
        self.securityRevision = securityRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        organizationID = try c.value(.organizationID, "")
        status = try c.decode(String.self, forKey: .status)
        securityRevision = try c.decode(Int64.self, forKey: .securityRevision)
    }
}

struct OrganizationLibrary: Decodable, Identifiable, Equatable, Sendable {
    let folderID: Int64
    let name: String
    let type: String
    /// `owned` by the organization, or `entitled` (shared by the server).
    let accessKind: String
    let entitlement: LibraryEntitlement?

    var id: Int64 { folderID }
    var isOwned: Bool { accessKind == "owned" }
    /// Whether members can use it right now: the organization's own libraries always, a shared one only while its
    /// entitlement is active. This is the ceiling an access group's library choice lives under.
    var countsTowardCeiling: Bool { isOwned || entitlement?.status == "active" }

    enum CodingKeys: String, CodingKey {
        case name, type, entitlement
        case folderID = "folder_id"
        case accessKind = "access_kind"
    }

    init(folderID: Int64, name: String, type: String = "", accessKind: String, entitlement: LibraryEntitlement? = nil) {
        self.folderID = folderID
        self.name = name
        self.type = type
        self.accessKind = accessKind
        self.entitlement = entitlement
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        folderID = try c.decode(Int64.self, forKey: .folderID)
        name = try c.decode(String.self, forKey: .name)
        type = try c.value(.type, "")
        accessKind = try c.decode(String.self, forKey: .accessKind)
        entitlement = try c.value(.entitlement, nil as LibraryEntitlement?)
    }
}

struct OrganizationLibrariesResponse: Decodable, Sendable {
    let libraries: [OrganizationLibrary]

    enum CodingKeys: String, CodingKey { case libraries }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraries = try c.value(.libraries, [OrganizationLibrary]())
    }
}

struct OrganizationEntitlementResponse: Decodable, Sendable {
    let entitlement: LibraryEntitlement
}

struct EntitlementStatusUpdate: Encodable, Equatable, Sendable {
    let expectedRevision: Int64
    let status: String

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case status
    }
}

// MARK: - Invitations

struct OrganizationInvitation: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let email: String
    let delivery: String
    let role: String
    let accessGroupID: String?
    let libraryIDs: [String]?
    let createProfile: Bool
    let showTour: Bool
    let note: String
    let invitedBy: String
    let invitedByName: String
    /// `pending`, `accepted`, `revoked` or `expired`.
    let status: String
    let expiresAt: String
    let acceptedAt: String?
    let acceptedUserID: String?
    let createdAt: String

    var isPending: Bool { status == "pending" }

    enum CodingKeys: String, CodingKey {
        case id, email, delivery, role, note, status
        case accessGroupID = "access_group_id"
        case libraryIDs = "library_ids"
        case createProfile = "create_profile"
        case showTour = "show_tour"
        case invitedBy = "invited_by"
        case invitedByName = "invited_by_name"
        case expiresAt = "expires_at"
        case acceptedAt = "accepted_at"
        case acceptedUserID = "accepted_user_id"
        case createdAt = "created_at"
    }

    init(
        id: String, email: String = "", delivery: String = "link", role: String = "user", accessGroupID: String? = nil,
        libraryIDs: [String]? = nil, createProfile: Bool = true, showTour: Bool = true, note: String = "",
        invitedBy: String = "", invitedByName: String = "", status: String, expiresAt: String = "",
        acceptedAt: String? = nil, acceptedUserID: String? = nil, createdAt: String = ""
    ) {
        self.id = id
        self.email = email
        self.delivery = delivery
        self.role = role
        self.accessGroupID = accessGroupID
        self.libraryIDs = libraryIDs
        self.createProfile = createProfile
        self.showTour = showTour
        self.note = note
        self.invitedBy = invitedBy
        self.invitedByName = invitedByName
        self.status = status
        self.expiresAt = expiresAt
        self.acceptedAt = acceptedAt
        self.acceptedUserID = acceptedUserID
        self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        email = try c.value(.email, "")
        delivery = try c.value(.delivery, "")
        role = try c.value(.role, "user")
        accessGroupID = try c.value(.accessGroupID, nil as String?)
        libraryIDs = try c.value(.libraryIDs, nil as [String]?)
        createProfile = try c.value(.createProfile, true)
        showTour = try c.value(.showTour, true)
        note = try c.value(.note, "")
        invitedBy = try c.value(.invitedBy, "")
        invitedByName = try c.value(.invitedByName, "")
        status = try c.decode(String.self, forKey: .status)
        expiresAt = try c.value(.expiresAt, "")
        acceptedAt = try c.value(.acceptedAt, nil as String?)
        acceptedUserID = try c.value(.acceptedUserID, nil as String?)
        createdAt = try c.value(.createdAt, "")
    }
}

struct OrganizationInvitationsResponse: Decodable, Sendable {
    let invitations: [OrganizationInvitation]

    enum CodingKeys: String, CodingKey { case invitations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        invitations = try c.value(.invitations, [OrganizationInvitation]())
    }
}

struct CreateOrganizationInvitation: Encodable, Equatable, Sendable {
    let email: String
    let expectedRevision: Int64
    let accessGroupID: Int64?
    let note: String?

    enum CodingKeys: String, CodingKey {
        case email, note
        case expectedRevision = "expected_revision"
        case accessGroupID = "access_group_id"
    }
}

struct RevisionBody: Encodable, Equatable, Sendable {
    let expectedRevision: Int64

    enum CodingKeys: String, CodingKey { case expectedRevision = "expected_revision" }
}

/// The answer to create and resend: the claim token is shown once and never again. It is a secret, so
/// `description` hides it and it must not be logged or saved.
struct InvitationHandoff: Decodable, Equatable, Sendable, CustomStringConvertible {
    let invitation: OrganizationInvitation
    let claimToken: String

    enum CodingKeys: String, CodingKey {
        case invitation
        case claimToken = "claim_token"
    }

    var description: String { "InvitationHandoff(invitation: \(invitation.id), claim_token: <redacted>)" }
}

// MARK: - Activity & Audit

struct OrganizationAuditEvent: Decodable, Identifiable, Equatable, Sendable {
    static let platformSupport = "platform_support"

    let id: Int64
    let source: String
    let createdAt: String
    let actorAccountID: Int64?
    let action: String
    let targetID: String
    let outcome: String
    /// `organization_admin`, or `platform_support` for the server operator under support access (who then has no
    /// account id here). Nil from a server that predates organization support.
    let actorAuthority: String?
    /// The reason a support access was opened with, shown to the organization as it was written.
    let reason: String?
    let supportAccessID: String?

    var isPlatformSupport: Bool { actorAuthority == Self.platformSupport }

    enum CodingKeys: String, CodingKey {
        case id, source, action, outcome, reason
        case createdAt = "created_at"
        case actorAccountID = "actor_account_id"
        case targetID = "target_id"
        case actorAuthority = "actor_authority"
        case supportAccessID = "support_access_id"
    }

    init(
        id: Int64, source: String = "", createdAt: String = "", actorAccountID: Int64? = nil,
        action: String, targetID: String = "", outcome: String = "", actorAuthority: String? = nil,
        reason: String? = nil, supportAccessID: String? = nil
    ) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
        self.actorAccountID = actorAccountID
        self.action = action
        self.targetID = targetID
        self.outcome = outcome
        self.actorAuthority = actorAuthority
        self.reason = reason
        self.supportAccessID = supportAccessID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        source = try c.value(.source, "")
        createdAt = try c.value(.createdAt, "")
        actorAccountID = try c.value(.actorAccountID, nil as Int64?)
        action = try c.decode(String.self, forKey: .action)
        targetID = try c.value(.targetID, "")
        outcome = try c.value(.outcome, "")
        actorAuthority = try c.value(.actorAuthority, nil as String?)
        let reason = try c.value(.reason, nil as String?)
        self.reason = (reason?.isEmpty ?? true) ? nil : reason
        let access = try c.value(.supportAccessID, nil as String?)
        supportAccessID = (access?.isEmpty ?? true) ? nil : access
    }
}

struct OrganizationAuditPage: Decodable, Equatable, Sendable {
    let events: [OrganizationAuditEvent]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case events
        case nextCursor = "next_cursor"
    }

    init(events: [OrganizationAuditEvent], nextCursor: String? = nil) {
        self.events = events
        self.nextCursor = nextCursor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        events = try c.value(.events, [OrganizationAuditEvent]())
        let cursor = try c.value(.nextCursor, nil as String?)
        nextCursor = (cursor?.isEmpty ?? true) ? nil : cursor
    }
}

// MARK: - Policy cohorts and policy decisions (read-only)

/// Any JSON value. Policy decisions carry a `resource` object the server has already sanitised; it is shown as
/// label and value pairs and never rendered raw.
enum PolicyJSONValue: Decodable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: PolicyJSONValue])
    case array([PolicyJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode([PolicyJSONValue].self) { self = .array(value) }
        else if let value = try? c.decode([String: PolicyJSONValue].self) { self = .object(value) }
        else { self = .null }
    }

    /// A short single-line reading for a label/value row.
    var displayText: String {
        switch self {
        case .string(let value): return value
        case .number(let value):
            return value.rounded() == value && abs(value) < 1e15 ? String(Int64(value)) : String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "–"
        case .array(let values): return values.map(\.displayText).joined(separator: ", ")
        case .object(let fields):
            return fields.keys.sorted().map { "\($0): \(fields[$0]?.displayText ?? "")" }.joined(separator: ", ")
        }
    }
}

struct PolicyView: Decodable, Equatable, Sendable {
    let libraryIDs: [Int64]?
    let playbackAllowed: Bool
    let maxStreams: Int64
    let maxProfiles: Int64
    let transcodeAllowed: Bool
    /// Not every server sends it; the row shows only when present.
    let audioTranscodeAllowed: Bool?
    let maxTranscodes: Int64
    let downloadAllowed: Bool
    let downloadTranscodeAllowed: Bool
    let maxPlaybackQuality: String
    let allowedPermissions: [String]?
    let requestsAllowed: Bool

    enum CodingKeys: String, CodingKey {
        case libraryIDs = "library_ids"
        case playbackAllowed = "playback_allowed"
        case maxStreams = "max_streams"
        case maxProfiles = "max_profiles"
        case transcodeAllowed = "transcode_allowed"
        case audioTranscodeAllowed = "audio_transcode_allowed"
        case maxTranscodes = "max_transcodes"
        case downloadAllowed = "download_allowed"
        case downloadTranscodeAllowed = "download_transcode_allowed"
        case maxPlaybackQuality = "max_playback_quality"
        case allowedPermissions = "allowed_permissions"
        case requestsAllowed = "requests_allowed"
    }

    init(
        libraryIDs: [Int64]? = nil, playbackAllowed: Bool = false, maxStreams: Int64 = 0, maxProfiles: Int64 = 0,
        transcodeAllowed: Bool = false, audioTranscodeAllowed: Bool? = nil, maxTranscodes: Int64 = 0,
        downloadAllowed: Bool = false, downloadTranscodeAllowed: Bool = false, maxPlaybackQuality: String = "",
        allowedPermissions: [String]? = nil, requestsAllowed: Bool = false
    ) {
        self.libraryIDs = libraryIDs
        self.playbackAllowed = playbackAllowed
        self.maxStreams = maxStreams
        self.maxProfiles = maxProfiles
        self.transcodeAllowed = transcodeAllowed
        self.audioTranscodeAllowed = audioTranscodeAllowed
        self.maxTranscodes = maxTranscodes
        self.downloadAllowed = downloadAllowed
        self.downloadTranscodeAllowed = downloadTranscodeAllowed
        self.maxPlaybackQuality = maxPlaybackQuality
        self.allowedPermissions = allowedPermissions
        self.requestsAllowed = requestsAllowed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraryIDs = try c.value(.libraryIDs, nil as [Int64]?)
        playbackAllowed = try c.value(.playbackAllowed, false)
        maxStreams = try c.value(.maxStreams, 0)
        maxProfiles = try c.value(.maxProfiles, 0)
        transcodeAllowed = try c.value(.transcodeAllowed, false)
        audioTranscodeAllowed = try c.value(.audioTranscodeAllowed, nil as Bool?)
        maxTranscodes = try c.value(.maxTranscodes, 0)
        downloadAllowed = try c.value(.downloadAllowed, false)
        downloadTranscodeAllowed = try c.value(.downloadTranscodeAllowed, false)
        maxPlaybackQuality = try c.value(.maxPlaybackQuality, "")
        allowedPermissions = try c.value(.allowedPermissions, nil as [String]?)
        requestsAllowed = try c.value(.requestsAllowed, false)
    }
}

struct EntitlementCohort: Decodable, Identifiable, Equatable, Sendable {
    let cohortID: String
    let organizationID: String
    let name: String
    let revision: Int64
    let accessGroupID: Int64
    let sourceTemplateKey: String?
    let sourceTemplateRevision: Int64?
    let parentCohortID: String?
    let derivationKind: String
    let policy: PolicyView
    /// A fingerprint of the settings, shown with the details.
    let policyDigest: String
    let archived: Bool
    let memberCount: Int64
    let createdByAccountID: Int64?
    let createdAt: String

    var id: String { cohortID }

    enum CodingKeys: String, CodingKey {
        case name, revision, policy, archived
        case cohortID = "cohort_id"
        case organizationID = "organization_id"
        case accessGroupID = "access_group_id"
        case sourceTemplateKey = "source_template_key"
        case sourceTemplateRevision = "source_template_revision"
        case parentCohortID = "parent_cohort_id"
        case derivationKind = "derivation_kind"
        case policyDigest = "policy_digest"
        case memberCount = "member_count"
        case createdByAccountID = "created_by_account_id"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cohortID = try c.decode(String.self, forKey: .cohortID)
        organizationID = try c.value(.organizationID, "")
        name = try c.decode(String.self, forKey: .name)
        revision = try c.value(.revision, 0)
        accessGroupID = try c.value(.accessGroupID, 0)
        sourceTemplateKey = try c.value(.sourceTemplateKey, nil as String?)
        sourceTemplateRevision = try c.value(.sourceTemplateRevision, nil as Int64?)
        parentCohortID = try c.value(.parentCohortID, nil as String?)
        derivationKind = try c.value(.derivationKind, "")
        policy = try c.value(.policy, PolicyView())
        policyDigest = try c.value(.policyDigest, "")
        archived = try c.value(.archived, false)
        memberCount = try c.value(.memberCount, 0)
        createdByAccountID = try c.value(.createdByAccountID, nil as Int64?)
        createdAt = try c.value(.createdAt, "")
    }
}

struct EntitlementCohortsResponse: Decodable, Sendable {
    let cohorts: [EntitlementCohort]

    enum CodingKeys: String, CodingKey { case cohorts }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cohorts = try c.value(.cohorts, [EntitlementCohort]())
    }
}

struct PolicyDecisionGroupRef: Decodable, Equatable, Sendable {
    let id: Int64
    let name: String

    enum CodingKeys: String, CodingKey { case id, name }

    init(id: Int64 = 0, name: String = "") {
        self.id = id
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, 0)
        name = try c.value(.name, "")
    }
}

struct PolicyDecisionSubject: Decodable, Equatable, Sendable {
    let accountID: Int64
    let profileID: String

    enum CodingKeys: String, CodingKey {
        case accountID = "account_id"
        case profileID = "profile_id"
    }

    init(accountID: Int64 = 0, profileID: String = "") {
        self.accountID = accountID
        self.profileID = profileID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.value(.accountID, 0)
        profileID = try c.value(.profileID, "")
    }
}

struct PolicyDecision: Decodable, Identifiable, Equatable, Sendable {
    let id: Int64
    let timestamp: String
    let subject: PolicyDecisionSubject
    let group: PolicyDecisionGroupRef
    let action: String
    let allowed: Bool
    let reasonCode: String
    /// Sanitised by the server; shown only as a count of its keys, never rendered raw.
    let resource: [String: PolicyJSONValue]

    enum CodingKeys: String, CodingKey {
        case id, timestamp, subject, group, action, allowed, resource
        case reasonCode = "reason_code"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        timestamp = try c.value(.timestamp, "")
        subject = try c.value(.subject, PolicyDecisionSubject())
        group = try c.value(.group, PolicyDecisionGroupRef())
        action = try c.decode(String.self, forKey: .action)
        allowed = try c.decode(Bool.self, forKey: .allowed)
        reasonCode = try c.value(.reasonCode, "")
        resource = try c.value(.resource, [String: PolicyJSONValue]())
    }
}

struct PolicyDecisionOrganizationRef: Decodable, Equatable, Sendable {
    let id: String
    let membershipID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case membershipID = "membership_id"
    }

    init(id: String = "", membershipID: String? = nil) {
        self.id = id
        self.membershipID = membershipID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.value(.id, "")
        membershipID = try c.value(.membershipID, nil as String?)
    }
}

struct PolicyVersionRef: Decodable, Equatable, Sendable {
    let kind: String
    let name: String?
    let version: Int64

    enum CodingKeys: String, CodingKey { case kind, name, version }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.value(.kind, "")
        name = try c.value(.name, nil as String?)
        version = try c.value(.version, 0)
    }
}

/// `GET /organization/policy-decisions/{id}`: one check with everything the server records about it.
struct PolicyDecisionDetail: Decodable, Equatable, Sendable {
    let id: Int64
    let timestamp: String
    let organization: PolicyDecisionOrganizationRef
    let subject: PolicyDecisionSubject
    let group: PolicyDecisionGroupRef
    /// The libraries the organization allowed this check to reach.
    let libraryCeiling: [Int64]?
    let action: String
    /// Sanitised by the server (sensitive values arrive as `[redacted]`); shown as label and value pairs.
    let resource: [String: PolicyJSONValue]
    let allowed: Bool
    let reasonCode: String
    let policyVersions: [PolicyVersionRef]?

    enum CodingKeys: String, CodingKey {
        case id, timestamp, organization, subject, group, action, resource, allowed
        case libraryCeiling = "library_ceiling"
        case reasonCode = "reason_code"
        case policyVersions = "policy_versions"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int64.self, forKey: .id)
        timestamp = try c.value(.timestamp, "")
        organization = try c.value(.organization, PolicyDecisionOrganizationRef())
        subject = try c.value(.subject, PolicyDecisionSubject())
        group = try c.value(.group, PolicyDecisionGroupRef())
        libraryCeiling = try c.value(.libraryCeiling, nil as [Int64]?)
        action = try c.value(.action, "")
        resource = try c.value(.resource, [String: PolicyJSONValue]())
        allowed = try c.value(.allowed, false)
        reasonCode = try c.value(.reasonCode, "")
        policyVersions = try c.value(.policyVersions, nil as [PolicyVersionRef]?)
    }
}

struct PolicyDecisionDetailResponse: Decodable, Sendable {
    let decision: PolicyDecisionDetail
}

struct PolicyDecisionsPage: Decodable, Equatable, Sendable {
    let decisions: [PolicyDecision]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case decisions
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        decisions = try c.value(.decisions, [PolicyDecision]())
        let cursor = try c.value(.nextCursor, nil as String?)
        nextCursor = (cursor?.isEmpty ?? true) ? nil : cursor
    }
}

extension PersonSummary {
    /// True when this row is the signed-in administrator's own membership. Suspending oneself would lock them out.
    func isSelf(in context: AdminContext?) -> Bool {
        guard let membershipID = context?.membershipID, !membershipID.isEmpty else { return false }
        return membershipID == self.membershipID
    }
}
