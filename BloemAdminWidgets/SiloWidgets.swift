import SwiftUI
import WidgetKit

// The five Bloem Admin widgets. Each one is the app's page with the cards of the app's own lists on it, drawn
// for every family that makes sense (`SiloWidgetKind.families`): small, medium, large, extra large on an iPad,
// and the three lock screen shapes. They set their own margins (`contentMarginsDisabled`), because the page
// edge is 8, as in the app.

struct ServerStatusWidget: Widget {
    private static let kind = SiloWidgetKind.serverStatus

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind.rawValue, intent: ServerSelectionIntent.self, provider: SiloProvider(kind: Self.kind)
        ) { entry in
            SiloWidgetRoot(kind: Self.kind, entry: entry)
        }
        .configurationDisplayName("Bloem Admin: Server status")
        .description("Bloem Admin: whether each Silo server answers, how many streams are playing and how many requests are waiting")
        .supportedFamilies(Self.kind.families)
        .contentMarginsDisabled()
    }
}

struct NowPlayingWidget: Widget {
    private static let kind = SiloWidgetKind.nowPlaying

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind.rawValue, intent: ServerSelectionIntent.self, provider: SiloProvider(kind: Self.kind)
        ) { entry in
            SiloWidgetRoot(kind: Self.kind, entry: entry)
        }
        .configurationDisplayName("Bloem Admin: Now playing")
        .description("Bloem Admin: the streams playing now as the app's session cards, with the title, who, how it plays, how far and the bitrate")
        .supportedFamilies(Self.kind.families)
        .contentMarginsDisabled()
    }
}

struct RequestsWidget: Widget {
    private static let kind = SiloWidgetKind.requests

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind.rawValue, intent: ServerSelectionIntent.self, provider: SiloProvider(kind: Self.kind)
        ) { entry in
            SiloWidgetRoot(kind: Self.kind, entry: entry)
        }
        .configurationDisplayName("Bloem Admin: Requests")
        .description("Bloem Admin: the newest requests waiting for approval, with Approve and Decline")
        .supportedFamilies(Self.kind.families)
        .contentMarginsDisabled()
    }
}

struct LibrariesWidget: Widget {
    private static let kind = SiloWidgetKind.libraries

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind.rawValue, intent: ServerSelectionIntent.self, provider: SiloProvider(kind: Self.kind)
        ) { entry in
            SiloWidgetRoot(kind: Self.kind, entry: entry)
        }
        .configurationDisplayName("Bloem Admin: Libraries and scans")
        .description("Bloem Admin: each library's last scan and warnings, and the progress of a running scan")
        .supportedFamilies(Self.kind.families)
        .contentMarginsDisabled()
    }
}

struct NodesWidget: Widget {
    private static let kind = SiloWidgetKind.nodes

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: Self.kind.rawValue, intent: ServerSelectionIntent.self, provider: SiloProvider(kind: Self.kind)
        ) { entry in
            SiloWidgetRoot(kind: Self.kind, entry: entry)
        }
        .configurationDisplayName("Bloem Admin: Nodes and resources")
        .description("Bloem Admin: each node's state, CPU, memory and disk")
        .supportedFamilies(Self.kind.families)
        .contentMarginsDisabled()
    }
}
