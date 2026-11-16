import Foundation

/// The words of the Overview's Watching now card: what an account is playing, said plainly.
enum WatchingNowText {
    struct Line: Equatable {
        let title: String
        /// "Playing" or "Paused", stated in words.
        let status: String
        /// The app and device, and how far in: "Bloem TV · tv · 10:00 of 2:00:00".
        let detail: String
    }

    static var empty: String { String(localized: "Not watching right now") }

    static func heading(count: Int) -> String {
        switch count {
        case 0: String(localized: "Watching now")
        case 1: String(localized: "Watching now · \(count) stream")
        default: String(localized: "Watching now · \(count) streams")
        }
    }

    static func line(_ session: AdminSession) -> Line {
        var parts: [String] = []
        if let client = session.streamClientLine { parts.append(client) }
        if let duration = session.fileDuration, duration > 0 {
            let position = StreamFormat.playbackClock(session.positionSeconds)
            let total = StreamFormat.playbackClock(duration)
            parts.append(String(localized: "\(position) of \(total)"))
        } else {
            parts.append(StreamFormat.playbackClock(session.positionSeconds))
        }
        return Line(
            title: session.streamTitle,
            status: session.isPaused ? String(localized: "Paused") : String(localized: "Playing"),
            detail: parts.joined(separator: " · ")
        )
    }
}

/// The lines of a login session or a device on the Sign-in tab: when it was last seen and when it expires, which tell a
/// lost phone from the television that is in use. Takes the clock, so a test can set it.
enum UserSessionText {
    /// "Last seen 3 hours ago", a date once it is over 30 days (the web's `formatLastSeen`), or that there was
    /// no activity since the sign-in.
    static func lastSeen(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return String(localized: "No activity since signing in") }
        return String(localized: "Last seen \(ago(date, now: now))")
    }

    static func expiry(_ date: Date, now: Date = .now) -> String {
        let day = date.formatted(date: .abbreviated, time: .omitted)
        return date > now ? String(localized: "Expires \(day)") : String(localized: "Expired \(day)")
    }

    static func sessionLines(_ session: AuthSession, showsIPs: Bool, now: Date = .now) -> [String] {
        var identity: [String] = []
        if showsIPs, !session.ipAddress.isEmpty { identity.append(session.ipAddress) }
        if session.current { identity.append(String(localized: "this session")) }
        var lines: [String] = []
        if !identity.isEmpty { lines.append(identity.joined(separator: " · ")) }
        lines.append(lastSeen(session.lastSeenAt, now: now))
        lines.append(expiry(session.expiresAt, now: now))
        if let created = UserFormat.dateTime(session.createdAt) { lines.append(String(localized: "Created \(created)")) }
        return lines
    }

    static func deviceLastSeen(_ device: UserDevice, now: Date = .now) -> String {
        guard let seen = device.lastSeenAt else { return String(localized: "Not seen yet") }
        return String(localized: "Last seen \(ago(seen, now: now))")
    }

    /// Relative while recent, a date after 30 days.
    private static func ago(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) > 30 * 24 * 3600 {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
