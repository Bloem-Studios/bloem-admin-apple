import Foundation

/*
 Wire shapes of the organization routes that change several people or one access group, as the server writes
 them (see the Bloem server's OpenAPI document). Unknown fields are ignored; strings the server may extend (status, reason) are
 never matched against a closed set when decoding.
 */

// MARK: - People selections and bulk jobs

/// `POST /organization/people/selections`: the server freezes everyone the filter matches into an immutable
/// selection and answers with a signed token. The token bears that snapshot, so it is kept in memory only and
/// `description` hides it.
struct PeopleSelection: Decodable, Equatable, Sendable, CustomStringConvertible {
    let token: String
    let matched: Int64
    let excluded: Int64
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case token, matched, excluded
        case expiresAt = "expires_at"
    }

    init(token: String, matched: Int64 = 0, excluded: Int64 = 0, expiresAt: String = "") {
        self.token = token
        self.matched = matched
        self.excluded = excluded
        self.expiresAt = expiresAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decode(String.self, forKey: .token)
        matched = try c.value(.matched, 0)
        excluded = try c.value(.excluded, 0)
        expiresAt = try c.value(.expiresAt, "")
    }

    var description: String { "PeopleSelection(matched: \(matched), excluded: \(excluded), token: <redacted>)" }
}

struct PeopleSelectionResponse: Decodable, Sendable {
    let selection: PeopleSelection
}

/// The filter a selection is made from. Empty lists stay in the body, like the web's.
struct PeopleSelectionRequest: Encodable, Equatable, Sendable {
    let query: String
    let status: [String]
    let groupIDs: [Int64]
    let sort: String
    let activeSince: String?

    enum CodingKeys: String, CodingKey {
        case query, status, sort
        case groupIDs = "group_ids"
        case activeSince = "active_since"
    }
}

/// The three changes the server's bulk job supports.
enum BulkKind {
    static let assignGroup = "assign_group"
    static let suspend = "suspend_memberships"
    static let reactivate = "reactivate_memberships"
}

struct BulkJobRequest: Encodable, Equatable, Sendable, CustomStringConvertible {
    let selectionToken: String
    let kind: String
    let groupID: Int64?

    enum CodingKeys: String, CodingKey {
        case kind
        case selectionToken = "selection_token"
        case groupID = "group_id"
    }

    var description: String { "BulkJobRequest(kind: \(kind), group_id: \(groupID.map(String.init) ?? "nil"), selection_token: <redacted>)" }
}

/// One person a job did not change, and why (`already_applied`, `no_profiles`, `protected_owner`, ...).
struct BulkRecordResult: Decodable, Equatable, Sendable, Identifiable {
    let accountID: Int64
    let reason: String

    var id: String { "\(accountID):\(reason)" }

    enum CodingKeys: String, CodingKey {
        case reason
        case accountID = "account_id"
    }

    init(accountID: Int64, reason: String = "") {
        self.accountID = accountID
        self.reason = reason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try c.decode(Int64.self, forKey: .accountID)
        reason = try c.value(.reason, "")
    }
}

/// A job's progress. `queued` and `running` are not final; `completed`, `failed` and `cancelled` are.
struct BulkJob: Decodable, Equatable, Sendable {
    let jobID: String
    let status: String
    let progressCurrent: Int64
    let progressTotal: Int64
    let succeeded: Int64
    let skipped: [BulkRecordResult]
    let failed: [BulkRecordResult]
    let targetGroupID: Int64?

    var isFinished: Bool { status == "completed" || status == "failed" || status == "cancelled" }

    enum CodingKeys: String, CodingKey {
        case status, succeeded, skipped, failed
        case jobID = "job_id"
        case progressCurrent = "progress_current"
        case progressTotal = "progress_total"
        case targetGroupID = "target_group_id"
    }

    init(
        jobID: String, status: String, progressCurrent: Int64 = 0, progressTotal: Int64 = 0, succeeded: Int64 = 0,
        skipped: [BulkRecordResult] = [], failed: [BulkRecordResult] = [], targetGroupID: Int64? = nil
    ) {
        self.jobID = jobID
        self.status = status
        self.progressCurrent = progressCurrent
        self.progressTotal = progressTotal
        self.succeeded = succeeded
        self.skipped = skipped
        self.failed = failed
        self.targetGroupID = targetGroupID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jobID = try c.decode(String.self, forKey: .jobID)
        status = try c.decode(String.self, forKey: .status)
        progressCurrent = try c.value(.progressCurrent, 0)
        progressTotal = try c.value(.progressTotal, 0)
        succeeded = try c.value(.succeeded, 0)
        skipped = try c.value(.skipped, [BulkRecordResult]())
        failed = try c.value(.failed, [BulkRecordResult]())
        targetGroupID = try c.value(.targetGroupID, nil as Int64?)
    }
}

