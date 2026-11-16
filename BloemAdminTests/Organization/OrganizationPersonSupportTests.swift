import XCTest
@testable import BloemAdmin

/// The person page's support actions: what each sends (the revision it quotes, the body it carries), what the page
/// shows afterwards, and how a refusal reads.
@MainActor
final class OrganizationPersonSupportTests: XCTestCase {
    typealias F = OrganizationFixtures

    private func json(_ http: MockHTTPHarness, _ route: String, index: Int = 0) -> [String: Any]? {
        http.state.organizationBody(route, index: index)
    }

    /// An opened session on a server with every support capability, and the person page loaded for account 5.
    private func openPerson(
        _ http: MockHTTPHarness,
        person: String? = nil,
        capabilities: String = F.capabilities(),
        sessions: [MockHTTPResponse]? = nil
    ) async throws -> (OrganizationSession, OrganizationPersonViewModel) {
        http.state.stubOrganization("/support-capabilities", capabilities)
        http.state.stubOrganization("/people/5", F.personResponse(person))
        http.state.stubSequence(path: "\(F.base)/people/5/sessions", responses: sessions ?? [
            MockHTTPResponse(data: F.data(F.supportSessions(F.supportSessionRow()))),
        ])
        http.state.stubOrganization("/people/5/devices", F.devices(F.device()))
        let session = try await openedOrganizationSession(http)
        let model = OrganizationPersonViewModel()
        await model.load(session: session, accountID: 5)
        return (session, model)
    }

    // MARK: Loading

    func testAMemberLoadsWithWhatTheServerOffersAndTheirSignIns() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let (_, model) = try await openPerson(http)

