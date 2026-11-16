import CryptoKit
import XCTest
@testable import BloemAdmin

/// PKCE, the issuer form, the start URL and every redirect check. A redirect that fails any check is
/// never redeemed, so the checks are exercised here without a network.
final class OAuthSignInTests: XCTestCase {
    private let baseURL = URL(string: "https://example.test")!
    private let unreserved = try! NSRegularExpression(pattern: "^[A-Za-z0-9\\-._~]{43}$")

    private func isUnreserved43(_ text: String) -> Bool {
        unreserved.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private func pending(started: Date = Date(timeIntervalSince1970: 1_000)) throws -> PendingOAuth {
        PendingOAuth(
            issuer: OAuthIssuer.form(of: baseURL),
            serverID: "srv-1",
            providerID: "26",
            providerName: "Corp SSO",
            pkce: try Pkce.generate(),
            appState: "state-abc",
            startedAt: started
        )
    }

    // MARK: - PKCE and state

    func testChallengeMatchesRFC7636AppendixBVector() {
        XCTAssertEqual(
            Pkce.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testGeneratedPkceIsUnpaddedBase64URLOf32BytesAndFresh() throws {
        let a = try Pkce.generate()
        let b = try Pkce.generate()
        XCTAssertTrue(isUnreserved43(a.verifier), a.verifier)
        XCTAssertEqual(a.challenge, Pkce.challenge(for: a.verifier))
        XCTAssertNotEqual(a.verifier, b.verifier)
    }

    func testAppStateIsUnreservedAnd43CharactersAndFresh() throws {
        let first = try OAuthRandom.appState()
        XCTAssertTrue(isUnreserved43(first), first)
        XCTAssertNotEqual(first, try OAuthRandom.appState())
    }

    func testDescriptionsNeverContainTheVerifierStateOrCode() throws {
        let pkce = try Pkce.generate()
        let state = try pending()
        XCTAssertFalse(String(describing: pkce).contains(pkce.verifier))
        XCTAssertFalse(String(reflecting: pkce).contains(pkce.verifier))
        XCTAssertFalse(String(describing: state).contains(state.pkce.verifier))
        XCTAssertFalse(String(describing: state).contains(state.appState))
        XCTAssertFalse(String(describing: OAuthRedirect.code("c0de")).contains("c0de"))
        XCTAssertFalse(String(reflecting: OAuthRedirect.code("c0de")).contains("c0de"))
        XCTAssertFalse(String(describing: OAuthCompleteRequest(code: "c0de", codeVerifier: "verifier-value")).contains("verifier-value"))
        XCTAssertFalse(String(describing: OAuthCompleteRequest(code: "c0de", codeVerifier: "verifier-value")).contains("c0de"))
    }

    // MARK: - Issuer

    func testIssuerIsTheValidatedOriginInTheServersForm() throws {
        XCTAssertEqual(OAuthIssuer.form(of: try ServerEndpointValidator.validate("https://Example.TEST")), "https://example.test")
        XCTAssertEqual(OAuthIssuer.form(of: try ServerEndpointValidator.validate("https://example.test:443/")), "https://example.test")
        XCTAssertEqual(OAuthIssuer.form(of: try ServerEndpointValidator.validate("https://Example.test:8443")), "https://example.test:8443")
        XCTAssertEqual(OAuthIssuer.form(of: URL(string: "https://[::1]:8443")!), "https://[::1]:8443")
        XCTAssertEqual(OAuthIssuer.form(of: URL(string: "https://[2001:db8::1]")!), "https://[2001:db8::1]")
        XCTAssertEqual(OAuthIssuer.form(of: URL(string: "https://example.test/")!), "https://example.test")
    }

    // MARK: - Start URL

    func testStartURLIsExactAndCarriesOnlyTheChallengeAndState() throws {
        let url = try OAuthStart.url(
            baseURL: baseURL,
            nativeStartPath: "/api/v2/auth/oauth/26/native/start",
            pkce: Pkce(verifier: "v", challenge: "C"),
            appState: "S"
        )
        XCTAssertEqual(
            url.absoluteString,
            "https://example.test/api/v2/auth/oauth/26/native/start?code_challenge=C&code_challenge_method=S256&app_state=S"
        )
    }

    func testStartURLRefusesAnythingThatIsNotAPlainPathOnTheSavedOrigin() throws {
        let refused = [
            "", "api/v2/x", "https://evil.test/x", "//evil.test/x", "/\\evil.test/x",
            "/a\\b", "/a?x=1", "/a#f", "/a b", "/a\tb", "/a\nb", "/a\u{00A0}b", "///x",
        ]
        for path in refused {
            XCTAssertThrowsError(
                try OAuthStart.url(baseURL: baseURL, nativeStartPath: path, pkce: Pkce(verifier: "v", challenge: "C"), appState: "S"),
                "\(path.debugDescription) must never reach the browser"
            )
        }
    }

    // MARK: - Redirect

    private func redirect(_ items: [(String, String)], base: String = "org.siloserver.silo:/auth/callback") -> String {
        base + "?" + items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private var good: [(String, String)] {
        [("code", "c0de"), ("state", "state-abc"), ("server", "srv-1"), ("iss", "https://example.test")]
    }

    private func good(replacing key: String, with value: String?) -> [(String, String)] {
        good.filter { $0.0 != key } + (value.map { [(key, $0)] } ?? [])
    }

    func testAcceptsAMatchingRedirect() throws {
        XCTAssertEqual(parseOAuthRedirect(redirect(good), pending: try pending()), .code("c0de"))
    }

    func testAcceptsAPercentEncodedIssuer() throws {
        let items = good(replacing: "iss", with: "https%3A%2F%2Fexample.test")
        XCTAssertEqual(parseOAuthRedirect(redirect(items), pending: try pending()), .code("c0de"))
    }

    func testPercentDecodingFollowsRFC3986AndKeepsPlus() throws {
        let p = try pending()
        XCTAssertEqual(parseOAuthRedirect(redirect(good(replacing: "code", with: "a+b")), pending: p), .code("a+b"))
        XCTAssertEqual(parseOAuthRedirect(redirect(good(replacing: "code", with: "a%2Bb")), pending: p), .code("a+b"))
        XCTAssertEqual(parseOAuthRedirect(redirect(good(replacing: "code", with: "a%20b")), pending: p), .code("a b"))
        XCTAssertEqual(parseOAuthRedirect(redirect(good(replacing: "code", with: "%C3%A9")), pending: p), .code("é"))
    }

    func testEveryFailedCheckIsUntrusted() throws {
        let p = try pending()
        let cases: [String: String] = [
            "wrong iss": redirect(good(replacing: "iss", with: "https://other.test")),
            "iss with port": redirect(good(replacing: "iss", with: "https://example.test:8443")),
            "iss with slash": redirect(good(replacing: "iss", with: "https://example.test/")),
            "iss missing": redirect(good(replacing: "iss", with: nil)),
            "state wrong": redirect(good(replacing: "state", with: "nope")),
            "state missing": redirect(good(replacing: "state", with: nil)),
            "state empty": redirect(good(replacing: "state", with: "")),
            "server wrong": redirect(good(replacing: "server", with: "srv-2")),
            "server missing": redirect(good(replacing: "server", with: nil)),
            "scheme": redirect(good, base: "https://example.test/auth/callback"),
            "other scheme": redirect(good, base: "org.siloserver.other:/auth/callback"),
            "path": redirect(good, base: "org.siloserver.silo:/auth/other"),
            "path trailing slash": redirect(good, base: "org.siloserver.silo:/auth/callback/"),
            "path longer": redirect(good, base: "org.siloserver.silo:/auth/callback/x"),
            "authority": redirect(good, base: "org.siloserver.silo://evil.test/auth/callback"),
            "empty authority": redirect(good, base: "org.siloserver.silo:///auth/callback"),
            "no path": redirect(good, base: "org.siloserver.silo:"),
            "duplicate code": redirect(good + [("code", "other")]),
            "duplicate state": redirect(good + [("state", "state-abc")]),
            "duplicate encoded name": redirect(good + [("c%6Fde", "other")]),
            "malformed escape": redirect(good(replacing: "code", with: "%zz")),
            "truncated escape": redirect(good(replacing: "code", with: "ab%4")),
            "invalid utf8": redirect(good(replacing: "code", with: "%FF")),
            "malformed name escape": redirect(good + [("%zz", "x")]),
            "not a uri": "this is not a uri",
            "empty": "",
        ]
        for (name, uri) in cases {
            XCTAssertEqual(parseOAuthRedirect(uri, pending: p), .untrusted, name)
        }
    }

    func testAnErrorWithMatchingOrAbsentStateFailsWithItsReason() throws {
        let p = try pending()
        let matching: [(String, String)] = [("error", "not_permitted"), ("state", "state-abc"), ("iss", "https://example.test")]
        XCTAssertEqual(parseOAuthRedirect(redirect(matching), pending: p), .failed("not_permitted"))
        let noState: [(String, String)] = [("error", "account_disabled"), ("iss", "https://example.test")]
        XCTAssertEqual(parseOAuthRedirect(redirect(noState), pending: p), .failed("account_disabled"))
    }

    func testAnErrorWithADifferentStateOrIssuerIsUntrusted() throws {
        let p = try pending()
        let differing: [(String, String)] = [("error", "not_permitted"), ("state", "nope"), ("iss", "https://example.test")]
        XCTAssertEqual(parseOAuthRedirect(redirect(differing), pending: p), .untrusted)
        let wrongIssuer: [(String, String)] = [("error", "not_permitted"), ("state", "state-abc"), ("iss", "https://other.test")]
        XCTAssertEqual(parseOAuthRedirect(redirect(wrongIssuer), pending: p), .untrusted)
    }

    func testNoCodeAndNoErrorIsLoginFailed() throws {
        let p = try pending()
        let bare: [(String, String)] = [("state", "state-abc"), ("server", "srv-1"), ("iss", "https://example.test")]
        XCTAssertEqual(parseOAuthRedirect(redirect(bare), pending: p), .failed("login_failed"))
    }

    func testAnEmptyCodeOrErrorCountsAsAbsent() throws {
        let p = try pending()
        XCTAssertEqual(parseOAuthRedirect(redirect(good(replacing: "code", with: "")), pending: p), .failed("login_failed"))
        XCTAssertEqual(parseOAuthRedirect(redirect(good + [("error", "")]), pending: p), .code("c0de"))
        let both: [(String, String)] = [("code", ""), ("error", ""), ("state", "state-abc"), ("server", "srv-1"), ("iss", "https://example.test")]
        XCTAssertEqual(parseOAuthRedirect(redirect(both), pending: p), .failed("login_failed"))
    }

    func testACodeIsOnlyReadFromTheQueryNotTheFragment() throws {
        let uri = "org.siloserver.silo:/auth/callback?state=state-abc&server=srv-1&iss=https%3A%2F%2Fexample.test#code=sneaky"
        XCTAssertEqual(parseOAuthRedirect(uri, pending: try pending()), .failed("login_failed"))
    }
}