struct BulkJobResponse: Decodable, Sendable {
    let job: BulkJob
}

// MARK: - Access groups

/// Creating a group needs only a name and the policy revision; the rest starts at the server's defaults.
struct AccessGroupCreateBody: Encodable, Equatable, Sendable {
    let expectedRevision: Int64
    let name: String

    enum CodingKeys: String, CodingKey {
        case expectedRevision = "expected_revision"
        case name
    }
}

/// `PUT /organization/groups/{id}`: the whole group. `library_ids` and `allowed_permissions` are always written,
/// including as `null`: `null` means every library / every permission, and leaving the field out would keep the
/// old value instead.
struct AccessGroupWrite: Encodable, Equatable, Sendable {
    let expectedRevision: Int64
    let name: String
    let description: String
    let libraryIDs: [String]?
    let maxPlaybackQuality: String
    let downloadAllowed: Bool
    let downloadTranscodeAllowed: Bool
    let transcodeAllowed: Bool
    let audioTranscodeAllowed: Bool
    let maxStreams: Int64
    let maxTranscodes: Int64
    let maxRemoteStreamBitrateKbps: Int64
    let maxLocalStreamBitrateKbps: Int64
    let maxProfiles: Int64
    let allowedPermissions: [String]?
    let requestsAllowed: Bool
    let isDefault: Bool

    enum CodingKeys: String, CodingKey {
        case name, description
        case expectedRevision = "expected_revision"
        case libraryIDs = "library_ids"
        case maxPlaybackQuality = "max_playback_quality"
        case downloadAllowed = "download_allowed"
        case downloadTranscodeAllowed = "download_transcode_allowed"
        case transcodeAllowed = "transcode_allowed"
        case audioTranscodeAllowed = "audio_transcode_allowed"
        case maxStreams = "max_streams"
        case maxTranscodes = "max_transcodes"
        case maxRemoteStreamBitrateKbps = "max_remote_stream_bitrate_kbps"
        case maxLocalStreamBitrateKbps = "max_local_stream_bitrate_kbps"
        case maxProfiles = "max_profiles"
        case allowedPermissions = "allowed_permissions"
        case requestsAllowed = "requests_allowed"
        case isDefault = "is_default"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(expectedRevision, forKey: .expectedRevision)
        try c.encode(name, forKey: .name)
        try c.encode(description, forKey: .description)
        // encode(_:) of an optional array writes `null`, which is what "every library" needs.
        try c.encode(libraryIDs, forKey: .libraryIDs)
        try c.encode(maxPlaybackQuality, forKey: .maxPlaybackQuality)
        try c.encode(downloadAllowed, forKey: .downloadAllowed)
        try c.encode(downloadTranscodeAllowed, forKey: .downloadTranscodeAllowed)
        try c.encode(transcodeAllowed, forKey: .transcodeAllowed)
        try c.encode(audioTranscodeAllowed, forKey: .audioTranscodeAllowed)
        try c.encode(maxStreams, forKey: .maxStreams)
        try c.encode(maxTranscodes, forKey: .maxTranscodes)
        try c.encode(maxRemoteStreamBitrateKbps, forKey: .maxRemoteStreamBitrateKbps)
        try c.encode(maxLocalStreamBitrateKbps, forKey: .maxLocalStreamBitrateKbps)
        try c.encode(maxProfiles, forKey: .maxProfiles)
        try c.encode(allowedPermissions, forKey: .allowedPermissions)
        try c.encode(requestsAllowed, forKey: .requestsAllowed)
        try c.encode(isDefault, forKey: .isDefault)
    }
}

struct OrganizationGroupMutationResponse: Decodable, Sendable {
    let group: OrganizationAccessGroup
    let policyRevision: Int64

    enum CodingKeys: String, CodingKey {
        case group
        case policyRevision = "policy_revision"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        group = try c.decode(OrganizationAccessGroup.self, forKey: .group)
        policyRevision = try c.value(.policyRevision, 0)
    }
}

/// What deleting a group did: its profiles moved to the default group.
struct GroupDeletionImpact: Decodable, Equatable, Sendable {
    let profilesReassigned: Int64
    let defaultGroupID: Int64

    enum CodingKeys: String, CodingKey {
        case profilesReassigned = "profiles_reassigned"
        case defaultGroupID = "default_group_id"
    }

