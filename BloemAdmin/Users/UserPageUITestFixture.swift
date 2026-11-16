#if DEBUG
import SwiftUI

/// The User page's UI-test seam. Launched with `--ui-testing-user-page` the app shows the Users
/// list of an in-process fake server instead of the server list, so the UI tests drive the real
/// page (header, tabs, swipe, back, confirmations) against known data without any network.
/// `--ui-testing-user-conflict` makes the first Access & limits save lose a race, as if another
/// admin had changed the account first. Compiled into debug builds only.
enum UserPageUITestFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-user-page")
    }

    static var forcesConflict: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-user-conflict")
    }

    /// `--ui-testing-people-shell`: the page is the real shell (menu, badge, page search) over the same fake server,
    /// with Requests, Users and API keys as its pages, so the UI tests drive bulk triage, the menu badge and the
    /// API keys page too.
    static var showsShell: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-people-shell")
    }

    /// `--ui-testing-user-support`: the fake server can create reset links and manage profiles
    /// (`password_reset_link` and `profile_management`), so the Profiles tab and Create link appear.
    static var offersUserSupport: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-user-support")
    }

    /// `--ui-testing-requests-unavailable`: the fake server runs no request administration.
    static var requestsUnavailable: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-requests-unavailable")
    }
}

struct UserPageUITestRoot: View {
    @State private var client: APIClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        _client = State(initialValue: APIClient(baseURL: URL(string: "https://fixture.test")!, accessToken: "fixture", session: session))
    }

    var body: some View {
        if UserPageUITestFixture.showsShell {
            PeopleShellFixture(client: client)
        } else {
            NavigationStack {
                UsersListView(client: client)
                    .bloemPageBackground()
            }
        }
    }
}

/// The shell over the fake server: Requests, Users and API keys, with the Requests badge polling like the app.
private struct PeopleShellFixture: View {
    let client: APIClient
    @State private var router = ShellRouter()
    @State private var badge = RequestBadgeModel()

    var body: some View {
        ShellLayout(
            destinations: [AdminDestination.requests, AdminDestination.users, AdminDestination.apiKeys],
            heading: "Fixture server",
            badges: [AdminDestination.requests.id: badge.needsApproval]
        ) { destination in
            switch destination.id {
            case AdminDestination.requests.id: RequestsListView(client: client)
            case AdminDestination.users.id: UsersListView(client: client)
            case AdminDestination.apiKeys.id: APIKeysListView(client: client)
            default: EmptyView()
            }
        }
        .requestBadgeRefresh(model: badge, sources: [RequestBadgeSource(serverID: "fixture", client: client)])
        .environment(router)
        .environment(\.adminSessionState, ServerScopedSession(state: AdminSessionState(), serverID: "fixture"))
    }
}

/// A tiny in-memory Bloem server for the Users area. Versions (ETags) advance on every write, and
/// a write whose `If-Match` is stale is refused with 412, like the real server.
private final class UserFixtureServer: @unchecked Sendable {
    static let shared = UserFixtureServer()

    private let lock = NSLock()
    private var users: [[String: Any]]
    private var versions: [String: Int] = [:]
    private var conflictPending = UserPageUITestFixture.forcesConflict
    /// Requests waiting for approval, oldest first. "Severance" cannot be answered: another admin got there first.
    private var pendingRequests: [[String: Any]] = [
        ("r1", "Dune"), ("r2", "Arrival"), ("r3", "Severance"), ("r4", "Heat"), ("r5", "Alien"),
    ].map { UserFixtureServer.request(id: $0.0, title: $0.1) }
    private var apiKeys: [[String: Any]] = [
        UserFixtureServer.apiKey("k1", label: "Backup script", owner: "bob", lastUsed: "2026-11-14T09:00:00.000Z"),
        UserFixtureServer.apiKey("k2", label: "Dashboard widget", owner: "alice", scopes: ["library.read", "stats.read"], tier: "elevated"),
        UserFixtureServer.apiKey("k3", label: "Old importer", owner: "alice"),
    ]
    private var profilesByUser: [String: [[String: Any]]] = [
        "2": [
            UserFixtureServer.profile("p1", "Main", pin: true, primary: true),
            UserFixtureServer.profile("p-kids", "Kids", child: true),
        ],
    ]
    private var nextProfile = 100
    private var lastResetDelivery = ""

