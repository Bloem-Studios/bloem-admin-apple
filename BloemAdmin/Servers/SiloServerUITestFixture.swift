#if DEBUG
import SwiftUI

/// The UI-test seam for "the app works with every Silo server". Launched with
/// `--ui-testing-silo-server=plain|bloem|mixed` the real app opens with saved, signed-in servers whose requests are
/// answered inside the process (no network, nothing leaves the device):
///
/// - `plain`: one plain upstream Silo server. It has no `/api/bloem/` routes, so those answer `404 page not found`
///   the way the real server does.
/// - `bloem`: one Bloem server. It answers `GET /api/bloem/v2/capabilities`, and offers Support access (its account
///   is the Owner).
/// - `mixed`: one of each.
///
/// Every request is logged. A hidden element (`silo-fixture-bloem-requests`) carries the `/api/bloem/` part of that
/// log, so a UI test can check which Bloem routes the app asked a server for. The Silo routes answer an empty
/// object: the pages are not under test here, the menu and the Bloem requests are. Compiled into debug builds only.
enum SiloServerUITestFixture: String {
    case plain, bloem, mixed

    static let plainHost = "plain-silo.fixture.test"
    static let bloemHost = "bloem.fixture.test"

    static var requested: SiloServerUITestFixture? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--ui-testing-silo-server=") {
            return SiloServerUITestFixture(rawValue: String(argument.dropFirst("--ui-testing-silo-server=".count)))
        }
        return nil
    }

    /// The servers this fixture saves, all signed in (`ui-testing-token`).
    var servers: [AdminServer] {
        let plain = AdminServer(id: "fixture-plain", baseURL: URL(string: "https://\(Self.plainHost)")!, displayName: "Plain Silo")
        let bloem = AdminServer(id: "fixture-bloem", baseURL: URL(string: "https://\(Self.bloemHost)")!, displayName: "Bloem server")
        switch self {
        case .plain: return [plain]
        case .bloem: return [bloem]
        case .mixed: return [plain, bloem]
        }
    }

    /// Makes every session the app builds from now on answer these two hosts from inside the process.
    static func install() {
        ProductionSession.debugProtocolClasses = [SiloFixtureURLProtocol.self]
    }
}

/// A one-point element that exposes which `/api/bloem/` requests each fixture server received.
struct SiloFixtureRequestProbe: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            Color.clear
                .frame(width: 1, height: 1)
                .accessibilityElement()
                .accessibilityIdentifier("silo-fixture-bloem-requests")
                .accessibilityLabel(SiloFixtureURLProtocol.bloemRequestSummary())
                .allowsHitTesting(false)
        }
    }
}

final class SiloFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    /// Built from parts: path literals belong in the API files (APIPathGuardTests).
    private static let bloemPrefix = "/" + "api/bloem/"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var log: [String] = []

    /// "host METHOD path" for every request the fixture hosts received so far.
    static func requests() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return log
    }

    /// The `/api/bloem/` requests, one per line, as "plain|bloem METHOD path".
    static func bloemRequestSummary() -> String {
        requests().compactMap { line -> String? in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, parts[2].hasPrefix(bloemPrefix) else { return nil }
            let kind = parts[0] == SiloServerUITestFixture.plainHost ? "plain" : "bloem"
            return "\(kind) \(parts[1]) \(parts[2])"
        }.joined(separator: "\n")
    }

    override class func canInit(with request: URLRequest) -> Bool {
        [SiloServerUITestFixture.plainHost, SiloServerUITestFixture.bloemHost].contains(request.url?.host ?? "")
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let request = self.request
        let host = request.url?.host ?? ""
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        Self.lock.lock()
        Self.log.append("\(host) \(method) \(path)")
        Self.lock.unlock()

        let (status, body, type) = Self.answer(host: host, method: method, path: path)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func answer(host: String, method: String, path: String) -> (Int, String, String) {
        let json = "application/json"
        if path.hasPrefix(bloemPrefix) {
            // A plain Silo server has no such route: its router answers a bare text 404.
            guard host == SiloServerUITestFixture.bloemHost else { return (404, "404 page not found\n", "text/plain; charset=utf-8") }
            switch path {
            case bloemPrefix + "v2/capabilities":
                return (200, #"{"api":"bloem/v2","identity_schema":2,"features":{"organization_memberships":true},"media_types":[],"feature_tokens":["organization_support_v1"]}"#, json)
            case bloemPrefix + "v2/organizations":
                return (200, #"{"organizations":[]}"#, json)
            default:
                return (404, #"{"error":"not_found","message":"Not found"}"#, json)
            }
        }
        if path == "/" + "api/v1/health" { return (200, #"{"status":"ok"}"#, json) }
        return (200, "{}", json)
    }
}
#endif
