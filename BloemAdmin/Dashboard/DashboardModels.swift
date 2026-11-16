import Foundation

// The endpoints behind the web dashboard's widgets other than `/admin/stats` and
// `/admin/system/resources` (see AdminStats.swift). Each model keeps only the fields a dashboard
// section shows. Timestamps decode leniently: one malformed instant leaves that field nil instead
// of failing the whole section, because the charts treat a missing sample as a gap.

private extension KeyedDecodingContainer {
    /// A timestamp, or nil when it is absent, null or not an ISO 8601 instant.
    func lenientDate(_ key: Key) -> Date? {
        (try? decodeIfPresent(Date.self, forKey: key)) ?? nil
    }

    func number<T: Decodable>(_ key: Key, default value: T) -> T {
        ((try? decodeIfPresent(T.self, forKey: key)) ?? nil) ?? value
    }
}

/// `GET /api/v2/admin/system/build`.
struct BuildInfo: Sendable, Equatable {
    var available = true
    var buildNumber = 0
    var dirty = false
    var display = ""
    var revision = ""
}

extension BuildInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case available, dirty, display, revision
        case buildNumber = "build_number"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        available = c.number(.available, default: true)
        buildNumber = c.number(.buildNumber, default: 0)
        dirty = c.number(.dirty, default: false)
        display = c.number(.display, default: "")
        revision = c.number(.revision, default: "")
    }
}

/// One row of `GET /api/v2/admin/nodes`.
struct DashboardNode: Sendable, Equatable, Decodable {
    let id: String
    var name = ""
    let enabled: Bool
    let healthy: Bool

    private enum CodingKeys: String, CodingKey { case id, name, enabled, healthy }

    init(id: String, name: String = "", enabled: Bool, healthy: Bool) {
        self.id = id
        self.name = name
        self.enabled = enabled
        self.healthy = healthy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.number(.name, default: "")
        enabled = try c.decode(Bool.self, forKey: .enabled)
        healthy = try c.decode(Bool.self, forKey: .healthy)
    }
}

/// One row of `GET /api/v2/libraries`.
struct DashboardLibrary: Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var type = ""
    var paths: [String] = []
    var enabled = true
    var lastScannedAt: Date?
}

extension DashboardLibrary: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, name, type, paths, enabled
        case lastScannedAt = "last_scanned_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = c.number(.type, default: "")
        paths = c.number(.paths, default: [])
        enabled = c.number(.enabled, default: true)
        lastScannedAt = c.lenientDate(.lastScannedAt)
    }
}

/// One hour (or day, past a two-day window) that saw a session. Hours without one are absent.
struct PlaybackBucket: Sendable, Equatable {
    var hour: Date?
    var direct = 0
    var remux = 0
    var transcode = 0
}

extension PlaybackBucket: Decodable {
    private enum CodingKeys: String, CodingKey { case hour, direct, remux, transcode }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hour = c.lenientDate(.hour)
        direct = c.number(.direct, default: 0)
        remux = c.number(.remux, default: 0)
        transcode = c.number(.transcode, default: 0)
    }
}

struct PlaybackReliability: Sendable, Equatable {
    var sessionsStarted = 0
    var transcodeStarts = 0
    var finalizedSessions = 0
    var completedSessions = 0
    var completionRate = 0.0
    var uniqueProfiles = 0
}

extension PlaybackReliability: Decodable {
    private enum CodingKeys: String, CodingKey {
        case sessionsStarted = "sessions_started"
        case transcodeStarts = "transcode_starts"
        case finalizedSessions = "finalized_sessions"
        case completedSessions = "completed_sessions"
        case completionRate = "completion_rate"
        case uniqueProfiles = "unique_profiles"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionsStarted = c.number(.sessionsStarted, default: 0)
        transcodeStarts = c.number(.transcodeStarts, default: 0)
        finalizedSessions = c.number(.finalizedSessions, default: 0)
        completedSessions = c.number(.completedSessions, default: 0)
        completionRate = c.number(.completionRate, default: 0)
        uniqueProfiles = c.number(.uniqueProfiles, default: 0)
    }
}

