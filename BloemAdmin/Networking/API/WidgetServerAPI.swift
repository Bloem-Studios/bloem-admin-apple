import Foundation

// The widget's own small client for the admin routes it reads. It is separate from the app's `APIClient`
// on purpose: it never changes a stored sign-in by itself (a refresh goes through `WidgetAuthorizer`, under
// the cross-process lock), it reads only the fields a widget draws, and it is small enough to compile into
// the extension. HTTPS only, no redirects, no cookies, no cache, like the app's session.

struct WidgetAPIError: Error, Equatable, Sendable {
    /// The HTTP status, or nil when no answer came (offline, timed out, a refused connection).
    let status: Int?

    static let transport = WidgetAPIError(status: nil)

    var isUnauthorized: Bool { status == 401 }
    var isForbidden: Bool { status == 403 }
    /// The server has no such route or feature.
    var isMissing: Bool { status == 404 || status == 501 || status == 405 }
    /// Nothing usable came back: no answer, or the server is failing.
    var isUnreachable: Bool { status == nil || (status ?? 0) >= 500 }
}

// MARK: Wire shapes

/// One playing session, with every field the app's own session card reads for its title, who, how it is
/// delivered and where it plays. Every field but the id, the user and the title is optional, so a server that
/// leaves one out still draws a card. `session` hands the same values to the app's presentation rules
/// (`AdminSession`, `StreamFacts`), so a widget says what the Now playing page says.
struct WidgetSessionDTO: Decodable, Equatable, Sendable {
    let sessionID: String
    let username: String
    let mediaTitle: String
    let mediaType: String?
    let playMethod: String?
    let effectivePlayMethod: String?
    let positionSeconds: Double?
    let fileDuration: Double?
    let isPaused: Bool?
    let streamBitrateKbps: Int?
    let seriesName: String?
    let episodeName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let profileName: String?
    let devicePlatform: String?
    let clientName: String?
    let clientLabel: String?
    let clientVersion: String?
    let videoDecision: String?
    let audioDecision: String?
    let transcodeAudio: Bool?
    let transcodeHWAccel: String?
    let sourceVideoCodec: String?
    let sourceVideoResolution: String?
    let sourceVideoHeight: Int?
    let sourceAudioCodec: String?
    let sourceContainer: String?
    let targetVideoCodec: String?
    let targetResolution: String?

    enum CodingKeys: String, CodingKey {
        case username
        case sessionID = "session_id"
        case mediaTitle = "media_title"
        case mediaType = "media_type"
        case playMethod = "play_method"
        case effectivePlayMethod = "effective_play_method"
        case positionSeconds = "position_seconds"
        case fileDuration = "file_duration"
        case isPaused = "is_paused"
        case streamBitrateKbps = "stream_bitrate_kbps"
        case seriesName = "series_name"
        case episodeName = "episode_name"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case profileName = "profile_name"
        case devicePlatform = "device_platform"
        case clientName = "client_name"
        case clientLabel = "client_label"
        case clientVersion = "client_version"
        case videoDecision = "video_decision"
        case audioDecision = "audio_decision"
        case transcodeAudio = "transcode_audio"
        case transcodeHWAccel = "transcode_hw_accel"
        case sourceVideoCodec = "source_video_codec"
        case sourceVideoResolution = "source_video_resolution"
        case sourceVideoHeight = "source_video_height"
        case sourceAudioCodec = "source_audio_codec"
        case sourceContainer = "source_container"
        case targetVideoCodec = "target_video_codec"
        case targetResolution = "target_resolution"
    }

    /// The session as the app reads it.
    var session: AdminSession {
        var value = AdminSession(
            sessionID: sessionID, username: username, mediaTitle: mediaTitle, mediaType: mediaType ?? "",
            playMethod: playMethod ?? "", positionSeconds: positionSeconds ?? 0, fileDuration: fileDuration,
            isPaused: isPaused ?? false, clientName: clientName
        )
        value.streamBitrateKbps = streamBitrateKbps
        value.effectivePlayMethod = effectivePlayMethod
        value.seriesName = seriesName
        value.episodeName = episodeName
        value.seasonNumber = seasonNumber
        value.episodeNumber = episodeNumber
        value.profileName = profileName
        value.devicePlatform = devicePlatform
        value.clientLabel = clientLabel
        value.clientVersion = clientVersion
        value.videoDecision = videoDecision
        value.audioDecision = audioDecision
        value.transcodeAudio = transcodeAudio
        value.transcodeHWAccel = transcodeHWAccel
        value.sourceVideoCodec = sourceVideoCodec
        value.sourceVideoResolution = sourceVideoResolution
        value.sourceVideoHeight = sourceVideoHeight
        value.sourceAudioCodec = sourceAudioCodec
        value.sourceContainer = sourceContainer
        value.targetVideoCodec = targetVideoCodec
        value.targetResolution = targetResolution
        return value
    }
}

