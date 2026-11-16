import SwiftUI

/// Shown above every organization page opened under break-glass support access: that this is support access, how
/// long is left, and (on the organization's menu) a way to end it early. Nothing shows for a membership.
struct OrganizationSupportBanner: View {
    let session: OrganizationSession
    /// The menu ends the access; the pages under it only say how long is left.
    var allowsEnding = false
    @State private var confirming = false
    @State private var isEnding = false
    @State private var error: String?

    var body: some View {
        if session.isSupportAccess {
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                content(now: timeline.date)
            }
            .confirmationDialog(
                String(localized: "End support access to \(session.context?.name ?? "")?"),
                isPresented: $confirming, titleVisibility: .visible
            ) {
                Button("End access", role: .destructive) { Task { await end() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its administrators see in Activity that you closed it. To open it again you'll state a new reason.")
            }
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            OrganizationFlowLayout(spacing: Theme.Space.s) {
                HStack(spacing: Theme.Space.s) {
                    Circle().fill(Theme.warn).frame(width: StatusLabel.dotSize, height: StatusLabel.dotSize).accessibilityHidden(true)
                    Text("Support access").bloemText(.titleSmall)
                }
                Text(timeLeft(now: now)).bloemText(.bodyMedium)
            }
            Text("Everything you change here is shown to the organization's administrators as Platform support.")
                .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if let error {
                Text(error).bloemText(.bodySmall).foregroundStyle(.bloemDanger)
            }
            if allowsEnding {
                Button(role: .destructive) { confirming = true } label: {
                    if isEnding { ProgressView() } else { Text("End access").frame(minHeight: Theme.minimumTarget) }
                }
                .buttonStyle(.bloemSecondary)
                .disabled(isEnding)
                .accessibilityIdentifier("organization-support-end")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        // One container: a card with a hairline edge; the state is the amber dot and the words.
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.hairline, lineWidth: 1))
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
        .background(Theme.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("organization-support-banner")
    }

    private func timeLeft(now: Date) -> String {
        guard let expires = session.context?.supportExpiresAt else { return String(localized: "Ends within four hours") }
        guard let left = OrganizationText.timeLeft(until: expires, now: now) else { return String(localized: "Ending now") }
        return String(localized: "\(left) left")
    }

    private func end() async {
        isEnding = true
        error = nil
        do {
            try await session.endSupportAccess()
        } catch {
            self.error = session.failureText(error, fallback: String(localized: "Support access couldn't be ended. Try again."))
        }
        isEnding = false
    }
}
