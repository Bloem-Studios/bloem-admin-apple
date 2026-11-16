import Foundation

/// The account a sign-in authenticates (`Account` in the v2 contract). Only the fields the
/// app reads are kept; the id is a string in v2.
struct LoggedInUser: Decodable, Sendable, Equatable {
    let id: String
    let username: String
    let email: String
    let role: String
    let permissions: [String]
    let downloadAllowed: Bool
    let passwordChangeRequired: Bool

    enum CodingKeys: String, CodingKey {
        case id, username, email, role, permissions
        case downloadAllowed = "download_allowed"
        case passwordChangeRequired = "password_change_required"
    }
}

/// `POST /api/v2/auth/login` response.
struct TokenPair: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let user: LoggedInUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case user
    }
}

/// `POST /api/v2/auth/refresh` response. The refresh token is rotated on every call, so both
/// tokens must be stored together.
struct RefreshedTokens: Decodable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
}

struct LoginRequest: Encodable {
    let username: String
    let password: String
    let provider: String?
}

struct RefreshRequest: Encodable {
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case refreshToken = "refresh_token"
    }
}

/// Unauthenticated auth calls. Home for sign-in methods; keep every auth path literal here.
enum AuthAPI {
    static func login(baseURL: URL, username: String, password: String, session: URLSession? = nil) async throws -> TokenPair {
        let client = APIClient(baseURL: baseURL, accessToken: nil, session: session)
        return try await client.post(
            "/api/v2/auth/login",
            body: LoginRequest(username: username, password: password, provider: nil)
        )
    }

    /// `GET /api/v2/system/identity`: the server's stable id, read before an OAuth start. No token.
    static func serverIdentity(baseURL: URL, session: URLSession? = nil) async throws -> ServerIdentity {
        let client = APIClient(baseURL: baseURL, accessToken: nil, session: session)
        return try await client.get("/api/v2/system/identity")
    }

    /// `GET /api/v2/auth/providers`: the sign-in methods the server offers. No token.
    static func authProviders(baseURL: URL, session: URLSession? = nil) async throws -> AuthProviderCollection {
        let client = APIClient(baseURL: baseURL, accessToken: nil, session: session)
        return try await client.get("/api/v2/auth/providers")
    }

    /// `POST /api/v2/auth/oauth/complete`: redeems the one-time code with the PKCE verifier, within
    /// 60 seconds and once. Device headers are not sent, matching password sign-in.
    static func completeOAuthLogin(baseURL: URL, code: String, verifier: String, session: URLSession? = nil) async throws -> OAuthCompletion {
        let client = APIClient(baseURL: baseURL, accessToken: nil, session: session)
        return try await client.post(
            "/api/v2/auth/oauth/complete",
            body: OAuthCompleteRequest(code: code, codeVerifier: verifier)
        )
    }

    /// Exchanges a stored refresh token for fresh tokens. The server rotates the refresh token
    /// on every successful call (the old one is single-use), so the response's `refreshToken`
    /// MUST replace the stored one. Failure (401) means refresh is dead and the caller must
    /// sign in again.
    static func refresh(baseURL: URL, refreshToken: String, session: URLSession? = nil) async throws -> RefreshedTokens {
        let client = APIClient(baseURL: baseURL, accessToken: nil, session: session)
        return try await client.post(
            "/api/v2/auth/refresh",
            body: RefreshRequest(refreshToken: refreshToken)
        )
    }
}