    private static func request(id: String, title: String) -> [String: Any] {
        [
            "id": id, "provider": "tmdb", "media_type": "movie", "tmdb_id": 100, "title": title, "status": "pending",
            "outcome": "active", "state": "pending", "seasons": [Int](), "season_progress": [Any](), "source": "direct",
            "is_anime": false, "targets": [Any](), "created_at": "2026-11-14T03:04:05.000Z", "updated_at": "2026-11-14T03:04:05.000Z",
            "requested_by_user_id": "2",
        ]
    }

    private static func apiKey(_ id: String, label: String, owner: String, scopes: [String] = [], tier: String = "standard", lastUsed: String? = nil) -> [String: Any] {
        var key: [String: Any] = [
            "id": id, "user_id": owner == "bob" ? "2" : "1", "label": label, "key_prefix": "bk_\(id)x9", "rate_tier": tier,
            "scopes": scopes, "created_at": "2026-10-01T03:04:05.000Z", "username": owner,
        ]
        if let lastUsed { key["last_used_at"] = lastUsed }
        return key
    }

    private static func profile(_ id: String, _ name: String, pin: Bool = false, primary: Bool = false, child: Bool = false) -> [String: Any] {
        [
            "id": id, "name": name, "has_pin": pin, "is_primary": primary, "is_child": child,
            "last_seen_at": "2026-02-03T04:05:06.000Z",
        ]
    }

    private init() {
        func user(_ id: String, _ name: String, role: String = "user", enabled: Bool = true, passwordLogin: Bool = true, owner: Bool = false, extra: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = [
                "id": id, "username": name, "email": "\(name)@example.test", "role": role, "enabled": enabled,
                "permissions": [String](), "library_ids": NSNull(), "access_group_id": NSNull(),
                "max_streams": 3, "max_transcodes": NSNull(), "max_profiles": NSNull(),
                "download_allowed": NSNull(), "requests_allowed": NSNull(), "transcode_allowed": NSNull(), "audio_transcode_allowed": NSNull(),
                "password_login": passwordLogin, "password_change_required": false, "is_owner": owner,
                "created_at": "2026-01-02T03:04:05.000Z", "last_active_at": NSNull(),
            ]
            value.merge(extra) { _, new in new }
            return value
        }
        var all = [
            user("1", "alice", role: "admin"),
            user("2", "bob"),
            user("3", "carol", passwordLogin: false, extra: ["password_change_required": true]),
            user("4", "dave", enabled: false),
            user("5", "erin", role: "admin"),
            user("9", "root", role: "admin", owner: true),
        ]
        for index in 10..<40 { all.append(user(String(index), String(format: "user%02d", index))) }
        users = all
    }

    nonisolated(unsafe) private static let policy: [String: Any] = [
        "library_ids": NSNull(), "max_playback_quality": "1080p", "max_streams": 8, "max_transcodes": 4, "max_profiles": 5,
        "transcode_allowed": true, "audio_transcode_allowed": true, "download_allowed": true, "download_transcode_allowed": false,
        "requests_allowed": false, "permissions": [String](),
    ]

    private func rendered(_ user: [String: Any]) -> [String: Any] {
        var value = user
        value["effective_policy"] = Self.policy
        return value
    }

    private func page(_ items: [Any]) -> [String: Any] { ["items": items, "page": ["has_more": false]] }

    private func problem(_ status: Int, _ detail: String, type: String? = nil) -> (Int, [String: Any], [String: String]) {
        (status, ["type": "https://fixture.test/problems/\(type ?? String(status))", "title": detail, "status": status, "detail": detail],
         ["Content-Type": "application/problem+json"])
    }