/// `GET /api/v2/admin/stats/playback-activity`.
struct PlaybackActivity: Sendable, Equatable {
    var hours = 24
    var bucketSeconds = 3600
    /// The window on the server's clock. The chart anchors its bucket grid on `to`, so a phone
    /// clock a minute off cannot drop the newest bucket.
    var from: Date?
    var to: Date?
    var buckets: [PlaybackBucket] = []
    var reliability = PlaybackReliability()
    var profilesActive24h: Int
}

extension PlaybackActivity: Decodable {
    private enum CodingKeys: String, CodingKey {
        case hours, from, to, buckets, reliability
        case bucketSeconds = "bucket_seconds"
        case profilesActive24h = "profiles_active_24h"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = c.number(.hours, default: 24)
        bucketSeconds = c.number(.bucketSeconds, default: 3600)
        from = c.lenientDate(.from)
        to = c.lenientDate(.to)
        buckets = c.number(.buckets, default: [])
        reliability = c.number(.reliability, default: PlaybackReliability())
        profilesActive24h = try c.decode(Int.self, forKey: .profilesActive24h)
    }
}

struct TimeseriesPoint: Sendable, Equatable {
    var t: Date?
    var streams = 0
    /// How many of `streams` were direct play, remux and transcode at the busiest minute of the
    /// bucket. Absent on servers that predate the split; the rest is direct stream.
    var direct: Int?
    var remux: Int?
    var transcode: Int?
    var egressKbps = 0.0
    /// The file-transfer part of `egressKbps`; 0 on samples written before the server measured it.
    var downloadEgressKbps = 0.0
}

extension TimeseriesPoint: Decodable {
    private enum CodingKeys: String, CodingKey {
        case t, streams, direct, remux, transcode
        case egressKbps = "egress_kbps"
        case downloadEgressKbps = "download_egress_kbps"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = c.lenientDate(.t)
        streams = c.number(.streams, default: 0)
        direct = (try? c.decodeIfPresent(Int.self, forKey: .direct)) ?? nil
        remux = (try? c.decodeIfPresent(Int.self, forKey: .remux)) ?? nil
        transcode = (try? c.decodeIfPresent(Int.self, forKey: .transcode)) ?? nil
        egressKbps = c.number(.egressKbps, default: 0)
        downloadEgressKbps = c.number(.downloadEgressKbps, default: 0)
    }
}

/// `GET /api/v2/admin/stats/timeseries`. Minutes the sampler missed are absent, not zero. A wide
/// window comes back in wider buckets (`resolutionSeconds`), each holding its peak minute.
struct Timeseries: Sendable, Equatable {
    var resolutionSeconds = 60
    var from: Date?
    var to: Date?
    var oldestSampleAt: Date?
    /// Bytes served over the whole window, integrated by the server. Absent on older servers.
    var egressBytes: Double?
    var points: [TimeseriesPoint] = []
}

extension Timeseries: Decodable {
    private enum CodingKeys: String, CodingKey {
        case from, to, points
        case resolutionSeconds = "resolution_seconds"
        case oldestSampleAt = "oldest_sample_at"
        case egressBytes = "egress_bytes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolutionSeconds = c.number(.resolutionSeconds, default: 60)
        from = c.lenientDate(.from)
        to = c.lenientDate(.to)
        oldestSampleAt = c.lenientDate(.oldestSampleAt)
        egressBytes = (try? c.decodeIfPresent(Double.self, forKey: .egressBytes)) ?? nil
        points = c.number(.points, default: [])
    }
}

struct TopTitle: Sendable, Equatable {
    var mediaItemID = ""
    var title = ""
    var mediaType = ""
    var plays = 0
    var totalSeconds = 0.0
}

extension TopTitle: Decodable {
    private enum CodingKeys: String, CodingKey {
        case title, plays
        case mediaItemID = "media_item_id"
        case mediaType = "media_type"
        case totalSeconds = "total_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mediaItemID = c.number(.mediaItemID, default: "")
        title = c.number(.title, default: "")
        mediaType = c.number(.mediaType, default: "")
        plays = c.number(.plays, default: 0)
        totalSeconds = c.number(.totalSeconds, default: 0)
    }
}

