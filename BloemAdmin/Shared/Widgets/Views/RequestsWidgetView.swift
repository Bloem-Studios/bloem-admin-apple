import AppIntents
import SwiftUI
import WidgetKit

struct RequestsFigures: Equatable, Sendable {
    var pending: Int
    var rows: [RequestItem]

    init(board: WidgetBoard<RequestItem>) {
        rows = board.items.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        pending = board.total ?? board.items.count
    }

    /// The rows a surface may draw: none where details are hidden.
    func visibleRows(_ context: WidgetContext) -> [RequestItem] {
        context.showsDetails ? rows : []
    }

    var pendingText: String { String(localized: "\(pending) waiting") }

    /// Whether any request is listed at all, whatever a surface may draw of it.
    var hasRows: Bool { !rows.isEmpty }

    /// How long the oldest listed request has waited: "3h". Counts only, so it is allowed on every surface.
    func oldestAge(now: Date) -> String? {
        WidgetTime.age(from: rows.compactMap(\.createdAt).min(), now: now)
    }

    /// The figures of the footer.
    func stats(now: Date, more: Int = 0) -> [WidgetStat] {
        var result = [WidgetStat(id: "waiting", value: String(pending), label: String(localized: "waiting"))]
        if let oldest = oldestAge(now: now) { result.append(WidgetStat(id: "oldest", value: oldest, label: String(localized: "oldest"))) }
        if more > 0 { result.append(WidgetStat(id: "more", value: "+\(more)", label: String(localized: "more"))) }
        return result
    }
}

/// How much of a request card is drawn; the buttons say their words where the card is wide enough.
enum RequestsTier: Int, CaseIterable, Sendable {
    case roomy, compact

    static let tiers: [WidgetCardTier] = [
        WidgetCardTier(height: 64, minWidth: 300),
        WidgetCardTier(height: 52, minWidth: 0),
    ]
}

struct RequestsWidgetView: View {
    let board: WidgetBoard<RequestItem>
    let notice: WidgetActionNotice?
    let context: WidgetContext
    @Environment(\.widgetPalette) private var palette

    private var state: BoardState { board.state(now: context.now) }
    private var figures: RequestsFigures { RequestsFigures(board: board) }
    private var link: URL { WidgetLink.page(DeepLinkPage.requests, serverID: board.serverID) }
    private var hasContent: Bool { state.phase == .content || state.phase == .empty }
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
                WidgetIconView(icon: hasContent ? .inbox : .warning, size: 16)
                Text(verbatim: hasContent ? String(figures.pending) : "–").widgetText(.titleLarge)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Requests")
        .accessibilityValue(figures.pendingText)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetRectangularTitle(title: "Requests")
            if hasContent {
                Text(verbatim: figures.pending == 0 ? String(localized: "No requests waiting") : figures.pendingText)
                    .widgetText(.bodySmall).lineLimit(1)
                if let first = figures.visibleRows(context).first {
                    Text(verbatim: first.title).widgetText(.bodySmall).lineLimit(1).widgetDetail(context)
                    Text(verbatim: meta(first)).widgetText(.labelSmall).lineLimit(1).widgetDetail(context)
                } else if let oldest = figures.oldestAge(now: context.now), figures.pending > 0 {
                    Text("Oldest \(oldest)").widgetText(.bodySmall).lineLimit(1)
                }
            } else if case .unreachable(let name) = state.phase {
                Text("Can't reach \(name)").widgetText(.bodySmall).lineLimit(2)
            } else if state.phase == .signedOut {
                Text("Sign in to see requests").widgetText(.bodySmall).lineLimit(2)
            } else {
                Text("Requests aren't available").widgetText(.bodySmall).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Group {
            if hasContent {
                Text(verbatim: figures.pending == 0 ? String(localized: "No requests waiting") : String(localized: "\(figures.pending) requests waiting"))
            } else {
                Text("Requests")
            }
        }
    }

    // MARK: Home screen

