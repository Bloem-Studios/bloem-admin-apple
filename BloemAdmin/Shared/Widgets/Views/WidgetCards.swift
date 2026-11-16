import SwiftUI
import WidgetKit

// The building blocks of the card layouts: the card itself (the app's `card` surface on its `canvas`, a hairline
// edge, radius 12, which is what a row looks like on the Now playing, Requests, Nodes and Libraries pages),
// the list that fills a widget with whole cards by `WidgetListPlanner`, the footer of totals, and the quiet
// card that says why there is nothing to show.

extension WidgetLayout {
    /// The text size relative to the default, from the same curve the type styles scale along.
    static func typeScale(_ size: DynamicTypeSize) -> CGFloat {
        BloemFont.uiFont(.bodySmall, category: size.contentSizeCategory).pointSize / BloemTextStyle.bodySmall.size
    }
}

/// A card: a row of one of the app's lists, in small.
struct WidgetCard<Content: View>: View {
    var padding = EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
    @ViewBuilder let content: () -> Content
    @Environment(\.widgetPalette) private var palette
    @Environment(\.widgetRenderingMode) private var renderingMode

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: WidgetLayout.cardRadius, style: .continuous) }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            // On a tinted Home Screen the system recolours everything; a faint plate keeps the cards apart.
            .background(renderingMode == .fullColor ? palette.card : Color.white.opacity(0.12), in: shape)
            .overlay(shape.strokeBorder(palette.hairline, lineWidth: 1))
    }
}

/// A dot and its word, in the status colours: a status is a small dot plus a word.
struct WidgetDotLabel: View {
    let color: Color
    let text: String
    var textColor: Color?
    var style: BloemTextStyle = .labelSmall
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(verbatim: text).widgetText(style).foregroundStyle(textColor ?? palette.muted).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One figure of a footer: a number and what it counts.
struct WidgetStat: Identifiable {
    let id: String
    let value: String
    let label: String
    var isLive = false
}

/// The footer of totals: one line where there is little room, a card of the figures where there is more.
struct WidgetFooterView: View {
    let kind: WidgetFooter
    let stats: [WidgetStat]
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        switch kind {
        case .none:
            EmptyView()
        case .line:
            Text(verbatim: stats.map { "\($0.value) \($0.label)" }.joined(separator: " · "))
                .widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: WidgetLayout.lineFooterHeight, alignment: .leading)
                .padding(.horizontal, 4)
        case .stats:
            WidgetCard(padding: EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12)) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                if stat.isLive { WidgetTallyDot() }
                                Text(verbatim: stat.value).widgetText(.titleLarge).foregroundStyle(palette.text)
                                    .minimumScaleFactor(0.7).lineLimit(1)
                            }
                            Text(verbatim: stat.label).widgetText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(height: WidgetLayout.statsFooterHeight)
        }
    }
}

/// What a widget draws when it has nothing to list: its header, and one calm card that says why.
struct WidgetStateCard: View {
    let icon: WidgetIcon
    let title: LocalizedStringKey
    var trailing: String?
    /// The count beside the title, when there is one to give ("No streams").
    var tally: String?
    var showsTallyDot = true
    var keepsTallyWord = false
    let phase: BoardPhase
    let thing: String
    let emptyText: String
    let unavailableText: String
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: icon, title: title, tally: tally, showsTallyDot: showsTallyDot, keepsTallyWord: keepsTallyWord, trailing: trailing)
            WidgetCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)) {
                WidgetMessage(phase: phase, thing: thing, emptyText: emptyText, unavailableText: unavailableText)
            }
        }
    }
}

/// The room one card has, and which tier of the design it is drawn in.
struct WidgetCardSlot: Equatable, Sendable {
    let tierIndex: Int
    let height: CGFloat
    let width: CGFloat
}

