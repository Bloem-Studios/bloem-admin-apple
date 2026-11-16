import XCTest
@testable import BloemAdmin

@MainActor
final class OrganizationPeopleViewModelTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let people = "/people"

    private func makeModel() -> OrganizationPeopleViewModel {
        let model = OrganizationPeopleViewModel()
        model.pollDelay = .milliseconds(1)
        model.now = { organizationFixtureNow }
        return model
    }

    private func stubPeople(_ http: MockHTTPHarness, _ rows: String..., next: String? = nil, total: Int? = nil) {
        let cursor = next.map { #""next_cursor":"\#($0)","# } ?? ""
        http.state.stubOrganization(people, #"{"items":[\#(rows.joined(separator: ","))],\#(cursor)"approximate_total":\#(total ?? rows.count)}"#)
        http.state.stubOrganization("/groups", F.groups(F.group(), F.group(id: "4", name: "Kids")))
    }

    private func queryValue(_ request: URLRequest?, _ name: String) -> String? {
        URLComponents(url: request?.url ?? URL(string: "x:")!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    // MARK: Loading, filters, paging

    func testLoadReadsGroupsOnceThenTheFirstPage() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), F.person(accountID: 6, name: "Kim"), next: "n1", total: 40)
        let model = makeModel()

        await model.load(session: session)
        await model.load(session: session)

        XCTAssertEqual(model.people.map(\.accountID), [5, 6])
        XCTAssertEqual(model.groups.map(\.name), ["Family", "Kids"])
        XCTAssertEqual(model.approximateTotal, 40)
        XCTAssertEqual(http.state.organizationRequests("/groups").count, 1, "groups are read once")
    }

    func testEveryFilterReachesTheRequestAndRecentActivityBecomesOneInstant() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person())
        let model = makeModel()

        await model.load(session: session, filter: PeopleFilter(
            query: "sam", statuses: ["suspended"], groupID: 4, sort: PeopleSort.recentActivity, activeWithinDays: 7
        ))

        let request = http.state.organizationRequests(people).last
        XCTAssertEqual(queryValue(request, "query"), "sam")
        XCTAssertEqual(queryValue(request, "status"), "suspended")
        XCTAssertEqual(queryValue(request, "group_id"), "4")
        XCTAssertEqual(queryValue(request, "sort"), "recent_activity")
        XCTAssertEqual(queryValue(request, "active_since"), "2026-11-06T12:00:00Z")
        XCTAssertTrue(model.filter.isNarrowed)
    }

    func testLoadMoreAppendsTheNextPageWithTheSameFilterAndCursor() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubSequence(path: "\(F.base)/people", responses: [
            MockHTTPResponse(data: F.data(F.peoplePage(F.person(), next: "n1", total: 2))),
            MockHTTPResponse(data: F.data(F.peoplePage(F.person(), F.person(accountID: 6, name: "Kim"), total: 2))),
        ])
        let model = makeModel()
        await model.load(session: session, filter: PeopleFilter(query: "a"))

        await model.loadMore(session: session)

        XCTAssertEqual(model.people.map(\.accountID), [5, 6], "a person on both pages shows once")
        XCTAssertNil(model.nextCursor)
        let second = http.state.organizationRequests(people).last
        XCTAssertEqual(queryValue(second, "cursor"), "n1")
        XCTAssertEqual(queryValue(second, "query"), "a")
    }

    func testChangingTheFilterDropsTheSelection() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), F.person(accountID: 6, name: "Kim"))
        let model = makeModel()
        await model.load(session: session)
        model.toggle(5)
        XCTAssertEqual(model.pickedIDs, [5])

        await model.load(session: session, filter: PeopleFilter(query: "kim"))

        XCTAssertTrue(model.pickedIDs.isEmpty)
        XCTAssertNil(model.matching)
    }

    func testAFailedLoadKeepsWhatWasShown() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person())
        let model = makeModel()
        await model.load(session: session)
        http.state.stubOrganization(people, F.error("boom", message: "Down"), status: 500)

        await model.load(session: session)

        XCTAssertEqual(model.errorMessage, "Down")
        XCTAssertEqual(model.people.count, 1)
    }

    // MARK: One person

    func testSuspendingQuotesThePersonRevisionAndUpdatesTheRow() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(revision: 4))
        http.state.stubOrganization("/people/5/memberships/current", F.personResponse(F.person(status: "suspended", revision: 5)))
        let model = makeModel()
        await model.load(session: session)

        await model.setSuspended(session: session, person: model.people[0], suspend: true)

        XCTAssertEqual(http.state.organizationBody("/people/5/memberships/current")?["expected_revision"] as? Int, 4)
        XCTAssertEqual(http.state.organizationBody("/people/5/memberships/current")?["status"] as? String, "suspended")
        XCTAssertTrue(model.people[0].isSuspended)
        XCTAssertEqual(model.people[0].securityRevision, 5)
        XCTAssertEqual(model.notice, "Membership suspended")
    }

    func testReactivatingSendsActive() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(status: "suspended"))
        http.state.stubOrganization("/people/5/memberships/current", F.personResponse(F.person(status: "active", revision: 5)))
        let model = makeModel()
        await model.load(session: session)

        await model.setSuspended(session: session, person: model.people[0], suspend: false)

        XCTAssertEqual(http.state.organizationBody("/people/5/memberships/current")?["status"] as? String, "active")
        XCTAssertEqual(model.notice, "Membership reactivated")
    }

    func testAnAdministratorNeverSuspendsTheirOwnMembership() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        // The pass context names membership F.membershipID; this row is that membership.
        stubPeople(http, F.person(accountID: 4, membershipID: F.membershipID))
        let model = makeModel()
        await model.load(session: session)

        await model.setSuspended(session: session, person: model.people[0], suspend: true)

        XCTAssertTrue(http.state.organizationRequests("/people/4/memberships/current").isEmpty)
    }

    func testTheOwnersRefusalIsExplainedAndTheListReloaded() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person())
        http.state.stubOrganization("/people/5/memberships/current", F.error("validation_failed", message: "validation failed"), status: 422)
        let model = makeModel()
        await model.load(session: session)

        await model.setSuspended(session: session, person: model.people[0], suspend: true)

        XCTAssertEqual(model.errorMessage, "That membership can't be suspended. The owner always keeps access.")
        XCTAssertEqual(http.state.organizationRequests(people).count, 2, "reloaded to show what the server holds")
        XCTAssertTrue(model.pendingAccountIDs.isEmpty)
    }

    func testMovingAProfileSendsTheGroupAndThePersonRevision() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(revision: 4))
        http.state.stubOrganization("/people/5/profiles/p1", F.personResponse(F.person(revision: 5, profiles: F.profile(groupID: 4, groupName: "Kids"))))
        let model = makeModel()
        await model.load(session: session)

        await model.assignGroup(session: session, person: model.people[0], profile: model.people[0].profiles[0], group: model.groups[1])

        let body = try XCTUnwrap(http.state.organizationBody("/people/5/profiles/p1"))
        XCTAssertEqual(body["group_id"] as? Int, 4)
        XCTAssertEqual(body["expected_revision"] as? Int, 4)
        XCTAssertEqual(model.people[0].profiles[0].groupName, "Kids")
        XCTAssertEqual(model.notice, "Profile moved to the access group")
    }

    func testAStaleWriteIsNotReplayedAndTheListIsReloaded() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person())
        http.state.stubOrganization("/people/5/memberships/current", F.error("authorization_state_changed"), status: 409)
        let model = makeModel()
        await model.load(session: session)

        await model.setSuspended(session: session, person: model.people[0], suspend: true)

        XCTAssertEqual(http.state.organizationRequests("/people/5/memberships/current").count, 1)
        XCTAssertEqual(model.errorMessage, "Someone else changed this just now. It has been reloaded; check it and try again.")
    }

    // MARK: Choosing

    func testTickingIsPerPersonAndSelectAllReplacesIt() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), F.person(accountID: 6, name: "Kim"), total: 12)
        http.state.stubOrganization("/people/selections", F.selection(token: "sel", matched: 12, excluded: 1), status: 201)
        let model = makeModel()
        await model.load(session: session)

        model.toggle(5)
        model.toggle(6)
        model.toggle(6)
        XCTAssertEqual(model.pickedIDs, [5])
        XCTAssertEqual(model.selectedCount, 1)

        await model.selectAllMatching(session: session)
        XCTAssertEqual(model.matching?.matched, 12)
        XCTAssertTrue(model.pickedIDs.isEmpty)
        XCTAssertEqual(model.selectedCount, 12)

        model.toggle(5)
        XCTAssertNil(model.matching, "choosing by hand replaces a select-all selection")
        model.stopSelecting()
        XCTAssertFalse(model.isSelecting)
        XCTAssertFalse(model.hasSelection)
    }

    // MARK: Bulk, the server's job

    func testSelectAllThenAssignGroupRunsOneServerJobAndFollowsItToTheEnd() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), F.person(accountID: 6, name: "Kim"), total: 12)
        http.state.stubOrganization("/people/selections", F.selection(token: "sel", matched: 12), status: 201)
        http.state.stubOrganization("/people/bulk-jobs", F.bulkJob(status: "queued"), status: 201)
        http.state.stubSequence(path: "\(F.base)/people/bulk-jobs/job-1", responses: [
            MockHTTPResponse(data: F.data(F.bulkJob(status: "running", current: 6, succeeded: 6))),
            MockHTTPResponse(data: F.data(F.bulkJob(status: "completed", current: 12, succeeded: 10, skipped: F.record(5, "already_applied"), failed: F.record(6, "protected_owner")))),
        ])
        let model = makeModel()
        await model.load(session: session)
        await model.selectAllMatching(session: session)

        await model.apply(session: session, action: .assignGroup(model.groups[1]))

        let start = try XCTUnwrap(http.state.organizationBody("/people/bulk-jobs"))
        XCTAssertEqual(start["kind"] as? String, "assign_group")
        XCTAssertEqual(start["group_id"] as? Int, 4)
        XCTAssertEqual(start["selection_token"] as? String, "sel")
        XCTAssertEqual(http.state.organizationRequests("/people/bulk-jobs/job-1").count, 2)
        let report = try XCTUnwrap(model.report)
        XCTAssertTrue(report.job.isFinished)
        XCTAssertEqual(report.job.succeeded, 10)
        XCTAssertEqual(report.job.skipped, [BulkRecordResult(accountID: 5, reason: "already_applied")])
        XCTAssertEqual(report.names[5], "Sam")
        XCTAssertEqual(OrganizationVocabulary.bulkHeading(report.job), "Some people were changed")
        XCTAssertFalse(model.isSelecting)
        XCTAssertNil(model.matching)
        XCTAssertEqual(http.state.organizationRequests(people).count, 2, "the list reloads when the job ends")
    }

    func testSuspendAndReactivateUseTheirOwnJobKinds() async throws {
        for (action, kind) in [(BulkAction.suspend, "suspend_memberships"), (BulkAction.reactivate, "reactivate_memberships")] {
            let http = MockHTTPHarness()
            defer { http.invalidate() }
            let session = try await openedOrganizationSession(http)
            stubPeople(http, F.person(), total: 3)
            http.state.stubOrganization("/people/selections", F.selection(matched: 3), status: 201)
            http.state.stubOrganization("/people/bulk-jobs", F.bulkJob(status: "completed", current: 3, total: 3, succeeded: 3), status: 201)
            let model = makeModel()
            await model.load(session: session)
            await model.selectAllMatching(session: session)

            await model.apply(session: session, action: action)

            let body = try XCTUnwrap(http.state.organizationBody("/people/bulk-jobs"))
            XCTAssertEqual(body["kind"] as? String, kind)
            XCTAssertNil(body["group_id"])
            XCTAssertEqual(model.report?.job.status, "completed")
        }
    }

    func testAnExpiredSelectionIsDroppedAndNeverRetried() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), total: 3)
        http.state.stubOrganization("/people/selections", F.selection(matched: 3), status: 201)
        http.state.stubOrganization("/people/bulk-jobs", F.error("selection_expired", message: "expired"), status: 409)
        let model = makeModel()
        await model.load(session: session)
        await model.selectAllMatching(session: session)

        await model.apply(session: session, action: .suspend)

        XCTAssertEqual(model.errorMessage, "That selection expired. Select the people again.")
        XCTAssertNil(model.matching)
        XCTAssertNil(model.report)
        XCTAssertEqual(http.state.organizationRequests("/people/bulk-jobs").count, 1, "starting a job is never replayed")
    }

    func testAJobThatCannotBeFollowedKeepsItsLastKnownResult() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), total: 3)
        http.state.stubOrganization("/people/selections", F.selection(matched: 3), status: 201)
        http.state.stubOrganization("/people/bulk-jobs", F.bulkJob(status: "running", current: 1, total: 3, succeeded: 1), status: 201)
        http.state.stubOrganization("/people/bulk-jobs/job-1", F.error("boom", message: "Down"), status: 500)
        let model = makeModel()
        await model.load(session: session)
        await model.selectAllMatching(session: session)

        await model.apply(session: session, action: .suspend)

        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.error, "Down")
        XCTAssertEqual(report.job.succeeded, 1)
        XCTAssertFalse(report.isRunning)
        XCTAssertEqual(http.state.organizationRequests("/people/bulk-jobs/job-1").count, 3)
        // The job exists on the server: its selection is spent, so Apply cannot start a second job over it.
        XCTAssertNil(model.matching)
        XCTAssertFalse(model.hasSelection)
        await model.apply(session: session, action: .suspend)
        XCTAssertEqual(http.state.organizationRequests("/people/bulk-jobs").count, 1, "no second job over the same selection")
    }

    func testASelectionThatArrivesAfterTheFilterChangedIsDropped() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), total: 120)
        http.state.stub(
            path: "\(F.base)/people/selections",
            response: MockHTTPResponse(data: F.data(F.selection(matched: 120)), status: 201),
            delayUntilReleased: true
        )
        let model = makeModel()
        await model.load(session: session, filter: PeopleFilter(statuses: ["active"]))

        let selecting = Task { await model.selectAllMatching(session: session) }
        await http.state.waitForRequest(path: "\(F.base)/people/selections")
        await model.load(session: session, filter: PeopleFilter(statuses: ["active"], groupID: 4))
        http.state.releaseResponses(matching: "\(F.base)/people/selections")
        await selecting.value

        XCTAssertNil(model.matching, "a selection made for the old filter must not be applied under the new one")
        XCTAssertFalse(model.isMakingSelection)
    }

    func testAStalePassWhenStartingAJobKeepsTheSelectionForAnotherTry() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(), total: 3)
        http.state.stubOrganization("/people/selections", F.selection(matched: 3), status: 201)
        http.state.stubOrganization("/people/bulk-jobs", F.error("authorization_state_stale"), status: 401)
        let model = makeModel()
        await model.load(session: session)
        await model.selectAllMatching(session: session)

        await model.apply(session: session, action: .suspend)

        XCTAssertEqual(model.matching?.matched, 3, "the selection token does not depend on the pass")
        XCTAssertEqual(model.errorMessage, "This organization changed. It has been reloaded; try again.")
        XCTAssertEqual(http.state.organizationRequests("/people/bulk-jobs").count, 1, "the start is never replayed")
    }

    // MARK: Bulk, people ticked by hand

    func testPeopleTickedByHandGetSinglePersonWritesOneAfterAnotherWithTheSameReport() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(
            http,
            F.person(accountID: 5, revision: 4),
            F.person(accountID: 6, name: "Kim", status: "suspended", revision: 2),
            F.person(accountID: 7, name: "Lee", revision: 3)
        )
        http.state.stubOrganization("/people/5/memberships/current", F.personResponse(F.person(accountID: 5, status: "suspended", revision: 5)))
        http.state.stubOrganization("/people/7/memberships/current", F.error("validation_failed", message: "validation failed"), status: 422)
        let model = makeModel()
        await model.load(session: session)
        model.toggle(5)
        model.toggle(6)
        model.toggle(7)

        await model.apply(session: session, action: .suspend)

        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.job.status, "completed")
        XCTAssertEqual(report.job.succeeded, 1)
        XCTAssertEqual(report.job.skipped, [BulkRecordResult(accountID: 6, reason: "already_applied")])
        XCTAssertEqual(report.job.failed, [BulkRecordResult(accountID: 7, reason: "protected_owner")])
        XCTAssertEqual(OrganizationVocabulary.resultReasonText("protected_owner"), "is the organization owner and can't be changed here")
        XCTAssertTrue(http.state.organizationRequests("/people/6/memberships/current").isEmpty, "an already suspended person is skipped, not written")
        XCTAssertTrue(http.state.organizationRequests("/people/bulk-jobs").isEmpty, "the server's job takes a filter, not account ids")
        XCTAssertEqual(http.state.organizationBody("/people/5/memberships/current")?["expected_revision"] as? Int, 4)
        XCTAssertFalse(model.isSelecting)
    }

    func testBulkSuspendSkipsTheAdministratorThemself() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(accountID: 4, name: "Me", membershipID: F.membershipID))
        let model = makeModel()
        await model.load(session: session)
        model.toggle(4)

        await model.apply(session: session, action: .suspend)

        XCTAssertEqual(model.report?.job.skipped, [BulkRecordResult(accountID: 4, reason: "actor_authority_target")])
        XCTAssertTrue(http.state.organizationRequests("/people/4/memberships/current").isEmpty)
    }

    func testMovingPickedPeopleSkipsProfilesAlreadyThereAndPeopleWithNone() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(
            http,
            F.person(accountID: 5, profiles: F.profile(id: "p1", groupID: 3) + "," + F.profile(id: "p2", groupID: 4, groupName: "Kids")),
            F.person(accountID: 6, name: "Kim", profiles: ""),
            F.person(accountID: 7, name: "Lee", profiles: F.profile(id: "p3", groupID: 4, groupName: "Kids"))
        )
        http.state.stubOrganization("/people/5/profiles/p1", F.personResponse(F.person(accountID: 5, revision: 5)))
        let model = makeModel()
        await model.load(session: session)
        model.toggle(5)
        model.toggle(6)
        model.toggle(7)

        await model.apply(session: session, action: .assignGroup(model.groups[1]))

        let report = try XCTUnwrap(model.report)
        XCTAssertEqual(report.job.succeeded, 1)
        XCTAssertEqual(Set(report.job.skipped.map(\.reason)), ["no_profiles", "already_applied"])
        XCTAssertTrue(http.state.organizationRequests("/people/5/profiles/p2").isEmpty, "the profile already in the group is left alone")
        XCTAssertEqual(http.state.organizationBody("/people/5/profiles/p1")?["group_id"] as? Int, 4)
    }

    func testAForbiddenAnswerStopsTheWholeRun() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        stubPeople(http, F.person(accountID: 5), F.person(accountID: 6, name: "Kim"))
        http.state.stubOrganization("/people/5/memberships/current", F.error("organization_suspended"), status: 403)
        let model = makeModel()
        await model.load(session: session)
        model.toggle(5)
        model.toggle(6)

        await model.apply(session: session, action: .suspend)

        XCTAssertEqual(model.report?.job.status, "failed")
        XCTAssertEqual(model.report?.error, OrganizationDenial.suspended.message)
        XCTAssertTrue(http.state.organizationRequests("/people/6/memberships/current").isEmpty)
        XCTAssertEqual(session.denial, .suspended)
    }

    // MARK: Person page

    func testPersonPageShowsTheProfilesAndOnlyChangesToThisMembership() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/people/5", F.personResponse(F.person(membershipID: "m-5")))
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubOrganization("/activity", F.audit(F.auditEvent(id: 3, target: "m-5"), F.auditEvent(id: 2, target: "m-9"), F.auditEvent(id: 1, target: "m-5")))
        let model = OrganizationPersonViewModel()

        await model.load(session: session, accountID: 5)

        XCTAssertEqual(model.person?.profiles.count, 1)
        XCTAssertEqual(model.changes.map(\.id), [3, 1])
        XCTAssertEqual(model.changesLooked, 3)
        XCTAssertFalse(model.changesUnavailable)
        XCTAssertFalse(model.isGone)
    }

    func testAPersonOfAnotherOrganizationIsGoneNotAnError() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/people/9", F.error("not_found"), status: 404)
        let model = OrganizationPersonViewModel()

        await model.load(session: session, accountID: 9)

        XCTAssertTrue(model.isGone)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.person)
    }

    func testPersonPageStillShowsThePersonWhenActivityFails() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/people/5", F.personResponse())
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubOrganization("/activity", F.error("boom"), status: 500)
        let model = OrganizationPersonViewModel()

        await model.load(session: session, accountID: 5)

        XCTAssertNotNil(model.person)
        XCTAssertTrue(model.changesUnavailable)
    }

    func testSuspendingFromThePersonPageUpdatesThePersonAndReadsTheActivityAgain() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/people/5", F.personResponse(F.person(revision: 4, membershipID: "m-5")))
        http.state.stubOrganization("/groups", F.groups(F.group()))
        http.state.stubOrganization("/activity", F.audit())
        http.state.stubOrganization("/people/5/memberships/current", F.personResponse(F.person(status: "suspended", revision: 5, membershipID: "m-5")))
        let model = OrganizationPersonViewModel()
        await model.load(session: session, accountID: 5)

        await model.setSuspended(session: session, suspend: true)

        XCTAssertTrue(model.person?.isSuspended ?? false)
        XCTAssertEqual(http.state.organizationBody("/people/5/memberships/current")?["expected_revision"] as? Int, 4)
        XCTAssertEqual(http.state.organizationRequests("/activity").count, 2)
        XCTAssertEqual(model.notice, "Membership suspended")
    }

    func testMovingAProfileFromThePersonPage() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)
        http.state.stubOrganization("/people/5", F.personResponse())
        http.state.stubOrganization("/groups", F.groups(F.group(), F.group(id: "4", name: "Kids")))
        http.state.stubOrganization("/activity", F.audit())
        http.state.stubOrganization("/people/5/profiles/p1", F.personResponse(F.person(revision: 5, profiles: F.profile(groupID: 4, groupName: "Kids"))))
        let model = OrganizationPersonViewModel()
        await model.load(session: session, accountID: 5)

        await model.assignGroup(session: session, profile: model.person!.profiles[0], group: model.groups[1])

        XCTAssertEqual(model.person?.profiles[0].groupName, "Kids")
        XCTAssertEqual(http.state.organizationBody("/people/5/profiles/p1")?["group_id"] as? Int, 4)
    }
}
