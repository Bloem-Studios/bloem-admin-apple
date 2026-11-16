import Foundation

/// One item of `GET /api/v2/admin/playback-history` (`AdminPlaybackHistoryEntry`). The route sends
/// every field below; the ones the schema marks nullable are optional here. `watched_seconds` is the
/// position the play ended at, not the watch time: `playedSeconds` is the watch time when the play
/// was measured. The ID, profile, method and series fields are required by the schema; they decode
/// to empty text when a server or fixture leaves them out, so a short row still lists.
struct PlaybackHistoryEntry: Decodable, Identifiable, Sendable {
    var id: String { sessionID }
    /// The playback session this play was. It is also the `playback_session_id` of its log lines.
    let sessionID: String
    let userID: String
    let username: String
    let profileID: String
    let profileName: String
    let mediaTitle: String
    let mediaType: String
    let playMethod: String
    let watchedSeconds: Double
    let durationSeconds: Double?
    let playedSeconds: Double?
    let pausedSeconds: Double?
    let completed: Bool
    let seriesTitle: String
    let seasonNumber: Int?
    let episodeNumber: Int?
    let startedAt: Date
    let endedAt: Date?
    let endReason: String?
    let clientName: String?
    let clientVersion: String?
    let devicePlatform: String?
    let clientIP: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case userID = "user_id"
        case username
        case profileID = "profile_id"
        case profileName = "profile_name"
        case mediaTitle = "media_title"
        case mediaType = "media_type"
        case playMethod = "play_method"
        case watchedSeconds = "watched_seconds"
        case durationSeconds = "duration_seconds"
        case playedSeconds = "played_seconds"
        case pausedSeconds = "paused_seconds"
        case completed
        case seriesTitle = "series_title"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case endReason = "end_reason"
        case clientName = "client_name"
        case clientVersion = "client_version"
        case devicePlatform = "device_platform"
        case clientIP = "client_ip"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        userID = try c.decodeIfPresent(String.self, forKey: .userID) ?? ""
        username = try c.decode(String.self, forKey: .username)
        profileID = try c.decodeIfPresent(String.self, forKey: .profileID) ?? ""
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? ""
        mediaTitle = try c.decode(String.self, forKey: .mediaTitle)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        playMethod = try c.decodeIfPresent(String.self, forKey: .playMethod) ?? ""
        watchedSeconds = try c.decode(Double.self, forKey: .watchedSeconds)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        playedSeconds = try c.decodeIfPresent(Double.self, forKey: .playedSeconds)
        pausedSeconds = try c.decodeIfPresent(Double.self, forKey: .pausedSeconds)
        completed = try c.decode(Bool.self, forKey: .completed)
        seriesTitle = try c.decodeIfPresent(String.self, forKey: .seriesTitle) ?? ""
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        endReason = try c.decodeIfPresent(String.self, forKey: .endReason)
        clientName = try c.decodeIfPresent(String.self, forKey: .clientName)
        clientVersion = try c.decodeIfPresent(String.self, forKey: .clientVersion)
        devicePlatform = try c.decodeIfPresent(String.self, forKey: .devicePlatform)
        clientIP = try c.decodeIfPresent(String.self, forKey: .clientIP)
    }
}