struct WidgetRequestDTO: Decodable, Equatable, Sendable {
    let id: String
    let title: String
    let year: Int?
    let requestedByUserID: String?
    let createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, title, year
        case requestedByUserID = "requested_by_user_id"
        case createdAt = "created_at"
    }
}

struct WidgetRequestCountsDTO: Decodable, Equatable, Sendable {
    let needsApproval: Int

    enum CodingKeys: String, CodingKey { case needsApproval = "needs_approval" }
}

struct WidgetRequestCapabilitiesDTO: Decodable, Equatable, Sendable {
    let available: Bool
}

struct WidgetUserDTO: Decodable, Equatable, Sendable {
    let id: String
    let username: String
}

struct WidgetLibraryDTO: Decodable, Equatable, Sendable {
    let id: String
    let name: String?
    let enabled: Bool?
    let lastScannedAt: String?
    let scanWarningCode: String?

    enum CodingKeys: String, CodingKey {
        case id, name, enabled
        case lastScannedAt = "last_scanned_at"
        case scanWarningCode = "scan_warning_code"
    }
}

struct WidgetScanRunDTO: Decodable, Equatable, Sendable {
    let id: String
    let libraryID: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case libraryID = "library_id"
    }
}

struct WidgetRefreshJobDTO: Decodable, Equatable, Sendable {
    struct Progress: Decodable, Equatable, Sendable {
        let current: Int
        let total: Int
    }

    let libraryID: String?
    let state: String
    let terminal: Bool?
    let progress: Progress?

    enum CodingKeys: String, CodingKey {
        case state, terminal, progress
        case libraryID = "library_id"
    }
}

struct WidgetNodeDTO: Decodable, Equatable, Sendable {
    struct Disk: Decodable, Equatable, Sendable {
        let usedGb: Double
        let totalGb: Double
        let unavailable: Bool?

        enum CodingKeys: String, CodingKey {
            case unavailable
            case usedGb = "used_gb"
            case totalGb = "total_gb"
        }
    }

    struct System: Decodable, Equatable, Sendable {
        let cpuPct: Int?
        let memUsedMb: Int?
        let memTotalMb: Int?
        let disks: [Disk]?

        enum CodingKeys: String, CodingKey {
            case disks
            case cpuPct = "cpu_pct"
            case memUsedMb = "mem_used_mb"
            case memTotalMb = "mem_total_mb"
        }
    }

    struct Resources: Decodable, Equatable, Sendable {
        let system: System?
    }

    let id: String
    let name: String
    let type: String?
    let enabled: Bool
    let healthy: Bool
    let drainState: String?
    let drainRequested: Bool?
    let resources: Resources?

    enum CodingKeys: String, CodingKey {
        case id, name, type, enabled, healthy, resources
        case drainState = "drain_state"
        case drainRequested = "drain_requested"
    }
}

struct WidgetCollection<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
}

struct WidgetTokenPair: Decodable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}

enum WidgetRequestAction: String, Sendable {
    case approve, decline
}

// MARK: Client

/// What the refresher and the intents ask a server. A protocol so tests answer without a network.
protocol WidgetServerAPI: Sendable {
    func sessions() async throws -> [WidgetSessionDTO]
    func requestCapabilities() async throws -> Bool
    func requestCounts() async throws -> WidgetRequestCountsDTO
    func pendingRequests(limit: Int) async throws -> [WidgetRequestDTO]
    func users() async throws -> [WidgetUserDTO]
    func libraries() async throws -> [WidgetLibraryDTO]
    func activeScans() async throws -> [WidgetScanRunDTO]
    func libraryRefreshJobs() async throws -> [WidgetRefreshJobDTO]
    func nodes() async throws -> [WidgetNodeDTO]
    func act(on requestID: String, _ action: WidgetRequestAction) async throws
}

struct WidgetHTTPAPI: WidgetServerAPI {
    let baseURL: URL
    let accessToken: String
    let session: URLSession

    init(baseURL: URL, accessToken: String, session: URLSession = WidgetHTTP.makeSession()) {
        self.baseURL = baseURL
        self.accessToken = accessToken
        self.session = session
    }

    func sessions() async throws -> [WidgetSessionDTO] {
        try await collection("/api/v2/admin/sessions", query: ["limit": "200"])
    }