        XCTAssertTrue(model.support.offersPersonSupport)
        XCTAssertEqual(model.sessions?.map(\.id), ["s1"])
        XCTAssertEqual(model.devices?.map(\.id), ["dev-s1"])
        XCTAssertNil(model.sessionsMessage)
    }

    func testYourOwnAccountListsNoSignInsToSignOutOf() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let (_, model) = try await openPerson(http, person: F.person(membershipID: F.membershipID))

        XCTAssertNil(model.sessions)
        XCTAssertNil(model.devices)
        XCTAssertTrue(http.state.organizationRequests("/people/5/sessions").isEmpty)
    }

    func testAnOlderServerOffersNothingNewAndAsksForNothing() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/support-capabilities", data: F.data("404 page not found"), status: 404)
        http.state.stubOrganization("/people/5", F.personResponse())
        let session = try await openedOrganizationSession(http)
        let model = OrganizationPersonViewModel()

        await model.load(session: session, accountID: 5)

        XCTAssertEqual(model.support, .none)
        XCTAssertNil(model.sessions)
        XCTAssertTrue(http.state.organizationRequests("/people/5/sessions").isEmpty)
        XCTAssertTrue(http.state.organizationRequests("/people/5/devices").isEmpty)
        XCTAssertNotNil(model.person)
    }

    func testASignInListTheServerRefusesSaysWhy() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let (_, model) = try await openPerson(http, sessions: [
            MockHTTPResponse(data: F.data(#"{"error":"account_shared","message":"This account belongs to more than one organization"}"#), status: 409),
        ])

        XCTAssertNil(model.sessions)
        XCTAssertEqual(model.sessionsMessage, "This account belongs to more than one organization, so it can't be changed from here.")
    }

    // MARK: Reset links

    func testALinkQuotesThePersonsRevisionAndIsShownOnceUntilClosed() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubOrganization("/people/5/password-reset", F.resetResponse(), status: 201)
        let (session, model) = try await openPerson(http, person: F.person(revision: 4))

        await model.issueReset(session: session, delivery: .link)

        let body = try XCTUnwrap(json(http, "/people/5/password-reset"))
        XCTAssertEqual(body["delivery"] as? String, "link")
        XCTAssertEqual(body["expected_revision"] as? Int, 4)
        XCTAssertEqual(body.keys.sorted(), ["delivery", "expected_revision"])
        XCTAssertEqual(model.resetLink?.url, "https://acme.example.test/reset-password/tok-123")
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.notice, "the link sheet says it all")
        XCTAssertEqual(http.state.organizationRequests("/people/5/password-reset").count, 1, "sent once")

        model.dismissResetLink()
        XCTAssertNil(model.resetLink, "nothing keeps the link once it is closed")
    }

    func testAnEmailSaysWhereItWentOrThatItMayNotHave() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "\(F.base)/people/5/password-reset", responses: [
            MockHTTPResponse(data: F.data(F.resetResponse(delivery: "email", status: "sent")), status: 201),
            MockHTTPResponse(data: F.data(F.resetResponse(delivery: "email", status: "failed_or_unknown")), status: 201),
        ])
        let (session, model) = try await openPerson(http)

        await model.issueReset(session: session, delivery: .email)
        XCTAssertEqual(model.notice, "A reset email is on its way to sam@example.test. The link works for 24 hours.")
        XCTAssertNil(model.resetLink)

        await model.issueReset(session: session, delivery: .email)
        XCTAssertEqual(model.notice, "The email may not have been sent. The link works anyway; send another, or create a link to hand over.")
    }

    func testAProtectedPersonIsRefusedInWordsAndTheOrganizationStaysOpen() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubOrganization("/people/5/password-reset", F.protected("organization_owner"), status: 409)
        let (session, model) = try await openPerson(http)

        await model.issueReset(session: session, delivery: .link)

        XCTAssertEqual(model.errorMessage, "This person is the organization's owner. Only the platform operator can help the owner.")
        XCTAssertNil(model.resetLink)
        XCTAssertNil(session.denial)
        XCTAssertGreaterThanOrEqual(http.state.organizationRequests("/people/5").count, 2, "the person is read again after a refusal")
    }

    func testAServerThatCannotEmailSaysToHandOverALink() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubOrganization("/people/5/password-reset", F.notConfigured("email"), status: 409)
        let (session, model) = try await openPerson(http)

        await model.issueReset(session: session, delivery: .email)

        XCTAssertEqual(model.errorMessage, "This server can't send email. Create a link to hand over instead.")
    }

    // MARK: Sign-outs

    func testSigningOutEverywhereQuotesTheRevisionAndShowsTheRaisedOne() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let (session, model) = try await openPerson(http, person: F.person(revision: 4), sessions: [
            MockHTTPResponse(data: F.data(F.supportSessions(F.supportSessionRow(), F.supportSessionRow(id: "s2")))),
            MockHTTPResponse(data: F.data(F.signOutResponse(revision: 5, sessions: 2))),
            MockHTTPResponse(data: F.data(F.supportSessions())),
        ])

        await model.signOutEverywhere(session: session)

        let requests = http.state.organizationRequests("/people/5/sessions")
        XCTAssertEqual(requests.map { $0.httpMethod ?? "" }, ["GET", "DELETE", "GET"])
        XCTAssertEqual(json(http, "/people/5/sessions", index: 1)?["expected_revision"] as? Int, 4)
        XCTAssertEqual(model.person?.securityRevision, 5, "the next write quotes the raised revision")
        XCTAssertEqual(model.sessions?.count, 0)
        XCTAssertEqual(model.notice, "Signed out everywhere: 2 sessions ended")
    }

    func testSigningOutOfOneSessionOrOneDeviceNamesItInThePath() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/people/5/sessions/s1", data: Data(), status: 204)
        http.state.stub(path: "\(F.base)/people/5/devices/dev-s1", data: Data(), status: 204)
        let (session, model) = try await openPerson(http)
        let signIn = try XCTUnwrap(model.sessions?.first)
        let device = try XCTUnwrap(model.devices?.first)

        await model.signOut(session: session, of: signIn)
        XCTAssertEqual(model.notice, "Signed out of that session")
        await model.signOut(session: session, of: device)
        XCTAssertEqual(model.notice, "Signed out of Living room TV")

        XCTAssertEqual(http.state.organizationRequests("/people/5/sessions/s1").first?.httpMethod, "DELETE")
        XCTAssertEqual(http.state.organizationRequests("/people/5/devices/dev-s1").first?.httpMethod, "DELETE")
        XCTAssertNil(http.state.body(path: "\(F.base)/people/5/sessions/s1", requestIndex: 0).flatMap { $0.isEmpty ? nil : $0 }, "no revision for one session")
    }

    // MARK: Profiles

    func testAddingAProfileSendsTheTrimmedNameAndTheGroupOnlyWhenChosen() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "\(F.base)/people/5/profiles", responses: [
            MockHTTPResponse(data: F.data(F.profileResponse(profile: F.profile(id: "p9", name: "Kids"))), status: 201),
            MockHTTPResponse(data: F.data(F.profileResponse(profile: F.profile(id: "p10", name: "Den"))), status: 201),
        ])
        let (session, model) = try await openPerson(http)

        await model.addProfile(session: session, name: "  Kids ", groupID: 4)
        XCTAssertEqual(model.notice, "Profile Kids added")
        await model.addProfile(session: session, name: "Den", groupID: nil)

        let first = try XCTUnwrap(json(http, "/people/5/profiles"))
        XCTAssertEqual(first["name"] as? String, "Kids")
        XCTAssertEqual(first["group_id"] as? Int, 4)
        let second = try XCTUnwrap(json(http, "/people/5/profiles", index: 1))
        XCTAssertEqual(second.keys.sorted(), ["name"], "no group, no PIN, no parental fields")
    }

    func testRenameClearPINAndRemoveQuoteTheProfilesOwnRevision() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let profile = F.profile(id: "p1", revision: 9, hasPIN: true)
        http.state.stubOrganization("/people/5/profiles/p1/details", F.profileResponse(profile: F.profile(id: "p1", name: "Den", revision: 10)))
        http.state.stubOrganization("/people/5/profiles/p1/pin", F.profileOnlyResponse(F.profile(id: "p1", revision: 11, hasPIN: false)))
        http.state.stub(path: "\(F.base)/people/5/profiles/p1", data: Data(), status: 204)
        let (session, model) = try await openPerson(http, person: F.person(revision: 4, profiles: profile))
        let loaded = try XCTUnwrap(model.person?.profiles.first)

        await model.renameProfile(session: session, profile: loaded, to: "Den")
        XCTAssertEqual(model.notice, "Profile renamed to Den")
        await model.clearPIN(session: session, profile: loaded)
        XCTAssertEqual(model.notice, "PIN cleared on Living room. They choose a new one on the profile.")
        XCTAssertEqual(model.person?.profiles.first?.hasPIN, false, "the cleared profile replaces the old one")
        await model.removeProfile(session: session, profile: loaded)
        XCTAssertEqual(model.notice, "Profile Living room removed")

        XCTAssertEqual(json(http, "/people/5/profiles/p1/details")?["expected_revision"] as? Int, 9)
        XCTAssertEqual(json(http, "/people/5/profiles/p1/details")?["name"] as? String, "Den")
        XCTAssertEqual(json(http, "/people/5/profiles/p1/pin")?["expected_revision"] as? Int, 9)
        XCTAssertEqual(http.state.organizationRequests("/people/5/profiles/p1/pin").first?.httpMethod, "DELETE")
        XCTAssertEqual(json(http, "/people/5/profiles/p1")?["expected_revision"] as? Int, 9, "the profile's revision, never the person's 4")
        XCTAssertEqual(http.state.organizationRequests("/people/5/profiles/p1").first?.httpMethod, "DELETE")
    }

    func testAStaleProfileRevisionReloadsAndIsNeverReplayed() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubOrganization(
            "/people/5/profiles/p1/details",
            #"{"error":"authorization_state_changed","message":"Authorization state changed; reload and retry","current_revision":4}"#,
            status: 409
        )
        let (session, model) = try await openPerson(http, person: F.person(profiles: F.profile(id: "p1", revision: 9)))
        let loaded = try XCTUnwrap(model.person?.profiles.first)
        let reads = http.state.organizationRequests("/people/5").count

        await model.renameProfile(session: session, profile: loaded, to: "Den")

        XCTAssertEqual(http.state.organizationRequests("/people/5/profiles/p1/details").count, 1, "never replayed")
        XCTAssertEqual(model.errorMessage, "Someone else changed this just now. It has been reloaded; check it and try again.")
        XCTAssertGreaterThan(http.state.organizationRequests("/people/5").count, reads, "the person is read again")
    }

    func testTheMainProfileCannotBeRemovedAndTheLimitIsWorded() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: "\(F.base)/people/5/profiles/p1",
            data: F.data(#"{"error":"primary_profile_protected","message":"The primary profile cannot be removed"}"#), status: 409
        )
        http.state.stubOrganization(
            "/people/5/profiles", #"{"error":"profile_limit_reached","message":"Profile limit reached","fields":{}}"#, status: 422
        )
        let (session, model) = try await openPerson(http, person: F.person(profiles: F.profile(id: "p1", isPrimary: true)))
        let loaded = try XCTUnwrap(model.person?.profiles.first)

        await model.removeProfile(session: session, profile: loaded)
        XCTAssertEqual(model.errorMessage, "The household's main profile can't be removed")
        await model.addProfile(session: session, name: "Kids", groupID: nil)
        XCTAssertEqual(model.errorMessage, "They already have as many profiles as they're allowed")
    }
}
