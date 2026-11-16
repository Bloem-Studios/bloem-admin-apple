import Foundation

/*
 Wire shapes of the organization support routes (the Bloem server's admin support handlers and the
 BloemSupport* and SupportCapabilities schemas of the Bloem server's OpenAPI document): reset links, sign-outs,
 profile edits and the organization's own streams. Same decoding rules as OrganizationModels.swift: a missing or
 null field takes its default, a malformed one fails the answer.
 */

// MARK: - What this server can do

/// `GET /admin/organization/support-capabilities`. The app hides what is false and never infers a capability from
/// a failure. A server that predates organization support has no such route: `none`, so nothing new shows.
struct SupportCapabilities: Decodable, Equatable, Sendable {
    struct PasswordReset: Equatable, Sendable {
        var email = false
        var link = false
    }

    struct Profiles: Equatable, Sendable {
        var add = false
        var rename = false
        var clearPIN = false
        var remove = false
    }

    struct Streams: Equatable, Sendable {
        var list = false
        var stop = false
        var message = false
    }

    var passwordReset = PasswordReset()
    var sessions = false
    var devices = false
    var profiles = Profiles()
    var streams = Streams()

    /// Everything off: an older server, or one whose answer has not arrived.
    static let none = SupportCapabilities()

    var offersPasswordReset: Bool { passwordReset.email || passwordReset.link }
    var offersProfileEdits: Bool { profiles.add || profiles.rename || profiles.clearPIN || profiles.remove }
    /// Anything at all on a person's page.
    var offersPersonSupport: Bool { offersPasswordReset || sessions || devices || offersProfileEdits }

    init(
        passwordReset: PasswordReset = PasswordReset(), sessions: Bool = false, devices: Bool = false,
        profiles: Profiles = Profiles(), streams: Streams = Streams()
    ) {
        self.passwordReset = passwordReset
        self.sessions = sessions
        self.devices = devices
        self.profiles = profiles
        self.streams = streams
    }

    private enum CodingKeys: String, CodingKey {
        case sessions, devices, profiles, streams
        case passwordReset = "password_reset"
    }

    private enum ResetKeys: String, CodingKey { case email, link }
    private enum ProfileKeys: String, CodingKey {
        case add, rename, remove
        case clearPIN = "clear_pin"
    }
    private enum StreamKeys: String, CodingKey { case list, stop, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.value(.sessions, false)
        devices = try c.value(.devices, false)
        if c.contains(.passwordReset), try c.decodeNil(forKey: .passwordReset) == false {
            let reset = try c.nestedContainer(keyedBy: ResetKeys.self, forKey: .passwordReset)
            passwordReset = PasswordReset(email: try reset.value(.email, false), link: try reset.value(.link, false))
        }
        if c.contains(.profiles), try c.decodeNil(forKey: .profiles) == false {
            let profiles = try c.nestedContainer(keyedBy: ProfileKeys.self, forKey: .profiles)
            self.profiles = Profiles(
                add: try profiles.value(.add, false), rename: try profiles.value(.rename, false),
                clearPIN: try profiles.value(.clearPIN, false), remove: try profiles.value(.remove, false)
            )
        }
        if c.contains(.streams), try c.decodeNil(forKey: .streams) == false {
            let streams = try c.nestedContainer(keyedBy: StreamKeys.self, forKey: .streams)
            self.streams = Streams(
                list: try streams.value(.list, false), stop: try streams.value(.stop, false),
                message: try streams.value(.message, false)
            )
        }
    }
}

/// The public `GET /api/bloem/v2/capabilities`: only the feature tokens matter here.
struct BloemCapabilities: Decodable, Equatable, Sendable {
    /// Advertised by a server whose organization support routes, and break-glass support access, are mounted.
    static let organizationSupportToken = "organization_support_v1"

    let featureTokens: [String]

    var offersOrganizationSupport: Bool { featureTokens.contains(Self.organizationSupportToken) }

    private enum CodingKeys: String, CodingKey {
        case featureTokens = "feature_tokens"
    }

    init(featureTokens: [String]) {
        self.featureTokens = featureTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        featureTokens = try c.value(.featureTokens, [String]())
    }
}

// MARK: - Reset links

enum PasswordResetDelivery: String, Sendable {
    /// Sent to the person's own address; the link works for 24 hours.
    case email
    /// Returned once in the answer for the administrator to hand over; it works for 4 hours.
    case link
}

