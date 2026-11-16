#if DEBUG
import SwiftUI

/// The Libraries page's UI-test seam. Launched with `--ui-testing-libraries` the app shows the real Libraries page
/// over an in-process fake server instead of the server list, so UI tests drive Scan, Stop, Check the mount and
/// Refresh metadata against known data without any network. The fake server moves a scan from queued (3 s) to
/// running (8 s, well over the fixture's 1 s fallback read so a slow simulator still sees it) to completed, and a refresh from queued to running to completed, by the clock, as the real one
/// would. Compiled into debug builds only.
enum LibrariesUITestFixture {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-testing-libraries")
    }
}

struct LibrariesUITestRoot: View {
    @State private var client: APIClient

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LibrariesFixtureURLProtocol.self]
        let session = URLSession(configuration: configuration)
        // The fixture server has no events socket, so the page falls back to a read at this pace (the real
        // fallback is once a minute) and the test sees a scan move without waiting.
        LiveHub.shared.makeConnection = { client in
            var timings = LiveTimings()
            timings.fallbackInterval = 1
            return LiveConnection(client: client, timings: timings)
        }
        _client = State(initialValue: APIClient(baseURL: URL(string: "https://fixture.test")!, accessToken: "fixture", session: session))
    }

    var body: some View {
        NavigationStack {
            LibrariesListView(client: client)
                .navigationTitle("Libraries")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// A tiny in-memory Bloem server for the Libraries routes.
private final class LibrariesFixtureServer: @unchecked Sendable {
    static let shared = LibrariesFixtureServer()

    private struct Run {
        let id: String
        let libraryID: String
        let trigger: String
        let requested: Date
        var cancelled = false
        var fixedStatus: String?
        var fixedError: String?
        var fixedResult: [String: Any]?
        var fixedFinish: Date?
    }

    private struct Refresh {
        let id: String
        let libraryID: String
        let created: Date
        var cancelled = false
    }

    private let lock = NSLock()
    private var runs: [Run]
    private var refreshes: [Refresh] = []
    private var nextRun = 1
    private var nextJob = 1
    private let queuedFor: TimeInterval = 3
    private let runningFor: TimeInterval = 8

    private init() {
        let now = Date()
        runs = [
            Run(
                id: "seed-1", libraryID: "1", trigger: "task:scan_libraries", requested: now.addingTimeInterval(-7200),
                fixedStatus: "completed", fixedResult: ["new": 4, "updated": 1, "unchanged": 1200, "missing": 0, "errors": 0, "skipped": 0],
                fixedFinish: now.addingTimeInterval(-7100)
            ),
            Run(
                id: "seed-2", libraryID: "2", trigger: "manual", requested: now.addingTimeInterval(-3600),
                fixedStatus: "failed", fixedError: "root /media/shows is not reachable", fixedFinish: now.addingTimeInterval(-3590)
            ),
        ]
    }

    private func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func status(of run: Run, at now: Date) -> String {
        if let fixed = run.fixedStatus { return fixed }
        if run.cancelled { return "cancelled" }
        let age = now.timeIntervalSince(run.requested)
        if age < queuedFor { return "accepted" }
        if age < queuedFor + runningFor { return "running" }
        return "completed"
    }

    private func json(_ run: Run, at now: Date) -> [String: Any] {
        let state = status(of: run, at: now)
        var value: [String: Any] = [
            "id": run.id, "library_id": run.libraryID, "mode": "library", "trigger": run.trigger, "status": state,
            "requested_at": iso(run.requested),
        ]
        if state != "accepted" { value["started_at"] = iso(run.requested.addingTimeInterval(run.fixedStatus == nil ? queuedFor : 5)) }
        switch state {
        case "completed":
            value["completed_at"] = iso(run.fixedFinish ?? run.requested.addingTimeInterval(queuedFor + runningFor))
            value["result"] = run.fixedResult ?? ["new": 12, "updated": 3, "unchanged": 900, "missing": 2, "errors": 1, "skipped": 0]
        case "failed":
            value["completed_at"] = iso(run.fixedFinish ?? now)
            if let error = run.fixedError { value["error_message"] = error }
        case "cancelled":
            value["completed_at"] = iso(now)
        default: break
        }
        return value
    }

    private func refreshJSON(_ job: Refresh, at now: Date) -> [String: Any] {
        let age = now.timeIntervalSince(job.created)
        let state: String
        if job.cancelled { state = "canceled" } else if age < 2 { state = "queued" } else if age < 8 { state = "running" } else { state = "succeeded" }
        let terminal = state == "canceled" || state == "succeeded"
        var value: [String: Any] = [
            "id": job.id, "kind": "library_refresh", "state": state, "terminal": terminal,
            "cancelable": !terminal, "created_at": iso(job.created), "library_id": job.libraryID,
            "library_name": job.libraryID == "1" ? "Movies" : "Shows", "library_ids": [String](),
        ]
        if state == "running" { value["progress"] = ["current": 40, "total": 200, "unit": "items"] }
        if state == "succeeded" { value["refresh_result"] = ["library_id": job.libraryID, "refreshed": 197, "failed": 3] }
        return value
    }

    func respond(method: String, path: String, query: [String: String], body: Data?) -> (status: Int, json: Any?) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        let bodyObject = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        // Routes are matched without the "api/v2" prefix, so this file holds no API path literals.
        let route = path.split(separator: "/").dropFirst(2).joined(separator: "/")
        switch (method, route) {
        case ("GET", "libraries"):
            let recently = iso(now.addingTimeInterval(-7200))
            return (200, ["items": [
                ["id": "1", "name": "Movies", "type": "movies", "paths": ["/media/movies"], "enabled": true, "last_scanned_at": recently],
                ["id": "2", "name": "Shows", "type": "series", "paths": ["/media/shows", "/media/more-shows"], "enabled": true,
                 "scan_warning_code": "dead_root", "scan_warning_message": "Root /media/shows is not reachable",
                 "scan_warning_at": iso(now.addingTimeInterval(-3590))],
            ]])
        case ("GET", "scan/capabilities"):
            return (200, ["revision": "fixture", "state": "available"])
        case ("POST", "scan"):
            let libraryID = bodyObject["library_id"] as? String ?? ""
            guard ["1", "2"].contains(libraryID) else { return (400, problem(400, "library_id must be a positive library identifier")) }
            runs.append(Run(id: "run-\(nextRun)", libraryID: libraryID, trigger: "manual", requested: now))
            nextRun += 1
            return (202, ["status": "accepted", "mode": "library", "library_id": libraryID])
        case ("POST", "scan/cancel"):
            let libraryID = bodyObject["library_id"] as? String ?? ""
            var stopped = 0
            for index in runs.indices where runs[index].libraryID == libraryID && runs[index].fixedStatus == nil && !runs[index].cancelled {
                if ["accepted", "running"].contains(status(of: runs[index], at: now)) {
                    runs[index].cancelled = true
                    stopped += 1
                }
            }
            return (200, ["cancelled": stopped, "library_id": libraryID])
        case ("GET", "admin/autoscan/scans"):
            let wanted = query["status"] ?? ""
            let limit = Int(query["limit"] ?? "") ?? 50
            let rows = runs.map { json($0, at: now) }
                .filter { wanted.isEmpty || ($0["status"] as? String) == wanted }
                .sorted { (($0["requested_at"] as? String) ?? "") > (($1["requested_at"] as? String) ?? "") }
                .prefix(limit)
            return (200, ["items": Array(rows), "page": ["has_more": false], "total": rows.count])
        case ("GET", "admin/jobs"):
            return (200, ["items": refreshes.reversed().map { refreshJSON($0, at: now) }])
        case ("POST", _) where route.hasSuffix("/check-mount"):
            let libraryID = route.split(separator: "/").dropLast().last.map(String.init) ?? ""
            let healthy = libraryID == "1"
            let roots: [[String: Any]] = healthy
                ? [["path": "/media/movies", "reachable": true, "error_code": NSNull(), "error_message": NSNull(), "suspect_empty": false]]
                : [["path": "/media/shows", "reachable": false, "error_code": "not_found", "error_message": "no such file or directory", "suspect_empty": false],
                   ["path": "/media/more-shows", "reachable": true, "error_code": NSNull(), "error_message": NSNull(), "suspect_empty": false]]
            return (200, [
                "status": healthy ? "healthy" : "unhealthy", "library_id": libraryID, "library_name": healthy ? "Movies" : "Shows",
                "healthy": healthy, "checked_at": iso(now),
                "summary": healthy ? "All configured roots are reachable" : "1 of 2 roots unreachable", "roots": roots,
            ])
        case ("POST", _) where route.hasSuffix("/refresh-metadata"):
            let libraryID = route.split(separator: "/").dropLast().last.map(String.init) ?? ""
            if let existing = refreshes.last(where: { $0.libraryID == libraryID }), !existing.cancelled, now.timeIntervalSince(existing.created) < 8 {
                return (409, problem(409, "a metadata refresh of this library is already running"))
            }
            let job = Refresh(id: "job-\(nextJob)", libraryID: libraryID, created: now)
            nextJob += 1
            refreshes.append(job)
            // The real answer is the plain job, which does not name the library.
            var answer = refreshJSON(job, at: now)
            answer["library_id"] = nil
            answer["library_name"] = nil
            answer["library_ids"] = nil
            return (202, answer)
        case ("POST", _) where route.hasPrefix("admin/jobs/") && route.hasSuffix("/cancel"):
            let id = route.split(separator: "/").dropLast().last.map(String.init) ?? ""
            guard let index = refreshes.firstIndex(where: { $0.id == id }) else { return (404, problem(404, "Job not found")) }
            refreshes[index].cancelled = true
            return (202, refreshJSON(refreshes[index], at: now))
        default:
            return (404, problem(404, "No such fixture route: \(method) \(path)"))
        }
    }

    private func problem(_ status: Int, _ detail: String) -> [String: Any] {
        ["type": "about:blank", "title": "Fixture", "status": status, "detail": detail]
    }
}

private final class LibrariesFixtureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let result = LibrariesFixtureServer.shared.respond(
            method: request.httpMethod ?? "GET", path: url.path.removingPercentEncoding ?? url.path, query: query, body: Self.body(of: request)
        )
        let data = result.json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        if let response = HTTPURLResponse(url: url, statusCode: result.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) {
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
