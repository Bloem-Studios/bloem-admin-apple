import Foundation

/// One row of `GET /api/v2/admin/sessions` (`AdminPlaybackSession`).
///
/// The schema always sends session_id, username, media_title, media_type, play_method,
/// position_seconds, file_duration (nullable) and is_paused. Everything else is omitted when it does
/// not apply (target_* only while transcoding, series fields only for TV, client and device fields
/// when the player did not report them), so nil is the steady-state value and the decision and codec
/// fields stay optional so a row from a server that omits them still decodes. The model keeps what
/// the rows show or need to address the row; the rest of the schema is ignored on decode.
struct AdminSession: Decodable, Identifiable, Sendable, Hashable {
    var id: String { sessionID }
    var sessionID: String
    /// The login account that is playing (`user_id`, a string on v2 and a number on older servers); the User page keeps
    /// only its own account's rows.
    var userIdentifier: FlexibleIdentifier?
    var userID: String? { userIdentifier?.text }
    var username: String
    var mediaTitle: String
    var mediaType: String
    var playMethod: String
    var positionSeconds: Double
    var fileDuration: Double?
    var isPaused: Bool
    var clientName: String?

    var streamBitrateKbps: Int?
    var videoDecision: String?
    var audioDecision: String?
    var effectivePlayMethod: String?
    var transcodeHWAccel: String?
    var sourceVideoResolution: String?
    var sourceVideoCodec: String?
    var targetResolution: String?
    var targetVideoCodec: String?
    var sourceAudioCodec: String?
    var targetAudioCodec: String?
    var seriesName: String?
    var episodeName: String?
    var seasonNumber: Int?
    var episodeNumber: Int?

    // The stream details. All are optional on the wire and nil when the server (or the player) did
    // not report them.
    var profileName: String?
    var devicePlatform: String?
    var transcodeAudio: Bool?
    var streamLocation: String?
    var clientLabel: String?
    var clientLabelFull: String?
    var clientVersion: String?
    var clientIP: String?
    var startedAt: String?
    var updatedAt: String?
    var reportingNode: String?
    var nodeDisplayName: String?
    var sourceContainer: String?
    var sourceBitrateKbps: Int?
    var sourceAudioChannels: Int?
    var sourceAudioLanguage: String?
    var sourceAudioTitle: String?
    var sourceVideoHeight: Int?
    var targetAudioChannels: Int?
    var targetBitrateKbps: Int?
    var toneMapMode: String?
    var outputContainer: String?
    var outputProtocol: String?
    var routingWorkload: String?
    var routingExecution: String?
    var routingExecutionNodeName: String?
    var routingEgress: String?
    var routingEgressNodeName: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case userIdentifier = "user_id"
        case username
        case mediaTitle = "media_title"
        case mediaType = "media_type"
        case playMethod = "play_method"
        case positionSeconds = "position_seconds"
        case fileDuration = "file_duration"
        case isPaused = "is_paused"
        case clientName = "client_name"
        case streamBitrateKbps = "stream_bitrate_kbps"
        case videoDecision = "video_decision"
        case audioDecision = "audio_decision"
        case effectivePlayMethod = "effective_play_method"
        case transcodeHWAccel = "transcode_hw_accel"
        case sourceVideoResolution = "source_video_resolution"
        case sourceVideoCodec = "source_video_codec"
        case targetResolution = "target_resolution"
        case targetVideoCodec = "target_video_codec"
        case sourceAudioCodec = "source_audio_codec"
        case targetAudioCodec = "target_audio_codec"
        case seriesName = "series_name"
        case episodeName = "episode_name"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case profileName = "profile_name"
        case devicePlatform = "device_platform"
        case transcodeAudio = "transcode_audio"
        case streamLocation = "stream_location"
        case clientLabel = "client_label"
        case clientLabelFull = "client_label_full"
        case clientVersion = "client_version"
        case clientIP = "client_ip"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case reportingNode = "reporting_node"
        case nodeDisplayName = "node_display_name"
        case sourceContainer = "source_container"
        case sourceBitrateKbps = "source_bitrate_kbps"
        case sourceAudioChannels = "source_audio_channels"
        case sourceAudioLanguage = "source_audio_language"
        case sourceAudioTitle = "source_audio_title"
        case sourceVideoHeight = "source_video_height"
        case targetAudioChannels = "target_audio_channels"
        case targetBitrateKbps = "target_bitrate_kbps"
        case toneMapMode = "tone_map_mode"
        case outputContainer = "output_container"
        case outputProtocol = "output_protocol"
        case routingWorkload = "routing_workload"
        case routingExecution = "routing_execution"
        case routingExecutionNodeName = "routing_execution_node_name"
        case routingEgress = "routing_egress"
        case routingEgressNodeName = "routing_egress_node_name"
    }

    init(
        sessionID: String,
        username: String,
        mediaTitle: String,
        mediaType: String,
        playMethod: String,
        positionSeconds: Double,
        fileDuration: Double?,
        isPaused: Bool,
        clientName: String?
    ) {
        self.sessionID = sessionID
        self.username = username
        self.mediaTitle = mediaTitle
        self.mediaType = mediaType
        self.playMethod = playMethod
        self.positionSeconds = positionSeconds
        self.fileDuration = fileDuration
        self.isPaused = isPaused
        self.clientName = clientName
    }
}

/// Receipt for an accepted playback command (`202 applied`, or `200 replayed`).
struct SessionCommandReceipt: Decodable, Sendable {
    let commandID: String
    let sequence: Int64
    let outcome: String
    let delivery: String

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case sequence, outcome, delivery
    }
}

/// An id that arrives as a string or as a number, kept as text.
struct FlexibleIdentifier: Decodable, Hashable, Sendable {
    let text: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            text = string
        } else {
            text = String(try container.decode(Int64.self))
        }
    }
}
