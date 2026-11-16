import SwiftUI

/// Whether the sessions below are live: the state, why the socket is not live, and that the rows may
/// be old. Android's `SessionSourceStatus`.
struct LiveSessionsStatus: View {
    let state: RealtimeState
    let failure: SessionFailure?
    let hasSessions: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if state == .live {
                // A live connection: the tally dot.
                LiveLabel(state.label)
            } else {
                Text(state.label)
                    .bloemText(.labelMedium)
                    .foregroundStyle(.bloemMuted)
            }
            if let message = failure?.message {
                Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if hasSessions && showsStaleNote {
                Text("Live sessions unavailable, showing the last reported data").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("live-sessions-status")
    }

    /// Connecting is the first read of a screen, not a failure to be live.
    private var showsStaleNote: Bool {
        switch state {
        case .reconnecting, .unavailable, .signInRequired: true
        case .connecting, .live: false
        }
    }
}