    init(profilesReassigned: Int64 = 0, defaultGroupID: Int64 = 0) {
        self.profilesReassigned = profilesReassigned
        self.defaultGroupID = defaultGroupID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profilesReassigned = try c.value(.profilesReassigned, 0)
        defaultGroupID = try c.value(.defaultGroupID, 0)
    }
}

/// The permissions an organization group can grant, as the server names them.
enum GroupPermissions {
    static let liveTV = "watch_live_tv"
    static let metadata = "metadata_curation"
    static let markers = "marker_edit"
    static let all = [liveTV, metadata, markers]
}

/// The group as an editable draft, and back to the body the server takes.
struct AccessGroupDraft: Equatable, Sendable {
    var name: String
    var description: String
    /// nil means every library the organization can use.
    var libraryIDs: Set<String>?
    var maxPlaybackQuality: String
    var downloadAllowed: Bool
    var downloadTranscodeAllowed: Bool
    var transcodeAllowed: Bool
    var audioTranscodeAllowed: Bool
    var maxStreams: Int64
    var maxTranscodes: Int64
    /// nil means every assignable permission.
    var allowedPermissions: Set<String>?
    var requestsAllowed: Bool
    var isDefault: Bool
    // Not shown in the editor, but written back unchanged so a save never resets them.
    var maxRemoteBitrateKbps: Int64
    var maxLocalBitrateKbps: Int64
    var maxProfiles: Int64

    init(group: OrganizationAccessGroup) {
        name = group.name
        description = group.description
        libraryIDs = group.libraryIDs.map(Set.init)
        maxPlaybackQuality = group.maxPlaybackQuality
        downloadAllowed = group.downloadAllowed
        downloadTranscodeAllowed = group.downloadTranscodeAllowed
        transcodeAllowed = group.transcodeAllowed
        audioTranscodeAllowed = group.audioTranscodeAllowed
        maxStreams = group.maxStreams
        maxTranscodes = group.maxTranscodes
        allowedPermissions = group.allowedPermissions.map(Set.init)
        requestsAllowed = group.requestsAllowed
        isDefault = group.isDefault
        maxRemoteBitrateKbps = group.maxRemoteStreamBitrateKbps
        maxLocalBitrateKbps = group.maxLocalStreamBitrateKbps
        maxProfiles = group.maxProfiles
    }

    /// What an editor holds after the group list reloads: nil keeps the current draft (the server's group is the
    /// one the draft started from); otherwise the draft starts again from what the server holds now.
    static func reconciled(
        draft: AccessGroupDraft?, original: OrganizationAccessGroup?, reloaded: OrganizationAccessGroup?
    ) -> (original: OrganizationAccessGroup, draft: AccessGroupDraft)? {
        guard let reloaded else { return nil }
        if draft != nil, original == reloaded { return nil }
        return (reloaded, AccessGroupDraft(group: reloaded))
    }

    func body(revision: Int64) -> AccessGroupWrite {
        AccessGroupWrite(
            expectedRevision: revision,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            libraryIDs: libraryIDs?.sorted { (Int64($0) ?? .max, $0) < (Int64($1) ?? .max, $1) },
            maxPlaybackQuality: maxPlaybackQuality,
            downloadAllowed: downloadAllowed,
            // Converted downloads need downloads: never save the contradictory pair.
            downloadTranscodeAllowed: downloadAllowed && downloadTranscodeAllowed,
            transcodeAllowed: transcodeAllowed,
            audioTranscodeAllowed: audioTranscodeAllowed,
            maxStreams: maxStreams,
            maxTranscodes: maxTranscodes,
            maxRemoteStreamBitrateKbps: maxRemoteBitrateKbps,
            maxLocalStreamBitrateKbps: maxLocalBitrateKbps,
            maxProfiles: maxProfiles,
            allowedPermissions: allowedPermissions?.sorted(),
            requestsAllowed: requestsAllowed,
            isDefault: isDefault
        )
    }
}

/// The picture-quality choices the web offers an access group: any, up to 1080p, up to 4K. The server stores
/// `""`, `1080p` and `2160p`; anything else it sent (for example `original`) is kept as its own choice until the
/// administrator picks another.
enum PlaybackQuality {
    static let any = ""
    static let upTo1080p = "1080p"
    static let upTo4K = "2160p"
    static let choices = [any, upTo1080p, upTo4K]

    /// The web's own reading of a stored value (lib/playback-quality.ts `canonicalPlaybackQuality`).
    static func canonical(_ value: String?) -> String {
        switch (value ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "", "any": return any
        case "standard", "480p", "720p", "1080p": return upTo1080p
        case "4k", "uhd", "2160p", "4320p": return upTo4K
        default: return any
        }
    }
}
