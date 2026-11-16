#if DEBUG
import SwiftUI

/// The UI-test seam for the Scheduled tasks, Nodes, Backups and Plugins pages. Launched with
/// `--ui-testing-automation=tasks|nodes|backups|plugins` the app shows that page over an in-process fake
/// server, so the UI tests drive the real page (rows, confirmations, sheets, Load more) against known data
/// without a network. Compiled into debug builds only.
enum AutomationUITestFixture {
    enum Page: String {
        case tasks, nodes, backups, plugins
    }

    static var requested: Page? {
        for argument in ProcessInfo.processInfo.arguments where argument.hasPrefix("--ui-testing-automation=") {
            return Page(rawValue: String(argument.dropFirst("--ui-testing-automation=".count)))
        }
        return nil
    }
}

struct AutomationUITestRoot: View {
    let page: AutomationUITestFixture.Page
    @State private var client: APIClient

    init(page: AutomationUITestFixture.Page) {
        self.page = page
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AutomationFixtureURLProtocol.self]
        _client = State(initialValue: APIClient(
            baseURL: URL(string: "https://fixture.test")!, accessToken: "fixture", session: URLSession(configuration: configuration)
        ))
    }

    var body: some View {
        NavigationStack {
            switch page {
            case .tasks: JobsListView(client: client)
            case .nodes: NodesView(client: client)
            case .backups: BackupsView(client: client)
            case .plugins: PluginsView(client: client)
            }
        }
    }
}

/// A tiny in-memory Bloem server for the automation pages. Writes change what the next read returns.
private final class AutomationFixtureServer: @unchecked Sendable {
    static let shared = AutomationFixtureServer()

    struct Reply {
        var status = 200
        var json: Any?
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private let iso = ISO8601DateFormatter()
    private var taskState: [String: String] = ["scan": "idle", "cleanup": "running", "nightly": "idle", "backup": "idle"]
    private var taskProgress: [String: Double] = ["cleanup": 42]
    private var triggers: [String: [[String: Any]]] = [
        "scan": [["type": "daily", "time_of_day": "02:00"]],
        "cleanup": [["type": "interval", "interval_ms": 3_600_000]],
        "nightly": [["type": "weekly", "day_of_week": 0, "time_of_day": "03:30"]],
        "backup": [["type": "daily", "time_of_day": "04:00"]],
    ]
    private var scheduleVersion = 1
    private var nodeDrain: [String: Bool] = [:]
    private var nodeEnabled: [String: Bool] = ["n1": true, "n2": true]
    private var backups: [[String: Any]] = []
    private var backupRunning = false
    private var settings: [String: String] = ["backup.enabled": "true", "backup.time": "04:00", "backup.keep": "7"]
    private var settingsVersion = 1
    private var pluginEnabled: [String: Bool] = ["tmdb": true, "subs": true, "lyrics": true]
    private var pluginState: [String: String] = ["tmdb": "running", "subs": "failed", "lyrics": "running"]
    private var pluginVersion: [String: String] = ["tmdb": "1.0.0", "subs": "2.1.0", "lyrics": "0.9.0"]
    private var pluginUpdate: [String: String?] = ["tmdb": "1.1.0", "subs": nil, "lyrics": nil]

    private init() {
        backups = [
            ["id": "b2", "kind": "nightly", "status": "complete", "created_at": stamp(-5 * 3600), "size_bytes": 1_500_000_000],
            ["id": "b1", "kind": "manual", "status": "complete", "created_at": stamp(-30 * 3600), "size_bytes": 1_400_000_000],
        ]
    }

    private func stamp(_ offset: TimeInterval) -> String { iso.string(from: Date().addingTimeInterval(offset)) }

    private func page(_ items: [Any], more: String? = nil) -> [String: Any] {
        var body: [String: Any] = ["items": items]
        if let more { body["page"] = ["has_more": true, "next_cursor": more] } else { body["page"] = ["has_more": false] }
        return body
    }