struct SupportResetRequest: Encodable, Equatable, Sendable {
    /// The person's `security_revision`. Checked, not raised: issuing a link signs nobody out.
    let expectedRevision: Int64
    let delivery: String

    enum CodingKeys: String, CodingKey {
        case delivery
        case expectedRevision = "expected_revision"
    }
}

/// The issued link. `resetURL` is a bearer credential, present for a `link` delivery only: shown once, never stored,
/// never printed.
struct SupportReset: Decodable, Equatable, Sendable, CustomStringConvertible {
    static let delivered = "sent"
    static let deliveryUncertain = "failed_or_unknown"

    let delivery: String
    /// `not_requested` for a link; `sent` or `failed_or_unknown` for email (the link is live either way).
    let deliveryStatus: String
    let resetURL: String?
    let expiresAt: String

    var description: String { "SupportReset(delivery: \(delivery), reset_url: <redacted>)" }

    enum CodingKeys: String, CodingKey {
        case delivery
        case deliveryStatus = "delivery_status"
        case resetURL = "reset_url"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        delivery = try c.decode(String.self, forKey: .delivery)
        deliveryStatus = try c.value(.deliveryStatus, "")
        let url = try c.value(.resetURL, nil as String?)
        resetURL = (url?.isEmpty ?? true) ? nil : url
        expiresAt = try c.value(.expiresAt, "")
    }
}

struct SupportResetResponse: Decodable, Sendable, CustomStringConvertible {
    let reset: SupportReset
    let person: PersonSummary

    var description: String { "SupportResetResponse(\(reset))" }
}

/// A reset link waiting to be handed over: held by the person page until the administrator closes it.
struct ResetLinkHandoff: Equatable, Identifiable, Sendable, CustomStringConvertible {
    let id = UUID()
    let url: String
    let expiresAt: String
    let personLabel: String

    var description: String { "ResetLinkHandoff(url: <redacted>)" }

    static func == (lhs: ResetLinkHandoff, rhs: ResetLinkHandoff) -> Bool { lhs.id == rhs.id }
}

// MARK: - Sessions and devices

/// One live sign-in of a person, as the server lists it: never an address, and only the person's own sign-ins.
struct SupportSession: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let deviceName: String
    let deviceID: String
    let devicePlatform: String
    let authMethod: String
    let profileID: String?
    let profileName: String?
    let createdAt: String
    let lastSeenAt: String?
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case deviceName = "device_name"
        case deviceID = "device_id"
        case devicePlatform = "device_platform"
        case authMethod = "auth_method"
        case profileID = "profile_id"
        case profileName = "profile_name"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case expiresAt = "expires_at"
    }

    init(
        id: String, deviceName: String = "", deviceID: String = "", devicePlatform: String = "", authMethod: String = "",
        profileID: String? = nil, profileName: String? = nil, createdAt: String = "", lastSeenAt: String? = nil, expiresAt: String = ""
    ) {
        self.id = id
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.devicePlatform = devicePlatform
        self.authMethod = authMethod
        self.profileID = profileID
        self.profileName = profileName
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deviceName = try c.value(.deviceName, "")
        deviceID = try c.value(.deviceID, "")
        devicePlatform = try c.value(.devicePlatform, "")
        authMethod = try c.value(.authMethod, "")
        profileID = try c.value(.profileID, nil as String?)
        profileName = try c.value(.profileName, nil as String?)
        createdAt = try c.value(.createdAt, "")
        lastSeenAt = try c.value(.lastSeenAt, nil as String?)
        expiresAt = try c.value(.expiresAt, "")
    }
}

struct SupportSessionsResponse: Decodable, Sendable {
    let sessions: [SupportSession]

    enum CodingKeys: String, CodingKey { case sessions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try c.value(.sessions, [SupportSession]())
    }
}

struct SupportDeviceProfile: Decodable, Equatable, Sendable {
    let profileID: String
    let profileName: String

    enum CodingKeys: String, CodingKey {
        case profileID = "profile_id"
        case profileName = "profile_name"
    }
}

/// A device the person's profiles in this organization have used.
struct SupportDevice: Decodable, Identifiable, Equatable, Sendable {
    let deviceID: String
    let name: String
    let platform: String
    let lastSeenAt: String
    let profiles: [SupportDeviceProfile]

    var id: String { deviceID }

