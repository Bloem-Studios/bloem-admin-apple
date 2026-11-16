import SwiftUI

/// What the Requests page says when the server runs no request administration. It is not a failure, so there
/// is no Retry: pulling down checks again, and the page stops polling meanwhile.
struct RequestsUnavailableView: View {
    /// One quiet line, for a server's section in All servers.
    var compact = false

    var body: some View {
        if compact {
            VStack(alignment: .leading, spacing: 4) {
                Text("Request administration isn't available on this server")
                Text("Check the server's configuration on the web.")
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("requests-unavailable")
        } else {
            BloemEmptyState {
                Label("Request administration isn't available on this server", icon: .inbox)
            } description: {
                Text("The server has no request service running. Check its configuration on the web, then pull down to check again.")
            }
            .accessibilityIdentifier("requests-unavailable")
        }
    }
}
