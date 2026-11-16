import Foundation

// The small file the app writes into the App Group container for widgets. It holds server names, each
// server's origin (so a widget can ask the public health route itself), whether the server answered,
// and two counts. It never holds a token, a user name, an email address or a title. Compiled into the
// app and into the widget extension.

enum AppGroup {
    static let identifier = "group.com.bloemstudios.admin"

    /// The shared container, or nil when the App Group is not available to this process (a build whose
    /// signing does not carry the entitlement).
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

struct SnapshotServer: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// `scheme://host[:port]` of an HTTPS server, used only to ask `GET /api/v1/health`. Never shown.
    var origin: URL?
    var reachable: Bool?
    var checkedAt: Date?
    var activeStreams: Int?
    var requestsWaiting: Int?
    /// When the two counts were read. Counts need a sign-in, so only the open app reads them.
    var countsAt: Date?
}

struct AdminSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = AdminSnapshot.currentVersion
    var generatedAt: Date
    var servers: [SnapshotServer]
}

// MARK: Building a snapshot

struct SnapshotServerInfo: Equatable, Sendable {
    let id: String
    let name: String
    let origin: URL?
}

struct SnapshotReachability: Equatable, Sendable {
    let reachable: Bool
    let checkedAt: Date
}

struct SnapshotCounts: Equatable, Sendable {
    let streams: Int
    let requests: Int
}

enum SnapshotCountsUpdate: Equatable, Sendable {
    case set(SnapshotCounts)
    /// The server could not be asked (signed out, no access, unreachable): show no numbers.
    case clear
}

extension AdminSnapshot {
    /// The snapshot for `servers` in their order. A server present in `previous` keeps what the update does
    /// not name (counts survive a reachability-only update); a server that is no longer saved is dropped.
    static func make(
        previous: AdminSnapshot?,
        servers: [SnapshotServerInfo],
        reachability: [String: SnapshotReachability],
        counts: [String: SnapshotCountsUpdate],
        now: Date
    ) -> AdminSnapshot {
        let rows = servers.map { info -> SnapshotServer in
            var row = previous?.servers.first { $0.id == info.id } ?? SnapshotServer(id: info.id, name: info.name)
            row.name = info.name
            row.origin = info.origin
            if let seen = reachability[info.id] {
                row.reachable = seen.reachable
                row.checkedAt = seen.checkedAt
            }
            switch counts[info.id] {
            case .set(let value):
                row.activeStreams = value.streams
                row.requestsWaiting = value.requests
                row.countsAt = now
            case .clear:
                row.activeStreams = nil
                row.requestsWaiting = nil
                row.countsAt = nil
            case nil:
                break
            }
            return row
        }
        return AdminSnapshot(generatedAt: now, servers: rows)
    }
}

// MARK: Reading it

/// What a widget shows for one server or for several, from the snapshot.
struct SnapshotSummary: Equatable, Sendable {
    /// Counts older than this are not shown: the open app is the only thing that reads them.
    static let countsFreshness: TimeInterval = 60 * 60

    let serverCount: Int
    let reachableCount: Int
    let unreachableCount: Int
    /// nil when no server has counts that are fresh enough to show.
    let activeStreams: Int?
    let requestsWaiting: Int?

    var hasLiveStreams: Bool { (activeStreams ?? 0) > 0 }

    init(servers: [SnapshotServer], now: Date) {
        serverCount = servers.count
        reachableCount = servers.filter { $0.reachable == true }.count
        unreachableCount = servers.filter { $0.reachable == false }.count
        let fresh = servers.filter { server in
            guard let at = server.countsAt else { return false }
            return now.timeIntervalSince(at) <= Self.countsFreshness
        }
        let streams = fresh.compactMap(\.activeStreams)
        let requests = fresh.compactMap(\.requestsWaiting)
        activeStreams = streams.isEmpty ? nil : streams.reduce(0, +)
        requestsWaiting = requests.isEmpty ? nil : requests.reduce(0, +)
    }
}

// MARK: Storage

protocol SnapshotStoring: Sendable {
    func load() -> AdminSnapshot?
    func save(_ snapshot: AdminSnapshot) throws
}

struct FileSnapshotStore: SnapshotStoring {
    static let fileName = "admin-snapshot.json"

    let directory: URL

    /// The store in the App Group container, or nil when the group is not available.
    static func appGroup() -> FileSnapshotStore? {
        AppGroup.containerURL.map { FileSnapshotStore(directory: $0) }
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> AdminSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(AdminSnapshot.self, from: data),
              snapshot.version == AdminSnapshot.currentVersion
        else { return nil }
        return snapshot
    }

    func save(_ snapshot: AdminSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        // Readable after the first unlock, so a widget can draw while the phone is locked.
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
