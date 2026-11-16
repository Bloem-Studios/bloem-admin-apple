import XCTest
@testable import BloemAdmin

@MainActor
final class InvitationsViewModelTests: XCTestCase {

    func testClaimLinkCopyActionUsesInjectedPasteboardWriter() {
        final class RecordingWriter: ClaimURLPasteboardWriting {
            var copiedClaimURL: String?

            func copy(_ claimURL: String) {
                copiedClaimURL = claimURL
            }
        }
        let writer = RecordingWriter()
        let actions = InvitationClaimLinkActions(pasteboardWriter: writer)

        actions.copy("https://example.test/invitations/claim/secret")

        XCTAssertEqual(writer.copiedClaimURL, "https://example.test/invitations/claim/secret")
    }

    // MARK: - Fixtures

    /// An `AdminInvitation` with every required field.
    private func invitationJSON(id: String = "9", email: String = "new@example.com", status: String = "pending", delivery: String = "email_sent", extra: String = "") -> String {
        #"{"id":"\#(id)","email":"\#(email)","delivery":"\#(delivery)","role":"user","library_ids":null,"create_profile":true,"show_tour":true,"note":"","invited_by":"1","invited_by_name":"Admin","status":"\#(status)","expires_at":"2026-01-01T00:00:00.000Z","created_at":"2026-01-01T00:00:00.000Z"\#(extra)}"#
    }

    private func deliveryJSON(id: String = "9", claim: String = "https://example.com/claim/xyz", status: String = "sent") -> Data {
        Data(#"{"invitation":\#(invitationJSON(id: id)),"claim_url":"\#(claim)","delivery_status":"\#(status)"}"#.utf8)
    }

    private func listJSON(_ items: [String], hasMore: Bool? = nil, cursor: String? = nil) -> Data {
        AuditFixtures.page(items, hasMore: hasMore, cursor: cursor)
    }

    private func makeClient(_ http: MockHTTPHarness) -> APIClient {
        APIClient(baseURL: URL(string: "https://example.test")!, accessToken: nil, session: http.session)
    }

    private func query(_ request: URLRequest?) throws -> [String: String] {
        let url = try XCTUnwrap(request?.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    private func invitation(id: String) throws -> Invitation {
        try JSONDecoder.iso8601.decode(Invitation.self, from: Data(invitationJSON(id: id).utf8))
    }

    // MARK: - Load

    func testLoadDecodesFullInvitationShape() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = listJSON([invitationJSON(id: "1", email: "user@example.com", extra: #","access_group_id":"5","accepted_at":"2026-01-02T00:00:00.500Z","accepted_user_id":"6""#).replacingOccurrences(of: #""library_ids":null"#, with: #""library_ids":["1","2"]"#)])
        let viewModel = InvitationsViewModel()
        await viewModel.load(client: makeClient(http))

        let invitation = try XCTUnwrap(viewModel.invitations.first)
        XCTAssertEqual(invitation.id, "1")
        XCTAssertEqual(invitation.email, "user@example.com")
        XCTAssertEqual(invitation.delivery, "email_sent")
        XCTAssertEqual(invitation.accessGroupID, "5")
        XCTAssertEqual(invitation.libraryIDs, ["1", "2"])
        XCTAssertEqual(invitation.invitedBy, "1")
        XCTAssertEqual(invitation.invitedByName, "Admin")
        XCTAssertTrue(invitation.isPending)
        XCTAssertEqual(invitation.acceptedUserID, "6")
        XCTAssertNotNil(invitation.acceptedAt)
        XCTAssertNil(viewModel.errorMessage)
        let request = try XCTUnwrap(http.state.lastRequest)
        XCTAssertEqual(request.url?.path, "/api/v2/admin/invitations")
        XCTAssertEqual(try query(request), ["limit": "200"])
    }

    func testLoadDecodesMinimalInvitationWithNullLibraries() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = listJSON([invitationJSON(id: "2", email: "", status: "expired", delivery: "link")])
        let viewModel = InvitationsViewModel()
        await viewModel.load(client: makeClient(http))

        let invitation = try XCTUnwrap(viewModel.invitations.first)
        XCTAssertEqual(invitation.email, "")
        XCTAssertFalse(invitation.isPending)
        XCTAssertNil(invitation.libraryIDs)
        XCTAssertNil(invitation.accessGroupID)
        XCTAssertNil(invitation.acceptedAt)
        XCTAssertNil(invitation.acceptedUserID)
    }

    func testLoadFollowsCursorAcrossPages() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/invitations", responses: [
            MockHTTPResponse(data: listJSON([invitationJSON(id: "1")], hasMore: true, cursor: "c2")),
            MockHTTPResponse(data: listJSON([invitationJSON(id: "2")], hasMore: false))
        ])
        let viewModel = InvitationsViewModel()
        await viewModel.load(client: makeClient(http))
        XCTAssertEqual(viewModel.invitations.map(\.id), ["1", "2"])
        XCTAssertEqual(try query(http.state.requestLog.last)["cursor"], "c2")
    }

    func testLoad401FlagsSessionStateTokenExpired() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401
        let rootSessionState = AdminSessionState()
        rootSessionState.setAdministratorToken("admin-token", serverID: "srv-1")
        let client = APIClient(
            baseURL: URL(string: "https://example.test")!,
            credentialProvider: rootSessionState.credentialProvider(serverID: "srv-1"),
            session: http.session
        )
        let viewModel = InvitationsViewModel()
        let sessionState = rootSessionState.scoped(to: "srv-1")

        await viewModel.load(client: client, sessionState: sessionState)

        XCTAssertTrue(sessionState.tokenExpired)
        XCTAssertEqual(viewModel.errorMessage, "Token expired")
    }