/// A list that fills its widget with whole cards: the header, the cards in one or two columns, a footer of
/// totals where the height allows, and a line at the bottom for what is old or could not be reached.
struct WidgetListLayout<Row: Identifiable & Sendable, Header: View, Card: View, Footer: View, Bottom: View>: View {
    let rows: [Row]
    let tiers: [WidgetCardTier]
    let maxColumns: Int
    /// The height the bottom view needs, 0 for none.
    let reserved: CGFloat
    let wantsFooter: Bool
    /// False when the caller draws the header itself, above this list.
    let hasHeader: Bool
    /// A paged list (Now playing): the page to draw and the key its buttons write it under. With no key the list
    /// has one page and no buttons.
    let page: Int
    let pagerKey: String?
    let header: () -> Header
    let card: (Row, WidgetCardSlot) -> Card
    let footer: (WidgetFooter, WidgetListPlan) -> Footer
    let bottom: () -> Bottom
    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        rows: [Row], tiers: [WidgetCardTier], maxColumns: Int = 1, reserved: CGFloat = 0, wantsFooter: Bool = true,
        hasHeader: Bool = true, page: Int = 0, pagerKey: String? = nil,
        @ViewBuilder header: @escaping () -> Header,
        @ViewBuilder card: @escaping (Row, WidgetCardSlot) -> Card,
        @ViewBuilder footer: @escaping (WidgetFooter, WidgetListPlan) -> Footer,
        @ViewBuilder bottom: @escaping () -> Bottom
    ) {
        self.rows = rows
        self.tiers = tiers
        self.maxColumns = maxColumns
        self.reserved = reserved
        self.wantsFooter = wantsFooter
        self.hasHeader = hasHeader
        self.page = page
        self.pagerKey = pagerKey
        self.header = header
        self.card = card
        self.footer = footer
        self.bottom = bottom
    }

    var body: some View {
        GeometryReader { proxy in
            let plan = WidgetListPlanner.plan(
                size: proxy.size, rows: rows.count, tiers: tiers, typeScale: WidgetLayout.typeScale(typeSize),
                maxColumns: maxColumns, reserved: reserved, wantsFooter: wantsFooter, hasHeader: hasHeader,
                page: page, pageable: pagerKey != nil
            )
            VStack(alignment: .leading, spacing: WidgetLayout.gap) {
                if plan.showsHeader {
                    // The buttons sit in the header, so paging costs no height: the header reads the pager from here.
                    header().environment(\.widgetPager, pagerKey.flatMap { WidgetPagerState(key: $0, plan: plan) })
                }
                grid(plan)
                if plan.footer != .none { footer(plan.footer, plan) }
                Spacer(minLength: 0)
                if reserved > 0 { bottom() }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    private func grid(_ plan: WidgetListPlan) -> some View {
        let shown = Array(rows.dropFirst(plan.pageStart).prefix(plan.shown))
        let slot = WidgetCardSlot(tierIndex: plan.tierIndex, height: plan.cardHeight, width: plan.columnWidth)
        return HStack(alignment: .top, spacing: WidgetLayout.gap) {
            ForEach(0..<plan.columns, id: \.self) { column in
                VStack(spacing: WidgetLayout.gap) {
                    ForEach(shown.enumerated().filter { $0.offset % plan.columns == column }.map(\.element)) { row in
                        card(row, slot).frame(height: plan.cardHeight)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

extension WidgetListLayout where Bottom == EmptyView {
    init(
        rows: [Row], tiers: [WidgetCardTier], maxColumns: Int = 1, wantsFooter: Bool = true, hasHeader: Bool = true,
        page: Int = 0, pagerKey: String? = nil,
        @ViewBuilder header: @escaping () -> Header, @ViewBuilder card: @escaping (Row, WidgetCardSlot) -> Card,
        @ViewBuilder footer: @escaping (WidgetFooter, WidgetListPlan) -> Footer
    ) {
        self.init(
            rows: rows, tiers: tiers, maxColumns: maxColumns, reserved: 0, wantsFooter: wantsFooter, hasHeader: hasHeader,
            page: page, pagerKey: pagerKey,
            header: header, card: card, footer: footer, bottom: { EmptyView() }
        )
    }
}

/// The height the "Updated 14:32" and "Can't reach" lines need under the cards.
func widgetFreshnessHeight(_ state: BoardState, notice: Bool = false) -> CGFloat {
    var lines = 0
    if notice { lines = 1 } else {
        if !state.unreachableNames.isEmpty { lines += 1 }
        if state.updatedAt != nil { lines += 1 }
    }
    return CGFloat(lines) * WidgetLayout.freshnessLine
}
