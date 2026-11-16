import SwiftUI

/// A state, said quietly: a small dot and a word, for every state, good ones included (maintainer, 2026-11-16, A9).
///
/// The dot's colour says how the state stands: green for good (Active, Running, Healthy), amber for a state that needs
/// a look, red for a failure, the orange tally for live right now, and a neutral grey for a state that is neither
/// (Off, Disabled, In progress). The word is always there, so colour is never the only cue.
struct StatusLabel: View {
    enum Tone: Equatable, Sendable {
        /// A neutral state, neither good nor bad (Off, Archived, In progress): muted text and a grey dot.
        case normal
        /// Needs a look: Paused, Transcode, Suspended, Stale.
        case warning
        /// Failed or refused. Red is for failures and nothing else.
        case failure
        /// A good state (Active, Running, Healthy, Allowed): a green dot.
        case positive
        /// Live right now (Playing): the orange tally dot, then quiet text.
        case live
    }

    let text: String
    var tone: Tone = .normal

    init(_ text: String, tone: Tone = .normal) {
        self.text = text
        self.tone = tone
    }

    init(_ text: LocalizedStringResource, tone: Tone = .normal) {
        self.init(String(localized: text), tone: tone)
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            if let dot = Self.dotColor(for: tone) {
                Circle()
                    .fill(dot)
                    .frame(width: Self.dotSize, height: Self.dotSize)
                    .accessibilityHidden(true)
            }
            Text(text)
                .bloemText(.labelMedium)
                .foregroundStyle(Self.textColor(for: tone))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    static let dotSize: CGFloat = 8

    /// Every state gets a dot.
    static func dotColor(for tone: Tone) -> Color? {
        switch tone {
        case .normal: Theme.outline
        case .warning: Theme.warn
        case .failure: Theme.danger
        case .positive: Theme.ok
        case .live: Theme.tally
        }
    }

    static func textColor(for tone: Tone) -> Color {
        switch tone {
        case .normal: Theme.muted
        case .warning: Theme.warn
        case .failure: Theme.danger
        case .positive: Theme.ok
        case .live: Theme.muted
        }
    }
}

/// The signature: a small orange dot that means live right now — the live stream count, a live connection,
/// a running job. It is used nowhere else, so that orange dot always means "on air".
struct TallyDot: View {
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Theme.tally)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A label with the tally dot in front of it.
struct LiveLabel: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            TallyDot()
            Text(text)
                .bloemText(.labelMedium)
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The one "..." for a row's actions menu: the same icon, size and 44pt target everywhere, in muted text
/// color rather than the accent.
struct RowActionsIcon: View {
    var body: some View {
        IconImage(.ellipsis, size: .row)
            .foregroundStyle(.bloemMuted)
            .frame(minWidth: Theme.minimumTarget, minHeight: Theme.minimumTarget)
            .contentShape(Rectangle())
    }
}