    func requestCapabilities() async throws -> Bool {
        let value: WidgetRequestCapabilitiesDTO = try await get("/api/v2/admin/requests/capabilities")
        return value.available
    }

    func requestCounts() async throws -> WidgetRequestCountsDTO {
        try await get("/api/v2/admin/requests/counts")
    }

    func pendingRequests(limit: Int) async throws -> [WidgetRequestDTO] {
        try await collection("/api/v2/admin/requests", query: ["view": "needs_approval", "limit": String(min(max(limit, 1), 50))])
    }

    func users() async throws -> [WidgetUserDTO] {
        try await collection("/api/v2/admin/users", query: ["limit": "200"])
    }

    func libraries() async throws -> [WidgetLibraryDTO] {
        try await collection("/api/v2/libraries", query: [:])
    }

    func activeScans() async throws -> [WidgetScanRunDTO] {
        // The runs of the last moments, newest first; a run that is queued or running counts as active.
        let runs: [WidgetScanRunDTO] = try await collection("/api/v2/admin/autoscan/scans", query: ["limit": "50"])
        return runs.filter { $0.status == "accepted" || $0.status == "running" }
    }

    func libraryRefreshJobs() async throws -> [WidgetRefreshJobDTO] {
        try await collection("/api/v2/admin/jobs", query: ["kind": "library_refresh", "limit": "50"])
    }

    func nodes() async throws -> [WidgetNodeDTO] {
        try await collection("/api/v2/admin/nodes/summary", query: ["limit": "200"])
    }

    func act(on requestID: String, _ action: WidgetRequestAction) async throws {
        _ = try await send(
            path: "/api/v2/admin/requests/\(WidgetHTTP.segment(requestID))/\(action.rawValue)",
            method: "POST", query: [:], body: Data("{}".utf8)
        )
    }

    // MARK: Plumbing

    private func collection<T: Decodable & Sendable>(_ path: String, query: [String: String]) async throws -> [T] {
        let value: WidgetCollection<T> = try await get(path, query: query)
        return value.items
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let data = try await send(path: path, method: "GET", query: query, body: nil)
        do {
            return try JSONDecoder.widgetServer.decode(T.self, from: data)
        } catch {
            // An answer that is not the shape a widget reads is as good as no answer from a working server.
            throw WidgetAPIError(status: 502)
        }
    }

    private func send(path: String, method: String, query: [String: String], body: Data?) async throws -> Data {
        try await WidgetHTTP.send(
            session: session, baseURL: baseURL, path: path, method: method, query: query, body: body, bearer: accessToken
        )
    }
}

enum WidgetHTTP {
    /// The app's session rules: ephemeral, no cookies, no cache, no redirects. Shorter limits, because a
    /// widget has seconds to answer.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )

    /// One path segment, every other character percent-encoded.
    static func segment(_ value: String) -> String {
        let encoded = value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
        return encoded == "." || encoded == ".." ? encoded.replacingOccurrences(of: ".", with: "%2E") : encoded
    }

    static func send(
        session: URLSession, baseURL: URL, path: String, method: String, query: [String: String],
        body: Data?, bearer: String?
    ) async throws -> Data {
        guard baseURL.scheme?.lowercased() == "https",
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw WidgetAPIError.transport
        }
        let base = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast()) : components.percentEncodedPath
        components.percentEncodedPath = base + path
        let items = query.filter { !$0.value.isEmpty }.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { throw WidgetAPIError.transport }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw WidgetAPIError.transport
        }
        guard let http = response as? HTTPURLResponse else { throw WidgetAPIError.transport }
        guard (200...299).contains(http.statusCode) else { throw WidgetAPIError(status: http.statusCode) }
        return data
    }

    /// `POST /api/v2/auth/refresh`: the server rotates the refresh token, so the answer replaces both.
    static func refresh(session: URLSession, baseURL: URL, refreshToken: String) async throws -> WidgetTokenPair {
        let body = try JSONEncoder().encode(["refresh_token": refreshToken])
        let data = try await send(
            session: session, baseURL: baseURL, path: "/api/v2/auth/refresh", method: "POST", query: [:], body: body, bearer: nil
        )
        guard let pair = try? JSONDecoder().decode(WidgetTokenPair.self, from: data) else { throw WidgetAPIError(status: 502) }
        return pair
    }
}

extension JSONDecoder {
    /// Decodes the server's instants as text and leaves them to `WidgetDates`; the DTOs keep dates as strings.
    static let widgetServer = JSONDecoder()
}

enum WidgetDates {
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
