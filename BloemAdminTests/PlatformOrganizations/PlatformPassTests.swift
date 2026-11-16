import XCTest
@testable import BloemAdmin

/// The platform pass the Organizations pages and Support access share: minted from the account token with
/// `scope: platform`, kept in memory, renewed once when the server says it is stale. A read is asked again after a
/// renewal; a write never is.
@MainActor
final class PlatformPassTests: XCTestCase {
    typealias F = OrganizationFixtures

    private let mint = "/api/bloem/v2/admin/session"
    private let probe = "/api/bloem/v2/admin/platform/organizations"
    private let baseURL = URL(string: "https://example.test")!

    private func platformPass(_ token: String, scope: String = "platform") -> String {
        #"{"access_token":"\#(token)","expires_at":"2026-11-13T12:15:00Z","context":{"key":"\#(scope)","scope":"\#(scope)","name":"Platform","status":"active","authority":"platform_admin"}}"#
    }

    private func pass(_ http: MockHTTPHarness) -> PlatformPass {
        PlatformPass(account: APIClient(baseURL: baseURL, accessToken: "account-token", session: http.session), baseURL: baseURL, session: http.session)
    }

    private func authorizations(_ http: MockHTTPHarness) -> [String?] {
        http.state.requests(path: probe).map { $0.value(forHTTPHeaderField: "Authorization") }
    }

    private func call(_ client: APIClient) async throws -> String {
        let page: PlatformOrganizationsPage = try await client.get(probe)
        return page.organizations.first?.name ?? "none"
    }

    func testTheFirstReadMintsAPlatformPassFromTheAccountToken() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(platformPass("pass-1")))
        http.state.stub(path: probe, data: F.data(#"{"organizations":[]}"#))

        _ = try await pass(http).read(call)

        XCTAssertEqual(try JSONSerialization.jsonObject(with: XCTUnwrap(http.state.body(path: mint, requestIndex: 0))) as? [String: String], ["scope": "platform"])
        XCTAssertEqual(http.state.requests(path: mint).first?.value(forHTTPHeaderField: "Authorization"), "Bearer account-token")
        XCTAssertEqual(authorizations(http), ["Bearer pass-1"])
    }

    func testThePassIsKeptBetweenReads() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(platformPass("pass-1")))
        http.state.stub(path: probe, data: F.data(#"{"organizations":[]}"#))
        let held = pass(http)

        _ = try await held.read(call)
        _ = try await held.read(call)

        XCTAssertEqual(http.state.requests(path: mint).count, 1)
    }

    func testAReadIsAskedAgainOnceWithANewPassWhenTheServerCallsTheOldOneStale() async throws {
        for code in ["authorization_state_stale", "tenant_session_required"] {
            let http = MockHTTPHarness()
            defer { http.invalidate() }
            http.state.stubSequence(path: mint, responses: [
                MockHTTPResponse(data: F.data(platformPass("pass-1"))), MockHTTPResponse(data: F.data(platformPass("pass-2"))),
            ])
            http.state.stubSequence(path: probe, responses: [
                MockHTTPResponse(data: F.data(F.error(code)), status: 401),
                MockHTTPResponse(data: F.data(#"{"organizations":[]}"#)),
            ])

            _ = try await pass(http).read(call)

            XCTAssertEqual(authorizations(http), ["Bearer pass-1", "Bearer pass-2"], code)
        }
    }

    func testAReadThatIsRefusedAgainAfterARenewalFails() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(platformPass("pass-1"))), MockHTTPResponse(data: F.data(platformPass("pass-2"))),
        ])
        http.state.stub(path: probe, data: F.data(F.error("authorization_state_stale")), status: 401)

        do {
            _ = try await pass(http).read(call)
            XCTFail("a second 401 must surface")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 401)
        }
        XCTAssertEqual(http.state.requests(path: mint).count, 2, "renewed once, not in a loop")
    }

    func testAWriteIsNeverSentAgainAfterARenewal() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: mint, responses: [
            MockHTTPResponse(data: F.data(platformPass("pass-1"))), MockHTTPResponse(data: F.data(platformPass("pass-2"))),
        ])
        http.state.stub(path: probe, data: F.data(F.error("tenant_session_required")), status: 401)

        do {
            _ = try await pass(http).write(call)
            XCTFail("a write refused as stale must tell the caller to look again")
        } catch let changed as PlatformStateChanged {
            XCTAssertFalse(changed.wasConflict)
        }
        XCTAssertEqual(http.state.requests(path: probe).count, 1, "the write was sent once")
        XCTAssertEqual(http.state.requests(path: mint).count, 2, "the pass was renewed for what comes next")
    }

    func testAWriteThatLostARaceSaysSoAndIsNotSentAgain() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(platformPass("pass-1")))
        http.state.stub(
            path: probe,
            data: F.data(#"{"error":"authorization_state_changed","message":"Authorization state changed; reload and retry","current_revision":9}"#),
            status: 409
        )

        do {
            _ = try await pass(http).write(call)
            XCTFail("a 409 must surface as a state change")
        } catch let changed as PlatformStateChanged {
            XCTAssertTrue(changed.wasConflict)
        }
        XCTAssertEqual(http.state.requests(path: probe).count, 1)
    }

    func testAnotherRefusalPassesThroughUntouched() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(platformPass("pass-1")))
        http.state.stub(path: probe, data: F.data(F.error("membership_conflict")), status: 409)

        do {
            _ = try await pass(http).write(call)
            XCTFail("expected the server's refusal")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 409)
            XCTAssertEqual(error.code, "membership_conflict")
        }
    }

    func testAMintThatIsNotAPlatformPassIsRefused() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(platformPass("pass-1", scope: "organization")))

        do {
            _ = try await pass(http).read(call)
            XCTFail("an organization pass must never stand in for a platform one")
        } catch let error as APIError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertEqual(error.code, "insufficient_platform_authority")
        }
        XCTAssertTrue(http.state.requests(path: probe).isEmpty)
    }

    func testClosingDropsThePassSoTheNextReadMintsANewOne() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: mint, data: F.data(platformPass("pass-1")))
        http.state.stub(path: probe, data: F.data(#"{"organizations":[]}"#))
        let held = pass(http)
        _ = try await held.read(call)

        held.close()
        _ = try await held.read(call)

        XCTAssertEqual(http.state.requests(path: mint).count, 2)
    }
}