    func respond(method: String, path: String, query: [String: String], ifMatch: String?, body: Data?) -> (status: Int, json: Any?, headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        // Routes are matched without the "api/v2" prefix, so this file holds no API path literals.
        let parts = path.split(separator: "/").map(String.init)
        let route = parts.dropFirst(2).joined(separator: "/")
        if parts.count == 5, parts[3] == "users", !["capabilities", "policy-defaults"].contains(parts[4]) {
            return userRoute(method: method, id: parts[4], ifMatch: ifMatch, body: body)
        }
        switch (method, route) {
        case ("GET", "admin/users"):
            return (200, page(users.map(rendered)), [:])
        case ("GET", "account/me"):
            return (200, ["id": "1"], [:])
        case ("GET", "admin/users/capabilities"):
            return (200, [
                "available": true, "login_sessions": true, "account_devices": true, "account_downloads": true, "watch_summary": true,
                "password_reset_email": true,
                "password_reset_link": UserPageUITestFixture.offersUserSupport,
                "profile_management": UserPageUITestFixture.offersUserSupport,
            ], [:])
        case ("GET", "admin/users/policy-defaults"):
            return (200, ["admin": ["library_ids": NSNull()], "ungrouped": ["library_ids": ["1", "2"]]], [:])
        case ("GET", "admin/access-groups"):
            return (200, page([["id": "g1", "name": "Family", "library_ids": ["1"], "allowed_permissions": ["marker_edit"], "max_streams": 2, "max_playback_quality": "1080p", "member_count": 1]]), [:])
        case ("GET", "libraries"):
            return (200, page([["id": "1", "name": "Movies"], ["id": "2", "name": "Shows"]]), [:])
        case ("GET", "settings/contract"):
            return (200, Self.contract, [:])
        case ("GET", "admin/playback-history"):
            return (200, page([["session_id": "s1", "username": "bob", "media_title": "The Long Film", "media_type": "movie", "watched_seconds": 3600.0, "duration_seconds": 7200.0, "completed": true, "started_at": "2026-02-03T04:05:06.000Z", "ended_at": NSNull()]]), [:])
        default:
            break
        }
        if let handled = peopleRoute(method: method, parts: parts, query: query, ifMatch: ifMatch, body: body) { return handled }
        if method == "GET", path.hasSuffix("/profiles") { return (200, page([["id": "p1", "name": "Main", "last_seen_at": "2026-02-03T04:05:06.000Z"]]), [:]) }
        if method == "GET", path.hasSuffix("/watch-summary") {
            return (200, ["days": 30, "plays": 12, "completed_plays": 9, "watched_seconds": 7500.0, "last_played_at": "2026-02-03T04:05:06.000Z"], [:])
        }
        if method == "GET", path.hasSuffix("/ips") {
            return (200, page([["client_ip": "203.0.113.7", "first_seen": "2026-02-01T01:00:00.000Z", "last_seen": "2026-02-03T01:00:00.000Z", "location": "Amsterdam", "request_count": 42]]), [:])
        }
        if method == "GET", path.hasSuffix("/downloads/summary") {
            return (200, ["total": 3, "completed": 2, "in_progress": 1, "failed": 0, "revoked": 0, "total_bytes": 1_500_000_000, "devices": 1], [:])
        }
        if method == "GET", path.hasSuffix("/downloads") {
            return (200, page([["id": "d1", "title": "Offline Episode", "media_type": "episode", "status": "completed", "file_size": 500_000_000, "quality": "1080p", "created_at": "2026-02-03T04:05:06.000Z"]]), [:])
        }
        if method == "GET", path.hasSuffix("/login-sessions") {
            return (200, page([["id": "ls1", "device_name": "Living room TV", "ip_address": "203.0.113.7", "created_at": "2026-02-01T01:00:00.000Z", "expires_at": "2026-03-01T01:00:00.000Z", "last_seen_at": "2026-02-03T04:05:06.000Z", "current": false]]), [:])
        }
        if method == "GET", path.hasSuffix("/devices") {
            return (200, page([["device_id": "dev1", "device_name": "Living room TV", "device_platform": "tv", "last_seen_at": "2026-02-03T04:05:06.000Z", "last_updated": NSNull(), "override_count": 0, "profiles": [["profile_id": "p1", "profile_name": "Main", "override_count": 0, "last_seen_at": NSNull()]]]]), [:])
        }
        if method == "GET", path.hasSuffix("/settings/values") {
            return (200, page([["key": "playback.autoplay", "scope": "profile", "value": true, "revision": 1, "profile_id": "p1"]]), [:])
        }
        if method == "POST", path.hasSuffix("/password-reset") {
            let delivery = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["delivery"] as? String ?? "email"
            lastResetDelivery = delivery
            if delivery == "link" {
                return (201, ["delivery": "link", "delivery_status": "not_requested", "reset_url": "https://fixture.test/reset-password#fixture-token-4821", "expires_at": "2026-12-04T04:05:06.000Z"], [:])
            }
            return (201, ["delivery": "email", "delivery_status": "sent", "expires_at": "2026-02-04T04:05:06.000Z"], [:])
        }
        if method == "DELETE", path.contains("/login-sessions") {
            if path.hasSuffix("/login-sessions") { return (200, ["revoked": 1], [:]) }
            return (204, nil, [:])
        }
        if method == "PUT" || method == "DELETE", path.contains("/settings/values/") { return (204, nil, [:]) }
        let missing = problem(404, "Not found")
        return (missing.0, missing.1, missing.2)
    }