    enum CodingKeys: String, CodingKey {
        case name, platform, profiles
        case deviceID = "device_id"
        case lastSeenAt = "last_seen_at"
    }

    init(deviceID: String, name: String = "", platform: String = "", lastSeenAt: String = "", profiles: [SupportDeviceProfile] = []) {
        self.deviceID = deviceID
        self.name = name
        self.platform = platform
        self.lastSeenAt = lastSeenAt
        self.profiles = profiles
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(String.self, forKey: .deviceID)
        name = try c.value(.name, "")
        platform = try c.value(.platform, "")
        lastSeenAt = try c.value(.lastSeenAt, "")
        profiles = try c.value(.profiles, [SupportDeviceProfile]())
    }
}

struct SupportDevicesResponse: Decodable, Sendable {
    let devices: [SupportDevice]

    enum CodingKeys: String, CodingKey { case devices }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = try c.value(.devices, [SupportDevice]())
    }
}

/// "Sign out everywhere": the person with the raised `security_revision`, and how many sessions ended.
struct SupportSignOutResponse: Decodable, Sendable {
    struct Revoked: Decodable, Sendable {
        let sessions: Int64
    }

    let person: PersonSummary
    let revoked: Revoked
}

// MARK: - Profiles

struct SupportProfileCreate: Encodable, Equatable, Sendable {
    let name: String
    /// An access group of this organization; left out for the group the account's other profiles inherit.
    let groupID: Int64?

    enum CodingKeys: String, CodingKey {
        case name
        case groupID = "group_id"
    }
}

struct SupportProfileRename: Encodable, Equatable, Sendable {
    /// The profile's own revision, not the person's.
    let expectedRevision: Int64
    let name: String

    enum CodingKeys: String, CodingKey {
        case name
        case expectedRevision = "expected_revision"
    }
}

struct SupportProfileResponse: Decodable, Sendable {
    let profile: ProfileSummary
    let person: PersonSummary
}

struct SupportProfileOnlyResponse: Decodable, Sendable {
    let profile: ProfileSummary
}

extension PersonSummary {
    /// The same person with one profile replaced (a cleared PIN answers with the profile alone).
    func replacing(_ profile: ProfileSummary) -> PersonSummary {
        PersonSummary(
            organizationID: organizationID, accountID: accountID, email: email, displayName: displayName,
            membershipID: membershipID, membershipStatus: membershipStatus, legacyRole: legacyRole,
            securityRevision: securityRevision, lastActivity: lastActivity,
            profiles: profiles.map { $0.id == profile.id ? profile : $0 }
        )
    }
}

// MARK: - Streams

/// One of the organization's live streams, with the support fields only: who, what, which device, and whether it
/// plays directly or is converted. No address, node, routing, bitrate or codec ever arrives here.
struct SupportStream: Decodable, Identifiable, Equatable, Sendable {
    struct Device: Decodable, Equatable, Sendable {
        let name: String
        let platform: String
        let id: String
        let app: String

        enum CodingKeys: String, CodingKey { case name, platform, id, app }

        init(name: String = "", platform: String = "", id: String = "", app: String = "") {
            self.name = name
            self.platform = platform
            self.id = id
            self.app = app
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.value(.name, "")
            platform = try c.value(.platform, "")
            id = try c.value(.id, "")
            app = try c.value(.app, "")
        }
    }

    let sessionID: String
    let accountID: Int64
    let personName: String
    let profileID: String
    let profileName: String
    let title: String
    let seriesName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let mediaType: String
    let startedAt: String
    let updatedAt: String
    let positionSeconds: Double
    let durationSeconds: Double?
    let isPaused: Bool
    /// direct, remux, direct_stream or transcode.
    let playMethod: String
    let videoDecision: String
    let audioDecision: String
    let device: Device
    /// The server's own judgement for this actor: their own stream and a platform account's are not theirs to stop.
    let canStop: Bool
    let canMessage: Bool

    var id: String { sessionID }

