import SwiftUI

/// A page that could not load, as one block in the content area (maintainer, 2026-11-16): what kind of failure it was, a
/// sentence on what went wrong and how to fix it, and a secondary Try again. The server's own words, when they say
/// more than that sentence, are behind a Details disclosure. An error never apologizes.
struct LoadFailureView: View {
    let failure: ServerSectionFailure
    let onRetry: () -> Void
    @State private var showsDetails = false

    var body: some View {
        BloemEmptyState {
            Label(failure.title, icon: failure.kind.icon)
        } description: {
            VStack(spacing: Theme.Space.s) {
                Text(failure.summary)
                if let detail = failure.detail {
                    DisclosureGroup(isExpanded: $showsDetails) {
                        Text(detail)
                            .bloemText(.bodySmall)
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    } label: {
                        Text("Details").bloemText(.labelMedium).foregroundStyle(Theme.muted)
                    }
                    .accessibilityIdentifier("failure-details")
                }
            }
        } actions: {
            Button("Try again", action: onRetry)
                .buttonStyle(.bloemSecondary)
                .accessibilityIdentifier("failure-try-again")
        }
    }
}

extension ServerSectionFailure {
    /// What went wrong and how to fix it, in the app's words, by kind.
    var summary: String {
        switch self {
        case .signedOut: String(localized: "This device is signed out of the server. Sign in again to carry on.")
        case .forbidden: String(localized: "This account can't open this page. Ask a server administrator for access.")
        case .connectivity: String(localized: "The app can't reach the server. Check the connection and try again.")
        case .incompatibleResponse:
            String(localized: "The server answered in a way this app doesn't understand. Update the server or the app, then try again.")
        case .serverFailure: String(localized: "The server couldn't finish the request. Try again in a moment.")
        }
    }

    /// The server's own words, for the Details disclosure; nil when there are none or they only repeat the sentence.
    var detail: String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty || text == summary ? nil : text
    }
}
