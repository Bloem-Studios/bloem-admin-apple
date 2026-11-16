import CoreGraphics
import Foundation

// One rule that turns a widget's size into a layout, for every list widget (Now playing, Requests, Libraries,
// Nodes, Server status). iOS widgets come in fixed families, so the rule is written for their sizes, and it
// also copes with a larger text size:
//  - the number of cards follows the height: as many whole cards as fit, in the richest design that still shows
//    a few of them;
//  - the detail in a card follows the width (the tiers' `minWidth`);
//  - a wide widget (iPad extra large) uses two columns;
//  - whatever height is left after whole cards goes to the cards (each grows a little) and then to a footer of
//    totals, so there is no empty band, and no text is cut off because a card is never drawn shorter than its tier.
// It is the same plan as the Android widgets' (`NowPlayingPlan.kt`), in the same words. Plain values, so every
// size is tested without WidgetKit.

enum WidgetLayout {
    /// The widget's own padding: the app's page edge in small.
    static let pageInset: CGFloat = 8
    static let gap: CGFloat = 6
    static let headerHeight: CGFloat = 24
    static let cardRadius: CGFloat = 12
    static let lineFooterHeight: CGFloat = 18
    static let statsFooterHeight: CGFloat = 64
    /// The most a card grows to use up the height that is left; beyond it the footer takes the room.
    static let maxStretch: CGFloat = 16
    /// From this width (the iPad's extra large widget) the list has two columns.
    static let twoColumnsFrom: CGFloat = 600
    /// A line under the cards: "Updated 14:32" or "Can't reach <server>".
    static let freshnessLine: CGFloat = 16

    /// A card is nearly all text, so nearly all of it grows with the person's text size.
    static func scaled(_ points: CGFloat, by typeScale: CGFloat) -> CGFloat {
        points * (1 + 0.85 * (max(typeScale, 0.9) - 1))
    }
}

/// How much of one card a design draws. Tiers are listed richest first, and the last one has `minWidth` 0.
struct WidgetCardTier: Equatable, Sendable {
    /// At the default text size.
    let height: CGFloat
    /// The narrowest card that shows this tier without cutting text.
    let minWidth: CGFloat
}

/// What sits under the cards: nothing, one line of totals, or a card of the figures.
enum WidgetFooter: Equatable, Sendable {
    case none, line, stats
}

struct WidgetListPlan: Equatable, Sendable {
    var showsHeader: Bool
    /// Which of the tiers passed in is drawn.
    var tierIndex: Int
    var columns: Int
    /// Cards drawn, across all columns.
    var visible: Int
    var rowsPerColumn: Int
    var columnWidth: CGFloat
    /// The tier's height, plus what was left over, so the cards fill the height.
    var cardHeight: CGFloat
    var footer: WidgetFooter
    /// Rows after this page: the ones that are not drawn and come later.
    var more: Int
    /// The page drawn, from 0, and how many pages the rows make. A list that is not paged is always page 0.
    var page = 0
    var pageCount = 1
    /// Index of the first row of this page, and how many rows this page draws (the last page can have fewer).
    var pageStart = 0
    var shown = 0

    var hasPreviousPage: Bool { page > 0 }
    var hasNextPage: Bool { page < pageCount - 1 }
}

enum WidgetListPlanner {
    /// `size` is the room the layout has: the widget less its padding. `reserved` is height already spoken for
    /// at the bottom (the "Updated 14:32" line). `typeScale` is the text size relative to the default.
    static func plan(
        size: CGSize, rows: Int, tiers: [WidgetCardTier], typeScale: CGFloat = 1,
        maxColumns: Int = 1, reserved: CGFloat = 0, wantsFooter: Bool = true, hasHeader: Bool = true,
        page: Int = 0, pageable: Bool = false
    ) -> WidgetListPlan {
        let gap = WidgetLayout.gap
        let columns = maxColumns >= 2 && size.width >= WidgetLayout.twoColumnsFrom ? 2 : 1
        let columnWidth = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let showsHeader = hasHeader && size.height >= 96
        let headerBlock = showsHeader ? WidgetLayout.scaled(WidgetLayout.headerHeight, by: typeScale) + gap : 0
        let reservedBlock = reserved > 0 ? reserved + gap : 0
        let available = max(0, size.height - headerBlock - reservedBlock)

        // How many cards the person should see at least: one, two, then three, as the widget gets taller.
        let wantedTotal: Int = {
            guard rows > 0 else { return 0 }
            if size.height >= 200 { return min(rows, 3) }
            if size.height >= 120 { return min(rows, 2) }
            return 1
        }()

        func height(_ tier: WidgetCardTier) -> CGFloat { WidgetLayout.scaled(tier.height, by: typeScale) }
        func fit(_ tier: WidgetCardTier) -> Int {
            max(0, Int(((available + gap) / (height(tier) + gap)).rounded(.down))) * columns
        }

        let allowed = tiers.indices.filter { columnWidth >= tiers[$0].minWidth }
        let chosen = allowed.first { fit(tiers[$0]) >= wantedTotal } ?? allowed.last ?? max(0, tiers.count - 1)
        let tier = tiers[chosen]

        let visible = rows == 0 ? 0 : max(1, min(rows, fit(tier)))
        let perColumn = visible == 0 ? 0 : (visible + columns - 1) / columns
        let base = height(tier)
        let used = perColumn == 0 ? 0 : CGFloat(perColumn) * base + CGFloat(perColumn - 1) * gap
        let leftover = max(0, available - used)

        let tall = size.height >= 200 && rows > 0 && wantsFooter
        let statsHeight = WidgetLayout.scaled(WidgetLayout.statsFooterHeight, by: typeScale)
        let lineHeight = WidgetLayout.scaled(WidgetLayout.lineFooterHeight, by: typeScale)
        let footer: WidgetFooter = {
            if tall, size.width >= 200, leftover >= statsHeight + gap { return .stats }
            if tall, leftover >= lineHeight + gap { return .line }
            return .none
        }()
        let footerBlock: CGFloat = {
            switch footer {
            case .none: 0
            case .line: lineHeight + gap
            case .stats: statsHeight + gap
            }
        }()
        let afterFooter = max(0, leftover - footerBlock)
        let stretch = perColumn == 0 ? 0 : min(afterFooter / CGFloat(perColumn), WidgetLayout.maxStretch)

        // Paging: the cards that fit are one page, so a page is as big as the widget allows and the last one can
        // be shorter (its cards keep the size of the others). A list that is not paged keeps to its first page.
        let pageCount = visible == 0 ? 1 : (rows + visible - 1) / visible
        let current = pageable ? min(max(0, page), pageCount - 1) : 0
        let start = current * visible
        let onPage = max(0, min(visible, rows - start))

        return WidgetListPlan(
            showsHeader: showsHeader, tierIndex: chosen, columns: columns, visible: visible, rowsPerColumn: perColumn,
            columnWidth: columnWidth, cardHeight: base + stretch, footer: footer, more: max(0, rows - start - onPage),
            page: current, pageCount: pageCount, pageStart: start, shown: onPage
        )
    }
}