    // MARK: - Send (create)

    func testSendDecodesDeliveryAndSendsOnlyEmailRoleAndNote() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/invitations", responses: [
            MockHTTPResponse(data: deliveryJSON(), status: 201),
            MockHTTPResponse(data: listJSON([invitationJSON()]))
        ])
        let viewModel = InvitationsViewModel()

        let delivery = await viewModel.send(email: "new@example.com", role: "user", note: " hi ", client: makeClient(http))

        let unwrapped = try XCTUnwrap(delivery)
        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertTrue(unwrapped.emailSent)
        XCTAssertFalse(unwrapped.deliveryFailed)
        XCTAssertEqual(unwrapped.claimLink, "https://example.com/claim/xyz")
        XCTAssertEqual(viewModel.pendingDelivery, unwrapped)
        XCTAssertEqual(viewModel.invitations.map(\.id), ["9"], "the list reloads after a send")
        let post = try XCTUnwrap(http.state.requestLog.first)
        XCTAssertEqual(post.httpMethod, "POST")
        XCTAssertEqual(post.url?.path, "/api/v2/admin/invitations")
        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/invitations", requestIndex: 0))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object, ["email": "new@example.com", "role": "user", "note": "hi"])
    }

    func testSendOmitsBlankNote() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/invitations", responses: [
            MockHTTPResponse(data: deliveryJSON(), status: 201),
            MockHTTPResponse(data: listJSON([]))
        ])
        await InvitationsViewModel().send(email: "new@example.com", role: "user", note: "  ", client: makeClient(http))
        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/invitations", requestIndex: 0))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["email", "role"])
    }

    func testFailedEmailDeliveryIsFlagged() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/invitations", responses: [
            MockHTTPResponse(data: deliveryJSON(status: "failed_or_unknown"), status: 201),
            MockHTTPResponse(data: listJSON([]))
        ])
        let viewModel = InvitationsViewModel()
        let delivery = await viewModel.send(email: "new@example.com", role: "user", note: nil, client: makeClient(http))
        let unwrapped = try XCTUnwrap(delivery)
        XCTAssertTrue(unwrapped.deliveryFailed)
        XCTAssertFalse(unwrapped.emailSent)
    }

    func testNonFailureDeliveryStatuses() throws {
        for status in ["sent", "not_configured", "not_requested"] {
            let delivery = try JSONDecoder.iso8601.decode(InvitationDelivery.self, from: deliveryJSON(status: status))
            XCTAssertFalse(delivery.deliveryFailed, status)
        }
        let unknown = try JSONDecoder.iso8601.decode(InvitationDelivery.self, from: deliveryJSON(status: "something_new"))
        XCTAssertTrue(unknown.deliveryFailed)
    }

    func testSendFailureSurfacesServerMessageAndStoresNothing() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"email_taken","message":"An account with this email already exists"}"#.utf8)
        http.state.responseStatus = 409
        let viewModel = InvitationsViewModel()

        let delivery = await viewModel.send(email: "taken@example.com", role: "user", note: nil, client: makeClient(http))

        XCTAssertNil(delivery)
        XCTAssertNil(viewModel.pendingDelivery)
        XCTAssertEqual(viewModel.actionErrorMessage, "An account with this email already exists")
    }

    func testSendProblemJSONSurfacesDetail() async {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"type":"https://api.bloem.example/problems/validation","title":"Unprocessable","status":422,"detail":"email is not valid"}"#.utf8)
        http.state.responseStatus = 422
        let viewModel = InvitationsViewModel()
        _ = await viewModel.send(email: "x", role: "user", note: nil, client: makeClient(http))
        XCTAssertEqual(viewModel.actionErrorMessage, "email is not valid")
    }

    /// The 201 holds the only copy of the claim link. If the reload that follows is cancelled,
    /// the link must already be in state.
    func testCancelledReloadAfterSendKeepsClaimLink() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/invitations", responses: [
            MockHTTPResponse(data: deliveryJSON(), status: 201),
            MockHTTPResponse(data: listJSON([invitationJSON()]))
        ])
        http.state.holdGETs(path: "/api/v2/admin/invitations")
        let viewModel = InvitationsViewModel()
        let client = makeClient(http)

        // The POST answers; the reload (a GET) is held, so it is in flight when the task is cancelled.
        let task = Task { await viewModel.send(email: "new@example.com", role: "user", note: nil, client: client) }
        await http.state.waitForRequest(path: "/api/v2/admin/invitations", count: 2)
        XCTAssertEqual(viewModel.pendingDelivery?.claimLink, "https://example.com/claim/xyz", "stored before the reload finishes")
        task.cancel()
        _ = await task.value

        XCTAssertEqual(viewModel.pendingDelivery?.claimLink, "https://example.com/claim/xyz")
        XCTAssertNil(viewModel.errorMessage, "a cancelled reload is not a load failure")
    }

    // MARK: - Resend

    func testResendPostsEmptyBodyToEncodedPathAndStoresDelivery() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/admin/invitations/9/resend", data: deliveryJSON(claim: "https://example.com/claim/again", status: "not_configured"), status: 201)
        http.state.stub(path: "/api/v2/admin/invitations", data: listJSON([invitationJSON()]))
        let viewModel = InvitationsViewModel()

        let delivery = await viewModel.resend(try invitation(id: "9"), client: makeClient(http))

        let unwrapped = try XCTUnwrap(delivery)
        XCTAssertEqual(unwrapped.claimLink, "https://example.com/claim/again")
        XCTAssertFalse(unwrapped.deliveryFailed)
        XCTAssertEqual(viewModel.pendingDelivery, unwrapped)
        let request = try XCTUnwrap(http.state.requests(path: "/api/v2/admin/invitations/9/resend").first)
        XCTAssertEqual(request.httpMethod, "POST")
        let body = try XCTUnwrap(http.state.body(path: "/api/v2/admin/invitations/9/resend", requestIndex: 0))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), "{}")
    }

    func testResendEncodesIDInPath() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = deliveryJSON(id: "a/b")
        http.state.responseStatus = 201
        let viewModel = InvitationsViewModel()
        let delivery = await viewModel.resend(try invitation(id: "a/b"), client: makeClient(http))
        XCTAssertNotNil(delivery)
        XCTAssertEqual(http.state.requestLog.first?.url?.absoluteString, "https://example.test/api/v2/admin/invitations/a%2Fb/resend")
    }

    func testCancelledReloadAfterResendKeepsClaimLink() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/api/v2/admin/invitations/9/resend", data: deliveryJSON(claim: "https://example.com/claim/again"), status: 201)
        http.state.stub(path: "/api/v2/admin/invitations", response: MockHTTPResponse(data: listJSON([])), delayUntilReleased: true)
        let viewModel = InvitationsViewModel()
        let client = makeClient(http)
        let target = try invitation(id: "9")

        let task = Task { await viewModel.resend(target, client: client) }
        await http.state.waitForRequest(path: "/api/v2/admin/invitations")
        XCTAssertEqual(viewModel.pendingDelivery?.claimLink, "https://example.com/claim/again", "stored before the reload finishes")
        task.cancel()
        _ = await task.value

        XCTAssertEqual(viewModel.pendingDelivery?.claimLink, "https://example.com/claim/again")
        XCTAssertNil(viewModel.errorMessage)
    }

    func testDismissDeliveryReleasesTheLink() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stubSequence(path: "/api/v2/admin/invitations", responses: [
            MockHTTPResponse(data: deliveryJSON(), status: 201),
            MockHTTPResponse(data: listJSON([]))
        ])
        let viewModel = InvitationsViewModel()
        await viewModel.send(email: "a@b.c", role: "user", note: nil, client: makeClient(http))
        XCTAssertNotNil(viewModel.pendingDelivery)
        viewModel.dismissDelivery()
        XCTAssertNil(viewModel.pendingDelivery)
    }

    // MARK: - Revoke

    func testRevokeSendsDeleteToEncodedPath() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseStatus = 204
        let viewModel = InvitationsViewModel()

        await viewModel.revoke(try invitation(id: "a b"), client: makeClient(http))

        XCTAssertNil(viewModel.actionErrorMessage)
        XCTAssertEqual(http.state.lastRequest?.url?.absoluteString, "https://example.test/api/v2/admin/invitations/a%20b")
        XCTAssertEqual(http.state.lastRequest?.httpMethod, "DELETE")
    }

    func testRevokeNotFoundSurfacesServerMessage() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.responseData = Data(#"{"error":"not_found","message":"Invitation not found"}"#.utf8)
        http.state.responseStatus = 404
        let viewModel = InvitationsViewModel()
        await viewModel.revoke(try invitation(id: "999"), client: makeClient(http))
        XCTAssertEqual(viewModel.actionErrorMessage, "Invitation not found")
    }
}
