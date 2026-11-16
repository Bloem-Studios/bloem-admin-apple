import CryptoKit
import Foundation
import Security

// The security-relevant half of OAuth/OIDC sign-in with PKCE: random values, the issuer form, the
// start URL and the redirect checks. A redirect that fails any check is never redeemed, and the
// verifier, the state and the code never reach a description, a log or the screen.

enum OAuthSignInError: Error, Equatable {
    case randomUnavailable
    /// The server's `native_start_path` is not a plain path on the saved origin.
    case invalidStartPath
}

private func base64URL(_ bytes: some Sequence<UInt8>) -> String {
    Data(bytes).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

enum OAuthRandom {
    /// 32 random bytes from `SecRandomCopyBytes` as unpadded base64url (43 characters).
    static func token() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw OAuthSignInError.randomUnavailable
        }
        return base64URL(bytes)
    }

    static func appState() throws -> String { try token() }
}

/// A PKCE S256 pair. The verifier stays in memory only.
struct Pkce: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let verifier: String
    let challenge: String

    static func generate() throws -> Pkce {
        let verifier = try OAuthRandom.token()
        return Pkce(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        base64URL(SHA256.hash(data: Data(verifier.utf8)))
    }

    var description: String { "Pkce(challenge: \(challenge))" }
    var debugDescription: String { description }
}

/// The origin form the server uses for `iss`: `scheme://host[:port]`, scheme and host lower case,
/// the default port omitted, IPv6 in brackets, no path and no trailing slash. The server address
/// validator only accepts an origin, so this is also the saved base URL.
enum OAuthIssuer {
    static func form(of url: URL) -> String {
        let scheme = (url.scheme ?? "https").lowercased()
        var host = (url.host(percentEncoded: false) ?? "").lowercased()
        if host.hasPrefix("[") { host.removeFirst() }
        if host.hasSuffix("]") { host.removeLast() }
        if host.contains(":") { host = "[\(host)]" }
        let defaultPort = scheme == "https" ? 443 : (scheme == "http" ? 80 : nil)
        if let port = url.port, port != defaultPort {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}

/// A sign-in waiting for its redirect. It lives in memory only.
struct PendingOAuth: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Pending sign-ins older than this are not redeemed.
    static let lifetime: TimeInterval = 10 * 60

    let issuer: String
    let serverID: String
    let providerID: String
    let providerName: String
    let pkce: Pkce
    let appState: String
    let startedAt: Date

    var description: String {
        "PendingOAuth(issuer: \(issuer), serverID: \(serverID), providerID: \(providerID), startedAt: \(startedAt))"
    }
    var debugDescription: String { description }
}

enum OAuthStart {
    /// The browser start URL: the saved origin plus `nativeStartPath`, which must be a plain path
    /// starting with exactly one `/`. Anything else never reaches the browser.
    static func url(baseURL: URL, nativeStartPath: String, pkce: Pkce, appState: String) throws -> URL {
        guard nativeStartPath.hasPrefix("/"), !nativeStartPath.hasPrefix("//") else {
            throw OAuthSignInError.invalidStartPath
        }
        for scalar in nativeStartPath.unicodeScalars {
            // Printable ASCII only: no whitespace or control characters, `\`, `?` or `#`.
            guard (0x21...0x7E).contains(scalar.value), scalar != "\\", scalar != "?", scalar != "#" else {
                throw OAuthSignInError.invalidStartPath
            }
        }
        let text = OAuthIssuer.form(of: baseURL) + nativeStartPath
            + "?code_challenge=\(pkce.challenge)&code_challenge_method=S256&app_state=\(appState)"
        guard let url = URL(string: text) else { throw OAuthSignInError.invalidStartPath }
        return url
    }
}

enum OAuthRedirect: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case code(String)
    case failed(String)
    /// Not from this server and sign-in: never redeemed, never shown.
    case untrusted

    var description: String {
        switch self {
        case .code: "code(redacted)"
        case .failed(let reason): "failed(\(reason))"
        case .untrusted: "untrusted"
        }
    }
    var debugDescription: String { description }
}

enum OAuthRedirectSpec {
    static let scheme = "org.siloserver.silo"
    static let path = "/auth/callback"
}

/// Checks a redirect against the pending sign-in. Fails closed: anything unparseable or unexpected is
/// `.untrusted`. Parsing is by hand so a malformed escape or a repeated name is visible instead of
/// being tolerated by a URL library, and `+` stays a plus (RFC 3986, not form encoding).
func parseOAuthRedirect(_ uri: String, pending: PendingOAuth) -> OAuthRedirect {
    guard let colon = uri.firstIndex(of: ":") else { return .untrusted }
    guard uri[..<colon].lowercased() == OAuthRedirectSpec.scheme else { return .untrusted }
    var rest = uri[uri.index(after: colon)...]
    if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
    let path: Substring
    let query: Substring
    if let mark = rest.firstIndex(of: "?") {
        path = rest[..<mark]
        query = rest[rest.index(after: mark)...]
    } else {
        path = rest
        query = ""
    }
    // An authority (`//host/...`) makes the path differ, so it fails here too.
    guard path == OAuthRedirectSpec.path else { return .untrusted }

    var params: [String: String] = [:]
    for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
        let name: Substring
        let value: Substring
        if let equals = pair.firstIndex(of: "=") {
            name = pair[..<equals]
            value = pair[pair.index(after: equals)...]
        } else {
            name = pair
            value = ""
        }
        guard let decodedName = percentDecode(name), let decodedValue = percentDecode(value) else {
            return .untrusted
        }
        guard params.updateValue(decodedValue, forKey: decodedName) == nil else { return .untrusted }
    }

    guard params["iss"] == pending.issuer else { return .untrusted }
    let state = params["state"]
    if let error = params["error"], !error.isEmpty {
        return state == nil || state == pending.appState ? .failed(error) : .untrusted
    }
    guard let code = params["code"], !code.isEmpty else { return .failed("login_failed") }
    guard state == pending.appState, params["server"] == pending.serverID else { return .untrusted }
    return .code(code)
}

/// RFC 3986 percent-decoding to UTF-8; nil for a malformed escape or invalid UTF-8.
private func percentDecode(_ text: Substring) -> String? {
    let input = Array(text.utf8)
    var output: [UInt8] = []
    output.reserveCapacity(input.count)
    var index = 0
    while index < input.count {
        let byte = input[index]
        guard byte == 0x25 else {
            output.append(byte)
            index += 1
            continue
        }
        guard index + 2 < input.count, let high = hexValue(input[index + 1]), let low = hexValue(input[index + 2]) else {
            return nil
        }
        output.append(high << 4 | low)
        index += 3
    }
    return String(data: Data(output), encoding: .utf8)
}

private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case 0x30...0x39: byte - 0x30
    case 0x41...0x46: byte - 0x41 + 10
    case 0x61...0x66: byte - 0x61 + 10
    default: nil
    }
}