struct TopProfile: Sendable, Equatable {
    var userID = ""
    var username = ""
    var profileID = ""
    var profileName = ""
    var plays = 0
    var totalSeconds = 0.0
}

extension TopProfile: Decodable {
    private enum CodingKeys: String, CodingKey {
        case username, plays
        case userID = "user_id"
        case profileID = "profile_id"
        case profileName = "profile_name"
        case totalSeconds = "total_seconds"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userID = c.number(.userID, default: "")
        username = c.number(.username, default: "")
        profileID = c.number(.profileID, default: "")
        profileName = c.number(.profileName, default: "")
        plays = c.number(.plays, default: 0)
        totalSeconds = c.number(.totalSeconds, default: 0)
    }
}

/// `GET /api/v2/admin/stats/top-activity`. Episodes are rolled up to their series.
struct TopActivity: Sendable, Equatable {
    var days = 7
    var titles: [TopTitle] = []
    var profiles: [TopProfile] = []
}

extension TopActivity: Decodable {
    private enum CodingKeys: String, CodingKey { case days, titles, profiles }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        days = c.number(.days, default: 7)
        titles = c.number(.titles, default: [])
        profiles = c.number(.profiles, default: [])
    }
}

/// A dependency in `/admin/server/status`: whether it is configured comes before whether it is up.
struct HealthComponent: Sendable, Equatable, Decodable {
    let configured: Bool
    var ok: Bool?
    var latencyMs: Double?

    private enum CodingKeys: String, CodingKey {
        case configured, ok
        case latencyMs = "latency_ms"
    }

    init(configured: Bool, ok: Bool? = nil, latencyMs: Double? = nil) {
        self.configured = configured
        self.ok = ok
        self.latencyMs = latencyMs
    }
}

/// The health summary of `/admin/server/status`. Absent on servers that predate it.
struct ServerHealthSummary: Sendable, Equatable, Decodable {
    let postgres: HealthComponent
    let redis: HealthComponent
    var errors24h = 0
    var warnings24h = 0

    private enum CodingKeys: String, CodingKey {
        case postgres, redis
        case errors24h = "errors_24h"
        case warnings24h = "warnings_24h"
    }

    init(postgres: HealthComponent, redis: HealthComponent, errors24h: Int = 0, warnings24h: Int = 0) {
        self.postgres = postgres
        self.redis = redis
        self.errors24h = errors24h
        self.warnings24h = warnings24h
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        postgres = try c.decode(HealthComponent.self, forKey: .postgres)
        redis = try c.decode(HealthComponent.self, forKey: .redis)
        errors24h = c.number(.errors24h, default: 0)
        warnings24h = c.number(.warnings24h, default: 0)
    }
}

/// One account of `GET /api/v2/admin/users`, as far as the dashboard's Users section shows it.
struct DashboardUser: Sendable, Equatable, Identifiable {
    var id: String
    var username: String
    var role = ""
    var enabled = true
    var lastActiveAt: Date?
}

extension DashboardUser: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, username, role, enabled
        case lastActiveAt = "last_active_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        role = c.number(.role, default: "")
        enabled = c.number(.enabled, default: true)
        lastActiveAt = c.lenientDate(.lastActiveAt)
    }
}

/// One row of `GET /api/v2/admin/playback-history`, as far as Recent activity shows it.
struct RecentPlayback: Sendable, Equatable, Identifiable {
    var id: String
    var username = ""
    var mediaTitle = ""
    var startedAt: Date?
}

extension RecentPlayback: Decodable {
    private enum CodingKeys: String, CodingKey {
        case username
        case id = "session_id"
        case mediaTitle = "media_title"
        case startedAt = "started_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.number(.id, default: UUID().uuidString)
        username = c.number(.username, default: "")
        mediaTitle = c.number(.mediaTitle, default: "")
        startedAt = c.lenientDate(.startedAt)
    }
}
