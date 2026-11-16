import Foundation

/// One media request as `GET /api/v2/admin/requests` returns it (the server's `MediaRequest`). The
/// fields the queue shows beyond the original eight are optional or defaulted when decoding, so an
/// older server's answer still reads.
struct MediaRequest: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let provider: String
    /// `movie` or `series`.
    let mediaType: String
    let title: String
    /// pending, approved, queued, downloading, completed.
    let status: String
    /// active, declined, cancelled, failed.
    let outcome: String
    let requestedByUserID: String?
    let lastError: String?
    /// The one state the requester sees: pending, approved, processing, partially_available,
    /// available, declined, cancelled or failed.
    var state: String?
    var outcomeReason: String?
    var year: Int?
    var posterPath: String?
    var overview: String?
    /// Series only: the requested seasons; empty means the whole series.
    var seasons: [Int]
    /// `direct` or `watchlist`; more values may be added.
    var source: String
    var tmdbID: Int?
    var targets: [RequestTarget]
    var createdAt: Date?
    var approvedAt: Date?
    var completedAt: Date?

    init(
        id: String, provider: String, mediaType: String, title: String, status: String, outcome: String,
        requestedByUserID: String?, lastError: String?, state: String? = nil, outcomeReason: String? = nil,
        year: Int? = nil, posterPath: String? = nil, overview: String? = nil, seasons: [Int] = [],
        source: String = "direct", tmdbID: Int? = nil, targets: [RequestTarget] = [], createdAt: Date? = nil,
        approvedAt: Date? = nil, completedAt: Date? = nil
    ) {
        self.id = id
        self.provider = provider
        self.mediaType = mediaType
        self.title = title
        self.status = status
        self.outcome = outcome
        self.requestedByUserID = requestedByUserID
        self.lastError = lastError
        self.state = state
        self.outcomeReason = outcomeReason
        self.year = year
        self.posterPath = posterPath
        self.overview = overview
        self.seasons = seasons
        self.source = source
        self.tmdbID = tmdbID
        self.targets = targets
        self.createdAt = createdAt
        self.approvedAt = approvedAt
        self.completedAt = completedAt
    }

    enum CodingKeys: String, CodingKey {
        case id, provider, title, status, outcome, state, year, overview, seasons, source, targets
        case mediaType = "media_type"
        case requestedByUserID = "requested_by_user_id"
        case lastError = "last_error"
        case outcomeReason = "outcome_reason"
        case posterPath = "poster_path"
        case tmdbID = "tmdb_id"
        case createdAt = "created_at"
        case approvedAt = "approved_at"
        case completedAt = "completed_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        provider = try c.decode(String.self, forKey: .provider)
        mediaType = try c.decode(String.self, forKey: .mediaType)
        title = try c.decode(String.self, forKey: .title)
        status = try c.decode(String.self, forKey: .status)
        outcome = try c.decode(String.self, forKey: .outcome)
        requestedByUserID = try c.decodeIfPresent(String.self, forKey: .requestedByUserID)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError).flatMap(Self.nonBlank)
        state = try c.decodeIfPresent(String.self, forKey: .state)
        outcomeReason = try c.decodeIfPresent(String.self, forKey: .outcomeReason).flatMap(Self.nonBlank)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        posterPath = try c.decodeIfPresent(String.self, forKey: .posterPath).flatMap(Self.nonBlank)
        overview = try c.decodeIfPresent(String.self, forKey: .overview).flatMap(Self.nonBlank)
        seasons = try c.decodeIfPresent([Int].self, forKey: .seasons) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "direct"
        tmdbID = try c.decodeIfPresent(Int.self, forKey: .tmdbID)
        targets = try c.decodeIfPresent([RequestTarget].self, forKey: .targets) ?? []
        createdAt = RequestDates.parse(try c.decodeIfPresent(String.self, forKey: .createdAt))
        approvedAt = RequestDates.parse(try c.decodeIfPresent(String.self, forKey: .approvedAt))
        completedAt = RequestDates.parse(try c.decodeIfPresent(String.self, forKey: .completedAt))
    }

    private static func nonBlank(_ text: String) -> String? {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }
}

/// Where one quality of a request went: a download server and its progress there.
struct RequestTarget: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let quality: String
    let status: String
    var instanceName: String?
    var integrationKind: String?
    /// The routing rule that sent it there, as named when it was sent.
    var routeName: String?
    var lastError: String?
    var download: RequestDownload?

    init(id: String, quality: String, status: String, instanceName: String? = nil, integrationKind: String? = nil,
         routeName: String? = nil, lastError: String? = nil, download: RequestDownload? = nil) {
        self.id = id
        self.quality = quality
        self.status = status
        self.instanceName = instanceName
        self.integrationKind = integrationKind
        self.routeName = routeName
        self.lastError = lastError
        self.download = download
    }

    enum CodingKeys: String, CodingKey {
        case id, quality, status, download
        case instanceName = "instance_name"
        case integrationKind = "integration_kind"
        case routeName = "route_name"
        case lastError = "last_error"
    }
}

/// How far a target's downloads are, while its download server reports them.
struct RequestDownload: Decodable, Sendable, Equatable {
    /// queued, downloading, paused, stalled, importing or import_blocked; more may be added.
    let phase: String
    /// Rounded down; absent while the size is unknown.
    var percent: Int?

    init(phase: String, percent: Int? = nil) {
        self.phase = phase
        self.percent = percent
    }
}

/// `GET /api/v2/admin/requests/counts`: how many requests each queue view holds.
struct RequestCounts: Decodable, Sendable, Equatable {
    var needsApproval: Int
    var inProgress: Int
    var failed: Int
    var done: Int

    enum CodingKeys: String, CodingKey {
        case failed, done
        case needsApproval = "needs_approval"
        case inProgress = "in_progress"
    }

    subscript(view: RequestQueueView) -> Int {
        switch view {
        case .needsApproval: needsApproval
        case .inProgress: inProgress
        case .failed: failed
        case .done: done
        }
    }
}

/// One entry of a request's history (`GET /api/v2/admin/requests/{id}/events`).
struct RequestEvent: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let type: String
    var message: String?
    var actorUsername: String?
    var createdAt: Date?

    init(id: String, type: String, message: String? = nil, actorUsername: String? = nil, createdAt: Date? = nil) {
        self.id = id
        self.type = type
        self.message = message
        self.actorUsername = actorUsername
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, type, message
        case actorUsername = "actor_username"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        actorUsername = try c.decodeIfPresent(String.self, forKey: .actorUsername)
        createdAt = RequestDates.parse(try c.decodeIfPresent(String.self, forKey: .createdAt))
    }
}

/// The server's RFC 3339 instants, with or without fractional seconds.
enum RequestDates {
    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle())
    }
}
