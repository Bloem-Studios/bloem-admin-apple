import SwiftUI
import WidgetKit

/// The numbers a Now playing layout draws, from the board. A stream that should have ended by `now` is left
/// out until the next reading says otherwise. `redacted` leaves the counts only.
struct NowPlayingFigures: Equatable, Sendable {
    var total: Int
    var transcodes: Int
    var bandwidthKbps: Int
    var rows: [StreamItem]

    init(board: WidgetBoard<StreamItem>, now: Date? = nil) {
        let all = board.items
        let live = now.map { date in all.filter { !$0.isOver(at: date) } } ?? all
        let over = all.filter { item in !live.contains { $0.id == item.id && $0.serverID == item.serverID } }
        rows = live
        total = max(0, (board.total ?? all.count) - over.count)
        transcodes = live.filter { $0.methodKind == .transcode }.count
        let overKbps = over.compactMap(\.bitrateKbps).reduce(0, +)
        bandwidthKbps = board.secondaryTotal.map { max(0, $0 - overKbps) } ?? live.compactMap(\.bitrateKbps).reduce(0, +)
    }

    /// "65.5": the bandwidth in Mbps, with one decimal at most.
    var bandwidthValue: String? {
        guard bandwidthKbps > 0 else { return nil }
        return (Double(bandwidthKbps) / 1000).formatted(.number.precision(.fractionLength(0...1)))
    }

    var bandwidthText: String? {
        bandwidthValue.map { String(localized: "\($0) Mbps") }
    }

    /// The rows a surface may draw: none where details are hidden, so no name or title reaches the view.
    func visibleRows(_ context: WidgetContext) -> [StreamItem] {
        context.showsDetails ? rows : []
    }

    /// "3 streams", "1 stream", "No streams": the count the header always shows. The plural is the catalog's
    /// (`%lld streams`, one and other), so it follows each language's own rule.
    var streamsText: String { Self.streamsText(total) }

    static func streamsText(_ count: Int) -> String {
        count <= 0 ? String(localized: "No streams") : String(localized: "\(count) streams")
    }

    /// The noun under the figure: "streams", "stream".
    var streamsNoun: String { total == 1 ? String(localized: "stream") : String(localized: "streams") }

    /// The figures of the footer: streams (live while any plays), transcoding and bandwidth.
    var stats: [WidgetStat] {
        var result = [WidgetStat(id: "streams", value: String(total), label: streamsNoun, isLive: total > 0)]
        result.append(WidgetStat(id: "transcoding", value: String(transcodes), label: String(localized: "transcoding")))
        if let bandwidthValue { result.append(WidgetStat(id: "bandwidth", value: bandwidthValue, label: String(localized: "Mbps"))) }
        return result
    }
}

/// Which design of a session card is drawn. The card is the app's own session card (`StreamRowView`) in small:
/// a title, who and how it plays, how far, and its state. More room adds more of the app's card.
enum NowPlayingTier: Int, CaseIterable, Sendable {
    /// The app's whole card: the Source to Playback to Client path, with the transcode detail.
    case full
    /// Title and state, who, the method with the client, the bar, then the time and the bitrate.
    case roomy
    /// Title and state, who and the method, then the time and the bitrate, with the bar as the card's lower edge.
    case compact

    /// Richest first, as `WidgetListPlanner` wants them.
    static let tiers: [WidgetCardTier] = [
        WidgetCardTier(height: 140, minWidth: 300),
        WidgetCardTier(height: 95, minWidth: 220),
        WidgetCardTier(height: 58, minWidth: 0),
    ]
}

struct NowPlayingWidgetView: View {
    let board: WidgetBoard<StreamItem>
    let context: WidgetContext
    /// The page the person left the list on (`WidgetPagingState`); the first page when there is none.
    var paging = WidgetPagingState()
    @Environment(\.widgetPalette) private var palette

    private var state: BoardState { board.state(now: context.now) }
    private var figures: NowPlayingFigures { NowPlayingFigures(board: board, now: context.now) }

    /// The board's phase, with "Nothing playing" once every stream it knew of should have ended.
    private var phase: BoardPhase {
        state.phase == .content && figures.total == 0 ? .empty : state.phase
    }
    private var hasContent: Bool { phase == .content }