    /// "Maya · 10m", with the server's name where several are shown.
    private func meta(_ row: RequestItem) -> String {
        let who = row.requester ?? String(localized: "Unknown account")
        let age = WidgetTime.age(from: row.createdAt, now: context.now)
        return [who, age, board.feeds.count > 1 ? row.serverName : nil].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private var home: some View {
        if state.phase == .content {
            if context.size == .small {
                small
            } else if context.showsDetails, figures.hasRows {
                list
            } else {
                countsOnly
            }
        } else {
            WidgetStateCard(
                icon: .inbox, title: "Requests", trailing: state.phase == .empty ? serverName : nil, phase: state.phase,
                thing: String(localized: "requests"), emptyText: String(localized: "No requests waiting"),
                unavailableText: String(localized: "Requests aren't available on this server")
            )
        }
    }

    /// Small: the count, as the one figure that matters, and the newest request under it.
    private var small: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .inbox, title: "Requests", compact: true)
            Spacer(minLength: 0)
            BigFigure(value: String(figures.pending), caption: String(localized: "waiting"), isAccent: figures.pending > 0)
            if let first = figures.visibleRows(context).first {
                VStack(alignment: .leading, spacing: 0) {
                    Text(verbatim: first.title).widgetText(.labelMedium).foregroundStyle(palette.text)
                        .lineLimit(state.updatedAt == nil && notice == nil ? 2 : 1).widgetDetail(context)
                    Text(verbatim: meta(first)).widgetText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1).widgetDetail(context)
                }
            }
            FreshnessLine(state: state, notice: notice?.text)
        }
    }

    private var list: some View {
        let values = figures
        return WidgetListLayout(
            rows: values.visibleRows(context), tiers: RequestsTier.tiers,
            maxColumns: context.size == .extraLarge ? 2 : 1, reserved: widgetFreshnessHeight(state, notice: notice != nil),
            header: {
                WidgetHeader(
                    icon: .inbox, title: "Requests", tally: values.pending > 0 ? String(localized: "\(values.pending) waiting") : nil,
                    trailing: serverName
                )
            },
            card: { row, slot in
                WidgetRequestCard(row: row, context: context, tier: RequestsTier(rawValue: slot.tierIndex) ?? .compact, width: slot.width, showsServer: board.feeds.count > 1)
            },
            footer: { kind, plan in WidgetFooterView(kind: kind, stats: values.stats(now: context.now, more: plan.more)) },
            bottom: { FreshnessLine(state: state, notice: notice?.text) }
        )
    }

    /// StandBy, Always On, or a count with no rows to list: the count and how long the oldest has waited.
    private var countsOnly: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .inbox, title: "Requests", tally: figures.pending > 0 ? String(localized: "\(figures.pending) waiting") : nil, trailing: serverName)
            WidgetFooterView(kind: .stats, stats: figures.stats(now: context.now))
            Spacer(minLength: 0)
            FreshnessLine(state: state, notice: notice?.text)
        }
    }
}

/// One waiting request, as the app's request card: the title, who asked and how long ago, with Decline and
/// Approve. Tapping the text opens that request on its server's request queue; the buttons are App Intents that
/// need the phone unlocked.
struct WidgetRequestCard: View {
    let row: RequestItem
    let context: WidgetContext
    let tier: RequestsTier
    let width: CGFloat
    var showsServer = false
    @Environment(\.widgetPalette) private var palette

    private var meta: String {
        let who = row.requester ?? String(localized: "Unknown account")
        let age = WidgetTime.age(from: row.createdAt, now: context.now)
        return [who, age, showsServer ? row.serverName : nil].compactMap { $0 }.joined(separator: " · ")
    }

    /// The buttons say Decline and Approve where the card is wide enough; otherwise they are the icons.
    private var wide: Bool { width >= 300 }

    var body: some View {
        WidgetCard {
            HStack(spacing: 8) {
                Link(destination: WidgetLink.item(row.id, on: DeepLinkPage.requests, serverID: row.serverID)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: row.title).widgetText(tier == .roomy ? .titleSmall : .labelMedium)
                            .foregroundStyle(palette.text).lineLimit(1).widgetDetail(context)
                        Text(verbatim: meta).widgetText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1).widgetDetail(context)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button(intent: DeclineRequestIntent(serverID: row.serverID, requestID: row.id)) {
                    RequestActionLabel(kind: .decline, wide: wide)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Decline")
                Button(intent: ApproveRequestIntent(serverID: row.serverID, requestID: row.id)) {
                    RequestActionLabel(kind: .approve, wide: wide)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Approve")
            }
        }
    }
}

/// Decline is a `raised` button, Approve an accent outline: the accent is the one action a request offers.
private struct RequestActionLabel: View {
    enum Kind { case approve, decline }

    let kind: Kind
    let wide: Bool
    @Environment(\.widgetPalette) private var palette

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        Group {
            if wide {
                Text(kind == .approve ? "Approve" : "Decline").widgetText(.labelMedium).lineLimit(1)
            } else {
                WidgetIconView(icon: kind == .approve ? .check : .x, size: 18)
            }
        }
        .foregroundStyle(kind == .approve ? palette.accent : palette.text)
        .padding(.horizontal, wide ? 12 : 0)
        .frame(minWidth: wide ? 0 : 40, minHeight: 32)
        .background(kind == .decline ? palette.raised : Color.clear, in: shape)
        .overlay {
            if kind == .approve { shape.strokeBorder(palette.accent, lineWidth: 1) }
        }
    }
}
