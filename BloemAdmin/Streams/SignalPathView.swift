import SwiftUI

/// One stop on a stream's way to the screen: where the file is, what the server decided to do with it, and
/// who is watching. Only a transcode is lit; every other decision reads as quiet text.
struct SignalStep: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable { case source, decision, client }

    let kind: Kind
    let label: String
    let value: String
    var detail: String?
    /// The play method the decision step names, for its dot.
    var method: PlaybackMethod?
    /// Lit: the one step that costs the server something.
    var lit = false

    var id: String { kind.rawValue }
}

/// A stream as its signal path: source, playback decision, client.
enum SignalPath {
    static func steps(for session: AdminSession, locale: Locale = .current) -> [SignalStep] {
        let facts = StreamFacts(session, locale: locale)
        let method = facts.method

        let sourceValue = session.videoFlow.source ?? StreamFormat.codec(session.sourceAudioCodec)
        let source = SignalStep(
            kind: .source, label: String(localized: "Source"),
            value: sourceValue ?? String(localized: "Unknown"),
            detail: session.sourceContainerLabel
        )

        // A transcode names what it converts to and what does the work; the rest just name the method.
        var decisionDetail: String?
        if method == .transcode {
            decisionDetail = StreamFacts.dotted([session.videoFlow.target, session.transcodeMode.map { StreamFacts.label(for: $0) }])
        }
        let decision = SignalStep(
            kind: .decision, label: String(localized: "Playback"),
            value: facts.methodLabel, detail: decisionDetail, method: PlaybackMethod(method), lit: PlaybackMethod(method)?.isLit ?? false
        )

        let client = SignalStep(
            kind: .client, label: String(localized: "Client"),
            value: session.streamClientLabel ?? String(localized: "Unknown client"),
            detail: session.streamDeviceLabel
        )
        return [source, decision, client]
    }
}

/// The signal path as a row of three: source → decision → client. At the largest text sizes it stacks.
struct SignalPathView: View {
    let session: AdminSession
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let steps = SignalPath.steps(for: session)
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(steps) { step in SignalStepView(step: step) }
                }
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                        if index > 0 {
                            // An arrow into or out of a transcode is amber with it.
                            let lit = step.lit || steps[index - 1].lit
                            IconImage(.arrowRight, size: .inline)
                                .foregroundStyle(lit ? Color.bloemWarn : Color.bloemMuted)
                                .padding(.top, Theme.Space.l)
                                .accessibilityHidden(true)
                        }
                        SignalStepView(step: step)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        // The row's one VoiceOver description already says all of this.
        .accessibilityHidden(true)
    }
}

private struct SignalStepView: View {
    let step: SignalStep

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(step.label)
                .bloemText(.labelSmall)
                .foregroundStyle(.bloemMuted)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                if let method = step.method {
                    Circle().fill(method.color).frame(width: StatusLabel.dotSize, height: StatusLabel.dotSize)
                }
                Text(step.value)
                    .bloemText(.labelMedium)
                    .foregroundStyle(step.lit ? Color.bloemWarn : Color.bloemText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = step.detail {
                Text(detail)
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // Only a transcode is lit: a raised surface behind the step, its dot and word in amber.
        .padding(step.lit ? Theme.Space.s : 0)
        .background(step.lit ? Theme.raised : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.inner))
    }
}

/// How far into the file a stream is: a thin bar in ink while it plays and amber while it is paused. The
/// dashboard's Now playing and the Now playing page share it, so progress never changes color between them.
struct StreamProgressBar: View {
    let fraction: Double
    let paused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.hairline)
                Capsule()
                    .fill(paused ? Theme.warn : Theme.muted)
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), 0))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