    func respond(method: String, path: String, query: [String: String], ifMatch: String?, body: Data?) -> Reply {
        lock.lock()
        defer { lock.unlock() }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 4, parts[0] == "api", parts[1] == "v2", parts[2] == "admin" else { return Reply(status: 404) }
        let route = parts.dropFirst(3).joined(separator: "/")
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]

        switch (method, route) {
        case ("GET", "tasks"): return Reply(json: page(taskKeys.map(taskJSON)))
        case ("GET", "tasks/backup"): return Reply(json: taskJSON("backup"))
        case ("POST", _) where route.hasPrefix("tasks/") && route.hasSuffix("/run"):
            let key = parts[4]
            taskState[key] = "running"
            taskProgress[key] = 5
            return Reply(status: 202, json: [String: Any]())
        case ("POST", _) where route.hasPrefix("tasks/") && route.hasSuffix("/cancel"):
            taskState[parts[4]] = "idle"
            return Reply(json: [String: Any]())
        case ("GET", _) where route.hasPrefix("tasks/") && route.hasSuffix("/history"):
            if query["cursor"] == "c2" {
                return Reply(json: page([run("h3", "completed", ago: 50 * 3600)]))
            }
            return Reply(json: page([run("h1", "failed", ago: 2 * 3600), run("h2", "completed", ago: 26 * 3600)], more: "c2"))
        case ("GET", _) where route.hasPrefix("tasks/") && route.hasSuffix("/triggers"):
            let key = parts[4]
            return Reply(json: ["task_key": key, "triggers": triggers[key] ?? []], headers: ["ETag": "\"s\(scheduleVersion)\""])
        case ("PUT", _) where route.hasPrefix("tasks/") && route.hasSuffix("/triggers"):
            guard ifMatch == "\"s\(scheduleVersion)\"" else { return Reply(status: 412, json: problem(412, "The schedule changed.")) }
            triggers[parts[4]] = object?["triggers"] as? [[String: Any]] ?? []
            scheduleVersion += 1
            return Reply(json: ["task_key": parts[4], "triggers": triggers[parts[4]] ?? []], headers: ["ETag": "\"s\(scheduleVersion)\""])
        case ("GET", "jobs"):
            if query["cursor"] == "c2" { return Reply(json: page([job("j3", "backup_restore", "failed")])) }
            return Reply(json: page([job("j1", "library_refresh", "completed"), job("j2", "image_cache_cleanup", "running")], more: "c2"))

        case ("GET", "nodes/summary"): return Reply(json: page(["n1", "n2"].map(nodeSummary)))
        case ("GET", "nodes"):
            return Reply(json: page(["n1", "n2"].map { ["id": $0, "config_etag": "\"cfg-\($0)\""] }))
        case ("POST", _) where route.hasPrefix("nodes/") && route.hasSuffix("/drain"):
            nodeDrain[parts[4]] = true
            return Reply(json: ["node_id": parts[4], "drain_requested": true, "drain_state": "draining", "active_jobs": 1])
        case ("POST", _) where route.hasPrefix("nodes/") && route.hasSuffix("/resume"):
            nodeDrain[parts[4]] = false
            return Reply(json: ["node_id": parts[4], "drain_requested": false, "drain_state": "none", "active_jobs": 1])
        case ("POST", _) where route.hasPrefix("nodes/") && route.hasSuffix("/check"):
            return Reply(json: ["healthy": true, "active_jobs": 1, "egress_kbps": 0, "health_persisted": true])
        case ("PUT", _) where route.hasPrefix("nodes/"):
            guard ifMatch == "\"cfg-\(parts[4])\"" else { return Reply(status: 412, json: problem(412, "changed")) }
            nodeEnabled[parts[4]] = object?["enabled"] as? Bool ?? true
            return Reply(json: nodeSummary(parts[4]))

        case ("GET", "backups"): return Reply(json: backupsOverview())
        case ("POST", "backups"):
            backupRunning = true
            return Reply(status: 202, json: ["id": "b3", "kind": "manual", "status": "in_progress"])
        case ("DELETE", _) where route.hasPrefix("backups/"):
            backups.removeAll { $0["id"] as? String == parts[4] }
            return Reply(status: 204)
        case ("GET", "settings/effective"):
            return Reply(json: settings, headers: ["ETag": "\"e\(settingsVersion)\""])
        case ("PUT", _) where route.hasPrefix("settings/"):
            guard ifMatch == "\"e\(settingsVersion)\"" else { return Reply(status: 412, json: problem(412, "changed")) }
            let value = object?["value"] as? String ?? ""
            settings[parts[4]] = value
            settingsVersion += 1
            return Reply(json: ["key": parts[4], "value": value])

        case ("GET", "plugins/installations"): return Reply(json: page(["tmdb", "subs", "lyrics"].map(pluginJSON)))
        case ("POST", _) where route.hasPrefix("plugins/installations/") && route.hasSuffix("/restart"):
            pluginState[parts[5]] = "running"
            return Reply(json: pluginJSON(parts[5]))
        case ("POST", _) where route.hasPrefix("plugins/installations/") && route.hasSuffix("/update"):
            if let next = pluginUpdate[parts[5]] ?? nil { pluginVersion[parts[5]] = next }
            pluginUpdate[parts[5]] = .some(nil)
            return Reply(json: pluginJSON(parts[5]))
        case ("PUT", _) where route.hasPrefix("plugins/installations/"):
            pluginEnabled[parts[5]] = object?["enabled"] as? Bool ?? true
            return Reply(json: pluginJSON(parts[5]))
        default:
            return Reply(status: 404, json: problem(404, "Not found"))
        }
    }

