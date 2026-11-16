import SwiftUI

/// One play in Playback history: what was watched, by whom, when it ended in local time, how long
/// out of how long, and how it was delivered, with the state in words. A tap opens its details.
struct HistoryRowView: View {
    let entry: PlaybackHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.headline).bloemText(.titleMedium)
            if let detail = entry.detailLine {
                Text(detail).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            }
            Text("\(entry.username) · \(entry.profileLabel)").bloemText(.bodyMedium)
            Text(entry.whenText())
                .bloemText(.bodyMedium)
                .foregroundStyle(.bloemMuted)
            Text(summary)
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "40m 10s of 1h 30m · Direct play · Partial".
    private var summary: String {
        let state = entry.completed ? String(localized: "Completed") : String(localized: "Partial")
        return [entry.watchLine, entry.playMethodLabel, state].joined(separator: " · ")
    }
}
