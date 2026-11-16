import Foundation

/*
 Administrative context and organization routes (Bloem v2).

 Two kinds of bearer, never mixed:
  - the ACCOUNT token (the normal sign-in) is for `listOrganizationMemberships` and `mintAdminSession` only;
  - the CONTEXT PASS that `mintAdminSession` returns is the bearer for every /admin/organization route.
 `OrganizationSession` owns both clients; pages receive only the pass client, through `read` and `write`.

 The organization id never appears in these paths: the server reads it from the pass.
 */

private let organizationBase = "/api/bloem/v2/admin/organization"

extension APIClient {
    /// Account token. The account's own active memberships, with their roles.
    func listOrganizationMemberships() async throws -> [OrganizationMembership] {
        let list: OrganizationMembershipList = try await get("/api/bloem/v2/organizations")
        return list.organizations
    }

    /// Account token. Exchanges the login session for a short-lived context pass.
    func mintAdminSession(_ body: AdminSessionRequest) async throws -> AdminSessionResponse {
        try await post("/api/bloem/v2/admin/session", body: body)
    }

    /// Context pass. Counts, owner and the policy revision.
    func organizationOverview() async throws -> OrganizationSummary {
        let response: OrganizationOverviewResponse = try await get("\(organizationBase)/overview")
        return response.organization
    }

    /// Context pass. One page of people; `cursor` is the previous page's `next_cursor`.
    func listOrganizationPeople(filter: PeopleFilter, cursor: String?, limit: Int = 50) async throws -> PeoplePage {
        try await get(
            "\(organizationBase)/people",
            query: [
                "query": filter.query.trimmingCharacters(in: .whitespacesAndNewlines),
                "status": filter.statuses.sorted().joined(separator: ","),
                "group_id": filter.groupID.map(String.init) ?? "",
                "sort": filter.sort ?? "",
                "active_since": filter.activeSince ?? "",
                "cursor": cursor ?? "",
                "limit": String(limit),
            ]
        )
    }

    /// Context pass. One person, with the profiles and the revision a write must quote.
    func organizationPerson(accountID: Int64) async throws -> PersonSummary {
        let response: PersonResponse = try await get("\(organizationBase)/people/\(accountID)")
        return response.person
    }

    /// Context pass. Suspends or reactivates a membership; `revision` is the person's `security_revision`.
    func setOrganizationMembershipStatus(accountID: Int64, status: String, revision: Int64) async throws -> PersonSummary {
        let response: PersonResponse = try await patch(
            "\(organizationBase)/people/\(accountID)/memberships/current",
            body: MembershipStatusUpdate(expectedRevision: revision, status: status)
        )
        return response.person
    }

    /// Context pass. Moves one profile to an access group; `revision` is the person's `security_revision`.
    func setOrganizationProfileGroup(accountID: Int64, profileID: String, groupID: Int64, revision: Int64) async throws -> PersonSummary {
        let response: PersonResponse = try await patch(
            "\(organizationBase)/people/\(accountID)/profiles/\(APIPath.segment(profileID))",
            body: ProfileGroupUpdate(expectedRevision: revision, groupID: groupID)
        )
        return response.person
    }

    /// Context pass. Every access group with its member count.
    func listOrganizationGroups() async throws -> [OrganizationAccessGroup] {
        let response: AccessGroupsResponse = try await get("\(organizationBase)/groups")
        return response.groups
    }

    /// Context pass. Libraries the organization owns or is entitled to.
    func listOrganizationLibraries() async throws -> [OrganizationLibrary] {
        let response: OrganizationLibrariesResponse = try await get("\(organizationBase)/libraries")
        return response.libraries
    }

    /// Context pass. Pauses (`suspended`) or restores (`active`); `revision` is the entitlement's `security_revision`.
    func setOrganizationEntitlementStatus(folderID: Int64, status: String, revision: Int64) async throws -> LibraryEntitlement {
        let response: OrganizationEntitlementResponse = try await put(
            "\(organizationBase)/entitlements/\(folderID)",
            body: EntitlementStatusUpdate(expectedRevision: revision, status: status)
        )
        return response.entitlement
    }

    /// Context pass. Gives a shared library back for good; `revision` is the entitlement's `security_revision`. Answers 204.
    func deleteOrganizationEntitlement(folderID: Int64, revision: Int64) async throws {
        try await delete("\(organizationBase)/entitlements/\(folderID)", body: RevisionBody(expectedRevision: revision))
    }

    /// Context pass. Newest first.
    func listOrganizationInvitations() async throws -> [OrganizationInvitation] {
        let response: OrganizationInvitationsResponse = try await get("\(organizationBase)/invitations")
        return response.invitations
    }

