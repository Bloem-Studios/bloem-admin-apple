#if DEBUG
import SwiftUI

/// The UI-test seam for Playback history, Logs and Audit. Launched with `--ui-testing-incident-pages` the
/// app shows those three pages over an in-process fake server, so UI tests drive the real lists, filters
/// and detail sheets, and the hand-off from a history row to Logs, without a network. Compiled into debug
/// builds only.
enum IncidentUITestFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-incident-pages")
    }
}

struct IncidentUITestRoot: View {
    private enum Page: String { case history, logs, audit }

    @State private var client: APIClient
    @State private var router = ShellRouter(
        scope: .allServers,
        preferences: ShellScopePreferences(defaults: UserDefaults(suiteName: "incident-ui-testing") ?? .standard)
    )
    @State private var page: Page = .history

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IncidentFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        _client = State(initialValue: APIClient(baseURL: URL(string: "https://fixture.test")!, accessToken: "fixture", session: session))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach([Page.history, .logs, .audit], id: \.self) { target in
                    Button(target.rawValue.capitalized) { page = target }
                        .accessibilityIdentifier("fixture-page-\(target.rawValue)")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
            }
            NavigationStack {
                switch page {
                case .history:
                    ActivityListView(client: client, onOpenLogs: { focus in
                        router.openLogs(focus)
                        page = .logs
                    })
                case .logs: LogsListView(client: client)
                case .audit: AuditListView(client: client)
                }
            }
            .id(page)
        }
        .environment(router)
    }
}

/// A tiny Bloem server for the three pages: two people with profiles, four plays, log lines for two
/// playback sessions and three audit entries. Filters are honoured the way the real routes do.
private enum IncidentFixtureServer {
    nonisolated(unsafe) private static let policy: [String: Any] = [
        "library_ids": NSNull(), "max_playback_quality": "1080p", "max_streams": 8, "max_transcodes": 4, "max_profiles": 5,
        "transcode_allowed": true, "audio_transcode_allowed": true, "download_allowed": true, "download_transcode_allowed": false,
        "requests_allowed": false, "permissions": [String](),
    ]

    private static func user(_ id: String, _ name: String) -> [String: Any] {
        [
            "id": id, "username": name, "email": "\(name)@example.test", "role": "user", "enabled": true,
            "permissions": [String](), "library_ids": NSNull(), "access_group_id": NSNull(),
            "max_streams": 3, "max_transcodes": NSNull(), "max_profiles": NSNull(),
            "download_allowed": NSNull(), "requests_allowed": NSNull(), "transcode_allowed": NSNull(), "audio_transcode_allowed": NSNull(),
            "password_login": true, "password_change_required": false, "is_owner": false,
            "created_at": "2026-01-02T03:04:05.000Z", "last_active_at": NSNull(), "effective_policy": policy,
        ]
    }

    private static func play(
        _ id: String, user: (String, String), profile: (String, String), title: String, series: String = "", season: Int? = nil, episode: Int? = nil,
        method: String, completed: Bool, played: Double, duration: Double, ended: String, endReason: String
    ) -> [String: Any] {
        [
            "session_id": id, "user_id": user.0, "username": user.1, "profile_id": profile.0, "profile_name": profile.1,
            "media_item_id": "m-\(id)", "media_file_id": "f-\(id)", "media_title": title, "media_type": series.isEmpty ? "movie" : "episode",
            "play_method": method, "started_at": "2026-11-14T20:00:00.000Z", "ended_at": ended, "watched_seconds": played,
            "duration_seconds": duration, "completed": completed, "played_seconds": played, "series_title": series,
            "season_number": season.map { $0 as Any } ?? NSNull(), "episode_number": episode.map { $0 as Any } ?? NSNull(), "measured": true,
            "start_position_seconds": 0.0, "paused_seconds": 60.0, "measured_since": NSNull(), "measured_until": NSNull(),
            "client_ip": "192.0.2.10", "device_id": "d1", "device_platform": "ios", "client_name": "Bloem for iPhone", "client_version": "1.4",
            "video_decision": NSNull(), "audio_decision": NSNull(), "end_reason": endReason, "lifecycle_seq": NSNull(),
        ]
    }

    nonisolated(unsafe) private static let plays: [[String: Any]] = [
        play("ps_night_shift_0004", user: ("2", "bob"), profile: ("p1", "Living room"), title: "The Handover", series: "Night Shift", season: 2, episode: 4,
             method: "transcode", completed: false, played: 1500, duration: 2700, ended: "2026-11-14T21:42:10.000Z", endReason: "expired"),
        play("ps_heat_000000001", user: ("2", "bob"), profile: ("p2", "Kids"), title: "Heat", method: "direct", completed: true, played: 10200, duration: 10200,
             ended: "2026-11-14T20:50:00.000Z", endReason: "stopped"),
        play("ps_alien_00000002", user: ("1", "alice"), profile: ("p3", "Main"), title: "Alien", method: "direct_stream", completed: true, played: 7000, duration: 7000,
             ended: "2026-11-14T19:30:00.000Z", endReason: "stopped"),
    ]