    /// Requests and their counts, API keys, an account's profiles and what it is playing: the routes the people wave
    /// added. Answers nil for any other route.
    private func peopleRoute(method: String, parts: [String], query: [String: String], ifMatch: String?, body: Data?) -> (status: Int, json: Any?, headers: [String: String])? {
        guard parts.count >= 4, parts[2] == "admin" else { return nil }
        let sent = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let area = parts[3]

        if area == "requests" {
            if UserPageUITestFixture.requestsUnavailable, !(parts.count == 5 && parts[4] == "capabilities") {
                let gone = problem(503, "The request administration service is not available on this server.", type: "dependency_unavailable")
                return (gone.0, gone.1, gone.2)
            }
            switch (method, parts.count, parts.count > 4 ? parts[4] : "") {
            case ("GET", 5, "capabilities"):
                let available = !UserPageUITestFixture.requestsUnavailable
                return (200, ["revision": "1", "state": available ? "available" : "unsupported", "available": available], [:])
            case ("GET", 5, "counts"):
                return (200, ["needs_approval": pendingRequests.count, "in_progress": 2, "failed": 1, "done": 5], [:])
            case ("GET", 4, _):
                return (200, page(query["view"] == "needs_approval" ? pendingRequests : []), [:])
            case ("POST", 6, let id) where parts[5] == "approve" || parts[5] == "decline":
                guard let index = pendingRequests.firstIndex(where: { ($0["id"] as? String) == id }) else {
                    let missing = problem(404, "Request not found.")
                    return (missing.0, missing.1, missing.2)
                }
                if id == "r3" {
                    let taken = problem(409, "Someone else already answered this request.")
                    return (taken.0, taken.1, taken.2)
                }
                var answered = pendingRequests.remove(at: index)
                answered["status"] = parts[5] == "approve" ? "approved" : "pending"
                answered["outcome"] = parts[5] == "approve" ? "active" : "declined"
                return (200, answered, [:])
            default:
                return nil
            }
        }

        if area == "api-keys" {
            if method == "GET", parts.count == 4 { return (200, page(apiKeys), [:]) }
            guard parts.count == 5 else { return nil }
            guard let index = apiKeys.firstIndex(where: { ($0["id"] as? String) == parts[4] }) else {
                let missing = problem(404, "API key not found.")
                return (missing.0, missing.1, missing.2)
            }
            let tag = "\"\(parts[4])-v1\""
            if method == "GET" { return (200, apiKeys[index], ["ETag": tag]) }
            if method == "DELETE" {
                guard ifMatch == tag else {
                    let stale = problem(412, "The API key changed; reload before saving.")
                    return (stale.0, stale.1, stale.2)
                }
                apiKeys.remove(at: index)
                return (204, nil, [:])
            }
            return nil
        }

        if area == "sessions", method == "GET", parts.count == 4 {
            let watching: [[String: Any]] = query["user_id"] == "2"
                ? [[
                    "session_id": "s-bob-1", "user_id": "2", "username": "bob", "media_title": "The Long Film", "media_type": "movie",
                    "play_method": "direct_play", "position_seconds": 600.0, "file_duration": 7200, "is_paused": false,
                    "client_name": "Bloem TV", "device_platform": "tv",
                ]]
                : []
            return (200, page(watching), [:])
        }

        if area == "users", parts.count >= 6, parts[5] == "profiles" {
            let userID = parts[4]
            var list = profilesByUser[userID] ?? [Self.profile("p1", "Main", primary: true)]
            defer { profilesByUser[userID] = list }
            switch (method, parts.count) {
            case ("GET", 6):
                return (200, page(list), [:])
            case ("POST", 6):
                nextProfile += 1
                let created = Self.profile("p-\(nextProfile)", sent["name"] as? String ?? "Profile", pin: sent["pin"] is String)
                list.append(created)
                return (201, created, [:])
            case ("PATCH", 7), ("DELETE", 7):
                guard let index = list.firstIndex(where: { ($0["id"] as? String) == parts[6] }) else {
                    let missing = problem(404, "Profile not found.")
                    return (missing.0, missing.1, missing.2)
                }
                if method == "DELETE" {
                    if list[index]["is_primary"] as? Bool == true {
                        let refused = problem(409, "The main profile can't be deleted. Delete the account instead.")
                        return (refused.0, refused.1, refused.2)
                    }
                    list.remove(at: index)
                    return (204, nil, [:])
                }
                if let name = sent["name"] as? String { list[index]["name"] = name }
                if sent.keys.contains("pin") { list[index]["has_pin"] = sent["pin"] is String }
                return (200, list[index], [:])
            default:
                return nil
            }
        }
        return nil
    }