    /// The key the page buttons write this widget's page under: the server choice and the size.
    private var pagingKey: String { WidgetPagingKey.nowPlaying(serverID: board.serverID, size: context.size) }

    private var link: URL { WidgetLink.page(DeepLinkPage.nowPlaying, serverID: board.serverID) }

    /// The server's name where one server is shown, "All servers" otherwise.
    private var serverName: String { board.feeds.count == 1 ? board.feeds[0].serverName : board.title }

    var body: some View {
        Group {
            switch context.size {
            case .circular: circular
            case .rectangular: rectangular
            case .inline: inline
            default: home
            }
        }
        .widgetURL(link)
    }

    // MARK: Lock screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                WidgetIconView(icon: state.phase == .content || state.phase == .empty ? .radio : .warning, size: 16)
                Text(verbatim: state.phase == .content || state.phase == .empty ? String(figures.total) : "–")
                    .widgetText(.titleLarge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Now playing")
        .accessibilityValue(figures.streamsText)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetRectangularTitle(title: "Now playing")
            switch state.phase {
            case .content, .empty:
                Text(verbatim: figures.total == 0 ? String(localized: "Nothing playing") : lockLine)
                    .widgetText(.bodySmall).lineLimit(1)
                if let first = figures.visibleRows(context).first {
                    Text(verbatim: first.title).widgetText(.bodySmall).lineLimit(1).widgetDetail(context)
                    WidgetStreamBar(item: first, now: context.now, height: 3).widgetDetail(context)
                }
            case .signedOut: Text("Sign in to see now playing").widgetText(.bodySmall).lineLimit(2)
            case .unreachable(let name): Text("Can't reach \(name)").widgetText(.bodySmall).lineLimit(2)
            case .unavailable: Text("Not available on this server").widgetText(.bodySmall).lineLimit(2)
            case .noServers: Text("Add a Silo server").widgetText(.bodySmall)
            case .loading: Text("Loading").widgetText(.bodySmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lockLine: String {
        figures.transcodes > 0
            ? String(localized: "\(figures.streamsText) · \(figures.transcodes) transcoding")
            : figures.streamsText
    }

    @ViewBuilder
    private var inline: some View {
        switch state.phase {
        case .content, .empty:
            Text(verbatim: figures.total == 0 ? String(localized: "Nothing playing") : String(localized: "\(figures.streamsText) playing"))
        case .signedOut: Text("Sign in to see now playing")
        case .unreachable(let name): Text("Can't reach \(name)")
        default: Text("Now playing")
        }
    }

    // MARK: Home screen

    @ViewBuilder
    private var home: some View {
        if hasContent {
            if context.size == .small {
                small
            } else if context.showsDetails {
                list
            } else {
                countsOnly
            }
        } else {
            WidgetStateCard(
                icon: .radio, title: "Now playing", trailing: phase == .empty ? serverName : nil,
                tally: phase == .empty ? figures.streamsText : nil, showsTallyDot: false, keepsTallyWord: true, phase: phase,
                thing: String(localized: "now playing"), emptyText: String(localized: "Nothing playing"),
                unavailableText: String(localized: "Now playing isn't available on this server")
            )
        }
    }

    /// Small: what is live, the count, and the top stream with its bar.
    private var small: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .radio, title: "Now playing", tally: figures.streamsText, showsTallyDot: figures.total > 0, compact: true)
            Spacer(minLength: 0)
            BigFigure(value: String(figures.total), caption: figures.streamsNoun, isLive: false)
            if let top = figures.visibleRows(context).first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: top.title).widgetText(.labelMedium).foregroundStyle(palette.text)
                        .lineLimit(state.updatedAt == nil ? 2 : 1)
                        .widgetDetail(context)
                    WidgetStreamBar(item: top, now: context.now).widgetDetail(context)
                }
            } else if figures.transcodes > 0 {
                Text("\(figures.transcodes) transcoding").widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
            }
            FreshnessLine(state: state)
        }
    }

    /// Medium, large and extra large: whole session cards, as many as fit, richer as the widget gets bigger.
    private var list: some View {
        let values = figures
        return WidgetListLayout(
            rows: values.visibleRows(context), tiers: NowPlayingTier.tiers,
            maxColumns: context.size == .extraLarge ? 2 : 1, reserved: widgetFreshnessHeight(state),
            page: paging.page(for: pagingKey, now: context.now), pagerKey: pagingKey,
            header: {
                WidgetHeader(
                    icon: .radio, title: "Now playing", tally: values.streamsText, showsTallyDot: values.total > 0,
                    keepsTallyWord: true, trailing: serverName
                )
            },
            card: { row, slot in
                WidgetStreamCard(
                    item: row, context: context, tier: NowPlayingTier(rawValue: slot.tierIndex) ?? .compact,
                    showsServer: board.feeds.count > 1
                )
            },
            footer: { kind, _ in WidgetFooterView(kind: kind, stats: values.stats) },
            bottom: { FreshnessLine(state: state) }
        )
    }

    /// StandBy and Always On: counts and statuses only, no titles and no names.
    private var countsOnly: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .radio, title: "Now playing", tally: figures.streamsText, showsTallyDot: figures.total > 0, keepsTallyWord: true, trailing: serverName)
            WidgetFooterView(kind: .stats, stats: figures.stats)
            Spacer(minLength: 0)
            FreshnessLine(state: state)
        }
    }
}

