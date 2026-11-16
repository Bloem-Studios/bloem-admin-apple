import XCTest
@testable import BloemAdmin

@MainActor
final class AdminSessionStateTests: XCTestCase {
    func testStaleAdmin401CannotExpireReplacementGeneration() {
        let state = AdminSessionState()
        state.setAdministratorToken("admin-1", serverID: "srv")
        let oldIdentity = state.requestCredential(serverID: "srv")!.identity
        state.setAdministratorToken("admin-2", serverID: "srv")

        let message = state.handleAuthenticationFailure(
            APIError(statusCode: 401, message: "expired", requestIdentity: oldIdentity)
        )

        XCTAssertEqual(message, "expired")
        XCTAssertFalse(state.isTokenExpired(for: "srv"))
        XCTAssertEqual(state.requestCredential(serverID: "srv")?.accessToken, "admin-2")
    }

    func testCurrentAdministrator401ExpiresOnlyCapturedServer() {
        let state = AdminSessionState()
        state.setAdministratorToken("admin-a", serverID: "srv-A")
        state.setAdministratorToken("admin-b", serverID: "srv-B")
        let identity = state.requestCredential(serverID: "srv-A")!.identity

        let message = state.handleAuthenticationFailure(
            APIError(statusCode: 401, message: "expired", requestIdentity: identity)
        )

        XCTAssertEqual(message, "expired")
        XCTAssertTrue(state.isTokenExpired(for: "srv-A"))
        XCTAssertNil(state.requestCredential(serverID: "srv-A"))
        XCTAssertFalse(state.isTokenExpired(for: "srv-B"))
        XCTAssertEqual(state.requestCredential(serverID: "srv-B")?.accessToken, "admin-b")
    }

    func testCurrentAdministrator403DoesNotExpireSession() {
        let state = AdminSessionState()
        state.setAdministratorToken("admin", serverID: "srv")
        let identity = state.requestCredential(serverID: "srv")!.identity

        let message = state.handleAuthenticationFailure(
            APIError(statusCode: 403, message: "forbidden", requestIdentity: identity)
        )

        XCTAssertEqual(message, "No admin access")
        XCTAssertFalse(state.isTokenExpired(for: "srv"))
        XCTAssertEqual(state.requestCredential(serverID: "srv")?.accessToken, "admin")
    }

    func testAuthenticationFailureWithoutCapturedIdentityDoesNotMutateSession() {
        let state = AdminSessionState()
        state.setAdministratorToken("admin", serverID: "srv")

        let message = state.handleAuthenticationFailure(APIError(statusCode: 401, message: "expired"))

        XCTAssertNil(message)
        XCTAssertFalse(state.isTokenExpired(for: "srv"))
        XCTAssertEqual(state.requestCredential(serverID: "srv")?.accessToken, "admin")
    }

    func testSeedStoredAdministratorsBuildsAuthenticatedFirstRequestClients() async throws {
        let http = MockHTTPHarness()
        defer { http.invalidate() }
        http.state.stub(path: "/action", data: Data(), status: 204)
        let first = AdminServer(id: "srv-A", baseURL: URL(string: "https://a.example.test")!, displayName: "A")
        let second = AdminServer(id: "srv-B", baseURL: URL(string: "https://b.example.test")!, displayName: "B")
        let store = makeIsolatedServerStore()
        try store.addServer(first, accessToken: "admin-a")
        try store.addServer(second, accessToken: "admin-b")
        let state = AdminSessionState()

        let clients = store.authenticatedClients(for: [first, second], sessionState: state, session: http.session)
        try await clients[first.id]!.post("/action")
        try await clients[second.id]!.post("/action")

        XCTAssertEqual(http.state.requests(host: "a.example.test", path: "/action").first?.value(forHTTPHeaderField: "Authorization"), "Bearer admin-a")
        XCTAssertEqual(http.state.requests(host: "b.example.test", path: "/action").first?.value(forHTTPHeaderField: "Authorization"), "Bearer admin-b")
    }

    func testStoredSeedDoesNotOverwriteNewerRuntimeAdministrator() throws {
        let store = makeIsolatedServerStore()
        try store.updateToken("stored-old", forServerID: "srv")
        let state = AdminSessionState()
        state.setAdministratorToken("runtime-new", serverID: "srv")
        let identity = state.requestCredential(serverID: "srv")!.identity

        store.seedAdministratorCredentialIfAbsent(in: state, serverID: "srv")

        XCTAssertEqual(state.requestCredential(serverID: "srv")?.accessToken, "runtime-new")
        XCTAssertEqual(state.requestCredential(serverID: "srv")?.identity, identity)
    }

    func testSignOutClearsOnlyMatchingRuntimeSessionAfterCredentialDeletion() throws {
        let store = makeIsolatedServerStore()
        try store.updateToken("stored-a", forServerID: "srv-A")
        try store.updateToken("stored-b", forServerID: "srv-B")
        let state = AdminSessionState()
        state.setAdministratorToken("admin-a", serverID: "srv-A")
        state.setAdministratorToken("admin-b", serverID: "srv-B")

        try store.signOut("srv-A", sessionState: state)

        XCTAssertNil(try store.credentials(for: "srv-A"))
        XCTAssertNil(state.requestCredential(serverID: "srv-A"))
        XCTAssertEqual(state.requestCredential(serverID: "srv-B")?.accessToken, "admin-b")
    }

    func testSignOutDeletionFailureLeavesRuntimeSessionUntouched() throws {
        let credentials = InMemoryCredentialStore(deleteError: TestError.expected)
        let store = ServerStore(metadataStore: InMemoryServerMetadataStore(), credentialStore: credentials)
        try store.updateToken("stored", forServerID: "srv")
        let state = AdminSessionState()
        state.setAdministratorToken("admin", serverID: "srv")

        XCTAssertThrowsError(try store.signOut("srv", sessionState: state))

        XCTAssertEqual(state.requestCredential(serverID: "srv")?.accessToken, "admin")
    }

    func testRemovalClearsOnlyRemovedServerRuntimeSession() throws {
        let store = makeIsolatedServerStore()
        let first = AdminServer(id: "srv-A", baseURL: URL(string: "https://a.example.test")!, displayName: "A")
        let second = AdminServer(id: "srv-B", baseURL: URL(string: "https://b.example.test")!, displayName: "B")
        try store.addServer(first, accessToken: "admin-a")
        try store.addServer(second, accessToken: "admin-b")
        let state = AdminSessionState()
        state.setAdministratorToken("admin-a", serverID: "srv-A")
        state.setAdministratorToken("admin-b", serverID: "srv-B")

        try store.removeServer("srv-A", sessionState: state)

        XCTAssertNil(state.requestCredential(serverID: "srv-A"))
        XCTAssertEqual(state.requestCredential(serverID: "srv-B")?.accessToken, "admin-b")
    }

    func testScopedSessionRoutesCapturedFailureIdentityRatherThanItsOwnServerID() {
        let state = AdminSessionState()
        state.setAdministratorToken("admin-a", serverID: "srv-A")
        state.setAdministratorToken("admin-b", serverID: "srv-B")
        let identityB = state.requestCredential(serverID: "srv-B")!.identity
        let scopedA = state.scoped(to: "srv-A")

        _ = scopedA.handleAuthenticationFailure(
            APIError(statusCode: 401, message: "expired", requestIdentity: identityB)
        )

        XCTAssertFalse(state.isTokenExpired(for: "srv-A"))
        XCTAssertTrue(state.isTokenExpired(for: "srv-B"))
    }

}