    private func userRoute(method: String, id: String, ifMatch: String?, body: Data?) -> (status: Int, json: Any?, headers: [String: String]) {
        guard let index = users.firstIndex(where: { ($0["id"] as? String) == id }) else {
            let missing = problem(404, "No such user")
            return (missing.0, missing.1, missing.2)
        }
        let version = versions[id, default: 0]
        switch method {
        case "GET":
            return (200, rendered(users[index]), ["ETag": "\"v\(version)\""])
        case "DELETE":
            guard ifMatch == "\"v\(version)\"" else { let stale = problem(412, "The user changed."); return (stale.0, stale.1, stale.2) }
            users.remove(at: index)
            return (204, nil, [:])
        case "PUT":
            if conflictPending, body.flatMap({ String(data: $0, encoding: .utf8) })?.contains("max_streams") == true {
                // Another admin got there first: the account changes and its version moves on.
                conflictPending = false
                users[index]["max_streams"] = 9
                versions[id] = version + 1
            }
            guard ifMatch == "\"v\(versions[id, default: 0])\"" else { let stale = problem(412, "The user changed."); return (stale.0, stale.1, stale.2) }
            let changes = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for (key, value) in changes {
                if key == "password" {
                    users[index]["password_login"] = true
                    users[index]["password_change_required"] = changes["require_password_change"] as? Bool ?? false
                } else if key != "require_password_change" {
                    users[index][key] = value
                }
            }
            versions[id] = versions[id, default: 0] + 1
            return (204, nil, [:])
        default:
            let missing = problem(405, "Method not allowed")
            return (missing.0, missing.1, missing.2)
        }
    }

    nonisolated(unsafe) private static let contract: [String: Any] = [
        "revision": 1,
        "definitions": [
            ["key": "playback.autoplay", "persistence": "remote", "allowed_scopes": ["profile", "profile_device"], "category": "playback", "label": "Autoplay next episode", "default_value": true, "value_schema": ["type": "boolean"]],
        ],
    ]
}

private final class UserFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let result = UserFixtureServer.shared.respond(
            method: request.httpMethod ?? "GET",
            path: url.path.removingPercentEncoding ?? url.path,
            query: query,
            ifMatch: request.value(forHTTPHeaderField: "If-Match"),
            body: Self.body(of: request)
        )
        var headers = result.headers
        if result.json != nil, headers["Content-Type"] == nil { headers["Content-Type"] = "application/json" }
        let data = result.json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        if let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil, headerFields: headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
#endif
