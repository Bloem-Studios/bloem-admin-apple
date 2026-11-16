import Foundation
import WidgetKit

/// Which readings a widget needs. The timeline provider only reads these, so a Now playing widget does not
/// ask for nodes.
enum WidgetSectionKind: Hashable, Sendable {
    case status, streams, requests, libraries, nodes
}

/// Everything one timeline entry holds. A widget draws only the part it needs.
struct SiloEntry: TimelineEntry {
    let date: Date
    /// The saved servers, with the last answers of the health check.
    let snapshot: AdminSnapshot?
    /// The health check the widget just made, by server id.
    let live: [String: Bool]
    let serverID: String?
    let settings: WidgetSettings
    let streams: WidgetBoard<StreamItem>
    let requests: WidgetBoard<RequestItem>
    let libraries: WidgetBoard<WidgetLibraryItem>
    let nodes: WidgetBoard<NodeItem>
    let notice: WidgetActionNotice?
    /// The page each paged widget (Now playing) was left on.
    var paging = WidgetPagingState()

    var statusModel: ServerStatusModel {
        ServerStatusModel(snapshot: snapshot, serverID: serverID, liveReachability: live, now: date)
    }

    /// The same readings, drawn as of another moment: what a later timeline entry is.
    func at(_ date: Date) -> SiloEntry {
        SiloEntry(
            date: date, snapshot: snapshot, live: live, serverID: serverID, settings: settings,
            streams: streams, requests: requests, libraries: libraries, nodes: nodes, notice: notice, paging: paging
        )
    }
}

/// When a widget's timeline draws again and when it reads again, with no request in between.
///
/// A timeline is the entries the system shows by the clock, and a date after which it asks for a new one. Now
/// playing's entries sit at the moments something changes by itself: where a stream should end (it comes off the
/// card) and where a reading turns old (the card stops moving and says "Updated 14:32"). Between entries the
/// system moves the bars and times itself. The reload date is about 15 minutes, and about 5 while something is
/// active (a stream plays, a scan runs), so what is shown is never long out of date. The app's saves, the live
/// socket and the server's silent wake reload sooner (`WidgetReload`).
enum WidgetTimelinePlan {
    static let idleInterval: TimeInterval = 15 * 60
    static let activeInterval: TimeInterval = 5 * 60
    /// How far ahead entries are planned: past the reload date, in case the system is late to reload.
    static let horizon: TimeInterval = 30 * 60
    static let maxEntries = 10
    /// Entries closer together than this are one.
    static let merge: TimeInterval = 30

    static func isActive(_ kind: SiloWidgetKind, _ entry: SiloEntry) -> Bool {
        switch kind {
        case .nowPlaying: NowPlayingFigures(board: entry.streams, now: entry.date).total > 0
        case .serverStatus: entry.statusModel.hasLiveStreams
        case .libraries: entry.libraries.items.contains { $0.activity != nil }
        case .requests, .nodes: false
        }
    }

    static func reloadDate(_ kind: SiloWidgetKind, _ entry: SiloEntry) -> Date {
        entry.date.addingTimeInterval(isActive(kind, entry) ? activeInterval : idleInterval)
    }

    static func entryDates(_ kind: SiloWidgetKind, _ entry: SiloEntry) -> [Date] {
        var dates = [entry.date]
        if kind == .nowPlaying {
            let limit = entry.date.addingTimeInterval(horizon)
            let freshness = WidgetBoard<StreamItem>.freshness
            for item in entry.streams.items {
                guard let readAt = item.readAt else { continue }
                // Only a reading that was fresh at the end can say the stream is over.
                if let end = item.expectedEnd, end.timeIntervalSince(readAt) <= freshness {
                    dates.append(end.addingTimeInterval(StreamItem.endSlack))
                }
                dates.append(readAt.addingTimeInterval(freshness + 1))
            }
            // A page left alone goes back to the first: draw it again then.
            dates += entry.paging.expiries(after: entry.date)
            dates = dates.filter { $0 == entry.date || ($0 > entry.date && $0 <= limit) }
        }
        var merged: [Date] = []
        for date in dates.sorted() {
            if let last = merged.last, date.timeIntervalSince(last) < merge, last != entry.date {
                merged[merged.count - 1] = date
            } else if let last = merged.last, date.timeIntervalSince(last) < merge {
                continue
            } else {
                merged.append(date)
            }
        }
        return Array(merged.prefix(maxEntries))
    }
}

/// Fixed example data, for the widget gallery, previews and the screenshot tour. Names are invented.
enum WidgetSamples {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static let snapshot: AdminSnapshot = {
        var home = SnapshotServer(id: "home", name: "Silo Home", origin: URL(string: "https://home.example.test"))
        home.reachable = true
        home.checkedAt = now
        home.activeStreams = 4
        home.requestsWaiting = 4
        home.countsAt = now
        var office = SnapshotServer(id: "office", name: "Office", origin: URL(string: "https://office.example.test"))
        office.reachable = true
        office.checkedAt = now
        office.activeStreams = 0
        office.requestsWaiting = 0
        office.countsAt = now
        return AdminSnapshot(generatedAt: now, servers: [home, office])
    }()

    private static func feed<Item: Codable & Equatable & Sendable>(
        _ id: String, _ name: String, _ items: [Item], total: Int? = nil, secondary: Int? = nil
    ) -> ServerFeed<Item> {
        ServerFeed(serverID: id, serverName: name, condition: .current, items: items, total: total ?? items.count, secondary: secondary, asOf: now)
    }