    enum CodingKeys: String, CodingKey {
        case title, device
        case sessionID = "session_id"
        case accountID = "account_id"
        case personName = "person_name"
        case profileID = "profile_id"
        case profileName = "profile_name"
        case seriesName = "series_name"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case mediaType = "media_type"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case positionSeconds = "position_seconds"
        case durationSeconds = "duration_seconds"
        case isPaused = "is_paused"
        case playMethod = "play_method"
        case videoDecision = "video_decision"
        case audioDecision = "audio_decision"
        case canStop = "can_stop"
        case canMessage = "can_message"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.decode(String.self, forKey: .sessionID)
        accountID = try c.value(.accountID, 0)
        personName = try c.value(.personName, "")
        profileID = try c.value(.profileID, "")
        profileName = try c.value(.profileName, "")
        title = try c.value(.title, "")
        let series = try c.value(.seriesName, nil as String?)
        seriesName = (series?.isEmpty ?? true) ? nil : series
        seasonNumber = try c.value(.seasonNumber, nil as Int?)
        episodeNumber = try c.value(.episodeNumber, nil as Int?)
        mediaType = try c.value(.mediaType, "")
        startedAt = try c.value(.startedAt, "")
        updatedAt = try c.value(.updatedAt, "")
        positionSeconds = try c.value(.positionSeconds, 0)
        durationSeconds = try c.value(.durationSeconds, nil as Double?)
        isPaused = try c.value(.isPaused, false)
        playMethod = try c.value(.playMethod, "")
        videoDecision = try c.value(.videoDecision, "")
        audioDecision = try c.value(.audioDecision, "")
        device = try c.value(.device, Device())
        canStop = try c.value(.canStop, false)
        canMessage = try c.value(.canMessage, false)
    }

    /// The row the platform's Now playing draws, filled from the support fields only. Everything the organization
    /// does not receive (addresses, nodes, routing, bitrates, codecs) stays nil, so the row has nothing of it to show.
    var playbackRow: AdminSession {
        var row = AdminSession(
            sessionID: sessionID, username: personName, mediaTitle: title, mediaType: mediaType, playMethod: playMethod,
            positionSeconds: positionSeconds, fileDuration: durationSeconds, isPaused: isPaused,
            clientName: device.app.isEmpty ? nil : device.app
        )
        row.profileName = profileName.isEmpty ? nil : profileName
        row.effectivePlayMethod = playMethod.isEmpty ? nil : playMethod
        row.videoDecision = videoDecision.isEmpty ? nil : videoDecision
        row.audioDecision = audioDecision.isEmpty ? nil : audioDecision
        row.seriesName = seriesName
        row.seasonNumber = seasonNumber
        row.episodeNumber = episodeNumber
        row.devicePlatform = device.platform.isEmpty ? nil : device.platform
        let label = [device.name, device.app].filter { !$0.isEmpty }.joined(separator: " · ")
        row.clientLabel = label.isEmpty ? nil : label
        row.startedAt = startedAt.isEmpty ? nil : startedAt
        row.updatedAt = updatedAt.isEmpty ? nil : updatedAt
        return row
    }

    /// "Sam · Kids" for the confirmations: the person, and the profile when it says something more.
    var watcherLabel: String {
        let profile = profileName.caseInsensitiveCompare(personName) == .orderedSame ? "" : profileName
        return [personName, profile].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct SupportStreamsPage: Decodable, Sendable {
    let streams: [SupportStream]
    let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case streams
        case nextCursor = "next_cursor"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        streams = try c.value(.streams, [SupportStream]())
        let cursor = try c.value(.nextCursor, nil as String?)
        nextCursor = (cursor?.isEmpty ?? true) ? nil : cursor
    }
}

/// Stopping uses Silo's terminate: the session's authority is revoked first, then the player is told if it can be.
struct SupportStreamStopResult: Decodable, Equatable, Sendable {
    let sessionID: String
    let authorityRevoked: Bool
    let alreadyRevoked: Bool
    let clientNotified: Bool

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case authorityRevoked = "authority_revoked"
        case alreadyRevoked = "already_revoked"
        case clientNotified = "client_notified"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionID = try c.value(.sessionID, "")
        authorityRevoked = try c.value(.authorityRevoked, false)
        alreadyRevoked = try c.value(.alreadyRevoked, false)
        clientNotified = try c.value(.clientNotified, false)
    }
}

/// A message keeps Silo's client-allocated command identity: a retry sends the same `command_id` and `sequence`.
struct SupportStreamMessage: Encodable, Equatable, Sendable {
    let commandID: String
    let sequence: Int64
    let title: String?
    let message: String

    enum CodingKeys: String, CodingKey {
        case title, message, sequence
        case commandID = "command_id"
    }
}
