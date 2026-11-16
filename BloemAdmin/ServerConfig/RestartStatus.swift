import Foundation

/// What the server says about restarting, in words for the person: which settings wait for a restart
/// (by their labels), how long the server has been up, and what a restart will do.
enum RestartStatus {
    /// The labels of the settings that wait for a restart, in the order the server recorded them and
    /// without repeats. A `setting:<key>` reason becomes that setting's label; any other reason is a
    /// short slug and is made readable. A server that only sends the single `restart_required_reason`
    /// is read the same way.
    static func reasonLabels(for status: ServerStatus) -> [String] {
        var reasons = status.restartRequiredReasons
        if reasons.isEmpty, let single = status.restartRequiredReason, !single.isEmpty { reasons = [single] }
        var seen = Set<String>()
        var labels: [String] = []
        for reason in reasons {
            let label = label(forReason: reason)
            if seen.insert(label).inserted { labels.append(label) }
        }
        return labels
    }

    static func label(forReason reason: String) -> String {
        let prefix = "setting:"
        if reason.hasPrefix(prefix) {
            return SettingsCatalogue.label(forKey: String(reason.dropFirst(prefix.count)))
        }
        return ServerStatus.humanize(reason)
    }

    /// "Up 3d 4h", or a dash while the start time is unknown.
    static func uptime(for status: ServerStatus, now: Date = Date()) -> String {
        formatUptime(startedAt: status.startedDate, now: now)
    }

    /// One line for the status section: whether a restart is needed and for what.
    static func summary(for status: ServerStatus) -> String {
        if status.restartRequested { return String(localized: "Restart in progress") }
        guard status.restartRequired else { return String(localized: "Not needed") }
        let labels = reasonLabels(for: status)
        guard !labels.isEmpty else { return String(localized: "Needed") }
        return String(localized: "Needed for \(labels.formatted(.list(type: .and)))")
    }

    /// What the restart confirmation says: the server's own warning (the web's), so nobody restarts a
    /// server with people watching without knowing.
    static var confirmationMessage: String {
        String(localized: "The server shuts down. It comes back on its own only if a service manager such as Docker or systemd restarts it; otherwise, start it again yourself. Active streams will be interrupted")
    }

    /// The line after a restart request, from the server's receipt.
    static func receiptNotice(_ receipt: RestartReceipt) -> String {
        if receipt.alreadyRequested { return String(localized: "A restart is already in progress") }
        if receipt.notifiedSessions > 0 {
            return String(localized: "Restart requested. \(receipt.notifiedSessions) streams were told")
        }
        return String(localized: "Restart requested")
    }
}

/// What `POST /api/v2/admin/server/restart` answers (202): `restart_requested` the first time, and
/// `already_requested` while the process is already shutting down.
struct RestartReceipt: Decodable, Equatable, Sendable {
    let status: String
    let message: String?
    let notifiedSessions: Int

    var alreadyRequested: Bool { status == "already_requested" }

    enum CodingKeys: String, CodingKey {
        case status, message
        case notifiedSessions = "notified_sessions"
    }

    init(status: String, message: String? = nil, notifiedSessions: Int = 0) {
        self.status = status
        self.message = message
        self.notifiedSessions = notifiedSessions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "restart_requested"
        message = try c.decodeIfPresent(String.self, forKey: .message)
        notifiedSessions = try c.decodeIfPresent(Int.self, forKey: .notifiedSessions) ?? 0
    }
}

extension RestartKeys {
    /// Whether a change to `key` waits for a restart: an exact key, or any key under a listed prefix.
    func requiresRestart(_ key: String) -> Bool {
        keys.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }
}