    /// The Now playing page's own sample (the Android app's reference screenshot): a direct play, a remux, a
    /// transcode and a paused stream. Positions are as of `now`.
    static let streams: [StreamItem] = [
        StreamItem(
            id: "s1", serverID: "home", serverName: "Silo Home", user: "maria", title: "Dune: Part Two",
            progress: 4_330 / 9_960, isPaused: false, delivery: .direct, bitrateKbps: 38_400,
            userLabel: "maria · Living room", clientLine: "Infuse 8.1 · tvOS", source: "HEVC 4K · MKV", method: .direct,
            positionSeconds: 4_330, durationSeconds: 9_960, readAt: now
        ),
        StreamItem(
            id: "s2", serverID: "home", serverName: "Silo Home", user: "jonas", title: "Severance · S2E3 · Who Is Alive?",
            progress: 754 / 2_652, isPaused: false, delivery: .direct, bitrateKbps: 12_800,
            userLabel: "jonas", clientLine: "Bloem 1.4.2 · Android", source: "H.264 1080p · MKV", method: .remux,
            positionSeconds: 754, durationSeconds: 2_652, readAt: now
        ),
        StreamItem(
            id: "s3", serverID: "home", serverName: "Silo Home", user: "amira", title: "Planet Earth III · S1E2 · Oceans",
            progress: 1_980 / 3_000, isPaused: false, delivery: .transcode, bitrateKbps: 8_200,
            userLabel: "amira", clientLine: "Bloem 1.4.1 · iOS", source: "HEVC 4K · MKV", method: .transcode,
            transcodeDetail: "H.264 1080p · HW QSV", positionSeconds: 1_980, durationSeconds: 3_000, readAt: now
        ),
        StreamItem(
            id: "s4", serverID: "home", serverName: "Silo Home", user: "tomas", title: "The River",
            progress: 1_200 / 5_400, isPaused: true, delivery: .direct, bitrateKbps: 6_100,
            userLabel: "tomas", clientLine: "Web · Web", source: "H.264 1080p · MP4", method: .direct,
            positionSeconds: 1_200, durationSeconds: 5_400, readAt: now
        ),
    ]

    static let requests: [RequestItem] = [
        RequestItem(id: "r1", serverID: "home", serverName: "Silo Home", title: "Dune: Part Two (2024)", requester: "Maya", createdAt: now.addingTimeInterval(-600)),
        RequestItem(id: "r2", serverID: "home", serverName: "Silo Home", title: "Shogun (2024)", requester: "Tomas", createdAt: now.addingTimeInterval(-7_200)),
        RequestItem(id: "r3", serverID: "home", serverName: "Silo Home", title: "Anatomy of a Fall (2023)", requester: "Priya", createdAt: now.addingTimeInterval(-26_000)),
        RequestItem(id: "r4", serverID: "home", serverName: "Silo Home", title: "Poor Things (2023)", requester: "Maya", createdAt: now.addingTimeInterval(-90_000)),
    ]

    static let libraries: [WidgetLibraryItem] = [
        WidgetLibraryItem(id: "l1", serverID: "home", serverName: "Silo Home", name: "Films", lastScannedAt: now.addingTimeInterval(-3_600), warning: nil, activity: nil),
        WidgetLibraryItem(id: "l2", serverID: "home", serverName: "Silo Home", name: "Series", lastScannedAt: now.addingTimeInterval(-300), warning: nil, activity: LibraryScanActivity(phase: .running, progress: 0.4)),
        WidgetLibraryItem(id: "l3", serverID: "home", serverName: "Silo Home", name: "Music", lastScannedAt: now.addingTimeInterval(-86_400), warning: "The scan found no media files", activity: nil),
    ]

    static let nodes: [NodeItem] = [
        NodeItem(id: "n1", serverID: "home", serverName: "Silo Home", name: "transcode-1", health: .healthy, cpuPercent: 34, memoryPercent: 52, diskPercent: 61),
        NodeItem(id: "n2", serverID: "home", serverName: "Silo Home", name: "transcode-2", health: .draining, cpuPercent: 8, memoryPercent: 30, diskPercent: 88),
        NodeItem(id: "n3", serverID: "home", serverName: "Silo Home", name: "edge-1", health: .unhealthy, cpuPercent: nil, memoryPercent: nil, diskPercent: nil),
    ]

    static func entry(settings: WidgetSettings = WidgetSettings(), serverID: String? = nil) -> SiloEntry {
        func board<Item: Codable & Equatable & Sendable>(_ feed: ServerFeed<Item>) -> WidgetBoard<Item> {
            WidgetBoard(title: String(localized: "All servers"), serverID: serverID, feeds: [feed])
        }
        return SiloEntry(
            date: now, snapshot: snapshot, live: ["home": true, "office": true], serverID: serverID, settings: settings,
            streams: board(feed("home", "Silo Home", streams, total: 4, secondary: 65_500)),
            requests: board(feed("home", "Silo Home", requests, total: 4)),
            libraries: board(feed("home", "Silo Home", libraries)),
            nodes: board(feed("home", "Silo Home", nodes)),
            notice: nil
        )
    }

    /// The widget gallery's entry: every board reads as loading, a quiet placeholder with no shimmer.
    static func placeholder() -> SiloEntry {
        let value = entry()
        func loading<Item: Codable & Equatable & Sendable>(_ board: WidgetBoard<Item>) -> WidgetBoard<Item> {
            var copy = board
            copy.isPlaceholder = true
            return copy
        }
        return SiloEntry(
            date: value.date, snapshot: value.snapshot, live: value.live, serverID: nil, settings: value.settings,
            streams: loading(value.streams), requests: loading(value.requests),
            libraries: loading(value.libraries), nodes: loading(value.nodes), notice: nil
        )
    }
}
