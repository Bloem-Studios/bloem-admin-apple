import Foundation

enum AdminContextScope: Equatable, Sendable {
    case platform
    case organization
}

/// What lets the account in: the platform role, or an administrator membership of one organization.
enum AdminAuthority: Equatable, Sendable {
    case platformAdmin
    case organizationAdmin
}

/// One place an account can administer. `key` is the web's own key: `platform` or
/// `organization:<organization id>`. `status` is `active` for every context offered, because the server lists
/// only active memberships of active organizations.
struct AdminContext: Identifiable, Equatable, Hashable, Sendable {
    static let platformKey = "platform"
    static func organizationKey(_ organizationID: String) -> String { "organization:\(organizationID)" }

    let key: String
    let name: String
    let scope: AdminContextScope
    let organizationID: String?
    let status: String
    let authority: AdminAuthority
    let membershipID: String?
    let policyRevision: Int64
    let securityRevision: Int64
    /// Set when the server Owner opened this organization under break-glass support access: the access to renew
    /// with, and when it ends (at most four hours after it was opened; a renewal cannot extend it).
    let supportAccessID: String?
    let supportExpiresAt: Date?

    var id: String { key }
    /// True for a pass opened under support access rather than a membership.
    var isSupportAccess: Bool { supportAccessID != nil }

    init(
        key: String, name: String, scope: AdminContextScope, organizationID: String?, status: String = "active",
        authority: AdminAuthority, membershipID: String? = nil, policyRevision: Int64 = 0, securityRevision: Int64 = 0,
        supportAccessID: String? = nil, supportExpiresAt: Date? = nil
    ) {
        self.key = key
        self.name = name
        self.scope = scope
        self.organizationID = organizationID
        self.status = status
        self.authority = authority
        self.membershipID = membershipID
        self.policyRevision = policyRevision
        self.securityRevision = securityRevision
        self.supportAccessID = supportAccessID
        self.supportExpiresAt = supportExpiresAt
    }
}

/// One row of `GET /api/bloem/v2/organizations`: the account's own membership.
struct OrganizationMembership: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let slug: String
    let name: String
    let isDefault: Bool
    let membershipID: String
    /// `admin` or `user`.
    let membershipRole: String
    let policyRevision: Int64
    let securityRevision: Int64

    enum CodingKeys: String, CodingKey {
        case id, slug, name
        case isDefault = "default"
        case membershipID = "membership_id"
        case membershipRole = "membership_role"
        case policyRevision = "policy_revision"
        case securityRevision = "security_revision"
    }

    init(
        id: String, slug: String = "", name: String, isDefault: Bool = false, membershipID: String,
        membershipRole: String, policyRevision: Int64 = 0, securityRevision: Int64 = 0
    ) {
        self.id = id
        self.slug = slug
        self.name = name
        self.isDefault = isDefault
        self.membershipID = membershipID
        self.membershipRole = membershipRole
        self.policyRevision = policyRevision
        self.securityRevision = securityRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.value(.slug, "")
        name = try c.decode(String.self, forKey: .name)
        isDefault = try c.value(.isDefault, false)
        membershipID = try c.decode(String.self, forKey: .membershipID)
        membershipRole = try c.decode(String.self, forKey: .membershipRole)
        policyRevision = try c.value(.policyRevision, 0)
        securityRevision = try c.value(.securityRevision, 0)
    }
}

struct OrganizationMembershipList: Decodable, Sendable {
    let organizations: [OrganizationMembership]

    enum CodingKeys: String, CodingKey { case organizations }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organizations = try c.value(.organizations, [OrganizationMembership]())
    }
}

/// The web's rule (AdminContextProvider): a platform administrator gets Platform first, then every organization
/// they belong to; anyone else gets only the organizations where their role is `admin`.
func adminContexts(for memberships: [OrganizationMembership], platformAdmin: Bool) -> [AdminContext] {
    var contexts: [AdminContext] = []
    if platformAdmin {
        contexts.append(
            AdminContext(
                key: AdminContext.platformKey, name: String(localized: "Platform"), scope: .platform,
                organizationID: nil, authority: .platformAdmin
            )
        )
    }
    for membership in memberships {
        if !platformAdmin && membership.membershipRole != "admin" { continue }
        contexts.append(
            AdminContext(
                key: AdminContext.organizationKey(membership.id), name: membership.name, scope: .organization,
                organizationID: membership.id, authority: platformAdmin ? .platformAdmin : .organizationAdmin,
                membershipID: membership.membershipID, policyRevision: membership.policyRevision,
                securityRevision: membership.securityRevision
            )
        )
    }
    return contexts
}

extension APIClient {
    /// The contexts `platformAdmin` and the account's memberships add up to. A plain Silo server has none: it is
    /// recognised by `GET /api/bloem/v2/capabilities` (remembered per server) and never asked for organizations. A
    /// server that cannot be asked at all throws. Uses the ACCOUNT token.
    func listAdminContexts(platformAdmin: Bool) async throws -> [AdminContext] {
        guard try await bloemCapabilitiesIfBloem() != nil else { return [] }
        let memberships: [OrganizationMembership]
        do {
            memberships = try await listOrganizationMemberships()
        } catch let error as APIError where error.statusCode == 404 {
            memberships = []
        }
        return adminContexts(for: memberships, platformAdmin: platformAdmin)
    }

    /// Probes platform authority with the admin status route (200 platform administrator, 403 not), then lists
    /// contexts. A 401 or any other failure propagates.
    func discoverAdminContexts() async throws -> [AdminContext] {
        // A plain Silo server has no administrator contexts: nothing more is asked of it.
        guard try await bloemCapabilitiesIfBloem() != nil else { return [] }
        let platformAdmin: Bool
        do {
            _ = try await serverStatus()
            platformAdmin = true
        } catch let error as APIError where error.statusCode == 403 {
            platformAdmin = false
        }
        return try await listAdminContexts(platformAdmin: platformAdmin)
    }
}