    private static func log(_ id: String, level: String, component: String, message: String, session: String?, request: String?, node: String? = "node-a", attrs: [String: Any] = [:]) -> [String: Any] {
        var value: [String: Any] = ["id": id, "timestamp": "2026-11-14T21:41:0\(id).250Z", "level": level, "component": component, "message": message, "attrs": attrs]
        if let session { value["playback_session_id"] = session }
        if let request { value["request_id"] = request }
        if let node { value["node_id"] = node }
        value["client_ip"] = "192.0.2.10"
        value["user_id"] = "2"
        return value
    }

    nonisolated(unsafe) private static let logs: [[String: Any]] = [
        log("1", level: "error", component: "ffmpeg", message: "muxer failed: broken pipe", session: "ps_night_shift_0004", request: "req-ffmpeg-1", attrs: ["method": "GET", "status": 502, "duration_ms": 1840, "path": "/stream/ps"]),
        log("2", level: "info", component: "playback", message: "session started", session: "ps_night_shift_0004", request: "req-play-1", node: "node-b"),
        log("3", level: "warn", component: "scanner", message: "slow disk", session: nil, request: "req-scan-1"),
    ]

    nonisolated(unsafe) private static let audits: [[String: Any]] = [
        [
            "id": "1", "timestamp": "2026-11-14T21:00:00.000Z", "client_ip": "198.51.100.4", "method": "PUT", "path": "/admin/users/2", "status_code": 204, "duration_ms": 38,
            "user_id": "1", "request_id": "req-audit-1", "node_id": "node-a", "user_agent": "Bloem Admin/1.0", "session_id": "sess-1",
            "action": "user.update", "target_type": "user", "target_id": "2",
            "changes": [["field": "role", "before": "\"user\"", "after": "\"admin\""], ["field": "max_streams", "before": "2", "after": "3"]],
        ],
        [
            "id": "2", "timestamp": "2026-11-14T20:00:00.000Z", "client_ip": "198.51.100.5", "method": "GET", "path": "/admin/users", "status_code": 200, "duration_ms": 12,
            "user_id": "2", "request_id": "req-audit-2",
        ],
    ]

    private static func page(_ items: [[String: Any]]) -> [String: Any] { ["items": items, "page": ["has_more": false]] }

    static func respond(path: String, query: [String: String]) -> (status: Int, json: Any) {
        // Routes are matched without the "api/v2" prefix, so this file holds no API path literals.
        let parts = path.split(separator: "/").map(String.init)
        let route = parts.dropFirst(2).joined(separator: "/")
        switch route {
        case "admin/users":
            return (200, page([user("1", "alice"), user("2", "bob")]))
        case "admin/users/1/profiles":
            return (200, page([["id": "p3", "name": "Main"]]))
        case "admin/users/2/profiles":
            return (200, page([["id": "p1", "name": "Living room"], ["id": "p2", "name": "Kids"]]))
        case "admin/playback-history":
            var rows = plays
            if let user = query["user_id"] { rows = rows.filter { $0["user_id"] as? String == user } }
            if let profile = query["profile_id"] { rows = rows.filter { $0["profile_id"] as? String == profile } }
            if let completed = query["completed"] { rows = rows.filter { ($0["completed"] as? Bool) == (completed == "true") } }
            return (200, page(rows))
        case "admin/logs/app":
            var rows = logs
            if let session = query["playback_session_id"] { rows = rows.filter { $0["playback_session_id"] as? String == session } }
            if let component = query["component"] { rows = rows.filter { $0["component"] as? String == component } }
            if let request = query["request_id"] { rows = rows.filter { $0["request_id"] as? String == request } }
            if let level = query["level"] { rows = rows.filter { level.split(separator: ",").map(String.init).contains($0["level"] as? String ?? "") } }
            return (200, page(rows))
        case "admin/logs/audit":
            var rows = audits
            if let user = query["user_id"] { rows = rows.filter { $0["user_id"] as? String == user } }
            if query["playback_session_id"] != nil { rows = [] }
            return (200, page(rows))
        default:
            return (404, ["type": "https://fixture.test/problems/404", "title": "Not found", "status": 404, "detail": "Not found"])
        }
    }
}

private final class IncidentFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let result = IncidentFixtureServer.respond(path: url.path, query: query)
        let data = (try? JSONSerialization.data(withJSONObject: result.json)) ?? Data()
        let headers = ["Content-Type": result.status == 200 ? "application/json" : "application/problem+json"]
        if let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil, headerFields: headers) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
#endif
