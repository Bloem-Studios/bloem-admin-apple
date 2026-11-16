import SwiftUI

/// The session summary on top of Logs when it is opened for one playback session: the counts, when
/// the session was first and last seen, and the nodes, with a switch for FFmpeg lines only.
struct PlaybackSessionSummaryView: View {
    let playbackSessionID: String
    let summary: PlaybackSessionSummary?
    let failureMessage: String?
    let ffmpegOnly: Bool
    let onToggleFFmpeg: () -> Void
    let onClearSession: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                IncidentField(String(localized: "Playback session"), LogIdentifier.short(playbackSessionID))
                Button("Show all logs", action: onClearSession)
                    .bloemText(.bodyMedium)
                    .accessibilityIdentifier("logs-session-clear")
            }
            if let summary {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)], alignment: .leading, spacing: 8) {
                    IncidentField(String(localized: "Application logs"), count(summary.appCount, partial: summary.appIsPartial))
                    IncidentField(String(localized: "FFmpeg logs"), count(summary.ffmpegCount, partial: summary.appIsPartial))
                    IncidentField(String(localized: "Audit entries"), count(summary.auditCount, partial: summary.auditIsPartial))
                    IncidentField(String(localized: "First seen"), summary.firstSeen.map(Self.time) ?? "–")
                    IncidentField(String(localized: "Last seen"), summary.lastSeen.map(Self.time) ?? "–")
                    IncidentField(String(localized: "Nodes"), summary.nodes.isEmpty ? "–" : summary.nodes.joined(separator: ", "))
                }
            } else if let failureMessage {
                Text(failureMessage).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            } else {
                ProgressView()
            }
            Toggle("FFmpeg lines only", isOn: Binding(get: { ffmpegOnly }, set: { _ in onToggleFFmpeg() }))
                .accessibilityIdentifier("logs-ffmpeg-only")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("logs-session-summary")
    }

    private func count(_ value: Int, partial: Bool) -> String {
        partial ? String(localized: "\(value) or more") : String(value)
    }

    private static func time(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}
