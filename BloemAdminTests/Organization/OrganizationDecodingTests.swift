import XCTest
@testable import BloemAdmin

/// Every organization response decodes from a body shaped exactly like the server's handler writes it, and the
/// requests the app sends carry the bodies and query the routes take.
@MainActor
final class OrganizationDecodingTests: XCTestCase {
    typealias F = OrganizationFixtures

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.iso8601.decode(type, from: F.data(json))
    }

    // MARK: Context discovery

    func testMembershipsDecodeWithRolesAndRevisions() throws {
        let list = try decode(OrganizationMembershipList.self, F.memberships(F.membership(), F.membership(id: "o2", name: "Other", role: "user")))
        XCTAssertEqual(list.organizations.map(\.membershipRole), ["admin", "user"])
        XCTAssertEqual(list.organizations[0].policyRevision, 7)
        XCTAssertEqual(list.organizations[0].membershipID, F.membershipID)
    }

    func testAPlatformAdministratorGetsPlatformFirstThenEveryMembership() throws {
        let memberships = [
            OrganizationMembership(id: "o1", name: "Acme", membershipID: "m1", membershipRole: "admin"),
            OrganizationMembership(id: "o2", name: "Other", membershipID: "m2", membershipRole: "user"),
        ]
        let contexts = adminContexts(for: memberships, platformAdmin: true)
        XCTAssertEqual(contexts.map(\.key), ["platform", "organization:o1", "organization:o2"])
        XCTAssertEqual(contexts[0].scope, .platform)
        XCTAssertNil(contexts[0].organizationID)
        XCTAssertEqual(contexts.dropFirst().map(\.authority), [.platformAdmin, .platformAdmin])
    }

    func testAnyoneElseGetsOnlyTheOrganizationsTheyAdminister() throws {
        let memberships = [
            OrganizationMembership(id: "o1", name: "Acme", membershipID: "m1", membershipRole: "admin"),
            OrganizationMembership(id: "o2", name: "Other", membershipID: "m2", membershipRole: "user"),
        ]
        let contexts = adminContexts(for: memberships, platformAdmin: false)
        XCTAssertEqual(contexts.map(\.key), ["organization:o1"])
        XCTAssertEqual(contexts[0].authority, .organizationAdmin)
        XCTAssertEqual(contexts[0].membershipID, "m1")
        XCTAssertTrue(adminContexts(for: [], platformAdmin: false).isEmpty)
    }

    func testListAdminContextsReadsTheAccountsMembershipsAndTreats404AsNone() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", data: F.data(F.memberships(F.membership())))
        let contexts = try await http.client.listAdminContexts(platformAdmin: true)
        XCTAssertEqual(contexts.map(\.name), ["Platform", "Acme Media"])

        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", data: F.data(F.error("not_found")), status: 404)
        let none = try await http.client.listAdminContexts(platformAdmin: true)
        XCTAssertEqual(none.map(\.key), ["platform"], "a server without organizations has only Platform")
    }

    func testDiscoverRunsTheAdminProbeThenLists() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/admin/server/status", data: F.data(F.error("forbidden")), status: 403)
        http.state.stubBloemServer()
        http.state.stub(path: "/api/bloem/v2/organizations", data: F.data(F.memberships(F.membership(), F.membership(id: "o2", name: "Other", role: "user"))))

        let contexts = try await http.client.discoverAdminContexts()

        XCTAssertEqual(contexts.map(\.name), ["Acme Media"])
        XCTAssertEqual(contexts[0].authority, .organizationAdmin)
    }

    func testDiscoverPropagatesAnExpiredSignIn() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubBloemServer()
        http.state.stub(path: "/api/v2/admin/server/status", data: F.data(F.error("unauthorized")), status: 401)
        do {
            _ = try await http.client.discoverAdminContexts()
            XCTFail("a 401 must reach the caller")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }
    }

    // MARK: Responses

    func testOverviewDecodes() throws {
        let summary = try decode(OrganizationOverviewResponse.self, F.overview()).organization
        XCTAssertEqual(summary.name, "Acme Media")
        XCTAssertEqual(summary.ownerAccountID, 4)
        XCTAssertEqual(summary.membershipCount, 12)
        XCTAssertEqual(summary.activeMembershipCount, 10)
        XCTAssertEqual(summary.profileCount, 25)
        XCTAssertEqual(summary.libraryCount, 3)
        XCTAssertEqual(summary.entitlementCount, 2)
        XCTAssertEqual(summary.policyRevision, 7)
    }

    func testPeoplePageDecodesPersonProfilesAndCursor() throws {
        let page = try decode(PeoplePage.self, F.peoplePage(F.person(), F.person(accountID: 6, email: "kim@example.test", name: "", status: "suspended"), next: "next-1", total: 40))
        XCTAssertEqual(page.items.count, 2)
        XCTAssertEqual(page.nextCursor, "next-1")
        XCTAssertEqual(page.approximateTotal, 40)
        let sam = page.items[0]
        XCTAssertEqual(sam.accountID, 5)
        XCTAssertEqual(sam.securityRevision, 4)
        XCTAssertEqual(sam.profiles.first?.groupName, "Family")
        XCTAssertEqual(sam.profiles.first?.groupID, 3)
        XCTAssertTrue(sam.isActive)
        XCTAssertEqual(page.items[1].label, "kim@example.test", "the email stands in for a blank display name")
        XCTAssertTrue(page.items[1].isSuspended)
    }

    func testAPersonWithoutLastActivityDecodes() throws {
        let json = #"{"organization_id":"o","account_id":9,"email":"a@b.c","display_name":"A","membership_id":"m","membership_status":"invited","legacy_role":"user","security_revision":1,"profiles":[]}"#
        let person = try decode(PersonSummary.self, json)
        XCTAssertNil(person.lastActivity)
        XCTAssertEqual(person.membershipStatus, "invited")
    }

    func testAnEmptyCursorMeansNoMorePages() throws {
        let page = try decode(PeoplePage.self, #"{"items":[],"next_cursor":"","approximate_total":0}"#)
        XCTAssertNil(page.nextCursor)
    }

    func testGroupsDecodeWithNullSetsAndStringIDs() throws {
        let groups = try decode(AccessGroupsResponse.self, F.groups(F.group(), F.group(id: "1", name: "Default", isDefault: true))).groups
        XCTAssertEqual(groups[0].id, "3")
        XCTAssertEqual(groups[0].numericID, 3)
        XCTAssertEqual(groups[0].libraryIDs, ["1", "2"])
        XCTAssertNil(groups[0].allowedPermissions)
        XCTAssertEqual(groups[0].memberCount, 6)
        XCTAssertTrue(groups[1].isDefault)
    }

    func testLibrariesDecodeOwnedAndSharedWithEntitlements() throws {
        let libraries = try decode(OrganizationLibrariesResponse.self, F.libraries(
            F.library(),
            F.library(folderID: 2, name: "Shows", kind: "entitled", entitlement: F.entitlement()),
            F.library(folderID: 3, name: "Music", kind: "entitled", entitlement: F.entitlement(status: "suspended", revision: 3))
        )).libraries
        XCTAssertTrue(libraries[0].isOwned)
        XCTAssertTrue(libraries[0].countsTowardCeiling)
        XCTAssertEqual(libraries[1].entitlement?.securityRevision, 9)
        XCTAssertTrue(libraries[1].countsTowardCeiling)
        XCTAssertFalse(libraries[2].countsTowardCeiling, "a paused shared library is not usable now")
    }

    func testInvitationsAndTheHandoffDecode() throws {
        let list = try decode(OrganizationInvitationsResponse.self, F.invitations(F.invitation(), F.invitation(id: "i2", status: "revoked", groupID: nil)))
        XCTAssertEqual(list.invitations.map(\.status), ["pending", "revoked"])
        XCTAssertEqual(list.invitations[0].accessGroupID, "3")
        XCTAssertNil(list.invitations[1].accessGroupID)
        XCTAssertNil(list.invitations[0].libraryIDs)
        XCTAssertTrue(list.invitations[0].isPending)

        let handoff = try decode(InvitationHandoff.self, F.handoff(token: "tok"))
        XCTAssertEqual(handoff.claimToken, "tok")
        XCTAssertEqual(handoff.invitation.id, "i1")
    }

    func testAuditPageDecodes() throws {
        let page = try decode(OrganizationAuditPage.self, F.audit(F.auditEvent(), F.auditEvent(id: 2, action: "something.new"), next: "c2"))
        XCTAssertEqual(page.events.map(\.id), [1, 2])
        XCTAssertEqual(page.events[0].actorAccountID, 4)
        XCTAssertEqual(page.nextCursor, "c2")
    }

    func testCohortsDecodeWithTheirPolicy() throws {
        let cohort = try decode(EntitlementCohortsResponse.self, F.cohorts(F.cohort())).cohorts[0]
        XCTAssertEqual(cohort.name, "Family plan")
        XCTAssertEqual(cohort.sourceTemplateKey, "family")
        XCTAssertEqual(cohort.sourceTemplateRevision, 1)
        XCTAssertEqual(cohort.parentCohortID, "c0")
        XCTAssertEqual(cohort.derivationKind, "exact_template")
        XCTAssertNil(cohort.policy.libraryIDs)
        XCTAssertNil(cohort.policy.audioTranscodeAllowed, "not every server sends it")
        XCTAssertEqual(cohort.policy.maxStreams, 2)
        XCTAssertEqual(cohort.memberCount, 6)
        XCTAssertFalse(cohort.archived)
    }

    func testDecisionsAndTheirDetailDecode() throws {
        let page = try decode(PolicyDecisionsPage.self, F.decisions(F.decision(), F.decision(id: 2, allowed: false), next: "c9"))
        XCTAssertEqual(page.decisions.map(\.allowed), [true, false])
        XCTAssertEqual(page.decisions[0].subject.accountID, 5)
        XCTAssertEqual(page.decisions[0].group.name, "Family")
        XCTAssertEqual(page.decisions[0].resource["library_id"], .number(1))
        XCTAssertEqual(page.nextCursor, "c9")

        let detail = try decode(PolicyDecisionDetailResponse.self, F.decisionDetail()).decision
        XCTAssertEqual(detail.libraryCeiling, [1, 2])
        XCTAssertEqual(detail.organization.membershipID, F.membershipID)
        XCTAssertEqual(detail.resource["token"], .string("[redacted]"))
        XCTAssertEqual(detail.policyVersions?.map(\.version), [4, 2])
        XCTAssertEqual(detail.policyVersions?.last?.name, "Kids rule")
    }

    func testSelectionAndBulkJobDecodeWithNullAndPopulatedRecords() throws {
        let selection = try decode(PeopleSelectionResponse.self, F.selection(token: "t", matched: 12, excluded: 2)).selection
        XCTAssertEqual(selection.matched, 12)
        XCTAssertEqual(selection.excluded, 2)
        XCTAssertFalse("\(selection)".contains("token: t"), "the selection token is redacted when printed")

        let running = try decode(BulkJobResponse.self, F.bulkJob(status: "running", current: 4)).job
        XCTAssertFalse(running.isFinished)
        let done = try decode(BulkJobResponse.self, F.bulkJob(status: "completed", current: 12, succeeded: 10, skipped: F.record(5, "already_applied"), failed: F.record(6, "protected_owner"))).job
        XCTAssertTrue(done.isFinished)
        XCTAssertEqual(done.skipped, [BulkRecordResult(accountID: 5, reason: "already_applied")])
        XCTAssertEqual(done.failed.first?.reason, "protected_owner")

        let nulls = try decode(BulkJobResponse.self, #"{"job":{"job_id":"j","status":"queued","progress_current":0,"progress_total":0,"succeeded":0,"skipped":null,"failed":null}}"#).job
        XCTAssertTrue(nulls.skipped.isEmpty)
    }

    func testGroupMutationAndDeletionImpactDecode() throws {
        let mutation = try decode(OrganizationGroupMutationResponse.self, F.groupMutation(policyRevision: 8))
        XCTAssertEqual(mutation.group.name, "Family")
        XCTAssertEqual(mutation.policyRevision, 8)
        let impact = try decode(GroupDeletionImpact.self, F.deletionImpact(reassigned: 4, defaultGroup: 3))
        XCTAssertEqual(impact, GroupDeletionImpact(profilesReassigned: 4, defaultGroupID: 3))
    }

    func testOneMalformedRowFailsTheAnswerInsteadOfEmptyingTheList() {
        // A person without its required security_revision: the page must say it could not read the answer, not
        // "there is nobody in this organization".
        let broken = #"{"organization_id":"o","account_id":6,"email":"a@b.c","display_name":"A","membership_id":"m","membership_status":"active","legacy_role":"user","profiles":[]}"#
        XCTAssertThrowsError(try decode(PeoplePage.self, F.peoplePage(F.person(), broken)))
        // A membership without its role: the gate must not quietly conclude the account administers nothing.
        let membership = #"{"id":"o2","slug":"x","name":"X","default":false,"membership_id":"m2","policy_revision":1,"security_revision":1}"#
        XCTAssertThrowsError(try decode(OrganizationMembershipList.self, F.memberships(F.membership(), membership)))
        XCTAssertThrowsError(try decode(BulkJobResponse.self, F.bulkJob(skipped: #"{"reason":"x"}"#)))
        // A field of the wrong type fails too, instead of turning into a default.
        XCTAssertThrowsError(try decode(OrganizationOverviewResponse.self, F.overview().replacingOccurrences(of: #""membership_count":12"#, with: #""membership_count":"12""#)))
    }

    func testMissingAndNullOptionalFieldsStillDecodeToTheirDefaults() throws {
        let page = try decode(PeoplePage.self, #"{"items":null,"approximate_total":0}"#)
        XCTAssertTrue(page.items.isEmpty)
        let job = try decode(BulkJobResponse.self, #"{"job":{"job_id":"j","status":"queued"}}"#).job
        XCTAssertTrue(job.skipped.isEmpty)
        XCTAssertEqual(job.progressTotal, 0)
    }

    func testAnUnknownFutureStatusDoesNotFailTheList() throws {
        let page = try decode(PeoplePage.self, F.peoplePage(F.person(status: "archived-in-the-future")))
        XCTAssertEqual(page.items[0].membershipStatus, "archived-in-the-future")
    }

    // MARK: Requests

    func testPeopleListSendsEveryFilterAsTheServerTakesIt() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/people", data: F.data(F.peoplePage()))

        _ = try await http.client.listOrganizationPeople(
            filter: PeopleFilter(query: "  sam ", statuses: ["suspended", "active"], groupID: 3, sort: "recent_activity", activeSince: "2026-11-01T00:00:00Z"),
            cursor: "c1", limit: 25
        )

        let items = URLComponents(url: try XCTUnwrap(http.state.requestLog.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "query": "sam", "status": "active,suspended", "group_id": "3", "sort": "recent_activity",
            "active_since": "2026-11-01T00:00:00Z", "cursor": "c1", "limit": "25",
        ])
    }

    func testAnEmptyPeopleFilterSendsOnlyTheLimit() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/people", data: F.data(F.peoplePage()))
        _ = try await http.client.listOrganizationPeople(filter: PeopleFilter(), cursor: nil)
        let items = URLComponents(url: try XCTUnwrap(http.state.requestLog.first?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.map(\.name), ["limit"])
    }

    func testMembershipAndProfileWritesQuoteThePersonRevision() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/people/5/memberships/current", data: F.data(F.personResponse(F.person(status: "suspended", revision: 5))))
        http.state.stub(path: "\(F.base)/people/5/profiles/p 1", data: F.data(F.personResponse()))

        let suspended = try await http.client.setOrganizationMembershipStatus(accountID: 5, status: "suspended", revision: 4)
        XCTAssertTrue(suspended.isSuspended)
        XCTAssertEqual(http.state.requestLog[0].httpMethod, "PATCH")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: "\(F.base)/people/5/memberships/current", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(body["expected_revision"] as? Int, 4)
        XCTAssertEqual(body["status"] as? String, "suspended")

        _ = try await http.client.setOrganizationProfileGroup(accountID: 5, profileID: "p 1", groupID: 3, revision: 4)
        XCTAssertEqual(http.state.requestLog[1].url?.absoluteString.hasSuffix("/people/5/profiles/p%201"), true, "the id is one encoded path segment")
        let profileBody = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: "\(F.base)/people/5/profiles/p 1", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(profileBody["group_id"] as? Int, 3)
        XCTAssertEqual(profileBody["expected_revision"] as? Int, 4)
    }

    func testDeletesCarryTheirRevisionInABody() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/entitlements/2", data: Data(), status: 204)
        http.state.stub(path: "\(F.base)/invitations/i1", data: Data(), status: 204)
        http.state.stub(path: "\(F.base)/groups/3", data: F.data(F.deletionImpact()))

        try await http.client.deleteOrganizationEntitlement(folderID: 2, revision: 9)
        try await http.client.revokeOrganizationInvitation(id: "i1", revision: 7)
        let impact = try await http.client.deleteOrganizationGroup(id: 3, revision: 7)

        XCTAssertEqual(impact.profilesReassigned, 4)
        for (path, revision) in [("\(F.base)/entitlements/2", 9), ("\(F.base)/invitations/i1", 7), ("\(F.base)/groups/3", 7)] {
            let request = try XCTUnwrap(http.state.requests(path: path).first)
            XCTAssertEqual(request.httpMethod, "DELETE")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: path, requestIndex: 0))) as? [String: Int])
            XCTAssertEqual(body, ["expected_revision": revision], path)
        }
    }

    func testTheGroupWriteAlwaysSendsNullForEveryLibraryAndEveryPermission() throws {
        var draft = AccessGroupDraft(group: OrganizationAccessGroup(id: "3", name: "Family", libraryIDs: nil, allowedPermissions: nil))
        draft.name = "  Kids "
        let data = try JSONEncoder().encode(draft.body(revision: 7))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(object["library_ids"] is NSNull, "null means every library; leaving the field out would keep the old value")
        XCTAssertTrue(object["allowed_permissions"] is NSNull)
        XCTAssertEqual(object["name"] as? String, "Kids")
        XCTAssertEqual(object["expected_revision"] as? Int, 7)
    }

    func testTheGroupWriteSortsLibrariesNumericallyAndNeverSavesConvertedDownloadsWithoutDownloads() throws {
        var draft = AccessGroupDraft(group: OrganizationAccessGroup(id: "3", name: "Family", libraryIDs: ["10", "2", "1"]))
        draft.downloadAllowed = false
        draft.downloadTranscodeAllowed = true
        let body = draft.body(revision: 1)
        XCTAssertEqual(body.libraryIDs, ["1", "2", "10"])
        XCTAssertFalse(body.downloadTranscodeAllowed)
    }

    func testAnEditorKeepsItsDraftUntilTheServersGroupChangesThenStartsAgainFromIt() throws {
        let original = OrganizationAccessGroup(id: "3", name: "Family", maxRemoteStreamBitrateKbps: 8_000, maxProfiles: 5)
        var draft = AccessGroupDraft(group: original)
        draft.name = "Family, edited"

        // The first time, the draft comes from the list.
        XCTAssertEqual(AccessGroupDraft.reconciled(draft: nil, original: nil, reloaded: original)?.draft, AccessGroupDraft(group: original))
        // A reload that finds the same group keeps what is being typed.
        XCTAssertNil(AccessGroupDraft.reconciled(draft: draft, original: original, reloaded: original))
        // Another administrator changed a field the editor does not show: the next save must not send the old value back.
        let changed = OrganizationAccessGroup(id: "3", name: "Family", maxRemoteStreamBitrateKbps: 4_000, maxProfiles: 2)
        let next = try XCTUnwrap(AccessGroupDraft.reconciled(draft: draft, original: original, reloaded: changed))
        XCTAssertEqual(next.original, changed)
        XCTAssertEqual(next.draft.body(revision: 9).maxProfiles, 2)
        XCTAssertEqual(next.draft.body(revision: 9).maxRemoteStreamBitrateKbps, 4_000)
        // The group went away (deleted elsewhere): nothing to rebase onto.
        XCTAssertNil(AccessGroupDraft.reconciled(draft: draft, original: original, reloaded: nil))
    }

    func testTheInvitationBodyCarriesThePolicyRevisionAndOmitsAnEmptyNote() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/invitations", data: F.data(F.handoff()), status: 201)

        let handoff = try await http.client.createOrganizationInvitation(
            CreateOrganizationInvitation(email: "new@example.test", expectedRevision: 7, accessGroupID: 3, note: nil)
        )

        XCTAssertEqual(handoff.claimToken, "claim-token-value")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: "\(F.base)/invitations", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(body["email"] as? String, "new@example.test")
        XCTAssertEqual(body["expected_revision"] as? Int, 7)
        XCTAssertEqual(body["access_group_id"] as? Int, 3)
        XCTAssertNil(body["note"])
    }

    func testTheSelectionRequestKeepsEmptyListsLikeTheWeb() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/people/selections", data: F.data(F.selection()), status: 201)

        _ = try await http.client.createOrganizationSelection(filter: PeopleFilter(query: " sam "))

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: "\(F.base)/people/selections", requestIndex: 0))) as? [String: Any])
        XCTAssertEqual(body["query"] as? String, "sam")
        XCTAssertEqual(body["status"] as? [String], [])
        XCTAssertEqual(body["group_ids"] as? [Int], [])
        XCTAssertEqual(body["sort"] as? String, "name")
        XCTAssertNil(body["active_since"])
    }

    func testNoRequestEverNamesAnOrganizationInAPath() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = F.data(F.groups())
        _ = try? await http.client.listOrganizationGroups()
        _ = try? await http.client.organizationOverview()
        for request in http.state.requestLog {
            XCTAssertFalse(request.url?.path.contains(F.orgID) ?? true)
        }
    }

    // MARK: Words

    func testVocabularyReadsLikeTheWebAndFallsBackToSentenceCase() {
        XCTAssertEqual(OrganizationVocabulary.resultReasonText("already_applied"), "already had these settings")
        XCTAssertEqual(OrganizationVocabulary.resultReasonText("brand_new_reason"), "Brand new reason")
        XCTAssertEqual(OrganizationVocabulary.auditActionText("people.bulk_job_created"), "Bulk change started")
        XCTAssertEqual(OrganizationVocabulary.auditActionText("people.something_new"), "People something new")
        XCTAssertEqual(OrganizationVocabulary.accessReasonText(""), "No reason recorded")
        XCTAssertEqual(OrganizationVocabulary.qualityText("2160p"), "Up to 4K")
        XCTAssertEqual(PlaybackQuality.canonical("original"), PlaybackQuality.any)
        XCTAssertEqual(PlaybackQuality.canonical("720p"), PlaybackQuality.upTo1080p)
        XCTAssertNil(OrganizationVocabulary.auditOutcome("success"))
        XCTAssertEqual(OrganizationVocabulary.auditOutcome("partial_failure"), "Some not changed")
        let job = BulkJob(jobID: "j", status: "completed", succeeded: 0, skipped: [BulkRecordResult(accountID: 1, reason: "x")])
        XCTAssertEqual(OrganizationVocabulary.bulkHeading(job), "Nobody was changed")
    }
}