    private func problem(_ status: Int, _ detail: String) -> [String: Any] {
        ["type": "about:blank", "title": "Error", "status": status, "detail": detail, "instance": "/"]
    }

    private var taskKeys: [String] { ["scan", "cleanup", "nightly", "backup"] }

    private func taskJSON(_ key: String) -> [String: Any] {
        let names = ["scan": "Scan libraries", "cleanup": "Clean up images", "nightly": "Nightly maintenance", "backup": "Backup"]
        let state = taskState[key] ?? "idle"
        var task: [String: Any] = [
            "key": key, "name": names[key] ?? key, "description": "Runs \(names[key] ?? key) on the server.", "category": "system",
            "state": state, "progress": state == "idle" ? 0 : (taskProgress[key] ?? 0), "manual_only": false,
            "triggers": triggers[key] ?? [], "execution_scope": "process",
        ]
        switch key {
        case "scan":
            task["last_execution"] = ["task_key": key, "started_at": stamp(-7500), "completed_at": stamp(-7200), "status": "completed", "duration_ms": 125_000]
            task["next_run_at"] = stamp(12 * 3600 + 300)
        case "cleanup":
            task["last_execution"] = ["task_key": key, "started_at": stamp(-90_000), "completed_at": stamp(-86_400), "status": "failed", "duration_ms": 800, "error_message": "Disk full"]
        case "nightly":
            task["next_run_at"] = stamp(-3600)
        default:
            task["next_run_at"] = stamp(16 * 3600 + 300)
        }
        return task
    }

