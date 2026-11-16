import SwiftUI

/// One audit entry in full: the action and what it changed, the target, and the request behind it
/// (client IP, user agent, duration, request ID, node and sessions), with Copy and Share. The client
/// address and user agent follow `showsClientIPs`.
struct AuditDetailSheet: View {
    let entry: AuditLogEntry
    @Environment(\.showsClientIPs) private var showsClientIPs

    var body: some View {
        IncidentSheet(title: String(localized: "Audit entry")) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.headline).bloemText(.titleMedium).textSelection(.enabled)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .bloemText(.bodyMedium)
                    .foregroundStyle(.bloemMuted)
            }
            if !entry.changes.isEmpty {
                DetailCard(String(localized: "Changes")) {
                    ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                        Text(change.line(targetType: entry.targetType)).textSelection(.enabled)
                    }
                }
            }
            DetailCard(String(localized: "Request")) {
                IncidentField(String(localized: "Request"), entry.requestLine)
                IncidentField(String(localized: "Status"), String(entry.statusCode))
                IncidentField(String(localized: "Duration"), "\(entry.durationMs) ms")
                OptionalIncidentField(String(localized: "Target"), entry.targetLabel)
                OptionalIncidentField(String(localized: "Request ID"), entry.requestID)
                OptionalIncidentField(String(localized: "Node"), entry.nodeID)
            }
            DetailCard(String(localized: "Who")) {
                OptionalIncidentField(String(localized: "User"), entry.actorText)
                if showsClientIPs {
                    IncidentField(String(localized: "Client IP"), entry.clientIP)
                    OptionalIncidentField(String(localized: "User agent"), entry.userAgent)
                }
                OptionalIncidentField(String(localized: "Session"), entry.sessionID)
                OptionalIncidentField(String(localized: "Playback session"), entry.playbackSessionID)
            }
            IncidentShareBar(
                text: entry.detailText(showsClientIP: showsClientIPs),
                copyIdentifier: "audit-detail-copy",
                shareIdentifier: "audit-detail-share"
            )
        }
        .accessibilityIdentifier("audit-detail")
    }
}
