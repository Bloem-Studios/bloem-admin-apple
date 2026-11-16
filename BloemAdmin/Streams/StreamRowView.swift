import SwiftUI

/// Accessibility identifiers for a row and its details, for UI tests.
enum StreamRowID {
    static func row(_ sessionID: String) -> String { "stream-row.\(sessionID)" }
    static func details(_ sessionID: String) -> String { "stream-details.\(sessionID)" }
    static func progress(_ sessionID: String) -> String { "stream-progress.\(sessionID)" }
    static func detail(_ kind: StreamDetailRow.Kind) -> String { "stream-detail.\(kind.rawValue)" }
}

/// One live stream: title, who is watching and on what, state and playback decision, a progress bar
/// that moves between polls while it plays, and — tapped — everything else support needs.
///
/// The stream's own controls are the caller's: `actions` is drawn in the row's top corner (the
/// Streams pages put their menu there) and is not part of the tappable summary. `showClientIP` is for
/// the platform administrator only; an organization context must leave it off, and turns
/// `showServerRouting` off too (the playing node and network belong to the server). `expandable` false
/// makes a plain summary with no details, for a preview (the dashboard's Now playing) that opens the
/// full page on tap.
struct StreamRowView<Actions: View>: View {
    let session: AdminSession
    let showClientIP: Bool
    let showServerRouting: Bool
    let pending: Bool
    let expandable: Bool
    private let actions: Actions

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        session: AdminSession,
        showClientIP: Bool = false,
        showServerRouting: Bool = true,
        pending: Bool = false,
        expandable: Bool = true,
        @ViewBuilder actions: () -> Actions
    ) {
        self.session = session
        self.showClientIP = showClientIP
        self.showServerRouting = showServerRouting
        self.pending = pending
        self.expandable = expandable
        self.actions = actions()
    }

    private var facts: StreamFacts { StreamFacts(session) }

    var body: some View {
        let facts = facts
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                summary(facts)
                if expandable && expanded {
                    StreamDetailsView(
                        session: session,
                        rows: streamDetailRows(session, showClientIP: showClientIP, showServerRouting: showServerRouting)
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
        .padding(.vertical, Theme.Space.xs)
    }

    private func toggle() {
        if reduceMotion {
            expanded.toggle()
        } else {
            withAnimation(Theme.Motion.feedback) { expanded.toggle() }
        }
    }

    @ViewBuilder
    private func summary(_ facts: StreamFacts) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(session.streamTitle).bloemText(.titleMedium).lineLimit(3)
                Text(session.streamUserLabel).bloemText(.bodyMedium)
                // Playing is live: the orange tally dot. Paused is the one that needs a look, in amber.
                StatusLabel(facts.stateLabel, tone: session.isPaused ? .warning : .live).padding(.top, Theme.Space.xs)
            }
            // The corner control sits over the header's right edge, so the header leaves it room.
            .padding(.trailing, hasActions ? Theme.minimumTarget : 0)
            SignalPathView(session: session)
            HStack(alignment: .bottom, spacing: Theme.Space.s) {
                StreamProgressView(session: session)
                if expandable {
                    IconImage(expanded ? .chevronUp : .chevronDown, size: .inline)
                        .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        .accessibilityHidden(true)
                }
            }
            if pending {
                StatusLabel("Action in progress", tone: .warning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { if expandable { toggle() } }
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(StreamRowID.row(session.sessionID))
        .accessibilityLabel(facts.accessibilityDescription(for: session))
        .accessibilityValue(expandable ? (expanded ? Text("Details shown") : Text("Details hidden")) : Text(""))
        .accessibilityHint(expandable ? (expanded ? Text("Hides the details") : Text("Shows the details")) : Text(""))
        .accessibilityAddTraits(expandable ? .isButton : [])
        .accessibilityAction(.default) { if expandable { toggle() } }
    }

    private var hasActions: Bool { Actions.self != EmptyView.self }
}

extension StreamRowView where Actions == EmptyView {
    init(session: AdminSession, showClientIP: Bool = false, pending: Bool = false, expandable: Bool = true) {
        self.init(session: session, showClientIP: showClientIP, pending: pending, expandable: expandable) { EmptyView() }
    }
}

// MARK: - Progress

/// Position and time left. While it plays the numbers move once a second between polls, from the
/// last reported position; paused they stay put. Under Reduce Motion, or while the app is not in
/// front, nothing moves between polls.
struct StreamProgressView: View {
    let session: AdminSession
    @Environment(\.streamTickClockProvider) private var clock

    var body: some View {
        TickingProgress(session: session, clock: clock.make())
    }
}

private struct TickingProgress: View {
    let session: AdminSession
    @State private var ticker: StreamProgressTicker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    init(session: AdminSession, clock: any StreamTickClock) {
        self.session = session
        _ticker = State(initialValue: StreamProgressTicker(
            clock: clock, position: session.positionSeconds, duration: session.fileDuration, paused: session.isPaused
        ))
    }

    /// A new report (a changed position, pause state or update time) starts the count again.
    private struct Report: Hashable {
        let sessionID: String
        let position: Double
        let duration: Double?
        let paused: Bool
        let updatedAt: String?
    }

    private var report: Report {
        Report(
            sessionID: session.sessionID, position: session.positionSeconds, duration: session.fileDuration,
            paused: session.isPaused, updatedAt: session.updatedAt
        )
    }

    private var ticking: Bool {
        StreamProgressTicker.shouldTick(paused: session.isPaused, reduceMotion: reduceMotion, foreground: scenePhase == .active)
    }

    var body: some View {
        let duration = ticker.duration
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if let fraction = ticker.fraction {
                StreamProgressBar(fraction: fraction, paused: session.isPaused)
            }
            ViewThatFits(in: .horizontal) {
                HStack {
                    positionText(duration)
                    Spacer(minLength: 8)
                    leftText
                }
                VStack(alignment: .leading, spacing: 0) {
                    positionText(duration)
                    leftText
                }
            }
            .foregroundStyle(.bloemMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // One element reading the live position. Inside a row it is folded into the row's single
        // element, whose description uses the reported position, so VoiceOver does not chatter.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StreamFacts.progressDescription(position: ticker.position, duration: ticker.duration))
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityIdentifier(StreamRowID.progress(session.sessionID))
        // Ticking stops with the app out of front, while paused and under Reduce Motion, and picks
        // up again from the same report: the stream kept playing meanwhile.
        .task(id: ticking) { await ticker.run(ticking: ticking) }
        .onChange(of: report) {
            ticker.report(position: session.positionSeconds, duration: session.fileDuration, paused: session.isPaused)
        }
    }

    /// Set on each Text, not on the group around them: a font set on the Text keeps scaling with Dynamic Type.
    private func tabular(_ text: Text) -> some View {
        text.bloemText(.bodySmall)
    }

    @ViewBuilder
    private func positionText(_ duration: Double?) -> some View {
        if let duration, duration > 0 {
            tabular(Text("\(StreamFormat.playbackClock(ticker.position)) / \(StreamFormat.playbackClock(duration))"))
        } else {
            tabular(Text(StreamFormat.playbackClock(ticker.position)))
        }
    }

    @ViewBuilder
    private var leftText: some View {
        // The bitrate, in tabular figures like the timecode beside it. Time left is not drawn: elapsed and total say it.
        if let bitrate = StreamFormat.bitrate(session.streamBitrateKbps) {
            tabular(Text(bitrate))
        }
    }
}

// MARK: - Details

private struct StreamDetailsView: View {
    let session: AdminSession
    let rows: [StreamDetailRow]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var labelWidth: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 0) {
                            label(row)
                            value(row)
                        }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            label(row).frame(width: labelWidth, alignment: .leading)
                            value(row)
                        }
                    }
                }
                .modifier(DetailAccessibility(row: row))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(StreamRowID.details(session.sessionID))
    }

    private func label(_ row: StreamDetailRow) -> some View {
        Text(row.label).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
    }

    private func value(_ row: StreamDetailRow) -> some View {
        Text(row.value)
            .bloemText(.bodySmall)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Each line reads as "label, value" and carries an identifier named for what it holds.
private struct DetailAccessibility: ViewModifier {
    let row: StreamDetailRow

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(row.label)
            .accessibilityValue(row.value)
            .accessibilityIdentifier(StreamRowID.detail(row.kind))
    }
}
