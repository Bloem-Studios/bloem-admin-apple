import SwiftUI
import WidgetKit

/// How much of a server card is drawn: the name and its state, then the two figures that matter.
enum ServerCardTier: Int, CaseIterable, Sendable {
    /// For a widget with room and few servers: the two figures large.
    case hero
    /// Name and state, with the live streams and the requests waiting as figures.
    case roomy
    /// Name and state, then one line of what is playing and waiting.
    case compact

    static let tiers: [WidgetCardTier] = [
        WidgetCardTier(height: 104, minWidth: 300),
        WidgetCardTier(height: 80, minWidth: 200),
        WidgetCardTier(height: 46, minWidth: 0),
    ]
}

/// Server status: whether each saved server answers, with the live stream count and the requests waiting.
/// The tally dot sits by the stream count while a stream is live, and by the status when a server is down.
struct ServerStatusWidgetView: View {
    let model: ServerStatusModel
    let context: WidgetContext
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        Group {
            switch context.size {
            case .circular: CircularLayout(model: model)
            case .rectangular: RectangularLayout(model: model)
            case .inline: InlineLayout(model: model)
            default: home
            }
        }
        .widgetURL(model.link)
    }

    // MARK: Home screen

    @ViewBuilder
    private var home: some View {
        if !model.hasServers {
            VStack(alignment: .leading, spacing: WidgetLayout.gap) {
                WidgetHeader(icon: .server, title: "Bloem Admin")
                WidgetCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Add a Silo server").widgetText(.titleSmall).foregroundStyle(palette.text)
                        Text("Open the app to add a server").widgetText(.bodySmall).foregroundStyle(palette.muted)
                    }
                }
            }
        } else {
            switch context.size {
            case .small: small
            case .medium: medium
            default: list
            }
        }
    }

    private var statusTally: String? { model.hasDownServer ? model.status.text : nil }
    private var statusTrailing: String? { model.hasDownServer ? nil : model.status.text }

    private var header: some View {
        WidgetHeader(icon: .server, title: "", verbatimTitle: model.title, tally: statusTally, trailing: statusTrailing, compact: context.size == .small)
    }

    private var stale: some View {
        Group {
            if let since = model.countsStaleSince {
                Text(verbatim: WidgetTime.updated(since)).widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
            }
        }
    }

    private var staleHeight: CGFloat { model.countsStaleSince == nil ? 0 : WidgetLayout.freshnessLine }

    /// Small: the live stream count, as the one figure that matters, and what waits.
    private var small: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            header
            Spacer(minLength: 0)
            BigFigure(
                value: countText(model.activeStreams),
                caption: model.activeStreams == 1 ? String(localized: "stream") : String(localized: "streams"),
                isLive: model.hasLiveStreams
            )
            Text("\(countText(model.requestsWaiting)) requests waiting").widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
            stale
        }
    }

    /// Medium: a card of the two figures, beside a card for each server.
    private var medium: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            header
            HStack(alignment: .top, spacing: WidgetLayout.gap) {
                WidgetCard(padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)) {
                    VStack(alignment: .leading, spacing: 6) {
                        BigFigure(
                            value: countText(model.activeStreams),
                            caption: model.activeStreams == 1 ? String(localized: "stream") : String(localized: "streams"),
                            isLive: model.hasLiveStreams
                        )
                        Text("\(countText(model.requestsWaiting)) requests waiting").widgetText(.labelMedium)
                            .foregroundStyle(palette.muted).lineLimit(2)
                    }
                }
                .frame(width: 132)
                serverList(hasHeader: false)
            }
            stale
        }
    }

    /// Large and extra large: a card for each server, then the totals.
    private var list: some View {
        serverList(hasHeader: true)
    }

    private func serverList(hasHeader: Bool) -> some View {
        WidgetListLayout(
            rows: model.rows, tiers: ServerCardTier.tiers,
            // Medium draws the "Updated" line itself, under the summary card and the list.
            maxColumns: context.size == .extraLarge ? 2 : 1, reserved: hasHeader ? staleHeight : 0, hasHeader: hasHeader,
            header: { header },
            card: { row, slot in WidgetServerCard(row: row, tier: ServerCardTier(rawValue: slot.tierIndex) ?? .compact) },
            footer: { kind, _ in WidgetFooterView(kind: kind, stats: stats) },
            bottom: { stale }
        )
    }

    private var stats: [WidgetStat] {
        var result = [
            WidgetStat(id: "streams", value: countText(model.activeStreams), label: model.activeStreams == 1 ? String(localized: "stream") : String(localized: "streams"), isLive: model.hasLiveStreams),
            WidgetStat(id: "waiting", value: countText(model.requestsWaiting), label: String(localized: "requests waiting")),
        ]
        let reachable = model.rows.filter { $0.reachability == .up }.count
        result.append(WidgetStat(id: "reachable", value: "\(reachable)/\(model.rows.count)", label: String(localized: "reachable")))
        return result
    }
}

