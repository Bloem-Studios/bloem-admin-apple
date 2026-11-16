import Foundation

/*
 The platform's organization routes (Bloem v2). Every call takes a PLATFORM pass as its bearer (`PlatformPass`), never
 the account token. The list call, `listPlatformOrganizations`, lives with the support routes it also serves.

   GET  /admin/platform/organizations/{id}                      one organization with its counts
   GET  /admin/platform/organizations/{id}/memberships          its members, cursor-paged
   POST /admin/platform/organizations/{id}/suspend | reactivate  `expected_revision` is the organization's policy revision
   GET  /admin/platform/organizations/{id}/entitlement          its plan and limits
   POST /admin/platform/organizations/{id}/entitlement/dry-run  what a plan would change, with a one-use token
   POST /admin/platform/organizations/{id}/entitlement/apply    puts the organization on the plan the token was made for
   GET  /admin/platform/entitlement-templates?status=enabled    the plans on offer
 */

private let platformBase = "/api/bloem/v2/admin/platform"

private struct ExpectedRevisionBody: Encodable {
    let expectedRevision: Int64

    enum CodingKeys: String, CodingKey { case expectedRevision = "expected_revision" }
}

private struct PlanSelectionBody: Encodable {
    let templateKey: String
    let templateRevision: Int64

    enum CodingKeys: String, CodingKey {
        case templateKey = "template_key"
        case templateRevision = "template_revision"
    }
}

private struct PlanApplyBody: Encodable {
    let templateKey: String
    let templateRevision: Int64
    let token: String
    let idempotencyKey: String

    enum CodingKeys: String, CodingKey {
        case templateKey = "template_key"
        case templateRevision = "template_revision"
        case token = "dry_run_token"
        case idempotencyKey = "idempotency_key"
    }
}

extension APIClient {
    private func platformOrganizationPath(_ id: String) -> String {
        "\(platformBase)/organizations/\(APIPath.segment(id))"
    }

    /// PLATFORM pass. One organization with its member, profile and library counts.
    func platformOrganization(id: String) async throws -> OrganizationSummary {
        let response: PlatformOrganizationEnvelope = try await get(platformOrganizationPath(id))
        return response.organization
    }

    /// PLATFORM pass. One page of an organization's members; `cursor` is the previous page's `next_cursor`.
    func platformOrganizationMemberships(id: String, cursor: String?, limit: Int = 100) async throws -> PlatformMembershipsPage {
        try await get("\(platformOrganizationPath(id))/memberships", query: ["cursor": cursor ?? "", "limit": String(limit)])
    }

    /// PLATFORM pass. Suspends the organization: its members are blocked until it is reactivated. Sent once.
    /// `expectedRevision` is the organization's `policy_revision` as the person saw it.
    func suspendPlatformOrganization(id: String, expectedRevision: Int64) async throws -> OrganizationSummary {
        let response: PlatformOrganizationEnvelope = try await post(
            "\(platformOrganizationPath(id))/suspend", body: ExpectedRevisionBody(expectedRevision: expectedRevision)
        )
        return response.organization
    }

    /// PLATFORM pass. Lets a suspended organization's members use it again. Sent once.
    func reactivatePlatformOrganization(id: String, expectedRevision: Int64) async throws -> OrganizationSummary {
        let response: PlatformOrganizationEnvelope = try await post(
            "\(platformOrganizationPath(id))/reactivate", body: ExpectedRevisionBody(expectedRevision: expectedRevision)
        )
        return response.organization
    }

    /// PLATFORM pass. The organization's plan, its limits and the default settings the plan gave its members.
    func platformOrganizationEntitlement(id: String) async throws -> OrganizationEntitlement {
        try await get("\(platformOrganizationPath(id))/entitlement")
    }

    /// PLATFORM pass. The plans on offer (enabled, not archived), the latest revision of each.
    func platformEntitlementTemplates() async throws -> [EntitlementTemplate] {
        let list: EntitlementTemplateList = try await get("\(platformBase)/entitlement-templates", query: ["status": "enabled"])
        return list.templates
    }

    /// PLATFORM pass. What putting the organization on a plan would change. Changes nothing; the token it returns
    /// lets `applyPlatformOrganizationEntitlement` apply exactly this change within ten minutes.
    func dryRunPlatformOrganizationEntitlement(id: String, templateKey: String, templateRevision: Int64) async throws -> EntitlementPreview {
        try await post(
            "\(platformOrganizationPath(id))/entitlement/dry-run",
            body: PlanSelectionBody(templateKey: templateKey, templateRevision: templateRevision)
        )
    }

    /// PLATFORM pass. Puts the organization on the plan the preview was made for. `idempotencyKey` names this one
    /// attempt: asking again with the same key answers the first result instead of applying twice.
    func applyPlatformOrganizationEntitlement(
        id: String, templateKey: String, templateRevision: Int64, token: String, idempotencyKey: String
    ) async throws -> EntitlementApplyResult {
        try await post(
            "\(platformOrganizationPath(id))/entitlement/apply",
            body: PlanApplyBody(templateKey: templateKey, templateRevision: templateRevision, token: token, idempotencyKey: idempotencyKey)
        )
    }
}
