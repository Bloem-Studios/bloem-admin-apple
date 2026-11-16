import Foundation

/// `GET /api/v2/system/identity` (`ServerIdentity`): the stable id of the deployment. The sign-in
/// redirect's `server` must equal it.
struct ServerIdentity: Decodable, Sendable, Equatable {
    let serverID: String

    enum CodingKeys: String, CodingKey {
        case serverID = "server_id"
    }
}

/// One sign-in method from `GET /api/v2/auth/providers` (`AuthProvider`). Only what the app reads is
/// kept; `icon_url` is deliberately not loaded and `network` providers are not offered.
struct AuthProvider: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let mode: String
    let isDefault: Bool
    /// A string in the contract, not a number.
    let installationID: String?
    let nativeStartPath: String?

    enum CodingKeys: String, CodingKey {
        case id, mode
        case displayName = "display_name"
        case isDefault = "default"
        case installationID = "installation_id"
        case nativeStartPath = "native_start_path"
    }

    /// Authentik, which the staff apps list first (maintainer, 2026-11-16). A server describes a provider only by an id and a
    /// display name, so it counts as Authentik when either says so.
    var isAuthentik: Bool {
        id.range(of: "authentik", options: .caseInsensitive) != nil
            || displayName.range(of: "authentik", options: .caseInsensitive) != nil
    }
}

/// `AuthProviderCollection`. `page` is ignored: providers are a bounded list.
struct AuthProviderCollection: Decodable, Sendable, Equatable {
    /// False hides the username and password form.
    let passwordLogin: Bool
    let items: [AuthProvider]

    enum CodingKeys: String, CodingKey {
        case passwordLogin = "password_login"
        case items
    }

    /// OAuth providers that offer native sign-in: Authentik first, then the server's default, then the rest in server
    /// order. (The server's `default` flag alone put Authentik first only on a server that happened to set it.)
    var nativeOAuth: [AuthProvider] {
        let native = items.filter { $0.mode == "oauth" && $0.nativeStartPath != nil }
        let authentik = native.filter(\.isAuthentik)
        let others = native.filter { !$0.isAuthentik }
        return authentik + others.filter(\.isDefault) + others.filter { !$0.isDefault }
    }

    /// `nativeOAuth` with the provider used last next, when the server still offers it. Authentik stays first
    /// whatever was used last (maintainer, 2026-11-16); the one used last leads the rest.
    func nativeOAuth(remembered rememberedID: String?) -> [AuthProvider] {
        let all = nativeOAuth
        guard let rememberedID, let remembered = all.first(where: { $0.id == rememberedID }), !remembered.isAuthentik else {
            return all
        }
        return all.filter(\.isAuthentik) + [remembered] + all.filter { !$0.isAuthentik && $0.id != rememberedID }
    }
}

/// `POST /api/v2/auth/oauth/complete` body. The code and verifier never reach a log.
struct OAuthCompleteRequest: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let code: String
    let codeVerifier: String

    enum CodingKeys: String, CodingKey {
        case code
        case codeVerifier = "code_verifier"
    }

    var description: String { "OAuthCompleteRequest(redacted)" }
    var debugDescription: String { description }
}

/// `OAuthCompletion`: the same tokens and account as a password login.
struct OAuthCompletion: Decodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let next: String
    let user: LoggedInUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case next, user
    }

    var description: String { "OAuthCompletion(redacted)" }
    var debugDescription: String { description }
}