// MARK: The card

/// One stream, as the app's session card says it: the title, then "user · profile", the playback method with
/// its dot, how far with the time and the bitrate, and Playing or Paused. Each card opens the stream's server.
struct WidgetStreamCard: View {
    let item: StreamItem
    let context: WidgetContext
    let tier: NowPlayingTier
    var showsServer = false
    @Environment(\.widgetPalette) private var palette

    private var method: StreamMethodKind { item.methodKind }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: WidgetLayout.cardRadius, style: .continuous) }

    var body: some View {
        Link(destination: WidgetLink.page(DeepLinkPage.nowPlaying, serverID: item.serverID)) {
            WidgetCard(padding: EdgeInsets(top: tier == .compact ? 6 : 8, leading: 10, bottom: tier == .compact ? 6 : 8, trailing: 10)) {
                VStack(alignment: .leading, spacing: 2) {
                    titleLine
                    whoLine
                    switch tier {
                    case .compact:
                        timeLine
                    case .roomy:
                        methodLine
                        Spacer(minLength: 3)
                        WidgetStreamBar(item: item, now: context.now).widgetDetail(context)
                        timeLine
                    case .full:
                        Spacer(minLength: 4)
                        path
                        Spacer(minLength: 4)
                        WidgetStreamBar(item: item, now: context.now).widgetDetail(context)
                        timeLine
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if tier == .compact {
                    WidgetStreamBar(item: item, now: context.now, height: 3, flush: true).widgetDetail(context)
                }
            }
            .clipShape(shape)
        }
        .accessibilityElement(children: .combine)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: item.title).widgetText(tier == .compact ? .labelMedium : .titleSmall)
                .foregroundStyle(palette.text).lineLimit(1).widgetDetail(context)
            Spacer(minLength: 4)
            status
        }
    }

    /// Playing is live, the orange tally dot; Paused is the one that needs a look, in amber.
    private var status: some View {
        item.isPaused
            ? WidgetDotLabel(color: palette.warning, text: String(localized: "Paused"), textColor: palette.warning)
            : WidgetDotLabel(color: palette.tally, text: String(localized: "Playing"))
    }

    private var whoLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: showsServer ? "\(item.userLine) · \(item.serverName)" : item.userLine)
                .widgetText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1).widgetDetail(context)
            Spacer(minLength: 4)
            if tier == .compact, method != .unknown {
                WidgetDotLabel(color: palette.methodColor(method), text: method.label, textColor: palette.text)
            }
        }
    }

    /// The method with its dot, then what the transcode converts to, or the player and device.
    private var methodLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if method != .unknown {
                WidgetDotLabel(color: palette.methodColor(method), text: method.label, textColor: palette.text, style: .labelMedium)
                    .fixedSize()
            }
            if let extra = item.transcodeDetail ?? item.clientLine {
                Text(verbatim: extra).widgetText(.bodySmall).foregroundStyle(method.isLit ? palette.warning : palette.muted)
                    .lineLimit(1).widgetDetail(context)
            }
        }
    }

    /// "1:12:10 / 2:46:00" and "38.4 Mbps", in tabular figures.
    private var timeLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WidgetStreamClock(item: item, now: context.now).widgetDetail(context)
            Spacer(minLength: 4)
            if let bitrate = StreamFormat.bitrate(item.bitrateKbps) {
                Text(verbatim: bitrate).widgetText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
            }
        }
    }

    // MARK: The signal path

    /// Source to Playback to Client, as on the Now playing page. Only a transcode is lit: its step sits on
    /// `raised`, in amber, and names what it converts to.
    private var path: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                step(label: String(localized: "Source"), value: item.source ?? String(localized: "Unknown"), dot: nil, lit: false)
                arrow(lit: method.isLit)
                step(label: String(localized: "Playback"), value: method.label, dot: palette.methodColor(method), lit: method.isLit)
                arrow(lit: method.isLit)
                step(label: String(localized: "Client"), value: item.clientLine ?? String(localized: "Unknown client"), dot: nil, lit: false)
            }
            if method.isLit, let detail = item.transcodeDetail {
                Text(verbatim: detail).widgetText(.labelSmall).foregroundStyle(palette.warning).lineLimit(1).widgetDetail(context)
            }
        }
    }

    private func step(label: String, value: String, dot: Color?, lit: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: label).widgetText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let dot { Circle().fill(dot).frame(width: 8, height: 8).accessibilityHidden(true) }
                Text(verbatim: value).widgetText(.labelMedium).foregroundStyle(lit ? palette.warning : palette.text)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).widgetDetail(context)
            }
        }
        .padding(lit ? 4 : 0)
        .background(lit ? palette.raised : Color.clear, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func arrow(lit: Bool) -> some View {
        WidgetIconView(icon: .arrowRight, size: 12)
            .foregroundStyle(lit ? palette.warning : palette.muted)
            .padding(.top, 14)
    }
}

