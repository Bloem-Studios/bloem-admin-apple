import AppIntents
import SwiftUI
import WidgetKit

// Small pieces every widget layout uses: the header, the state messages, the updated line, the progress bar,
// the tally dot and the Refresh button. All text is Plus Jakarta Sans through `.bloemText`, all icons are
// Lucide, all colours are the staff look's tokens from `WidgetPalette`.

/// Everything a layout needs to know about where and how it is drawn.
struct WidgetContext: Equatable, Sendable {
    var size: WidgetSize
    var surface: WidgetSurface
    var settings: WidgetSettings
    var now: Date

    /// Names, titles and amounts may be drawn.
    var showsDetails: Bool { surface.showsDetails(settings) }
}

private struct SiloFamilyOverrideKey: EnvironmentKey {
    static let defaultValue: WidgetFamily? = nil
}

private struct SiloSurfaceOverrideKey: EnvironmentKey {
    static let defaultValue: WidgetSurface? = nil
}

private struct SiloStaticTimeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Draws times and bars as still values instead of the system's moving timers. A moving timer is drawn by
    /// the system, not by the view, so the render tests and the screenshot tour (which draw through
    /// `ImageRenderer`) turn this on.
    var siloStaticTime: Bool {
        get { self[SiloStaticTimeKey.self] }
        set { self[SiloStaticTimeKey.self] = newValue }
    }

    /// Draws a layout for a family WidgetKit did not give the view (the render tests and previews).
    var siloFamilyOverride: WidgetFamily? {
        get { self[SiloFamilyOverrideKey.self] }
        set { self[SiloFamilyOverrideKey.self] = newValue }
    }

    var siloSurfaceOverride: WidgetSurface? {
        get { self[SiloSurfaceOverrideKey.self] }
        set { self[SiloSurfaceOverrideKey.self] = newValue }
    }
}

/// Reads the widget environment once and hands the layout a `WidgetContext` and the palette.
struct WidgetContextReader<Content: View>: View {
    let settings: WidgetSettings
    let now: Date
    @ViewBuilder let content: (WidgetContext) -> Content

    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.siloFamilyOverride) private var familyOverride
    @Environment(\.siloSurfaceOverride) private var surfaceOverride
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.showsWidgetContainerBackground) private var showsBackground
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let family = familyOverride ?? systemFamily
        let context = WidgetContext(
            size: WidgetSize(family),
            surface: surfaceOverride ?? .of(family: family, isLuminanceReduced: isLuminanceReduced, showsContainerBackground: showsBackground),
            settings: settings,
            now: now
        )
        content(context)
            .environment(\.widgetPalette, .of(settings.colorScheme ?? colorScheme))
    }
}

extension View {
    /// Marks detail text so the system redacts it on a locked phone, unless the person turned details on.
    func widgetDetail(_ context: WidgetContext) -> some View {
        privacySensitive(!context.settings.showDetailsOnLockScreen)
    }
}

struct WidgetTallyDot: View {
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        Circle().fill(palette.tally).frame(width: 8, height: 8).accessibilityHidden(true)
    }
}

/// A status dot and its word, in the status colours. Status is a dot plus a word.
struct StatusDot: View {
    enum Tone { case ok, warning, danger, neutral }

    let tone: Tone
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
    }

    private var color: Color {
        switch tone {
        case .ok: palette.ok
        case .warning: palette.warning
        case .danger: palette.danger
        case .neutral: palette.muted
        }
    }
}

/// The app a widget comes from: the home-screen name, so widgets of the three Bloem apps cannot be confused.
enum WidgetApp {
    static let name = "Bloem Admin"
}

/// The app's own small mark: the tulip with the admin app's server badge, in the icon's one-colour drawing, as a
/// template image (`scripts/render-widget-mark.py`). It is identification, not content: `muted`, never the accent
/// and never the tally dot.
struct WidgetAppMark: View {
    var size: CGFloat = 14
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        Image("bloem.admin-mark")
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(palette.muted)
            .accessibilityHidden(true)
    }
}

/// The app tag at the start of a header: the mark and, where there is room, "Bloem Admin ·" in muted label text,
/// so that the header reads "Bloem Admin · Now playing".
struct WidgetAppTag: View {
    var showsName = true
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            WidgetAppMark()
            if showsName {
                Text(verbatim: WidgetApp.name + " ·").widgetText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: WidgetApp.name))
    }
}

