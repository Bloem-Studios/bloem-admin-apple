import XCTest
@testable import BloemAdmin

/// Break-glass support access in the pass, the support capabilities, the error body's refusal reasons, and the
/// words a refusal becomes.
@MainActor
final class OrganizationSupportSessionTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let mint = "/api/bloem/v2/admin/session"
    private let overview = "\(F.base)/overview"
    private let capabilities = "\(F.base)/support-capabilities"
    private let supportAccess = "\(F.base)/support-access"

    private func make(_ http: MockHTTPHarness, clock: OrgTestClock = OrgTestClock()) -> OrganizationSession {
        let account = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "account-token", session: http.session)
        return OrganizationSession(
            account: account, baseURL: URL(string: "https://example.test")!, organizationID: F.orgID,
            session: http.session, now: { clock.date }
        )
    }

    private func mintBody(_ http: MockHTTPHarness, _ index: Int) throws -> [String: Any] {
        let data = try XCTUnwrap(http.state.body(path: mint, requestIndex: index))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: Support access

    func testTheOwnerOpensWithAReasonOnceAndRenewsWithTheAccessAfterwards() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.supportSession(token: "pass-1"))),
            MockHTTPResponse(data: F.data(F.supportSession(token: "pass-2"))),
        ])
        http.state.stubSequence(path: overview, responses: [
            MockHTTPResponse(data: F.data(F.error("tenant_session_required")), status: 401),
            MockHTTPResponse(data: F.data(F.overview())),
        ])
        let session = make(http)

        let context = try await session.openSupport(reason: "  Admin locked out; helping her  ")
        _ = try await session.read { try await $0.organizationOverview() }

        XCTAssertTrue(context.isSupportAccess)
        XCTAssertTrue(session.isSupportAccess)
        XCTAssertEqual(context.authority, .platformAdmin)
        XCTAssertNil(context.membershipID)
        XCTAssertEqual(context.supportExpiresAt, ISO8601DateFormatter().date(from: "2026-11-13T16:00:00Z"))
        let first = try mintBody(http, 0)
        XCTAssertEqual(first["scope"] as? String, "organization")
        XCTAssertEqual(first["support"] as? [String: String], ["reason": "Admin locked out; helping her"], "the reason, trimmed, and nothing else")
        let renewal = try mintBody(http, 1)
        XCTAssertEqual(renewal["support"] as? [String: String], ["access_id": F.supportAccessID], "a renewal never states the reason again")
    }

    func testAnOrdinaryMintSendsNoSupportObject() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        let session = make(http)

        try await session.open()

        XCTAssertNil(try mintBody(http, 0)["support"])
        XCTAssertFalse(session.isSupportAccess)
        XCTAssertNil(session.context?.supportAccessID)
    }

    func testAnAccessThatEndedIsToldApartFromNoAccessAtAll() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.supportSession(token: "pass-1"))),
            MockHTTPResponse(data: F.data(F.error("not_found", message: "Organization not found")), status: 404),
        ])
        http.state.stub(path: overview, data: F.data(F.error("authorization_state_stale")), status: 401)
        let session = make(http)
        try await session.openSupport(reason: "Admin locked out; helping her")

        do {
            _ = try await session.read { try await $0.organizationOverview() }
            XCTFail("the renewal was refused")
        } catch let denied as OrganizationAccessDenied {
            XCTAssertEqual(denied.reason, .supportEnded)
        }
        XCTAssertEqual(session.denial, .supportEnded)
    }

    func testSomeoneWhoMayNotOpenItGetsTheSameNotFoundAsEver() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.error("not_found", message: "Organization not found")), status: 404)
        let session = make(http)

        do {
            try await session.openSupport(reason: "Admin locked out; helping her")
            XCTFail("refused")
        } catch let denied as OrganizationAccessDenied {
            XCTAssertEqual(denied.reason, .notFound)
        }
    }

    func testAReasonTheServerWillNotTakeIsItsValidationAnswer() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(
            path: mint,
            data: F.data(#"{"error":"validation_failed","message":"Validation failed","fields":{"support.reason":"must state why"}}"#),
            status: 422
        )
        let session = make(http)

        do {
            try await session.openSupport(reason: "short")
            XCTFail("refused")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 422)
            XCTAssertEqual(error.code, "validation_failed")
        }
        XCTAssertNil(session.denial, "a refused reason is not a refusal of the organization")
    }

    func testResumingAnOpenAccessNamesItWithoutAReason() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.supportSession()))
        let session = make(http)

        try await session.resumeSupport(accessID: F.supportAccessID)

        XCTAssertEqual(try mintBody(http, 0)["support"] as? [String: String], ["access_id": F.supportAccessID])
        XCTAssertTrue(session.isSupportAccess)
    }

    func testEndingTheAccessClosesItOnTheServerAndDropsThePass() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.supportSession()))
        http.state.stub(path: supportAccess, data: Data(), status: 204)
        let session = make(http)
        try await session.openSupport(reason: "Admin locked out; helping her")

        try await session.endSupportAccess()

        let request = try XCTUnwrap(http.state.requests(path: supportAccess).first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(F.pass)")
        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.denial, .supportEnded)
        XCTAssertNil(session.supportAccessID)
    }

    func testEndingAnAccessThatAlreadyEndedStillEndsIt() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.supportSession()))
        http.state.stub(path: supportAccess, data: F.data(F.error("not_found")), status: 404)
        let session = make(http)
        try await session.openSupport(reason: "Admin locked out; helping her")

        try await session.endSupportAccess()

        XCTAssertFalse(session.isOpen)
        XCTAssertEqual(session.denial, .supportEnded)
    }

    func testAMembershipPassHasNoSupportAccessToEnd() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = try await openedOrganizationSession(http)

        try await session.endSupportAccess()

        XCTAssertTrue(http.state.requests(path: supportAccess).isEmpty)
        XCTAssertTrue(session.isOpen)
    }

    // MARK: Capabilities

    func testCapabilitiesAreReadOnceAndGateEachFeature() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: capabilities, data: F.data(F.capabilities(email: false, remove: false, message: false)))
        let session = try await openedOrganizationSession(http)
        XCTAssertEqual(session.support, .none, "nothing is offered before the server says")

        await session.loadSupportCapabilities()
        await session.loadSupportCapabilities()

        XCTAssertEqual(http.state.requests(path: capabilities).count, 1)
        XCTAssertEqual(http.state.requests(path: capabilities).first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(F.pass)")
        XCTAssertFalse(session.support.passwordReset.email)
        XCTAssertTrue(session.support.passwordReset.link)
        XCTAssertTrue(session.support.sessions)
        XCTAssertTrue(session.support.profiles.clearPIN)
        XCTAssertFalse(session.support.profiles.remove)
        XCTAssertTrue(session.support.streams.list)
        XCTAssertFalse(session.support.streams.message)
    }

    func testAnOlderServerWithoutTheRouteOffersNothingNew() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: capabilities, data: F.data("404 page not found"), status: 404)
        let session = try await openedOrganizationSession(http)

        await session.loadSupportCapabilities()

        XCTAssertEqual(session.supportCapabilities, SupportCapabilities.none)
        XCTAssertFalse(session.support.offersPersonSupport)
        XCTAssertFalse(session.support.streams.list)
        XCTAssertNil(session.denial, "a missing route is not a refusal of the organization")
    }

    func testAFailedAnswerIsNotTakenAsNoAndIsAskedAgain() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: capabilities, responses: [
            MockHTTPResponse(data: F.data(F.error("tenant_unavailable")), status: 503),
            MockHTTPResponse(data: F.data(F.capabilities())),
        ])
        let session = try await openedOrganizationSession(http)

        await session.loadSupportCapabilities()
        XCTAssertNil(session.supportCapabilities)
        await session.loadSupportCapabilities()

        XCTAssertTrue(session.support.streams.list)
        XCTAssertEqual(http.state.requests(path: capabilities).count, 2)
    }

    func testTheHostOffersCapabilitiesOnceThePassIsOpenAndKeepsAPassAlreadyOpened() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.supportSession()))
        http.state.stub(path: capabilities, data: F.data(F.capabilities()))
        let session = make(http)
        try await session.openSupport(reason: "Admin locked out; helping her")
        let host = OrganizationHostModel()

        await host.open(session: session, accountSession: nil)

        XCTAssertEqual(host.phase, .ready)
        XCTAssertEqual(http.state.requests(path: mint).count, 1, "the support pass opened with its reason is kept, not minted again")
        XCTAssertTrue(session.support.streams.list)
    }

    // MARK: Refusals in words

    func testTheErrorBodyCarriesTheRefusalReasonAndTheMissingCapability() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "\(F.base)/people/5/password-reset", data: F.data(F.protected("organization_admin")), status: 409)
        http.state.stub(path: "\(F.base)/people/6/password-reset", data: F.data(F.notConfigured("email")), status: 409)
        let session = try await openedOrganizationSession(http)

        var errors: [APIError] = []
        for account: Int64 in [5, 6] {
            do {
                _ = try await session.write { client, _ in try await client.issueOrganizationPasswordReset(accountID: account, delivery: .email, revision: 4) }
            } catch let error as APIError {
                errors.append(error)
            }
        }

        XCTAssertEqual(errors.map(\.code), ["target_protected", "capability_not_configured"])
        XCTAssertEqual(errors.first?.reason, "organization_admin")
        XCTAssertEqual(errors.last?.capability, "email")
        XCTAssertNil(session.denial, "a protected person is not loss of access to the organization")
        XCTAssertEqual(
            session.failureText(errors[0], fallback: "x"),
            "This person is an administrator. Only the organization's owner can help another administrator."
        )
        XCTAssertEqual(session.failureText(errors[1], fallback: "x"), "This server can't send email. Create a link to hand over instead.")
    }

    func testEveryProtectionReasonHasItsOwnWords() {
        let texts = ["self", "platform_account", "organization_owner", "organization_admin", "something_new"].map {
            OrganizationVocabulary.supportRefusal(APIError(statusCode: 409, code: "target_protected", message: "m", reason: $0))
        }
        XCTAssertEqual(Set(texts.compactMap { $0 }).count, 5)
        XCTAssertEqual(texts[0], "You can't do this to your own account. Change your own password or sign out in the app.")
        XCTAssertEqual(texts[2], "This person is the organization's owner. Only the platform operator can help the owner.")
        XCTAssertEqual(texts[4], "This person is protected from this action")
    }

    func testARateLimitSaysHowLongToWait() {
        func text(_ retryAfter: String?) -> String? {
            OrganizationVocabulary.supportRefusal(APIError(statusCode: 429, code: "rate_limited", message: "m", retryAfter: retryAfter))
        }
        XCTAssertEqual(text("45"), "Too many support actions in a short time. Try again in a minute.")
        XCTAssertEqual(text("125"), "Too many support actions in a short time. Try again in 3 minutes.")
        XCTAssertEqual(text(nil), "Too many support actions in a short time. Wait a few minutes and try again.")
    }

    func testOtherAnswersAreLeftToTheUsualWords() {
        XCTAssertNil(OrganizationVocabulary.supportRefusal(APIError(statusCode: 409, code: "authorization_state_changed", message: "m")))
        XCTAssertNil(OrganizationVocabulary.supportRefusal(APIError(statusCode: 404, code: "not_found", message: "m")))
        XCTAssertNil(OrganizationVocabulary.supportRefusal(APIError(statusCode: 422, code: "validation_failed", message: "m")))
    }

    func testTheSupportAuditActionsAreWorded() {
        XCTAssertEqual(OrganizationVocabulary.auditActionText("support_access.opened"), "Platform support opened this organization")
        XCTAssertEqual(OrganizationVocabulary.auditActionText("people.password_reset_issued"), "Password reset link issued")
        XCTAssertEqual(OrganizationVocabulary.auditActionText("stream.stop_refused"), "Stream action refused")
        XCTAssertNotNil(OrganizationVocabulary.resultReason("target_protected"))
    }
}
