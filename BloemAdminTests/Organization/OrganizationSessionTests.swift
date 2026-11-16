import XCTest
@testable import BloemAdmin

@MainActor
final class OrgTestClock {
    var date = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

/// The pass exchange: the pass lives in memory, bears every organization call, renews on a stale 401 for a read
/// (once), and is never replayed for a write.
@MainActor
final class OrganizationSessionTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let mint = "/api/bloem/v2/admin/session"
    private let overview = "\(F.base)/overview"
    private let person = "\(F.base)/people/5/memberships/current"

    private func make(
        _ http: MockHTTPHarness,
        clock: OrgTestClock = OrgTestClock(),
        organizationID: String = F.orgID
    ) -> OrganizationSession {
        let account = APIClient(baseURL: URL(string: "https://example.test")!, accessToken: "account-token", session: http.session)
        return OrganizationSession(
            account: account, baseURL: URL(string: "https://example.test")!, organizationID: organizationID,
            session: http.session, now: { clock.date }
        )
    }

    private func authorization(_ request: URLRequest?) -> String? {
        request?.value(forHTTPHeaderField: "Authorization")
    }

    func testOpenExchangesTheAccountTokenForAPassForExactlyThisOrganization() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        let session = make(http)

        let context = try await session.open()

        XCTAssertEqual(context.organizationID, F.orgID)
        XCTAssertEqual(context.authority, .organizationAdmin)
        XCTAssertEqual(session.policyRevision, 7)
        let request = try XCTUnwrap(http.state.requests(path: mint).first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(authorization(request), "Bearer account-token")
        let body = try XCTUnwrap(http.state.body(path: mint, requestIndex: 0))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json, ["scope": "organization", "organization_id": F.orgID])
    }

    func testThePassNotTheAccountTokenBearsOrganizationCalls() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        http.state.stub(path: overview, data: F.data(F.overview()))
        let session = make(http)
        try await session.open()

        let summary = try await session.read { try await $0.organizationOverview() }

        XCTAssertEqual(summary.name, "Acme Media")
        XCTAssertEqual(authorization(http.state.requests(path: overview).first), "Bearer \(F.pass)")
    }

    func testAPassForAnotherOrganizationIsRefused() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session(organizationID: "someone-else")))
        let session = make(http)

        do {
            try await session.open()
            XCTFail("a pass for another organization must not be accepted")
        } catch let denied as OrganizationAccessDenied {
            XCTAssertEqual(denied.reason, .lostAuthority)
        }
        XCTAssertTrue(session.accessDenied)
        do {
            _ = try await session.read { try await $0.organizationOverview() }
            XCTFail("no client without a pass")
        } catch is OrganizationAccessDenied {}
        XCTAssertTrue(http.state.requests(path: overview).isEmpty)
    }

    func testAPlatformScopedPassIsRefused() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session(scope: "platform")))
        let session = make(http)
        do {
            try await session.open()
            XCTFail("a platform pass must not open an organization")
        } catch is OrganizationAccessDenied {}
    }

    func testSuspendedOtherForbiddenAndMissingAreToldApart() async throws {
        let cases: [(Int, String, OrganizationDenial)] = [
            (403, "organization_suspended", .suspended),
            (403, "insufficient_organization_authority", .lostAuthority),
            (404, "not_found", .notFound),
        ]
        for (status, code, reason) in cases {
            let http = MockHTTPHarness()
            defer { http.invalidate() }
            http.state.stub(path: mint, data: F.data(F.error(code)), status: status)
            let session = make(http)
            do {
                try await session.open()
                XCTFail("\(code) must not open")
            } catch let denied as OrganizationAccessDenied {
                XCTAssertEqual(denied.reason, reason, code)
            }
            XCTAssertEqual(session.denial, reason, code)
        }
    }

    func testTheFirstDenialSticks() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        http.state.stub(path: overview, data: F.data(F.error("organization_suspended")), status: 403)
        let session = make(http)
        try await session.open()

        _ = try? await session.read { try await $0.organizationOverview() }
        session.markDenied(.lostAuthority)

        XCTAssertEqual(session.denial, .suspended)
    }

    func testAReadThatGetsA401RenewsThePassOnceAndIsRetried() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session(token: "pass-1"))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-2"))),
        ])
        http.state.stubSequence(path: overview, responses: [
            MockHTTPResponse(data: F.data(F.error("tenant_session_required")), status: 401),
            MockHTTPResponse(data: F.data(F.overview())),
        ])
        let session = make(http)
        try await session.open()

        let summary = try await session.read { try await $0.organizationOverview() }

        XCTAssertEqual(summary.id, F.orgID)
        XCTAssertEqual(http.state.requests(path: mint).count, 2)
        let reads = http.state.requests(path: overview)
        XCTAssertEqual(reads.map(authorization), ["Bearer pass-1", "Bearer pass-2"])
    }

    func testAReadIsRetriedOnlyOnce() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session(token: "pass-1"))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-2"))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-3"))),
        ])
        http.state.stub(path: overview, data: F.data(F.error("authorization_state_stale")), status: 401)
        let session = make(http)
        try await session.open()

        do {
            _ = try await session.read { try await $0.organizationOverview() }
            XCTFail("a second 401 must surface")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }

        XCTAssertEqual(http.state.requests(path: overview).count, 2, "one try and one retry")
        XCTAssertEqual(http.state.requests(path: mint).count, 2, "one renewal")
    }

    func testParallelReadsShareOneRenewal() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session(token: "pass-1"))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-2"))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-3"))),
        ])
        http.state.stubSequence(path: overview, responses: [
            MockHTTPResponse(data: F.data(F.error("authorization_state_stale")), status: 401),
            MockHTTPResponse(data: F.data(F.error("authorization_state_stale")), status: 401),
            MockHTTPResponse(data: F.data(F.overview())),
            MockHTTPResponse(data: F.data(F.overview())),
        ])
        let session = make(http)
        try await session.open()

        let first = Task { @MainActor in try await session.read { try await $0.organizationOverview() } }
        let second = Task { @MainActor in try await session.read { try await $0.organizationOverview() } }
        _ = try await first.value
        _ = try await second.value

        XCTAssertEqual(http.state.requests(path: mint).count, 2, "open plus one shared renewal")
    }

    func testAWriteIsNeverReplayedAndAStalePassIsRenewedForTheReload() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session(token: "pass-1", policyRevision: 7))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-2", policyRevision: 8))),
        ])
        http.state.stub(path: person, data: F.data(F.error("authorization_state_stale")), status: 401)
        let session = make(http)
        try await session.open()

        do {
            _ = try await session.write { client, _ in
                try await client.setOrganizationMembershipStatus(accountID: 5, status: "suspended", revision: 4)
            }
            XCTFail("a stale write must be reported, not retried")
        } catch let changed as OrganizationStateChanged {
            XCTAssertFalse(changed.wasConflict)
        }

        XCTAssertEqual(http.state.requests(path: person).count, 1, "the write is sent once")
        XCTAssertEqual(http.state.requests(path: mint).count, 2, "the pass is renewed")
        XCTAssertEqual(session.policyRevision, 8)
    }

    func testARevisionConflictRenewsAndNeverReplays() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session(token: "pass-1"))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-2"))),
        ])
        http.state.stub(path: person, data: F.data(F.error("authorization_state_changed")), status: 409)
        let session = make(http)
        try await session.open()

        do {
            _ = try await session.write { client, _ in
                try await client.setOrganizationMembershipStatus(accountID: 5, status: "suspended", revision: 4)
            }
            XCTFail("a conflict must be reported")
        } catch let changed as OrganizationStateChanged {
            XCTAssertTrue(changed.wasConflict)
        }
        XCTAssertEqual(http.state.requests(path: person).count, 1)
    }

    func testAWriteThatGetsAnyOther401IsNotReplayedEither() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session(token: "pass-1"))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-2"))),
        ])
        http.state.stub(path: person, data: F.data(F.error("unauthorized")), status: 401)
        let session = make(http)
        try await session.open()

        do {
            _ = try await session.write { client, _ in
                try await client.setOrganizationMembershipStatus(accountID: 5, status: "active", revision: 4)
            }
            XCTFail("expected a state change")
        } catch is OrganizationStateChanged {}
        XCTAssertEqual(http.state.requests(path: person).count, 1)
    }

    func testAWriteQuotesTheCurrentPolicyRevisionAndRenewsANearlyExpiredPassFirst() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session(token: "pass-1", policyRevision: 7))),
            MockHTTPResponse(data: F.data(F.session(token: "pass-2", policyRevision: 9, expiresAt: "2026-11-13T12:30:00Z"))),
        ])
        http.state.stub(path: person, data: F.data(F.personResponse()))
        let clock = OrgTestClock()
        let session = make(http, clock: clock)
        try await session.open()

        let first = try await session.write { _, revision in revision }
        XCTAssertEqual(first, 7)

        clock.advance(14 * 60 + 30)
        let second = try await session.write { client, revision in
            _ = try await client.setOrganizationMembershipStatus(accountID: 5, status: "suspended", revision: 4)
            return revision
        }

        XCTAssertEqual(second, 9, "the renewal happens before the write and its revision is quoted")
        XCTAssertEqual(authorization(http.state.requests(path: person).first), "Bearer pass-2")
        XCTAssertEqual(http.state.requests(path: mint).count, 2)
    }

    func testAForbiddenWriteIsRecordedAsDenialAndNotReplayed() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        http.state.stub(path: person, data: F.data(F.error("organization_suspended")), status: 403)
        let session = make(http)
        try await session.open()

        do {
            _ = try await session.write { client, _ in
                try await client.setOrganizationMembershipStatus(accountID: 5, status: "suspended", revision: 4)
            }
            XCTFail("expected 403")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 403)
        }
        XCTAssertEqual(session.denial, .suspended)
        XCTAssertEqual(http.state.requests(path: person).count, 1)
    }

    func testARenewalTheServerRefusesEndsTheHoldOnTheOrganization() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(F.session())),
            MockHTTPResponse(data: F.data(F.error("organization_suspended")), status: 403),
        ])
        http.state.stub(path: overview, data: F.data(F.error("authorization_state_stale")), status: 401)
        let session = make(http)
        try await session.open()

        do {
            _ = try await session.read { try await $0.organizationOverview() }
            XCTFail("the renewal was refused")
        } catch let denied as OrganizationAccessDenied {
            XCTAssertEqual(denied.reason, .suspended)
        }
        XCTAssertEqual(session.denial, .suspended)
    }

    func testClosingDropsThePass() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        let session = make(http)
        try await session.open()

        session.close()

        XCTAssertNil(session.context)
        do {
            _ = try await session.read { try await $0.organizationOverview() }
            XCTFail("no pass after close")
        } catch is OrganizationAccessDenied {}
    }

    func testARenewalStillInFlightWhenTheSessionClosesDoesNotBringThePassBack() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(F.session()))
        http.state.stub(path: overview, data: F.data(F.error("authorization_state_stale")), status: 401)
        let session = make(http)
        try await session.open()
        http.state.stub(path: mint, response: MockHTTPResponse(data: F.data(F.session(token: "late-pass"))), delayUntilReleased: true)

        let reading = Task { @MainActor in try await session.read { try await $0.organizationOverview() } }
        await http.state.waitForRequest(path: mint, count: 2)
        session.close()
        http.state.releaseResponses(matching: mint)
        _ = try? await reading.value

        XCTAssertNil(session.context)
        do {
            _ = try await session.read { try await $0.organizationOverview() }
            XCTFail("a closed session has no pass")
        } catch is OrganizationAccessDenied {
        } catch is CancellationError {}
        XCTAssertFalse(http.state.requests(path: overview).contains { $0.value(forHTTPHeaderField: "Authorization") == "Bearer late-pass" })
    }

    func testThePassAndTheClaimTokenAreRedactedWhenPrinted() throws {
        let response = try JSONDecoder().decode(AdminSessionResponse.self, from: F.data(F.session(token: "secret-pass")))
        XCTAssertFalse("\(response)".contains("secret-pass"))
        let handoff = try JSONDecoder().decode(InvitationHandoff.self, from: F.data(F.handoff(token: "secret-claim")))
        XCTAssertFalse("\(handoff)".contains("secret-claim"))
    }

    func testFailureTextTellsEachRefusalApart() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        let session = make(http)
        let suspended = APIError(statusCode: 403, code: "organization_suspended", message: "x")
        let other = APIError(statusCode: 403, code: "insufficient_organization_authority", message: "x")
        XCTAssertEqual(session.failureText(suspended, fallback: "f"), OrganizationDenial.suspended.message)
        XCTAssertEqual(session.denial, .suspended)
        XCTAssertNotEqual(OrganizationDenial.suspended.message, OrganizationDenial.lostAuthority.message)
        XCTAssertNotEqual(OrganizationDenial.notFound.message, OrganizationDenial.lostAuthority.message)
        XCTAssertEqual(session.failureText(other, fallback: "f"), OrganizationDenial.lostAuthority.message)
        XCTAssertEqual(session.failureText(OrganizationStateChanged(wasConflict: true), fallback: "f").contains("Someone else"), true)
        XCTAssertEqual(session.failureText(APIError(statusCode: 422, message: "validation"), fallback: "f", refused: "refused"), "refused")
        XCTAssertEqual(session.failureText(APIError(statusCode: 500, message: "boom"), fallback: "f"), "boom")
        XCTAssertEqual(session.failureText(TestError.expected, fallback: "f"), "f")
    }
}
