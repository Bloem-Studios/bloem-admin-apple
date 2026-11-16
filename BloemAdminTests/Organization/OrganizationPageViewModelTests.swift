import XCTest
@testable import BloemAdmin

@MainActor
final class OrganizationPageViewModelTests: XCTestCase {
    typealias F = OrganizationFixtures

    // MARK: Overview

    func testOverviewLoadsAndReportsAFailure() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/overview", F.overview())
        let model = OrganizationOverviewViewModel()

        await model.load(session: session)
        XCTAssertEqual(model.summary?.name, "Acme Media")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoading)

        http.state.stubOrganization("/overview", F.error("boom", message: "Server fell over"), status: 500)
        await model.load(session: session)
        XCTAssertEqual(model.errorMessage, "Server fell over")
        XCTAssertEqual(model.summary?.name, "Acme Media", "the last good answer stays on screen under the message")
    }

    func testOverviewNamesTheOwnerFromThePeopleRouteNeverByAccountNumber() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/overview", F.overview())
        http.state.stubOrganization("/people/4", F.personResponse(F.person(accountID: 4, email: "avery@example.test", name: "Avery Ames")))
        let model = OrganizationOverviewViewModel()

        await model.load(session: session)

        XCTAssertEqual(model.ownerText, "Avery Ames")
        XCTAssertFalse(model.ownerText.contains("4"))
        XCTAssertEqual(http.state.organizationRequests("/people/4").first?.httpMethod, "GET")
    }

    func testOverviewNamesAnOwnerWithNoDisplayNameByEmail() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/overview", F.overview())
        http.state.stubOrganization("/people/4", F.personResponse(F.person(accountID: 4, email: "avery@example.test", name: "")))
        let model = OrganizationOverviewViewModel()

        await model.load(session: session)

        XCTAssertEqual(model.ownerText, "avery@example.test")
    }

    func testOverviewAnOwnerWhoCannotBeReadIsSaidToBeUnavailableNotShownAsANumber() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/overview", F.overview())
        http.state.stubOrganization("/people/4", F.error("not_found"), status: 404)
        let model = OrganizationOverviewViewModel()

        await model.load(session: session)

        XCTAssertEqual(model.summary?.name, "Acme Media", "the page still shows")
        XCTAssertEqual(model.ownerText, "Not available")
        XCTAssertNil(model.errorMessage, "a missing name is not a failure of the page")
    }

    func testOverviewWithNoOwnerSaysNobodyYet() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/overview", F.overview().replacingOccurrences(of: #""owner_account_id":4,"#, with: ""))
        let model = OrganizationOverviewViewModel()

        await model.load(session: session)

        XCTAssertEqual(model.ownerText, "Nobody yet")
        XCTAssertTrue(http.state.organizationRequests("/people/4").isEmpty)
    }

    func testOverviewAForbiddenAnswerRecordsWhyAndNamesIt() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/overview", F.error("organization_suspended"), status: 403)
        let model = OrganizationOverviewViewModel()

        await model.load(session: session)

        XCTAssertEqual(model.errorMessage, OrganizationDenial.suspended.message)
        XCTAssertEqual(session.denial, .suspended)
    }

    // MARK: Libraries

    private func librariesBody() -> String {
        F.libraries(
            F.library(),
            F.library(folderID: 2, name: "Shows", kind: "entitled", entitlement: F.entitlement(status: "active", revision: 9)),
            F.library(folderID: 3, name: "Music", kind: "entitled", entitlement: F.entitlement(status: "suspended", revision: 5))
        )
    }

    func testPausingASharedLibraryQuotesItsEntitlementRevisionAndUpdatesTheRow() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/entitlements/2", #"{"entitlement":\#(F.entitlement(status: "suspended", revision: 10))}"#)
        let model = OrganizationLibrariesViewModel()
        await model.load(session: session)
        let shows = try XCTUnwrap(model.libraries.first { $0.folderID == 2 })

        await model.setStatus(session: session, library: shows, status: "suspended")

        XCTAssertEqual(http.state.organizationRequests("/entitlements/2").first?.httpMethod, "PUT")
        XCTAssertEqual(http.state.organizationBody("/entitlements/2")?["expected_revision"] as? Int, 9)
        XCTAssertEqual(http.state.organizationBody("/entitlements/2")?["status"] as? String, "suspended")
        XCTAssertEqual(model.libraries.first { $0.folderID == 2 }?.entitlement?.status, "suspended")
        XCTAssertEqual(model.libraries.first { $0.folderID == 2 }?.entitlement?.securityRevision, 10)
        XCTAssertEqual(model.notice, "Library paused. Members can't use it until you restore it.")
    }

    func testAnOwnedLibraryIsNeverPausedOrGivenBack() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/libraries", librariesBody())
        let model = OrganizationLibrariesViewModel()
        await model.load(session: session)
        let films = try XCTUnwrap(model.libraries.first { $0.folderID == 1 })

        await model.setStatus(session: session, library: films, status: "suspended")
        await model.giveBack(session: session, library: films)

        XCTAssertTrue(http.state.organizationRequests("/entitlements/1").isEmpty)
    }

    func testGivingALibraryBackSendsADeleteWithTheRevisionThenReadsTheListAgain() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stub(path: "\(F.base)/entitlements/2", data: Data(), status: 204)
        let model = OrganizationLibrariesViewModel()
        await model.load(session: session)
        let shows = try XCTUnwrap(model.libraries.first { $0.folderID == 2 })

        await model.giveBack(session: session, library: shows)

        XCTAssertEqual(http.state.organizationRequests("/entitlements/2").first?.httpMethod, "DELETE")
        XCTAssertEqual(http.state.organizationBody("/entitlements/2")?["expected_revision"] as? Int, 9)
        XCTAssertEqual(http.state.organizationRequests("/libraries").count, 2, "the list is read back, not guessed")
        XCTAssertEqual(model.notice, "Library given back")
    }

    func testAWithdrawnLibraryCannotBeGivenBackAgain() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/libraries", F.libraries(F.library(folderID: 4, name: "Old", kind: "entitled", entitlement: F.entitlement(status: "revoked", revision: 2))))
        let model = OrganizationLibrariesViewModel()
        await model.load(session: session)

        await model.giveBack(session: session, library: model.libraries[0])

        XCTAssertTrue(http.state.organizationRequests("/entitlements/4").isEmpty)
    }

    func testAFailedLibraryWriteReloadsTheListAndSaysWhy() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/entitlements/2", F.error("authorization_state_changed"), status: 409)
        let model = OrganizationLibrariesViewModel()
        await model.load(session: session)

        await model.setStatus(session: session, library: model.libraries[1], status: "suspended")

        XCTAssertEqual(http.state.organizationRequests("/entitlements/2").count, 1, "never replayed")
        XCTAssertEqual(http.state.organizationRequests("/libraries").count, 2, "reloaded")
        XCTAssertEqual(model.errorMessage, "Someone else changed this just now. It has been reloaded; check it and try again.")
        XCTAssertTrue(model.pendingFolderIDs.isEmpty)
    }

    // MARK: Activity

    func testActivityPagesOlderEntriesWithoutRepeatingOnes() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubSequence(path: "\(F.base)/activity", responses: [
            MockHTTPResponse(data: F.data(F.audit(F.auditEvent(id: 2), F.auditEvent(id: 1), next: "c2"))),
            MockHTTPResponse(data: F.data(F.audit(F.auditEvent(id: 1), F.auditEvent(id: 0)))),
        ])
        let model = OrganizationActivityViewModel()

        await model.load(session: session)
        XCTAssertEqual(model.events.map(\.id), [2, 1])
        XCTAssertEqual(model.nextCursor, "c2")

        await model.loadOlder(session: session)
        XCTAssertEqual(model.events.map(\.id), [2, 1, 0])
        XCTAssertNil(model.nextCursor)
        let cursor = URLComponents(url: try XCTUnwrap(http.state.organizationRequests("/activity").last?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(cursor?.first { $0.name == "cursor" }?.value, "c2")
    }

    // MARK: Cohorts and decisions

    func testCohortsSeparateArchivedOnesAndNameLibraries() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/entitlement-cohorts", F.cohorts(F.cohort(), F.cohort(id: "c2", name: "Old plan", archived: true)))
        http.state.stubOrganization("/libraries", librariesBody())
        let model = OrganizationCohortsViewModel()

        await model.load(session: session)

        XCTAssertEqual(model.activeCohorts.map(\.name), ["Family plan"])
        XCTAssertEqual(model.archivedCohorts.map(\.name), ["Old plan"])
        XCTAssertEqual(model.libraryNames(for: PolicyView(libraryIDs: [1, 99])), ["Films", "Library 99"])
        XCTAssertNil(model.libraryNames(for: PolicyView(libraryIDs: nil)), "no list means every library")
        let query = URLComponents(url: try XCTUnwrap(http.state.organizationRequests("/entitlement-cohorts").first?.url), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "include_archived" }?.value, "true")
    }

    func testDecisionsListLoadMoreAndOpenDetail() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubSequence(path: "\(F.base)/policy-decisions", responses: [
            MockHTTPResponse(data: F.data(F.decisions(F.decision(id: 2), next: "c1"))),
            MockHTTPResponse(data: F.data(F.decisions(F.decision(id: 2), F.decision(id: 1, allowed: false)))),
        ])
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/policy-decisions/2", F.decisionDetail(id: 2))
        let model = OrganizationDecisionsViewModel()

        await model.load(session: session)
        await model.loadMore(session: session)
        XCTAssertEqual(model.decisions.map(\.id), [2, 1])

        await model.open(session: session, id: 2)
        XCTAssertEqual(model.detail?.id, 2)
        XCTAssertEqual(model.detail?.policyVersions?.count, 2)
        XCTAssertEqual(model.libraryName(1), "Films")
        model.close()
        XCTAssertNil(model.detail)
        XCTAssertNil(model.selectedID)
    }

    func testAFailedDecisionDetailIsShownWithoutLosingTheList() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/policy-decisions", F.decisions(F.decision()))
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/policy-decisions/1", F.error("not_found", message: "No such check"), status: 404)
        let model = OrganizationDecisionsViewModel()
        await model.load(session: session)

        await model.open(session: session, id: 1)

        XCTAssertEqual(model.detailErrorMessage, "No such check")
        XCTAssertEqual(model.decisions.count, 1)
    }

    // MARK: Access groups

    func testCreatingAGroupQuotesThePolicyRevisionRenewsThePassAndReloads() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubOrganization("/libraries", librariesBody())
        let model = OrganizationGroupsViewModel()
        await model.load(session: session)
        http.state.stubOrganization("/groups", F.groupMutation(group: F.group(id: "9", name: "Kids"), policyRevision: 8), status: 201)

        await model.create(session: session, name: " Kids ")

        let request = http.state.organizationRequests("/groups").first { $0.httpMethod == "POST" }
        XCTAssertNotNil(request)
        XCTAssertEqual(http.state.organizationBody("/groups", index: 1)?["name"] as? String, "Kids")
        XCTAssertEqual(http.state.organizationBody("/groups", index: 1)?["expected_revision"] as? Int, 7)
        XCTAssertEqual(model.createdID, "9")
        XCTAssertEqual(model.notice, "Group created")
        XCTAssertEqual(http.state.requests(path: "/api/bloem/v2/admin/session").count, 2, "the pass is renewed after a group write")
    }

    func testAGroupNeedsAName() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        let model = OrganizationGroupsViewModel()

        await model.create(session: session, name: "   ")

        XCTAssertEqual(model.errorMessage, "Enter a name for the group")
        XCTAssertTrue(http.state.organizationRequests("/groups").isEmpty)
    }

    func testSavingAGroupSendsTheWholeGroupWithItsRevision() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        let group = OrganizationAccessGroup(id: "3", name: "Family", libraryIDs: ["1"], maxStreams: 2)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/groups/3", F.groupMutation(), status: 200)
        let model = OrganizationGroupsViewModel()
        var draft = AccessGroupDraft(group: group)
        draft.name = "Family 2"
        draft.maxStreams = 4

        await model.save(session: session, group: group, draft: draft)

        XCTAssertEqual(http.state.organizationRequests("/groups/3").first?.httpMethod, "PUT")
        let body = try XCTUnwrap(http.state.organizationBody("/groups/3"))
        XCTAssertEqual(body["name"] as? String, "Family 2")
        XCTAssertEqual(body["max_streams"] as? Int, 4)
        XCTAssertEqual(body["expected_revision"] as? Int, 7)
        XCTAssertEqual(body["library_ids"] as? [String], ["1"])
        XCTAssertEqual(model.notice, "Group saved")
    }

    func testDeletingAGroupReportsHowManyProfilesMoved() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/groups/3", F.deletionImpact(reassigned: 4, defaultGroup: 1))
        let model = OrganizationGroupsViewModel()
        await model.load(session: session)

        let deleted = await model.delete(session: session, group: model.groups[0])

        XCTAssertTrue(deleted)
        XCTAssertEqual(model.lastDeletion, GroupDeletionImpact(profilesReassigned: 4, defaultGroupID: 1))
        XCTAssertEqual(http.state.organizationRequests("/groups/3").first?.httpMethod, "DELETE")
        XCTAssertEqual(http.state.organizationBody("/groups/3")?["expected_revision"] as? Int, 7)
    }

    func testADefaultOrManagedGroupRefusalShowsTheAppsWordsAndReloads() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/groups", F.groups(F.group(isDefault: true)))
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/groups/3", F.error("validation_failed", message: "validation failed"), status: 422)
        let model = OrganizationGroupsViewModel()
        await model.load(session: session)

        let deleted = await model.delete(session: session, group: model.groups[0])

        XCTAssertFalse(deleted)
        XCTAssertEqual(model.errorMessage, "The server refused that change. A group managed by a plan can only be changed there, and the default group can't be deleted.")
        XCTAssertEqual(http.state.organizationRequests("/groups/3").count, 1, "not replayed")
        XCTAssertFalse(model.isSaving)
    }

    func testAGroupWriteThatFindsTheOrganizationChangedReloadsAndAsksTheAdministratorToTryAgain() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubOrganization("/libraries", librariesBody())
        http.state.stubOrganization("/groups/3", F.error("authorization_state_changed"), status: 409)
        let model = OrganizationGroupsViewModel()
        await model.load(session: session)

        await model.save(session: session, group: model.groups[0], draft: AccessGroupDraft(group: model.groups[0]))

        XCTAssertEqual(http.state.organizationRequests("/groups/3").count, 1)
        XCTAssertEqual(model.errorMessage, "Someone else changed this just now. It has been reloaded; check it and try again.")
    }

    // MARK: Invitations

    func testSendingAnInvitationQuotesThePolicyRevisionAndKeepsTheOneTimeLinkInMemory() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/invitations", F.handoff(token: "tok/with space"), status: 201)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        let model = OrganizationInvitationsViewModel()

        let result = await model.send(session: session, email: " new@example.test ", accessGroupID: 3, note: "  ")

        guard case .sent(let link) = result else { return XCTFail("expected a link, got \(result)") }
        XCTAssertEqual(link.url, "https://example.test/invite/tok%2Fwith%20space")
        XCTAssertEqual(model.claimLink, link)
        XCTAssertFalse("\(link)".contains("tok"), "the link is never printed")
        let body = try XCTUnwrap(http.state.organizationBody("/invitations"))
        XCTAssertEqual(body["email"] as? String, "new@example.test")
        XCTAssertEqual(body["expected_revision"] as? Int, 7)
        XCTAssertEqual(body["access_group_id"] as? Int, 3)
        XCTAssertNil(body["note"], "a blank note is left out")
        model.dismissClaimLink()
        XCTAssertNil(model.claimLink)
    }

    func testAnEmptyAddressIsNotSent() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        let model = OrganizationInvitationsViewModel()

        let result = await model.send(session: session, email: "  ", accessGroupID: nil, note: nil)

        XCTAssertEqual(result, .failed("Enter an email address"))
        XCTAssertTrue(http.state.organizationRequests("/invitations").isEmpty)
    }

    func testAnInvitationThatCouldNotBeConfirmedIsNeverSentASecondTime() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubSequence(path: "\(F.base)/invitations", responses: [
            MockHTTPResponse(data: F.data(F.error("authorization_state_stale")), status: 401),
            MockHTTPResponse(data: F.data(F.invitations(F.invitation()))),
        ])
        http.state.stubOrganization("/groups", F.groups(F.group()))
        let model = OrganizationInvitationsViewModel()

        let result = await model.send(session: session, email: "new@example.test", accessGroupID: nil, note: nil)

        guard case .failed = result else { return XCTFail("a stale pass must report, not replay") }
        XCTAssertEqual(http.state.organizationRequests("/invitations").filter { $0.httpMethod == "POST" }.count, 1)
        XCTAssertNil(model.claimLink)
        XCTAssertNotNil(model.errorMessage)
    }

    func testEmailAlreadyTakenIsShownWithTheServersOwnWords() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/invitations", F.error("email_taken", message: "That address already has an account"), status: 409)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        let model = OrganizationInvitationsViewModel()

        let result = await model.send(session: session, email: "old@example.test", accessGroupID: nil, note: nil)

        XCTAssertEqual(result, .failed("That address already has an account"))
    }

    func testResendReplacesTheLinkAndRevokeSendsTheRevisionBody() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/invitations/i1/resend", F.handoff(token: "fresh"), status: 201)
        http.state.stubOrganization("/invitations", F.invitations(F.invitation(), F.invitation(id: "i2", status: "accepted")))
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stub(path: "\(F.base)/invitations/i2", data: Data(), status: 204)
        let model = OrganizationInvitationsViewModel()
        await model.load(session: session)

        let resent = await model.resend(session: session, invitation: model.invitations[0])
        guard case .sent(let link) = resent else { return XCTFail("expected a link") }
        XCTAssertTrue(link.url.hasSuffix("/invite/fresh"))
        XCTAssertEqual(http.state.organizationBody("/invitations/i1/resend")?["expected_revision"] as? Int, 7)

        let revoked = await model.revoke(session: session, invitation: model.invitations[1])
        XCTAssertTrue(revoked)
        XCTAssertEqual(http.state.organizationRequests("/invitations/i2").first?.httpMethod, "DELETE")
        XCTAssertEqual(http.state.organizationBody("/invitations/i2")?["expected_revision"] as? Int, 7)
    }

    func testClosingTheSurfaceDropsTheLinkAndALateAnswerNeverReopensIt() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/invitations", F.handoff(), status: 201)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        let model = OrganizationInvitationsViewModel()
        _ = await model.send(session: session, email: "a@example.test", accessGroupID: nil, note: nil)
        XCTAssertNotNil(model.claimLink)

        model.closeSurface()

        XCTAssertNil(model.claimLink)
    }

    func testTheClaimLinkUsesTheServersOriginAndEncodesTheToken() {
        XCTAssertEqual(ClaimLink.url(for: URL(string: "https://media.example.test:8443/base/path")!, token: "a b/c"), "https://media.example.test:8443/invite/a%20b%2Fc")
    }
}
