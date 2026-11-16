import Foundation

// What a data widget holds: one feed per saved server, each with its last good data and why it could not be
// refreshed, if it could not. `state(now:)` turns that into the one of the spec's states a widget draws
// (loading, signed out, can't reach, not available, empty, content), with "Updated 14:32" whenever what is
// shown is older than its refresh window. Plain values, so every state is unit tested without WidgetKit.

enum FeedCondition: String, Codable, Equatable, Sendable {
    /// Read just now.
    case current
    /// No sign-in for this server, or the server refused it.
    case signedOut
    /// The server did not answer.
    case unreachable
    /// The server has no such feature (a plain Silo server has no Bloem extras).
    case unavailable
    /// The phone is locked and the sign-in cannot be read; the last data stays.
    case deviceLocked
}

struct ServerFeed<Item: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    var serverID: String
    var serverName: String
    var condition: FeedCondition
    /// The last good items, whatever the condition now is.
    var items: [Item]
    /// The last good total (the count a small widget shows); it can exceed `items.count`.
    var total: Int?
    /// A second total: for streams, the bandwidth in kbps.
    var secondary: Int?
    /// When `items` and `total` were read.
    var asOf: Date?

    var hasData: Bool { asOf != nil }
}

enum BoardPhase: Equatable, Sendable {
    case loading
    /// No saved server.
    case noServers
    case signedOut
    case unavailable
    /// Nothing to show and no server answered: `Can't reach <server>`.
    case unreachable(serverName: String)
    case empty
    case content
}

struct BoardState: Equatable, Sendable {
    let phase: BoardPhase
    /// Servers that did not answer while others did (or while old data is shown).
    let unreachableNames: [String]
    /// Set when what is shown is older than its refresh window: the oldest time to put in "Updated 14:32".
    let updatedAt: Date?
}

struct WidgetBoard<Item: Codable & Equatable & Sendable>: Equatable, Sendable {
    /// Data older than this is labelled with its time. The refresh interval is 15 minutes; the rest is slack.
    static var freshness: TimeInterval { 20 * 60 }

    /// "All servers", or the chosen server's name.
    var title: String
    /// The chosen server's id, nil for all servers; what a tap opens.
    var serverID: String?
    var feeds: [ServerFeed<Item>]
    var isPlaceholder = false

    init(title: String, serverID: String?, feeds: [ServerFeed<Item>], isPlaceholder: Bool = false) {
        self.title = title
        self.serverID = serverID
        self.feeds = feeds
        self.isPlaceholder = isPlaceholder
    }

    var items: [Item] { feeds.flatMap(\.items) }

    /// The sum of the feeds' totals; nil when no feed has a total.
    var total: Int? {
        let totals = feeds.compactMap(\.total)
        return totals.isEmpty ? nil : totals.reduce(0, +)
    }

    var secondaryTotal: Int? {
        let totals = feeds.compactMap(\.secondary)
        return totals.isEmpty ? nil : totals.reduce(0, +)
    }

    func state(now: Date) -> BoardState {
        if isPlaceholder { return BoardState(phase: .loading, unreachableNames: [], updatedAt: nil) }
        if feeds.isEmpty { return BoardState(phase: .noServers, unreachableNames: [], updatedAt: nil) }

        let withData = feeds.filter(\.hasData)
        let unreachable = feeds.filter { $0.condition == .unreachable }.map(\.serverName)

        if withData.isEmpty {
            if feeds.allSatisfy({ $0.condition == .signedOut }) {
                return BoardState(phase: .signedOut, unreachableNames: [], updatedAt: nil)
            }
            if feeds.allSatisfy({ $0.condition == .unavailable }) {
                return BoardState(phase: .unavailable, unreachableNames: [], updatedAt: nil)
            }
            if let first = unreachable.first {
                return BoardState(phase: .unreachable(serverName: first), unreachableNames: unreachable, updatedAt: nil)
            }
            if feeds.contains(where: { $0.condition == .signedOut }) {
                return BoardState(phase: .signedOut, unreachableNames: [], updatedAt: nil)
            }
            return BoardState(phase: .loading, unreachableNames: [], updatedAt: nil)
        }

        // A feed is out of date when it failed (other than a locked phone) or its data is older than the window.
        let outOfDate = withData.filter { feed in
            let failed = feed.condition != .current && feed.condition != .deviceLocked
            let old = feed.asOf.map { now.timeIntervalSince($0) > Self.freshness } ?? false
            return failed || old
        }
        let updatedAt = outOfDate.compactMap(\.asOf).min()
        let empty = items.isEmpty && (total ?? 0) == 0
        return BoardState(phase: empty ? .empty : .content, unreachableNames: unreachable, updatedAt: updatedAt)
    }
}

// MARK: Items

enum StreamDelivery: String, Codable, Equatable, Sendable {
    case direct, transcode

    init(raw: String?) {
        let value = (raw ?? "").lowercased().replacingOccurrences(of: "_", with: " ")
        self = value.contains("transcode") ? .transcode : .direct
    }

    var label: String {
        switch self {
        case .direct: String(localized: "Direct")
        case .transcode: String(localized: "Transcode")
        }
    }
}

/// How the whole session is delivered, in the app's words: Direct play, Remux, Direct stream, Transcode.
enum StreamMethodKind: String, Codable, Equatable, Sendable {
    case direct, remux, directStream, transcode, unknown

    init(_ method: StreamMethod) {
        switch method {
        case .direct: self = .direct
        case .remux: self = .remux
        case .directStream: self = .directStream
        case .transcode: self = .transcode
        case .unknown: self = .unknown
        }
    }

