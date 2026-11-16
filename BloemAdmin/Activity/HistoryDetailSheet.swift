import SwiftUI

/// The details of one play: who, what, when, how long, how it was delivered and why it ended, with
/// "Logs" and "FFmpeg logs" for its playback session where Logs is available, and Copy and Share.
struct HistoryDetailSheet: View {
    let entry: PlaybackHistoryEntry
    /// Opens Logs for this play's playback session; nil where the page has no Logs (All servers).
    var onOpenLogs: ((LogsFocus) -> Void)?
    @Environment(\.showsClientIPs) private var showsClientIPs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        IncidentSheet(title: String(localized: "Play details")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.headline).bloemText(.titleLarge)
                if let detail = entry.detailLine {
                    Text(detail).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                }
            }
            DetailCard(String(localized: "Who")) {
                IncidentField(String(localized: "User"), entry.username)
                IncidentField(String(localized: "Profile"), entry.profileLabel)
            }
            DetailCard(String(localized: "Play")) {
                IncidentField(String(localized: "Ended"), entry.whenText())
                IncidentField(String(localized: "Started"), entry.startedText())
                IncidentField(String(localized: "Watched"), entry.watchLine)
                OptionalIncidentField(String(localized: "Paused"), entry.pausedSeconds.map { PlaybackHistoryEntry.durationText($0) })
                IncidentField(String(localized: "Result"), entry.completed ? String(localized: "Completed") : String(localized: "Partial"))
                OptionalIncidentField(String(localized: "How it ended"), entry.endReasonLabel)
            }
            DetailCard(String(localized: "Delivery")) {
                IncidentField(String(localized: "Play method"), entry.playMethodLabel)
                OptionalIncidentField(String(localized: "Client"), entry.clientLine)
                if showsClientIPs {
                    OptionalIncidentField(String(localized: "Client IP"), entry.clientIP)
                }
                IncidentField(String(localized: "Playback session"), entry.sessionID)
            }
            if let onOpenLogs {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Logs") {
                        dismiss()
                        onOpenLogs(LogsFocus(playbackSessionID: entry.sessionID, ffmpegOnly: false))
                    }
                    .accessibilityIdentifier("history-detail-logs")
                    Button("FFmpeg logs") {
                        dismiss()
                        onOpenLogs(LogsFocus(playbackSessionID: entry.sessionID, ffmpegOnly: true))
                    }
                    .accessibilityIdentifier("history-detail-ffmpeg-logs")
                }
                .buttonStyle(.bloemSecondary)
                .frame(minHeight: 44)
            }
            IncidentShareBar(text: shareText, copyIdentifier: "history-detail-copy", shareIdentifier: "history-detail-share")
        }
        .accessibilityIdentifier("history-detail")
    }

    /// The play as plain text for Copy and Share; the client address only when addresses are shown.
    var shareText: String {
        var lines = [entry.headline]
        if let detail = entry.detailLine { lines.append(detail) }
        lines.append(String(localized: "User: \(entry.username) · \(entry.profileLabel)"))
        lines.append(String(localized: "Ended: \(entry.whenText())"))
        lines.append(String(localized: "Watched: \(entry.watchLine)"))
        lines.append(String(localized: "Play method: \(entry.playMethodLabel)"))
        lines.append(entry.completed ? String(localized: "Result: Completed") : String(localized: "Result: Partial"))
        if let reason = entry.endReasonLabel { lines.append(String(localized: "How it ended: \(reason)")) }
        if let client = entry.clientLine { lines.append(String(localized: "Client: \(client)")) }
        if showsClientIPs, let ip = entry.clientIP, !ip.isEmpty { lines.append(String(localized: "Client IP: \(ip)")) }
        lines.append(String(localized: "Playback session: \(entry.sessionID)"))
        return lines.joined(separator: "\n")
    }
}
