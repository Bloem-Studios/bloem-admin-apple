import Foundation

/// The summary above Logs when it is opened for one playback session, as on the web's logs page
/// (AdminLogsPlaybackSummary): application, FFmpeg and audit row counts, first and last seen, and the
/// nodes involved. The server has no summary route; the web counts the session's rows, and so does
/// this, reading the first page of `logs/app` and `logs/audit` filtered by the session.
struct PlaybackSessionSummary: Equatable, Sendable {
    let playbackSessionID: String
    let appCount: Int
    let ffmpegCount: Int
    let auditCount: Int
    let firstSeen: Date?
    let lastSeen: Date?
    let nodes: [String]
    /// True when the page read had more behind it: the count is then a lower bound.
    let appIsPartial: Bool
    let auditIsPartial: Bool

    static let pageSize = 200

    init(playbackSessionID: String, appRows: [OperationalLogEntry], auditRows: [AuditLogEntry], appIsPartial: Bool = false, auditIsPartial: Bool = false) {
        let app = appRows.filter { $0.playbackSessionID == playbackSessionID }
        let audit = auditRows.filter { $0.playbackSessionID == playbackSessionID }
        let times = app.map(\.timestamp) + audit.map(\.timestamp)
        self.playbackSessionID = playbackSessionID
        appCount = app.count
        ffmpegCount = app.filter { $0.component == "ffmpeg" }.count
        auditCount = audit.count
        firstSeen = times.min()
        lastSeen = times.max()
        nodes = Set((app.compactMap(\.nodeID) + audit.compactMap(\.nodeID)).filter { !$0.isEmpty }).sorted()
        self.appIsPartial = appIsPartial
        self.auditIsPartial = auditIsPartial
    }

    /// Reads the session's rows and counts them. The component filter is deliberately not applied,
    /// so the FFmpeg count sits beside the application count.
    static func load(playbackSessionID: String, client: APIClient) async throws -> PlaybackSessionSummary {
        async let app = client.operationalLogs(filter: LogFilter(playbackSessionID: playbackSessionID), cursor: nil, limit: pageSize)
        async let audit = client.auditLogs(filter: AuditFilter(playbackSessionID: playbackSessionID), cursor: nil, limit: pageSize)
        let (appPage, auditPage) = try await (app, audit)
        return PlaybackSessionSummary(
            playbackSessionID: playbackSessionID,
            appRows: appPage.items,
            auditRows: auditPage.items,
            appIsPartial: appPage.page?.hasMore ?? false,
            auditIsPartial: auditPage.page?.hasMore ?? false
        )
    }
}
