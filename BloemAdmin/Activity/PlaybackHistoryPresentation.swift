import Foundation

/// What a Playback history row and its details say, following the web's AdminPlaybackHistory page:
/// an episode leads with its series and details "S02E04 · Episode title", and watch time is the
/// measured `played_seconds`, or for an older play the end position capped at the time that passed.
extension PlaybackHistoryEntry {
    /// "S02E04", from `season_number` and `episode_number`; nil unless the play has both.
    var episodeCode: String? {
        guard let seasonNumber, let episodeNumber else { return nil }
        return String(format: "S%02dE%02d", seasonNumber, episodeNumber)
    }

    private var series: String? {
        let trimmed = seriesTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The series for an episode, the item's own title for anything else.
    var headline: String { series ?? mediaTitle }

    /// "S02E04 · Episode title" for an episode. A pilot named after its show does not repeat it.
    var detailLine: String? {
        guard let series else { return nil }
        let title = mediaTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = [episodeCode, title == series || title.isEmpty ? nil : title].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Measured watch time, or for a play recorded before it was measured the server's estimate:
    /// the end position, capped at the time between start and end.
    var watchTime: (seconds: Double, estimated: Bool) {
        if let playedSeconds { return (max(playedSeconds, 0), false) }
        guard let endedAt else { return (max(watchedSeconds, 0), true) }
        let elapsed = max(endedAt.timeIntervalSince(startedAt), 0)
        return (max(min(watchedSeconds, elapsed), 0), true)
    }

    /// "12m 04s of 42m 10s"; "About ..." when the watch time is an estimate; no "of" without a length.
    var watchLine: String {
        let watch = watchTime
        let watched = Self.durationText(watch.seconds)
        let base: String
        if let durationSeconds, durationSeconds > 0 {
            base = String(localized: "\(watched) of \(Self.durationText(durationSeconds))")
        } else {
            base = watched
        }
        return watch.estimated ? String(localized: "About \(base)") : base
    }

    /// "1h 30m", "12m 04s" or "45s".
    static func durationText(_ seconds: Double) -> String {
        let whole = max(Int(seconds.rounded(.down)), 0)
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let rest = whole % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m " + String(format: "%02d", rest) + "s" }
        return "\(rest)s"
    }

    /// The server's method for the whole play, in the words Now playing uses.
    var method: StreamMethod {
        switch playMethod.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "direct", "direct_play", "direct play": .direct
        case "remux": .remux
        case "direct_stream", "direct stream", "audio": .directStream
        case "transcode", "hls": .transcode
        default: .unknown
        }
    }

    var playMethodLabel: String { StreamFacts.label(for: method) }

    /// The profile's name, or its ID when the server recorded no name.
    var profileLabel: String {
        let name = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? profileID : name
    }

    /// Why the play ended, in words; nil when the server does not know.
    var endReasonLabel: String? {
        switch endReason {
        case "stopped": String(localized: "Stopped by the viewer")
        case "terminated": String(localized: "Ended by an administrator")
        case "expired": String(localized: "Client stopped responding")
        case "aborted": String(localized: "Stopped by the server")
        case "replaced": String(localized: "Replaced by a new session")
        default: nil
        }
    }

    /// When the play ended (its start when no end was recorded), as a date and time in the viewer's
    /// time zone: "14 Nov, 22:42".
    func whenText(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        Self.moment(endedAt ?? startedAt, timeZone: timeZone, locale: locale)
    }

    func startedText(timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        Self.moment(startedAt, timeZone: timeZone, locale: locale)
    }

    private static func moment(_ date: Date, timeZone: TimeZone, locale: Locale) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone)
        style.calendar.timeZone = timeZone
        return date.formatted(style)
    }

    /// "Bloem for iPhone 1.4 · ios": the app and platform the client reported, for the details sheet.
    var clientLine: String? {
        let name = [clientName, clientVersion].compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }.joined(separator: " ")
        let platform = devicePlatform?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [name.isEmpty ? nil : name, platform.isEmpty ? nil : platform].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