    private func run(_ id: String, _ status: String, ago: TimeInterval) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "task_key": "scan", "started_at": stamp(-ago - 60), "completed_at": stamp(-ago), "status": status, "duration_ms": 60_000,
        ]
        if status == "failed" {
            item["error_message"] = "Disk full"
            item["steps"] = [["key": "a", "name": "Read folders", "status": "completed"], ["key": "b", "name": "Probe files", "status": "failed"]]
        }
        return item
    }

    private func job(_ id: String, _ kind: String, _ state: String) -> [String: Any] {
        var item: [String: Any] = [
            "id": id, "kind": kind, "state": state, "terminal": state != "running", "cancelable": state == "running",
            "created_at": stamp(-7200), "library_ids": [Int](),
        ]
        if state == "running" { item["started_at"] = stamp(-600); item["progress"] = ["current": 40, "total": 100, "unit": "items"] }
        if state == "failed" {
            item["finished_at"] = stamp(-3600)
            item["failure"] = ["type": "x", "title": "Restore failed", "detail": "Not enough space", "retryable": false]
        }
        return item
    }

    private func nodeSummary(_ id: String) -> [String: Any] {
        let draining = nodeDrain[id] ?? false
        return [
            "id": id, "name": "node-\(id)", "type": "transcode", "enabled": nodeEnabled[id] ?? true, "healthy": true, "group": "rack-1",
            "drain_state": draining ? "draining" : "none", "drain_requested": draining, "active_jobs": 1, "max_jobs": 4,
            "egress_kbps": 12_500, "max_bandwidth_kbps": NSNull(), "last_health_check": stamp(-180), "created_at": "2026-01-01T00:00:00Z",
            "resources": [
                "gpu": [Any](), "sampled_at": stamp(-2),
                "system": ["cpu_pct": 37, "load1": 1.5, "cores": 8, "mem_used_mb": 3072, "mem_total_mb": 8192,
                           "disks": [["used_gb": 50, "total_gb": 100]], "net_rx_bps": 2_500_000, "net_tx_bps": 400_000],
            ],
        ]
    }

    private func backupsOverview() -> [String: Any] {
        var overview: [String: Any] = [
            "busy": backupRunning, "destination": "default", "destination_available": true, "enabled": settings["backup.enabled"] == "true",
            "encrypted": false, "items": backups.map { item -> [String: Any] in
                var full = item
                full["blob_count"] = 3; full["clean"] = true; full["encrypted"] = false; full["key_matches"] = true; full["location"] = "x"
                full["missing_blobs"] = [Any](); full["missing_blobs_total"] = 0; full["objects"] = [Any](); full["restore_set_omitted"] = [Any]()
                return full
            },
            "keep": Int(settings["backup.keep"] ?? "7") ?? 7, "key_check": "k", "key_confirmed": true, "other_server_ids": [Any](),
            "server_id": "s", "warnings": [Any](), "last_success_at": stamp(-5 * 3600),
        ]
        if backupRunning {
            overview["active"] = ["operation": "backup", "progress": 42.0, "started_at": stamp(-60), "message": "Copying files"]
        }
        return overview
    }

    private func pluginJSON(_ id: String) -> [String: Any] {
        let state = pluginState[id] ?? "running"
        var plugin: [String: Any] = [
            "id": id, "plugin_id": "silo.\(id)", "enabled": pluginEnabled[id] ?? true, "version": pluginVersion[id] ?? "1",
            "source_kind": "silo", "repository_id": "repo", "update_policy": "notify", "updates_paused": false,
            "signature": ["state": "verified"],
            "runtime": ["resident": true, "state": state, "restart_count": 0, "last_error": state == "failed" ? "exit status 2" : ""],
            "presentation": ["display_name": ["tmdb": "Movie database", "subs": "Subtitles", "lyrics": "Lyrics"][id] ?? id, "summary": "s", "publisher_name": "p"],
        ]
        if let update = pluginUpdate[id] ?? nil { plugin["available_version"] = update }
        return plugin
    }
}

private final class AutomationFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let reply = AutomationFixtureServer.shared.respond(
            method: request.httpMethod ?? "GET",
            path: url.path.removingPercentEncoding ?? url.path,
            query: query,
            ifMatch: request.value(forHTTPHeaderField: "If-Match"),
            body: Self.body(of: request)
        )
        var headers = reply.headers
        if reply.json != nil { headers["Content-Type"] = reply.status >= 400 ? "application/problem+json" : "application/json" }
        let data = reply.json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        if let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: headers) {
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
