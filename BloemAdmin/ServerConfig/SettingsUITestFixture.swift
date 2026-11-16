#if DEBUG
import SwiftUI

/// The Settings pages' UI-test seam. Launched with `--ui-testing-settings` the app shows Settings of an
/// in-process fake server instead of the server list, so UI tests drive the real pages (named pages,
/// search, save bar, conflict, restart status, tests) against known data without any network.
/// `--ui-testing-settings-conflict` makes the first save lose a race, as if another administrator had
/// changed the settings first. Compiled into debug builds only.
enum SettingsUITestFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-settings")
    }

    static var forcesConflict: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-settings-conflict")
    }
}

struct SettingsUITestRoot: View {
    @State private var client: APIClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        _client = State(initialValue: APIClient(baseURL: URL(string: "https://fixture.test")!, accessToken: "fixture", session: session))
    }

    var body: some View {
        NavigationStack {
            ServerConfigView(client: client)
        }
    }
}

/// A tiny in-memory Bloem server for the settings routes. The snapshot version (the `ETag`) advances on
/// every write, and a write whose `If-Match` is stale is refused with 412, like the real server.
private final class SettingsFixtureServer: @unchecked Sendable {
    static let shared = SettingsFixtureServer()

    private let lock = NSLock()
    private var values: [String: String] = [
        "server.log_level": "info", "server.public_url": "", "server.lan_discovery": "true",
        "playback.transcode_enabled": "true", "playback.hw_accel": "auto", "allow_4k_transcode": "true",
        "email.enabled": "true", "email.smtp_host": "smtp.example.test", "email.smtp_port": "587", "email.smtp_security": "starttls",
        "auth.local_password_login": "true", "download.enabled": "false", "download.artifact_max_bytes": "50000000000",
        "scanner.workers": "8", "custom.flag": "on",
    ]
    private var version = 1
    private var reasons: [String] = []
    private var conflictPending = SettingsUITestFixture.forcesConflict
    private var requestSettings: [String: Any] = [
        "requests_enabled": true, "global_max_requests": 5, "global_window_days": 7,
        "global_auto_approval_enabled": false, "force_dual_quality": false, "watchlist_requests": false,
    ]
    private var requestVersion = 1
    private let restartKeys = ["server.public_url", "playback.hw_accel", "server.lan_discovery"]
    private let startedAt = Date(timeIntervalSinceNow: -(3 * 86_400 + 4 * 3600))

    private func page(_ items: [Any]) -> [String: Any] { ["items": items, "page": ["has_more": false]] }

    private func problem(_ status: Int, _ type: String, _ detail: String) -> (Int, [String: Any], [String: String]) {
        (status, ["type": "https://fixture.test/problems/\(type)", "title": detail, "status": status, "detail": detail],
         ["Content-Type": "application/problem+json"])
    }

