import AppIntents
import SwiftUI
import WidgetKit

// The page buttons of a paged widget (Now playing): "1/3" and Up and Down, in the header beside Refresh. A list
// sets the pager on its header through the environment (`WidgetListLayout`), and the header draws it when there
// is more than one page. Up shows the page before, Down the page after; at the first or last page the button
// is a still, dimmed arrow, not a button.

/// Where a paged list is, and what each button moves it to.
struct WidgetPagerState: Equatable, Sendable {
    let key: String
    let page: Int
    let pageCount: Int

    /// A pager exists only for a list of more than one page.
    init?(key: String, plan: WidgetListPlan) {
        guard plan.pageCount > 1 else { return nil }
        self.key = key
        page = plan.page
        pageCount = plan.pageCount
    }

    init(key: String, page: Int, pageCount: Int) {
        self.key = key
        self.page = page
        self.pageCount = pageCount
    }

    var previous: Int? { page > 0 ? page - 1 : nil }
    var next: Int? { page < pageCount - 1 ? page + 1 : nil }

    /// "1/3".
    var label: String { "\(page + 1)/\(pageCount)" }

    /// "Page 1 of 3", for VoiceOver.
    var spokenLabel: String { String(localized: "Page \(page + 1) of \(pageCount)") }
}

private struct WidgetPagerKey: EnvironmentKey {
    static let defaultValue: WidgetPagerState? = nil
}

extension EnvironmentValues {
    var widgetPager: WidgetPagerState? {
        get { self[WidgetPagerKey.self] }
        set { self[WidgetPagerKey.self] = newValue }
    }
}

/// "1/3", then Up and Down. 24 points square each, as Refresh is.
struct WidgetPagerControls: View {
    let pager: WidgetPagerState
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: pager.label).widgetText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
                .accessibilityLabel(Text(verbatim: pager.spokenLabel))
                .padding(.trailing, 2)
            arrow(.chevronUp, to: pager.previous, label: String(localized: "Previous streams"))
            arrow(.chevronDown, to: pager.next, label: String(localized: "More streams"))
        }
    }

    @ViewBuilder
    private func arrow(_ icon: WidgetIcon, to page: Int?, label: String) -> some View {
        if let page {
            Button(intent: NowPlayingPageIntent(key: pager.key, page: page)) {
                WidgetIconView(icon: icon, size: 16).foregroundStyle(palette.text).frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
        } else {
            WidgetIconView(icon: icon, size: 16).foregroundStyle(palette.muted.opacity(0.4)).frame(width: 24, height: 24)
                .accessibilityHidden(true)
        }
    }
}