// MARK: Progress

/// How far into the file a stream is. While it plays and the reading is fresh, the system moves the bar by
/// itself (`ProgressView(timerInterval:)`), so progress advances between readings with no request. Paused,
/// stale or unknown it is a still bar, in amber while paused.
struct WidgetStreamBar: View {
    let item: StreamItem
    let now: Date
    var height: CGFloat = 4
    /// The card's lower edge: edge to edge, no rounding.
    var flush = false
    @Environment(\.widgetPalette) private var palette
    @Environment(\.siloStaticTime) private var isStatic

    var body: some View {
        if !isStatic, item.isMoving(at: now), let start = item.playbackStart, let length = item.length {
            ProgressView(timerInterval: start...start.addingTimeInterval(length), countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.linear)
            .tint(palette.muted)
            .frame(height: height)
            .accessibilityHidden(true)
        } else if let fraction = item.fraction(at: now) {
            ProgressBar(fraction: fraction, height: height, paused: item.isPaused)
                .clipShape(RoundedRectangle(cornerRadius: flush ? 0 : height / 2))
        }
    }
}

/// "1:12:10 / 2:46:00". The elapsed part is a timer the system runs while the stream plays; the total is still.
struct WidgetStreamClock: View {
    let item: StreamItem
    let now: Date
    @Environment(\.widgetPalette) private var palette
    @Environment(\.siloStaticTime) private var isStatic

    var body: some View {
        HStack(spacing: 0) {
            elapsed
            if let length = item.length {
                Text(verbatim: " / \(StreamFormat.playbackClock(length))")
            }
        }
        .widgetText(.labelSmall)
        .foregroundStyle(palette.muted)
        .lineLimit(1)
    }

    @ViewBuilder
    private var elapsed: some View {
        let position = item.position(at: now) ?? 0
        let still = Text(verbatim: StreamFormat.playbackClock(position))
        if !isStatic, item.isMoving(at: now), let start = item.playbackStart, let length = item.length {
            // The still text sizes the slot; the system's timer draws over it.
            still.hidden().overlay(alignment: .leading) {
                Text(timerInterval: start...start.addingTimeInterval(length), pauseTime: nil, countsDown: false, showsHours: position >= 3600)
                    .lineLimit(1)
            }
        } else {
            still
        }
    }
}
