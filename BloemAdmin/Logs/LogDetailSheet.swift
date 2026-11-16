import SwiftUI

/// One log entry in full: request ID, node, method, status, duration, client IP, user, session,
/// playback session and attributes, with Copy and Share. The client IP follows `showsClientIPs`.
struct LogDetailSheet: View {
    let entry: OperationalLogEntry
    /// Opens Logs for this entry's playback session, in place of this sheet's page.
    var onViewSession: ((String) -> Void)?
    @Environment(\.showsClientIPs) private var showsClientIPs
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        IncidentSheet(title: String(localized: "Log entry")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.message).bloemText(.titleMedium).textSelection(.enabled)
                Text("\(Vocabulary.sentenceCase(entry.level)) · \(entry.component) · \(entry.timestamp.formatted(date: .abbreviated, time: .standard))")
                    .bloemText(.bodyMedium)
                    .foregroundStyle(.bloemMuted)
            }
            DetailCard(String(localized: "Request")) {
                OptionalIncidentField(String(localized: "Request ID"), entry.requestID)
                OptionalIncidentField(String(localized: "Node"), entry.nodeID)
                OptionalIncidentField(String(localized: "Method"), entry.method)
                OptionalIncidentField(String(localized: "Status"), entry.statusText)
                OptionalIncidentField(String(localized: "Duration"), entry.durationText)
                OptionalIncidentField(String(localized: "Path"), entry.path)
                if showsClientIPs {
                    OptionalIncidentField(String(localized: "Client IP"), entry.effectiveClientIP)
                }
            }
            DetailCard(String(localized: "Who")) {
                OptionalIncidentField(String(localized: "User"), entry.userID)
                OptionalIncidentField(String(localized: "Session"), entry.effectiveSessionID)
                OptionalIncidentField(String(localized: "Playback session"), entry.effectivePlaybackSessionID)
            }
            if let session = entry.effectivePlaybackSessionID, let onViewSession {
                Button("Logs for this playback session") {
                    dismiss()
                    onViewSession(session)
                }
                .buttonStyle(.bloemSecondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("log-detail-session-logs")
            }
            if let attributes = entry.attributesText(showsClientIP: showsClientIPs) {
                DetailCard(String(localized: "Attributes")) {
                    Text(attributes)
                        .bloemText(.bodySmall)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            IncidentShareBar(
                text: entry.detailText(showsClientIP: showsClientIPs),
                copyIdentifier: "log-detail-copy",
                shareIdentifier: "log-detail-share"
            )
        }
        .accessibilityIdentifier("log-detail")
    }
}
