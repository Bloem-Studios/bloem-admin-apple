import Foundation

// What a widget draws, as plain values: built from the snapshot and from the widget's own reachability
// check, so the choices (which servers, what counts as live, what is too old to show) are tested without
// WidgetKit. Compiled into the app and the widget extension.

struct ServerStatusRow: Equatable, Identifiable, Sendable {
    enum Reachability: Equatable, Sendable {
        case up, down, unknown
    }

    let id: String
    let name: String
    let reachability: Reachability
    /// nil when the count is unknown or too old to show.
    let activeStreams: Int?
    let requestsWaiting: Int?
}

struct ServerStatusModel: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case reachable
        case unreachable
        case someUnreachable(reachable: Int, of: Int)
        case unknown
    }

    let title: String
    let rows: [ServerStatusRow]
    let status: Status
    let activeStreams: Int?
    let requestsWaiting: Int?
    /// What a tap on the widget opens.
    let link: URL
    /// The oldest time of the counts shown, when they are older than the refresh window (the widget then says
    /// "Updated 14:32"); nil while they are current or when there are none.
    let countsStaleSince: Date?

    var hasServers: Bool { !rows.isEmpty }

    /// Counts older than this are labelled with their time (the refresh interval is 15 minutes).
    static let countsFreshWindow: TimeInterval = 20 * 60

    /// A server is down: the tally dot means this needs the person.
    var hasDownServer: Bool { rows.contains { $0.reachability == .down } }

    /// The tally dot means a stream is live right now, and appears nowhere else.
    var hasLiveStreams: Bool { (activeStreams ?? 0) > 0 }

    /// `serverID` nil, or an id that is no longer saved, shows all servers.
    /// `liveReachability` holds what the widget's own check just found per server id; it wins over the
    /// snapshot's last answer.
    init(snapshot: AdminSnapshot?, serverID: String?, liveReachability: [String: Bool], now: Date) {
        let all = snapshot?.servers ?? []
        let chosen = serverID.flatMap { id in all.first { $0.id == id } }
        let scoped = chosen.map { [$0] } ?? all
        let servers = scoped.map { server -> SnapshotServer in
            var row = server
            if let live = liveReachability[server.id] { row.reachable = live }
            return row
        }

        let summary = SnapshotSummary(servers: servers, now: now)
        activeStreams = summary.activeStreams
        requestsWaiting = summary.requestsWaiting
        let freshTimes = servers.compactMap { server -> Date? in
            guard let at = server.countsAt, now.timeIntervalSince(at) <= SnapshotSummary.countsFreshness else { return nil }
            return at
        }
        countsStaleSince = freshTimes.min().flatMap { now.timeIntervalSince($0) > Self.countsFreshWindow ? $0 : nil }
        title = chosen?.name ?? String(localized: "All servers")
        rows = servers.map { server in
            let fresh = server.countsAt.map { now.timeIntervalSince($0) <= SnapshotSummary.countsFreshness } ?? false
            return ServerStatusRow(
                id: server.id,
                name: server.name,
                reachability: server.reachable.map { $0 ? .up : .down } ?? .unknown,
                activeStreams: fresh ? server.activeStreams : nil,
                requestsWaiting: fresh ? server.requestsWaiting : nil
            )
        }

        if summary.reachableCount + summary.unreachableCount == 0 {
            status = .unknown
        } else if summary.reachableCount == summary.serverCount {
            status = .reachable
        } else if summary.reachableCount == 0 {
            status = .unreachable
        } else {
            status = .someUnreachable(reachable: summary.reachableCount, of: summary.serverCount)
        }

        link = DeepLinkRoute(
            target: chosen.map { .server($0.id) } ?? .allServers, pageID: DeepLinkPage.nowPlaying
        ).url
    }

    /// The servers a widget asks the public health route itself: those in scope that have an HTTPS origin.
    static func checkTargets(in snapshot: AdminSnapshot?, serverID: String?) -> [SnapshotServer] {
        let all = snapshot?.servers ?? []
        let chosen = serverID.flatMap { id in all.first { $0.id == id } }
        return (chosen.map { [$0] } ?? all).filter { $0.origin?.scheme?.lowercased() == "https" }
    }
}
