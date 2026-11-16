import SwiftUI
import WidgetKit

enum SiloWidgetKind: String, CaseIterable, Sendable {
    case serverStatus = "com.bloemstudios.admin.widget.server-status"
    case nowPlaying = "com.bloemstudios.admin.widget.now-playing"
    case requests = "com.bloemstudios.admin.widget.requests"
    case libraries = "com.bloemstudios.admin.widget.libraries"
    case nodes = "com.bloemstudios.admin.widget.nodes"

    /// The sizes each widget offers: every family that makes sense for what it shows. Small is the figure, medium
    /// and large add whole cards, extra large (iPad) uses two columns, and the lock screen's three shapes show
    /// counts and statuses.
    var families: [WidgetFamily] {
        switch self {
        case .serverStatus, .nowPlaying, .requests, .libraries, .nodes:
            [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline]
        }
    }

    var sections: Set<WidgetSectionKind> {
        switch self {
        case .serverStatus: [.status]
        case .nowPlaying: [.streams]
        case .requests: [.requests]
        case .libraries: [.libraries]
        case .nodes: [.nodes]
        }
    }

    /// The channels of changes this widget shows, in the words of the server's silent wake (`sessions`,
    /// `requests`, `libraries`, `nodes`). The app reports the channels of the widgets that are placed, and a
    /// wake for one of them reloads this widget (`WidgetReload.kinds(forChannels:)`).
    var channels: Set<String> {
        switch self {
        case .serverStatus: ["sessions", "requests"]
        case .nowPlaying: ["sessions"]
        case .requests: ["requests"]
        case .libraries: ["libraries"]
        case .nodes: ["nodes"]
        }
    }
}

/// One widget as the person sees it: the app's page (the `canvas`) with the cards of the app's own lists on it,
/// laid out for its size, in the look's tokens. The extension's widgets and the screenshot tour both draw
/// through this view.
struct SiloWidgetRoot: View {
    let kind: SiloWidgetKind
    let entry: SiloEntry
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.siloFamilyOverride) private var familyOverride
    private var family: WidgetFamily { familyOverride ?? systemFamily }
    private var isAccessory: Bool { WidgetSize(family).isAccessory }

    private var scheme: ColorScheme { entry.settings.colorScheme ?? systemScheme }

    var body: some View {
        WidgetContextReader(settings: entry.settings, now: entry.date) { context in
            Group {
                switch kind {
                case .serverStatus: ServerStatusWidgetView(model: entry.statusModel, context: context)
                case .nowPlaying: NowPlayingWidgetView(board: entry.streams, context: context, paging: entry.paging)
                case .requests: RequestsWidgetView(board: entry.requests, notice: entry.notice, context: context)
                case .libraries: LibrariesWidgetView(board: entry.libraries, context: context)
                case .nodes: NodesWidgetView(board: entry.nodes, context: context)
                }
            }
            // The widget sets its own margins (`contentMarginsDisabled`): the page edge is 8, as in the app.
            .padding(isAccessory ? 0 : WidgetLayout.pageInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.colorScheme, scheme)
        .containerBackground(for: .widget) {
            if isAccessory {
                Color.clear
            } else {
                WidgetPalette.of(scheme).canvas
            }
        }
    }
}
