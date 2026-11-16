import Foundation

struct AdminSetting: Decodable, Identifiable, Sendable {
    var id: String { key }
    let key: String
    let value: String
}

struct UpdateSettingRequest: Encodable {
    let value: String
}

struct ServerStatus: Decodable, Sendable {
    let startedAt: String
    let restartRequired: Bool
    let restartRequested: Bool
    /// Short machine-readable slug explaining *why* a restart is required
    /// (e.g. "jellyfin_compat"). Open-ended set decided server-side — this
    /// app only humanizes it for display, never switches on specific values.
    let restartRequiredReason: String?
    /// Every reason the server has recorded since it started, each `setting:<key>` for a saved
    /// setting or a short slug for anything else. Empty when none was recorded.
    let restartRequiredReasons: [String]
    /// When the first reason was recorded, as the server sent it.
    let restartRequiredAt: String?

    init(
        startedAt: String, restartRequired: Bool, restartRequested: Bool, restartRequiredReason: String?,
        restartRequiredReasons: [String] = [], restartRequiredAt: String? = nil
    ) {
        self.startedAt = startedAt
        self.restartRequired = restartRequired
        self.restartRequested = restartRequested
        self.restartRequiredReason = restartRequiredReason
        self.restartRequiredReasons = restartRequiredReasons
        self.restartRequiredAt = restartRequiredAt
    }

    enum CodingKeys: String, CodingKey {
        case startedAt = "started_at"
        case restartRequired = "restart_required"
        case restartRequested = "restart_requested"
        case restartRequiredReason = "restart_required_reason"
        case restartRequiredReasons = "restart_required_reasons"
        case restartRequiredAt = "restart_required_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        restartRequired = try c.decode(Bool.self, forKey: .restartRequired)
        restartRequested = try c.decode(Bool.self, forKey: .restartRequested)
        restartRequiredReason = try c.decodeIfPresent(String.self, forKey: .restartRequiredReason)
        restartRequiredReasons = try c.decodeIfPresent([String].self, forKey: .restartRequiredReasons) ?? []
        restartRequiredAt = try c.decodeIfPresent(String.self, forKey: .restartRequiredAt)
    }
}

extension ServerStatus {
    /// Humanizes `restartRequiredReason` for display, e.g. "jellyfin_compat"
    /// -> "Jellyfin compat". Returns nil when there's no reason to show.
    var humanizedRestartRequiredReason: String? {
        guard let reason = restartRequiredReason, !reason.isEmpty else { return nil }
        return Self.humanize(reason)
    }

    /// "jellyfin_compat" -> "Jellyfin compat".
    static func humanize(_ slug: String) -> String {
        let words = slug.split(whereSeparator: { $0 == "_" || $0 == "." || $0 == "-" }).map(String.init)
        guard let first = words.first else { return slug }
        let rest = words.dropFirst().joined(separator: " ")
        let capitalizedFirst = first.prefix(1).uppercased() + first.dropFirst()
        return rest.isEmpty ? capitalizedFirst : "\(capitalizedFirst) \(rest)"
    }

    /// The instant the server started, when `startedAt` parses.
    var startedDate: Date? {
        Self.parse(startedAt)
    }

    /// When the first restart reason was recorded, when the server said.
    var restartRequiredDate: Date? {
        restartRequiredAt.flatMap(Self.parse)
    }

    private static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