extension ServerStatusModel.Status {
    var text: String {
        switch self {
        case .reachable: String(localized: "Reachable")
        case .unreachable: String(localized: "Can't reach")
        case .someUnreachable(let reachable, let total): String(localized: "\(reachable) of \(total) reachable")
        case .unknown: String(localized: "Not checked yet")
        }
    }

    var isFailure: Bool {
        switch self {
        case .unreachable, .someUnreachable: true
        case .reachable, .unknown: false
        }
    }
}

private func countText(_ value: Int?) -> String {
    value.map(String.init) ?? "–"
}

/// One saved server, as a card: a status dot and its name, whether it answers, how many streams play and
/// how many requests wait. Each card opens that server's Now playing page.
struct WidgetServerCard: View {
    let row: ServerStatusRow
    var tier: ServerCardTier = .compact
    @Environment(\.widgetPalette) private var palette

    private var tone: Color {
        switch row.reachability {
        case .up: palette.ok
        case .down: palette.danger
        case .unknown: palette.muted
        }
    }

    private var stateWord: String {
        switch row.reachability {
        case .up: String(localized: "Reachable")
        case .down: String(localized: "Can't reach")
        case .unknown: String(localized: "Not checked yet")
        }
    }

    private var streamsLabel: String {
        row.activeStreams == 1 ? String(localized: "stream") : String(localized: "streams")
    }

    var body: some View {
        Link(destination: DeepLinkRoute(target: .server(row.id), pageID: DeepLinkPage.nowPlaying).url) {
            WidgetCard {
                VStack(alignment: .leading, spacing: tier == .compact ? 2 : 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(tone).frame(width: 8, height: 8).accessibilityHidden(true)
                        Text(verbatim: row.name).widgetText(tier == .compact ? .labelMedium : .titleSmall)
                            .foregroundStyle(palette.text).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(verbatim: stateWord).widgetText(.labelSmall)
                            .foregroundStyle(row.reachability == .down ? palette.danger : palette.muted).lineLimit(1)
                    }
                    switch tier {
                    case .hero:
                        HStack(alignment: .top, spacing: 28) {
                            heroFigure(row.activeStreams, label: streamsLabel, isLive: (row.activeStreams ?? 0) > 0)
                            heroFigure(row.requestsWaiting, label: String(localized: "requests waiting"), isLive: false)
                        }
                    case .roomy:
                        HStack(alignment: .firstTextBaseline, spacing: 16) {
                            figure(row.activeStreams, label: streamsLabel, isLive: (row.activeStreams ?? 0) > 0)
                            figure(row.requestsWaiting, label: String(localized: "requests waiting"), isLive: false)
                        }
                    case .compact:
                        if row.reachability != .down {
                            HStack(spacing: 6) {
                                if (row.activeStreams ?? 0) > 0 { WidgetTallyDot() }
                                Text("\(countText(row.activeStreams)) \(streamsLabel) · \(countText(row.requestsWaiting)) requests waiting")
                                    .widgetText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func heroFigure(_ value: Int?, label: String, isLive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: countText(value)).widgetText(.headlineLarge).foregroundStyle(palette.text)
                if isLive { WidgetTallyDot() }
            }
            Text(verbatim: label).widgetText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func figure(_ value: Int?, label: String, isLive: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isLive { WidgetTallyDot() }
            Text(verbatim: countText(value)).widgetText(.headlineSmall).foregroundStyle(palette.text)
            Text(verbatim: label).widgetText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Lock screen

private struct CircularLayout: View {
    let model: ServerStatusModel

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                WidgetIconView(icon: model.status.isFailure ? .warning : .radio, size: 16)
                Text(verbatim: countText(model.activeStreams)).widgetText(.titleLarge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.title)
        .accessibilityValue(model.status.isFailure ? model.status.text : String(localized: "\(countText(model.activeStreams)) streams"))
    }
}

private struct RectangularLayout: View {
    let model: ServerStatusModel

    var body: some View {
        if model.hasServers {
            VStack(alignment: .leading, spacing: 2) {
                WidgetRectangularTitle(title: "", verbatimTitle: model.title)
                Text(verbatim: model.status.text).widgetText(.bodySmall).lineLimit(1)
                Text("\(countText(model.activeStreams)) streams · \(countText(model.requestsWaiting)) requests")
                    .widgetText(.bodySmall).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("Open Bloem Admin to add a server").widgetText(.bodySmall)
        }
    }
}

private struct InlineLayout: View {
    let model: ServerStatusModel

    var body: some View {
        if !model.hasServers {
            Text("Bloem Admin")
        } else if model.status.isFailure {
            ViewThatFits {
                Text("\(model.title): \(model.status.text)")
                Text(verbatim: model.status.text)
            }
        } else {
            // The longest that fits: the lock screen's inline line is short.
            ViewThatFits {
                Text("\(model.title): \(countText(model.activeStreams)) streams, \(countText(model.requestsWaiting)) requests")
                Text("\(countText(model.activeStreams)) streams, \(countText(model.requestsWaiting)) requests")
                Text("\(countText(model.activeStreams)) streams")
            }
        }
    }
}