    /// Context pass. One submission: the answer holds the only copy of the claim token.
    func createOrganizationInvitation(_ body: CreateOrganizationInvitation) async throws -> InvitationHandoff {
        try await post("\(organizationBase)/invitations", body: body)
    }

    /// Context pass. Replaces the claim token. One submission, for the same reason as create.
    func resendOrganizationInvitation(id: String, revision: Int64) async throws -> InvitationHandoff {
        try await post(
            "\(organizationBase)/invitations/\(APIPath.segment(id))/resend",
            body: RevisionBody(expectedRevision: revision)
        )
    }

    /// Context pass. DELETE carries the policy revision in a JSON body; the answer is 204.
    func revokeOrganizationInvitation(id: String, revision: Int64) async throws {
        try await delete("\(organizationBase)/invitations/\(APIPath.segment(id))", body: RevisionBody(expectedRevision: revision))
    }

    /// Context pass. One page of changes to the organization, newest first.
    func listOrganizationActivity(cursor: String?) async throws -> OrganizationAuditPage {
        try await get("\(organizationBase)/activity", query: ["cursor": cursor ?? ""])
    }

    /// Context pass. Read-only.
    func listOrganizationCohorts(includeArchived: Bool) async throws -> [EntitlementCohort] {
        let response: EntitlementCohortsResponse = try await get(
            "\(organizationBase)/entitlement-cohorts",
            query: includeArchived ? ["include_archived": "true"] : [:]
        )
        return response.cohorts
    }

    /// Context pass. Read-only; newest first.
    func listOrganizationPolicyDecisions(cursor: String?, limit: Int = 50) async throws -> PolicyDecisionsPage {
        try await get("\(organizationBase)/policy-decisions", query: ["cursor": cursor ?? "", "limit": String(limit)])
    }

    /// Context pass. One policy check with the rules the server applied.
    func organizationPolicyDecision(id: Int64) async throws -> PolicyDecisionDetail {
        let response: PolicyDecisionDetailResponse = try await get("\(organizationBase)/policy-decisions/\(id)")
        return response.decision
    }

    // MARK: Several people, and access groups

    /// Context pass. Freezes everyone the filter matches into a selection the server remembers for a while. It
    /// changes nothing, so a renewed pass may ask again. The server takes the filter without a limit or cursor.
    func createOrganizationSelection(filter: PeopleFilter) async throws -> PeopleSelection {
        let response: PeopleSelectionResponse = try await post(
            "\(organizationBase)/people/selections",
            body: PeopleSelectionRequest(
                query: filter.query.trimmingCharacters(in: .whitespacesAndNewlines),
                status: filter.statuses.sorted(),
                groupIDs: filter.groupID.map { [$0] } ?? [],
                sort: filter.sort ?? PeopleSort.name,
                activeSince: filter.activeSince
            )
        )
        return response.selection
    }

    /// Context pass. Starts a bulk change over a selection: `assign_group`, `suspend_memberships` or
    /// `reactivate_memberships`. Sent once: a lost answer is not retried, because the job may exist.
    func startOrganizationBulkJob(selectionToken: String, kind: String, groupID: Int64? = nil) async throws -> BulkJob {
        let response: BulkJobResponse = try await post(
            "\(organizationBase)/people/bulk-jobs",
            body: BulkJobRequest(selectionToken: selectionToken, kind: kind, groupID: groupID)
        )
        return response.job
    }

    /// Context pass. A job's progress and what it skipped or could not change.
    func organizationBulkJob(id: String) async throws -> BulkJob {
        let response: BulkJobResponse = try await get("\(organizationBase)/people/bulk-jobs/\(APIPath.segment(id))")
        return response.job
    }

    /// Context pass. A new group with the server's defaults; `revision` is the organization policy revision.
    func createOrganizationGroup(name: String, revision: Int64) async throws -> OrganizationAccessGroup {
        let response: OrganizationGroupMutationResponse = try await post(
            "\(organizationBase)/groups",
            body: AccessGroupCreateBody(expectedRevision: revision, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        return response.group
    }

    /// Context pass. Saves a group; `body` carries the organization policy revision.
    func updateOrganizationGroup(id: Int64, body: AccessGroupWrite) async throws -> OrganizationAccessGroup {
        let response: OrganizationGroupMutationResponse = try await put("\(organizationBase)/groups/\(id)", body: body)
        return response.group
    }

    /// Context pass. Deletes a group; its profiles move to the default group. DELETE carries the revision in a body.
    func deleteOrganizationGroup(id: Int64, revision: Int64) async throws -> GroupDeletionImpact {
        try await deleteDecoding("\(organizationBase)/groups/\(id)", body: RevisionBody(expectedRevision: revision))
    }
}
