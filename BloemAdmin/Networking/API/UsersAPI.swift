import Foundation

/// `201` body of `POST /api/v2/admin/users`.
struct CreatedUser: Decodable, Sendable {
    let id: String
}

/// `200` body of `DELETE /api/v2/admin/users/{user_id}/login-sessions`.
struct LoginSessionsRevoked: Decodable, Sendable {
    let revoked: Int
}

extension APIClient {
    private static func userPath(_ id: String, _ suffix: String = "") -> String {
        "/api/v2/admin/users/\(APIPath.segment(id))\(suffix)"
    }

    /// Every account, following the list cursor. The route allows a `limit` up to 200.
    func users() async throws -> [AdminUser] {
        try await readAllPages("/api/v2/admin/users")
    }

    /// One account plus the ETag that guards the next write to it.
    func user(id: String) async throws -> (AdminUser, String?) {
        try await getWithValidator(Self.userPath(id))
    }

    func createUser(_ body: CreateUserRequest) async throws -> CreatedUser {
        try await post("/api/v2/admin/users", body: body)
    }

    /// `PUT /api/v2/admin/users/{id}` with `If-Match`; answers 204 and is never replayed.
    func updateUser(id: String, body: some Encodable, validator: String) async throws {
        try await putConditional(Self.userPath(id), body: body, validator: validator)
    }

    /// `DELETE /api/v2/admin/users/{id}` with `If-Match`; answers 204 and is never replayed.
    func deleteUser(id: String, validator: String) async throws {
        try await deleteConditional(Self.userPath(id), validator: validator)
    }

    /// The user's login sessions. The route allows a `limit` up to 200.
    func loginSessions(userID: String) async throws -> [AuthSession] {
        try await readAllPages(Self.userPath(userID, "/login-sessions"))
    }

    func revokeLoginSession(userID: String, sessionID: String) async throws {
        try await delete(Self.userPath(userID, "/login-sessions/\(APIPath.segment(sessionID))"))
    }

    /// Revokes every live login session of the user and returns how many there were.
    func revokeAllLoginSessions(userID: String) async throws -> Int {
        let result: LoginSessionsRevoked = try await deleteDecoding(Self.userPath(userID, "/login-sessions"))
        return result.revoked
    }

    /// The user's devices. The route declares no paging, so this is one request with no query.
    func userDevices(userID: String) async throws -> [UserDevice] {
        let collection: APICollection<UserDevice> = try await getCollection(Self.userPath(userID, "/devices"))
        return collection.items
    }
}
