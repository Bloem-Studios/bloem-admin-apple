import Foundation

/// `GET /api/bloem/v2/admin/platform/tenants` row. Bloem-specific (multi-tenant
/// reseller/hosting); the route needs the platform pass, so the Tenants tab is hidden for now.
///
/// `externalRef` (the `{"operator_id":..., "service_id":...}` object) is
/// deliberately NOT modeled — nothing in this read-only screen displays it,
/// and `Decodable` tolerates the extra key being present without a matching
/// property.
struct Tenant: Decodable, Identifiable, Equatable {
    let tenantId: String
    let name: String
    let limits: TenantLimits?
    let usage: TenantUsage?
    let frozen: Bool
    let frozenReason: String?
    let appliedEntitlementRevision: Int?

    var id: String { tenantId }

    enum CodingKeys: String, CodingKey {
        case tenantId = "tenant_id"
        case name
        case limits
        case usage
        case frozen
        case frozenReason = "frozen_reason"
        case appliedEntitlementRevision = "applied_entitlement_revision"
    }

    /// "7 / 10 slots" when both usage and limit are known; degrades
    /// gracefully (rather than crashing or showing "nil") when either side
    /// is missing, since `limits`/`usage` are both optional top-level
    /// objects the server could plausibly omit.
    var slotsUsageText: String {
        switch (usage?.slotsUsed, limits?.slots) {
        case let (used?, total?):
            return String(localized: "\(used) / \(total) slots")
        case let (used?, nil):
            return String(localized: "\(used) slots used")
        case let (nil, total?):
            return String(localized: "0 / \(total) slots")
        case (nil, nil):
            return String(localized: "No slot data")
        }
    }

    var transcodeLimitText: String {
        if let transcodes = limits?.transcodes {
            return transcodes == 1 ? String(localized: "1 transcode") : String(localized: "\(transcodes) transcodes")
        }
        return String(localized: "No transcode limit set")
    }
}

struct TenantLimits: Decodable, Equatable {
    let slots: Int?
    let transcodes: Int?
}

struct TenantUsage: Decodable, Equatable {
    let slotsUsed: Int?

    enum CodingKeys: String, CodingKey {
        case slotsUsed = "slots_used"
    }
}

/// `GET /api/bloem/v2/admin/platform/tenants/{tenant_id}/members` row.
struct TenantMember: Decodable, Identifiable, Equatable {
    let userId: Int
    let username: String
    let email: String
    let status: String

    var id: Int { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case username
        case email
        case status
    }
}
