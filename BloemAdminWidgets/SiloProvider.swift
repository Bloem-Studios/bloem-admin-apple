import AppIntents
import SwiftUI
import WidgetKit

/// "Server" in the widget's settings: one saved server, or none for all servers.
struct ServerSelectionIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Server"
    static let description = IntentDescription("Choose a server, or leave it empty for all servers")

    @Parameter(title: "Server")
    var server: ServerEntity?
}

/// Builds the timeline for every Bloem Admin widget. Each widget names the readings it needs (`sections`).
/// A timeline asks for a refresh in about 15 minutes, or about 5 while a stream plays or a scan runs
/// (`WidgetTimelinePlan`), and Now playing has an entry where each stream should end, so its progress moves and
/// finished streams drop off with no request in between. The app's own saves, the live socket, the server's
/// silent wake and the Refresh button reload it sooner. What a widget could not read keeps its last data,
/// and says so.
struct SiloProvider: AppIntentTimelineProvider {
    static let refreshInterval = WidgetTimelinePlan.idleInterval

    let kind: SiloWidgetKind

    func placeholder(in context: Context) -> SiloEntry {
        WidgetSamples.placeholder()
    }

    func snapshot(for configuration: ServerSelectionIntent, in context: Context) async -> SiloEntry {
        if context.isPreview { return WidgetSamples.entry(settings: WidgetSettingsLoader.current()) }
        return await entry(for: configuration)
    }

    func timeline(for configuration: ServerSelectionIntent, in context: Context) async -> Timeline<SiloEntry> {
        let entry = await entry(for: configuration)
        let dates = WidgetTimelinePlan.entryDates(kind, entry)
        return Timeline(entries: dates.map { entry.at($0) }, policy: .after(WidgetTimelinePlan.reloadDate(kind, entry)))
    }

    private func entry(for configuration: ServerSelectionIntent) async -> SiloEntry {
        let sections = kind.sections
        var snapshot = FileSnapshotStore.appGroup()?.load()
        let serverID = configuration.server?.id
        let fetcher = WidgetFetcher.live()
        let now = Date()

        func empty<Item: Codable & Equatable & Sendable>(_ type: Item.Type) -> WidgetBoard<Item> {
            let chosen = serverID.flatMap { id in snapshot?.servers.first { $0.id == id } }
            return WidgetBoard(title: chosen?.name ?? String(localized: "All servers"), serverID: chosen?.id, feeds: [])
        }

        var live: [String: Bool] = [:]
        if sections.contains(.status) {
            // The public health route needs no sign-in, so Server status keeps working without one.
            live = await Self.check(ServerStatusModel.checkTargets(in: snapshot, serverID: serverID))
            // Live counts, where a sign-in is readable; otherwise the open app's last counts stay.
            if let fetcher {
                let counts = await fetcher.counts(snapshot: snapshot, serverID: serverID)
                snapshot = snapshot?.applying(counts, at: now)
            }
        }
        var streams = empty(StreamItem.self)
        var requests = empty(RequestItem.self)
        var libraries = empty(WidgetLibraryItem.self)
        var nodes = empty(NodeItem.self)
        if let fetcher {
            if sections.contains(.streams) { streams = await fetcher.streams(snapshot: snapshot, serverID: serverID) }
            if sections.contains(.requests) { requests = await fetcher.requests(snapshot: snapshot, serverID: serverID) }
            if sections.contains(.libraries) { libraries = await fetcher.libraries(snapshot: snapshot, serverID: serverID) }
            if sections.contains(.nodes) { nodes = await fetcher.nodes(snapshot: snapshot, serverID: serverID) }
        } else if let cache = FileWidgetDataStore.appGroup()?.load() {
            streams = cache.board(\.streams, snapshot: snapshot, serverID: serverID)
        }
        return SiloEntry(
            date: now, snapshot: snapshot, live: live, serverID: serverID, settings: WidgetSettingsLoader.current(),
            streams: streams, requests: requests, libraries: libraries, nodes: nodes,
            notice: FileWidgetDataStore.appGroup()?.load().notice(now: now),
            paging: FileWidgetPagingStore.appGroup()?.load() ?? WidgetPagingState()
        )
    }

    /// Reachability per server id. A check the phone could not make leaves the snapshot's answer.
    private static func check(_ targets: [SnapshotServer]) async -> [String: Bool] {
        let probe = HealthProbe(timeout: 6)
        return await withTaskGroup(of: (String, Bool?).self) { group in
            for target in targets {
                guard let origin = target.origin else { continue }
                let id = target.id
                group.addTask {
                    switch await probe.check(baseURL: origin) {
                    case .up: return (id, true)
                    case .down: return (id, false)
                    case .inconclusive: return (id, nil)
                    }
                }
            }
            var found: [String: Bool] = [:]
            for await (id, reachable) in group {
                if let reachable { found[id] = reachable }
            }
            return found
        }
    }
}

enum WidgetSettingsLoader {
    static func current() -> WidgetSettings {
        FileWidgetSettingsStore.appGroup()?.load() ?? WidgetSettings()
    }
}
