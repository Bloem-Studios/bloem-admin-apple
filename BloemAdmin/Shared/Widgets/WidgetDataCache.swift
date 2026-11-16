import Foundation

// The last good data of every data widget, one file in the App Group (`widget-data.json`). The widget
// extension writes it when it refreshes; the app's own writes only trigger a reload. It holds what the
// widgets show, so it can hold names and titles; it is protected until the first unlock, never holds a token,
// and is removed with the app. Which of it a widget draws depends on the surface (see `WidgetSurface`).

struct WidgetDataCache: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = WidgetDataCache.currentVersion
    var streams: [String: ServerFeed<StreamItem>] = [:]
    var requests: [String: ServerFeed<RequestItem>] = [:]
    var libraries: [String: ServerFeed<WidgetLibraryItem>] = [:]
    var nodes: [String: ServerFeed<NodeItem>] = [:]
    /// The last failed request action, until a later read replaces it.
    var notice: WidgetActionNotice?
    var updatedAt: Date?

    /// How long a failed action's note stays on the widget.
    static let noticeLifetime: TimeInterval = 10 * 60

    func notice(now: Date) -> WidgetActionNotice? {
        notice.flatMap { now.timeIntervalSince($0.at) <= Self.noticeLifetime ? $0 : nil }
    }

    /// A board for the saved servers (`snapshot`), in their order; `serverID` nil is all servers. A saved
    /// server with no feed yet has an empty one, which reads as loading.
    func board<Item: Codable & Equatable & Sendable>(
        _ feeds: KeyPath<WidgetDataCache, [String: ServerFeed<Item>]>,
        snapshot: AdminSnapshot?,
        serverID: String?
    ) -> WidgetBoard<Item> {
        let all = snapshot?.servers ?? []
        let chosen = serverID.flatMap { id in all.first { $0.id == id } }
        let scoped = chosen.map { [$0] } ?? all
        let stored = self[keyPath: feeds]
        let result = scoped.map { server -> ServerFeed<Item> in
            var feed = stored[server.id] ?? ServerFeed<Item>(
                serverID: server.id, serverName: server.name, condition: .current, items: [], total: nil, secondary: nil, asOf: nil
            )
            feed.serverName = server.name
            return feed
        }
        return WidgetBoard(title: chosen?.name ?? String(localized: "All servers"), serverID: chosen?.id, feeds: result)
    }

    /// Drops what belongs to servers that are no longer saved.
    mutating func keepOnly(serverIDs: Set<String>) {
        streams = streams.filter { serverIDs.contains($0.key) }
        requests = requests.filter { serverIDs.contains($0.key) }
        libraries = libraries.filter { serverIDs.contains($0.key) }
        nodes = nodes.filter { serverIDs.contains($0.key) }
        if let notice, !serverIDs.contains(notice.serverID) { self.notice = nil }
    }
}

protocol WidgetDataStoring: Sendable {
    func load() -> WidgetDataCache
    func save(_ cache: WidgetDataCache) throws
}

struct FileWidgetDataStore: WidgetDataStoring {
    static let fileName = "widget-data.json"

    let directory: URL

    static func appGroup() -> FileWidgetDataStore? {
        AppGroup.containerURL.map { FileWidgetDataStore(directory: $0) }
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> WidgetDataCache {
        guard let data = try? Data(contentsOf: fileURL),
              let cache = try? JSONDecoder.widgetCache.decode(WidgetDataCache.self, from: data),
              cache.version == WidgetDataCache.currentVersion
        else { return WidgetDataCache() }
        return cache
    }

    func save(_ cache: WidgetDataCache) throws {
        let data = try JSONEncoder.widgetCache.encode(cache)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

extension JSONEncoder {
    static let widgetCache: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()
}

extension JSONDecoder {
    static let widgetCache: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()
}