/// The first line of a lock screen rectangle: the app's mark where it fits, then the widget's name. The system
/// draws it in its own tint, so the mark takes no colour of its own.
struct WidgetRectangularTitle: View {
    let title: LocalizedStringKey
    var verbatimTitle: String?

    var body: some View {
        HStack(spacing: 4) {
            WidgetAppMark(size: 12)
            Group {
                if let verbatimTitle { Text(verbatim: verbatimTitle) } else { Text(title) }
            }
            .widgetText(.titleSmall).lineLimit(1)
        }
        .widgetAccentable()
    }
}

/// The page's header, as in the app: the app tag, the page's icon and name, what is live or needs you (the tally
/// dot and a word or a count), the server's name and Refresh. What does not fit is dropped, the least important
/// first: the page's icon, the server's name, the word beside the dot, and the app's name down to its mark. A
/// small widget shows the mark only.
struct WidgetHeader: View {
    let icon: WidgetIcon
    let title: LocalizedStringKey
    /// A name that is not a string of the catalog (a server's name), drawn as it is in place of `title`.
    var verbatimTitle: String?
    /// "3 streams", "3 waiting": drawn beside a tally dot.
    var tally: String?
    /// False where nothing is live ("No streams"): the dot means live now or needs you, so it is left out.
    var showsTallyDot = true
    /// Keep the word beside the dot ("3 streams") ahead of the app's name when the header is tight.
    var keepsTallyWord = false
    /// The server's name, or a quiet summary.
    var trailing: String?
    var showsRefresh = true
    /// A small widget: the app's mark alone, and the name a step smaller, so that all of it fits on one line.
    var compact = false
    @Environment(\.widgetPalette) private var palette
    /// Set by a paged list (`WidgetListLayout`): the page buttons, drawn before Refresh and kept in every variant.
    @Environment(\.widgetPager) private var pager

    var body: some View {
        Group {
            if compact {
                ViewThatFits(in: .horizontal) {
                    row(appName: false, pageIcon: false, tallyWord: true, trailing: false)
                    row(appName: false, pageIcon: false, tallyWord: false, trailing: false)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    row(appName: true, pageIcon: true, tallyWord: true, trailing: true)
                    row(appName: true, pageIcon: false, tallyWord: true, trailing: true)
                    row(appName: true, pageIcon: false, tallyWord: true, trailing: false)
                    if keepsTallyWord {
                        // The count is the point of the header (Now playing): the app's name shrinks to its mark first.
                        row(appName: false, pageIcon: false, tallyWord: true, trailing: false)
                        row(appName: true, pageIcon: false, tallyWord: false, trailing: false)
                    } else {
                        row(appName: true, pageIcon: false, tallyWord: false, trailing: false)
                        row(appName: false, pageIcon: false, tallyWord: true, trailing: false)
                    }
                    row(appName: false, pageIcon: false, tallyWord: false, trailing: false)
                }
            }
        }
        .frame(height: WidgetLayout.headerHeight)
    }