    var streamMethod: StreamMethod {
        switch self {
        case .direct: .direct
        case .remux: .remux
        case .directStream: .directStream
        case .transcode: .transcode
        case .unknown: .unknown
        }
    }

    /// "Direct play", "Remux", "Direct stream", "Transcode": the words of the Now playing page.
    var label: String { StreamFacts.label(for: streamMethod) }

    /// Only a transcode is lit: it is the one way of playing that costs the server something.
    var isLit: Bool { self == .transcode }
}

struct StreamItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var serverID: String
    var serverName: String
    /// Who is watching. A detail: hidden on the lock screen unless the setting is on.
    var user: String
    var title: String
    /// 0 to 1 when it was read, nil when the length is unknown.
    var progress: Double?
    var isPaused: Bool
    var delivery: StreamDelivery
    var bitrateKbps: Int?
    /// "maria · Living room": the user and the profile, as the app's session card says it.
    var userLabel: String? = nil
    /// "Infuse 8.1 · tvOS": the player and the device.
    var clientLine: String? = nil
    /// "HEVC 4K · MKV": what the file holds.
    var source: String? = nil
    var method: StreamMethodKind? = nil
    /// "H.264 1080p · HW QSV": what a transcode converts to and what does the work.
    var transcodeDetail: String? = nil
    /// Where playback was and how long the file is, as of `readAt`.
    var positionSeconds: Double? = nil
    var durationSeconds: Double? = nil
    var readAt: Date? = nil
}

// MARK: Time

extension StreamItem {
    /// A moment past the expected end, so the server has dropped the session by the time it is asked again.
    static let endSlack: TimeInterval = 20

    /// "maria · Living room", or the account alone.
    var userLine: String { userLabel ?? user }

    var methodKind: StreamMethodKind { method ?? (delivery == .transcode ? .transcode : .direct) }

    /// The file's length, when it is known.
    var length: Double? { durationSeconds.flatMap { $0 > 0 ? $0 : nil } }

    private var readPosition: Double? {
        if let positionSeconds { return max(0, positionSeconds) }
        if let progress, let length { return progress * length }
        return nil
    }

    /// While it plays and the reading is fresh, a stream moves on by itself between reads. Paused, or once the
    /// reading is older than the board's freshness window, it stays where it was.
    func isMoving(at date: Date) -> Bool {
        guard !isPaused, let readAt, readPosition != nil else { return false }
        let elapsed = date.timeIntervalSince(readAt)
        return elapsed > 0 && elapsed <= WidgetBoard<StreamItem>.freshness
    }

    /// Where playback is at `date`: the read position plus the time since, while it moves, never past the end.
    /// Data older than the freshness window stops where it was at the end of that window.
    func position(at date: Date) -> Double? {
        guard let base = readPosition else { return nil }
        var value = base
        if !isPaused, let readAt {
            value += min(max(0, date.timeIntervalSince(readAt)), WidgetBoard<StreamItem>.freshness)
        }
        if let length { value = min(value, length) }
        return value
    }

    /// 0 to 1 at `date`, nil when the length is unknown.
    func fraction(at date: Date) -> Double? {
        guard let length, let position = position(at: date) else { return progress }
        return min(1, max(0, position / length))
    }

    /// When the file should end if it keeps playing; nil while paused or when the length or the reading is unknown.
    var expectedEnd: Date? {
        guard !isPaused, let length, let readPosition, let readAt else { return nil }
        return readAt.addingTimeInterval(max(0, length - readPosition))
    }

    /// The moment the bar was at 0, for a bar the system moves by itself (`ProgressView(timerInterval:)`).
    var playbackStart: Date? {
        guard let readAt, let readPosition else { return nil }
        return readAt.addingTimeInterval(-readPosition)
    }

    /// A stream that should have ended a little while ago comes off the card until the next reading says
    /// otherwise. Only a reading that was fresh at the end can say so.
    func isOver(at date: Date) -> Bool {
        guard let end = expectedEnd, let readAt, end.timeIntervalSince(readAt) <= WidgetBoard<StreamItem>.freshness else { return false }
        return date >= end.addingTimeInterval(Self.endSlack)
    }
}

struct RequestItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var serverID: String
    var serverName: String
    var title: String
    var requester: String?
    var createdAt: Date?
}

struct LibraryScanActivity: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Equatable, Sendable { case queued, running }
    var phase: Phase
    /// 0 to 1 while a metadata refresh reports it; a scan run reports none.
    var progress: Double?
}

struct WidgetLibraryItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var serverID: String
    var serverName: String
    var name: String
    var lastScannedAt: Date?
    /// The scan warning's headline, nil when there is none.
    var warning: String?
    var activity: LibraryScanActivity?
}

enum NodeHealth: String, Codable, Equatable, Sendable {
    case healthy, draining, drained, unhealthy, disabled

    var label: String {
        switch self {
        case .healthy: String(localized: "Healthy")
        case .draining: String(localized: "Draining")
        case .drained: String(localized: "Drained")
        case .unhealthy: String(localized: "Unhealthy")
        case .disabled: String(localized: "Disabled")
        }
    }
}

struct NodeItem: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var serverID: String
    var serverName: String
    var name: String
    var health: NodeHealth
    var cpuPercent: Int?
    var memoryPercent: Int?
    /// The fullest disk.
    var diskPercent: Int?
}

/// A request action that did not work, shown in the widget until the next read.
struct WidgetActionNotice: Codable, Equatable, Sendable {
    var requestID: String
    var serverID: String
    var text: String
    var at: Date
}