    private func isoNow(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    func respond(method: String, path: String, ifMatch: String?, body: Data?) -> (status: Int, json: Any?, headers: [String: String]) {
        lock.lock()
        defer { lock.unlock() }
        // Routes are matched without the "api/v2" prefix, so this file holds no API path literals.
        let parts = path.split(separator: "/").map(String.init)
        let route = parts.dropFirst(2).joined(separator: "/")
        let json = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        switch (method, route) {
        case ("GET", "admin/settings/effective"):
            return (200, values, ["ETag": "\"v\(version)\""])
        case ("GET", "admin/settings/restart-keys"):
            return (200, ["keys": restartKeys, "prefixes": ["jellyfin_compat."]], [:])
        case ("GET", "admin/settings/sensitive-status"):
            return (200, ["configured": ["email.smtp_password"], "managed_by_env": [String]()], [:])
        case ("GET", "admin/server/status"):
            var status: [String: Any] = [
                "started_at": isoNow(startedAt), "restart_required": !reasons.isEmpty, "restart_requested": false,
                "restart_mark_count": reasons.count,
            ]
            if !reasons.isEmpty {
                status["restart_required_reasons"] = reasons
                status["restart_required_reason"] = reasons[0]
                status["restart_required_at"] = isoNow(Date())
            }
            return (200, status, [:])
        case ("PUT", "admin/settings"):
            let incoming = json["values"] as? [String: String] ?? [:]
            if conflictPending, incoming.keys.contains("server.log_level") || incoming.keys.contains("server.public_url") {
                // Another admin got there first: a setting changes and the version moves on.
                conflictPending = false
                values["server.log_level"] = "warn"
                version += 1
            }
            guard ifMatch == "\"v\(version)\"" else {
                let stale = problem(412, "precondition_failed", "The settings changed.")
                return (stale.0, stale.1, stale.2)
            }
            if incoming["auth.local_password_login"] == "false" {
                let refused = problem(409, "break_glass_required", "No break-glass admin")
                return (refused.0, refused.1, refused.2)
            }
            var restartKeysSaved: [String] = []
            for (key, value) in incoming where key != "email.smtp_password" {
                values[key] = value
                if restartKeys.contains(key) {
                    restartKeysSaved.append(key)
                    let reason = "setting:\(key)"
                    if !reasons.contains(reason) { reasons.append(reason) }
                }
            }
            version += 1
            var result: [String: Any] = ["values": incoming, "restart_required": !restartKeysSaved.isEmpty]
            if !restartKeysSaved.isEmpty { result["restart_required_keys"] = restartKeysSaved }
            return (200, result, ["ETag": "\"v\(version)\""])
        case ("POST", "admin/server/restart"):
            return (202, ["status": "restart_requested", "message": "ok", "notified_sessions": 2], [:])
        case ("POST", "admin/email/test"):
            let to = json["to"] as? String ?? ""
            return to.hasPrefix("ok@")
                ? (200, ["ok": true, "duration_ms": 312], [:])
                : (200, ["ok": false, "duration_ms": 90, "message": "535 authentication failed"], [:])
        case ("POST", "admin/settings/check/redis"):
            return (200, ["success": false, "message": "dial tcp: connection refused"], [:])
        case ("GET", "admin/notifications/server-channels"):
            return (200, page([[
                "id": "7", "name": "Ops channel", "type": "discord", "url_host": "discord.com", "enabled": true,
                "consecutive_failures": 3, "disabled_reason": NSNull(), "last_failure_message": "HTTP 404 unknown webhook",
                "last_failure_at": "2026-11-14T09:00:00.000Z", "last_success_at": NSNull(),
            ]]), [:])
        case ("POST", "admin/notifications/server-channels/7/test"):
            return (200, ["ok": false, "http_status": 404, "duration_ms": 130, "message": "Unknown webhook"], [:])
        case ("GET", "admin/plugins/installations"):
            return (200, page([[
                "id": "3", "plugin_id": "oidc", "enabled": true,
                "capabilities": [["type": "auth_provider.v1", "id": "oidc-main", "display_name": "Company SSO", "sign_in_mode": "oauth"]],
                "auth_bindings": [["capability_id": "oidc-main", "enabled": true]],
            ]]), [:])
        case ("POST", "admin/plugins/installations/3/auth-binding/test"):
            return (200, ["ok": true, "callback_url": "", "steps": [
                ["id": "discovery", "label": "Discovery document reachable", "ok": true, "message": "Loaded the document"],
            ]], [:])
        case ("GET", "admin/request-settings"):
            return (200, requestSettings, ["ETag": "\"s\(requestVersion)\""])
        case ("PUT", "admin/request-settings"):
            guard ifMatch == "\"s\(requestVersion)\"" else {
                let stale = problem(412, "precondition_failed", "Request settings changed; reload before saving.")
                return (stale.0, stale.1, stale.2)
            }
            for (key, value) in json { requestSettings[key] = value }
            requestVersion += 1
            return (200, requestSettings, ["ETag": "\"s\(requestVersion)\""])
        case ("GET", "network-access/capabilities"):
            return (200, ["state": "available", "providers": [["provider": "tailscale", "display_name": "Tailscale", "installation_id": "9"]]], [:])
        case ("GET", "admin/network-access/tailscale/status"):
            return (200, ["provider": "tailscale", "hosts": [[
                "host": ["id": "api", "role": "api", "name": "Main"], "state": "awaiting_authorization", "addresses": [String](),
                "auth_url": "https://login.tailscale.com/a/fixture",
            ]]], [:])
        default:
            break
        }
        if method == "PUT", parts.count == 5, parts[3] == "settings" {
            let key = parts[4]
            values[key] = json["value"] as? String ?? ""
            version += 1
            return (200, ["key": key, "value": values[key] ?? ""], [:])
        }
        let missing = problem(404, "not_found", "Not found")
        return (missing.0, missing.1, missing.2)
    }
}

private final class SettingsFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let result = SettingsFixtureServer.shared.respond(
            method: request.httpMethod ?? "GET",
            path: url.path.removingPercentEncoding ?? url.path,
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