    private func row(appName: Bool, pageIcon: Bool, tallyWord: Bool, trailing showsTrailing: Bool) -> some View {
        // A variant is only chosen when it fits with room to spare (the Spacer's minimum), so that no label is squeezed;
        // the last, leanest variant of each list needs none.
        let leanest = !appName && !tallyWord
        return HStack(spacing: 6) {
            WidgetAppTag(showsName: appName)
            if pageIcon { WidgetIconView(icon: icon, size: 16).foregroundStyle(palette.muted) }
            Group {
                if let verbatimTitle { Text(verbatim: verbatimTitle) } else { Text(title) }
            }
            .widgetText(compact ? .labelMedium : .labelLarge).foregroundStyle(palette.text).lineLimit(1)
            if let tally {
                HStack(spacing: 4) {
                    if showsTallyDot { WidgetTallyDot() }
                    if tallyWord || !showsTallyDot {
                        Text(verbatim: tally).widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Spacer(minLength: leanest ? 4 : 16)
            if showsTrailing, let trailing {
                Text(verbatim: trailing).widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
            }
            if let pager { WidgetPagerControls(pager: pager) }
            if showsRefresh { RefreshButton() }
        }
    }
}

extension View {
    /// A widget's text: one of the named styles of the look (Plus Jakarta Sans, its size and weight, tabular
    /// figures, Dynamic Type), set at the font's own line height. A widget packs more lines into less room than
    /// a page does, so it leaves out the page's extra line spacing.
    func widgetText(_ style: BloemTextStyle) -> some View { bloemFont(style) }
}

/// Refresh: reloads every Silo widget, which reads the servers again.
struct RefreshButton: View {
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        Button(intent: RefreshWidgetsIntent()) {
            WidgetIconView(icon: .refresh, size: 16)
                .foregroundStyle(palette.muted)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Refresh")
    }
}

/// A thin bar for progress, as on the Now playing page: the track is `raised`, the fill is the muted text
/// colour, and amber while paused. Accent is kept for the one figure that matters.
struct ProgressBar: View {
    let fraction: Double
    var height: CGFloat = 4
    var paused = false
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(palette.raised)
                Capsule().fill(paused ? palette.warning : palette.muted)
                    .frame(width: proxy.size.width * min(1, max(0, fraction)))
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: States

/// "Updated 14:32" and "Can't reach <server>", the lines that keep a widget honest about old data.
struct FreshnessLine: View {
    let state: BoardState
    var notice: String?
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        if let notice {
            Text(verbatim: notice).bloemText(.labelMedium).foregroundStyle(palette.danger).lineLimit(1)
        } else if !state.unreachableNames.isEmpty {
            let names = state.unreachableNames.joined(separator: ", ")
            Text("Can't reach \(names)")
                .bloemText(.labelMedium).foregroundStyle(palette.danger).lineLimit(1)
            if let at = state.updatedAt {
                Text(verbatim: WidgetTime.updated(at)).bloemText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
            }
        } else if let at = state.updatedAt {
            Text(verbatim: WidgetTime.updated(at)).bloemText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
        }
    }
}

/// The message for a widget with nothing to draw: loading, signed out, can't reach, not available, empty.
struct WidgetMessage: View {
    let phase: BoardPhase
    /// What the widget shows, for "Sign in to see <thing>": "now playing", "requests".
    let thing: String
    /// What an empty widget says: "Nothing playing".
    let emptyText: String
    /// What "not available on this server" says.
    let unavailableText: String
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        switch phase {
        case .loading:
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 4).fill(palette.raised).frame(width: 96, height: 12)
                RoundedRectangle(cornerRadius: 4).fill(palette.raised).frame(width: 64, height: 12)
            }
            .accessibilityLabel("Loading")
        case .noServers:
            VStack(alignment: .leading, spacing: 4) {
                Text("Add a Silo server").bloemText(.titleSmall).foregroundStyle(palette.text)
                Text("Open the app to add one").bloemText(.bodySmall).foregroundStyle(palette.muted)
            }
        case .signedOut:
            VStack(alignment: .leading, spacing: 4) {
                Text("Sign in to see \(thing)").bloemText(.titleSmall).foregroundStyle(palette.text)
                Text("Open the app to sign in").bloemText(.bodySmall).foregroundStyle(palette.muted)
            }
        case .unavailable:
            Text(verbatim: unavailableText).bloemText(.titleSmall).foregroundStyle(palette.text)
        case .unreachable(let name):
            VStack(alignment: .leading, spacing: 4) {
                Text("Can't reach \(name)").bloemText(.titleSmall).foregroundStyle(palette.danger)
                Text("Nothing read yet").bloemText(.bodySmall).foregroundStyle(palette.muted)
            }
        case .empty:
            Text(verbatim: emptyText).bloemText(.titleSmall).foregroundStyle(palette.muted)
        case .content:
            EmptyView()
        }
    }
}

/// The container every layout sits in: the `card` surface and the standard 16 padding. Used by the widget
/// configuration (as the container background) and by the screenshot tour.
struct WidgetCardBackground: View {
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        palette.card
    }
}

/// A count in the figure style, with its caption under it.
struct BigFigure: View {
    let value: String
    let caption: String
    var isAccent = false
    var isLive = false
    @Environment(\.widgetPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: value)
                    .bloemText(.displaySmall)
                    .foregroundStyle(isAccent ? palette.accent : palette.text)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if isLive { WidgetTallyDot() }
            }
            Text(verbatim: caption).bloemText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
