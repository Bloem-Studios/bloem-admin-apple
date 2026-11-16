import Foundation

// Fetches what each data widget shows, per saved server, with the app's sign-in from the shared keychain,
// and keeps the last good result. Every outcome is one of `FeedCondition`; nothing here throws to a widget.

/// A saved server a widget can ask: its id, its name and its HTTPS origin.
struct WidgetServer: Equatable, Sendable {
    let id: String
    let name: String
    let origin: URL?
}

extension AdminSnapshot {
    func widgetServers(serverID: String?) -> [WidgetServer] {
        let chosen = serverID.flatMap { id in servers.first { $0.id == id } }
        return (chosen.map { [$0] } ?? servers).map { WidgetServer(id: $0.id, name: $0.name, origin: $0.origin) }
    }
}

extension AdminSnapshot {
    /// The counts a widget just read, in place of the snapshot's, stamped with `now`. A server that could not
    /// say keeps the open app's last counts and the time they were read.
    func applying(_ counts: [String: (streams: Int?, requests: Int?)], at now: Date) -> AdminSnapshot {
        var copy = self
        for index in copy.servers.indices {
            guard let found = counts[copy.servers[index].id] else { continue }
            if let streams = found.streams { copy.servers[index].activeStreams = streams }
            if let requests = found.requests { copy.servers[index].requestsWaiting = requests }
            if found.streams != nil || found.requests != nil { copy.servers[index].countsAt = now }
        }
        return copy
    }
}

struct WidgetFetcher: Sendable {
    typealias APIFactory = @Sendable (URL, String) -> any WidgetServerAPI
    typealias Refresher = @Sendable (URL, String) async throws -> WidgetTokenPair

    struct Loaded<Item: Sendable>: Sendable {
        var items: [Item]
        var total: Int?
        var secondary: Int? = nil
    }

    let credentials: any SharedCredentialStoring
    let lock: CredentialRefreshLock
    let dataStore: any WidgetDataStoring
    let api: APIFactory
    let refresh: Refresher
    let now: @Sendable () -> Date

    static func live() -> WidgetFetcher? {
        guard let dataStore = FileWidgetDataStore.appGroup() else { return nil }
        let session = WidgetHTTP.makeSession()
        return WidgetFetcher(
            credentials: KeychainSharedCredentialStore(),
            lock: .appGroup(),
            dataStore: dataStore,
            api: { origin, token in WidgetHTTPAPI(baseURL: origin, accessToken: token, session: session) },
            refresh: { origin, refreshToken in
                try await WidgetHTTP.refresh(session: session, baseURL: origin, refreshToken: refreshToken)
            },
            now: { Date() }
        )
    }

    // MARK: Boards

    func streams(snapshot: AdminSnapshot?, serverID: String?) async -> WidgetBoard<StreamItem> {
        let clock = now
        return await board(\.streams, snapshot: snapshot, serverID: serverID) { api, server in
            let rows = try await api.sessions()
            let readAt = clock()
            let items = rows.prefix(12).map { WidgetStreamMapper.item($0, server: server, readAt: readAt) }
            let bandwidth = rows.compactMap(\.streamBitrateKbps).reduce(0, +)
            return Loaded(items: Array(items), total: rows.count, secondary: bandwidth)
        }
    }

    func requests(snapshot: AdminSnapshot?, serverID: String?) async -> WidgetBoard<RequestItem> {
        let result = await requestsBoard(snapshot: snapshot, serverID: serverID)
        // A failed action's note goes once the request is gone from a fresh list, or after ten minutes.
        var cache = dataStore.load()
        if let notice = cache.notice {
            let feed = result.feeds.first { $0.serverID == notice.serverID }
            let resolved = feed.map { $0.condition == .current && !$0.items.contains { $0.id == notice.requestID } } ?? false
            if resolved || cache.notice(now: now()) == nil {
                cache.notice = nil
                try? dataStore.save(cache)
            }
        }
        return result
    }

    private func requestsBoard(snapshot: AdminSnapshot?, serverID: String?) async -> WidgetBoard<RequestItem> {
        await board(\.requests, snapshot: snapshot, serverID: serverID) { api, server in
            guard try await api.requestCapabilities() else { throw WidgetAPIError(status: 404) }
            let counts = try await api.requestCounts()
            let rows = counts.needsApproval > 0 ? try await api.pendingRequests(limit: 8) : []
            var names: [String: String] = [:]
            if !rows.isEmpty, let users = try? await api.users() {
                names = Dictionary(users.map { ($0.id, $0.username) }, uniquingKeysWith: { first, _ in first })
            }
            let items = rows.map { row in
                RequestItem(
                    id: row.id, serverID: server.id, serverName: server.name,
                    title: row.year.map { "\(row.title) (\($0))" } ?? row.title,
                    requester: row.requestedByUserID.flatMap { names[$0] },
                    createdAt: WidgetDates.parse(row.createdAt)
                )
            }
            return Loaded(items: items, total: counts.needsApproval)
        }
    }

    func libraries(snapshot: AdminSnapshot?, serverID: String?) async -> WidgetBoard<WidgetLibraryItem> {
        await board(\.libraries, snapshot: snapshot, serverID: serverID) { api, server in
            let libraries = try await api.libraries()
            let runs = (try? await api.activeScans()) ?? []
            let jobs = (try? await api.libraryRefreshJobs()) ?? []
            let items = WidgetLibraryMapper.items(libraries: libraries, runs: runs, jobs: jobs, server: server)
            return Loaded(items: Array(items.prefix(10)), total: libraries.count)
        }
    }

    func nodes(snapshot: AdminSnapshot?, serverID: String?) async -> WidgetBoard<NodeItem> {
        await board(\.nodes, snapshot: snapshot, serverID: serverID) { api, server in
            let nodes = try await api.nodes()
            let items = nodes.map { WidgetNodeMapper.item($0, server: server) }
            return Loaded(items: Array(items.prefix(10)), total: nodes.count)
        }
    }

    /// The live stream and request counts of the Server status widget; nil for what a server could not say.
    func counts(snapshot: AdminSnapshot?, serverID: String?) async -> [String: (streams: Int?, requests: Int?)] {
        let servers = (snapshot?.widgetServers(serverID: serverID) ?? []).filter { $0.origin != nil }
        return await withTaskGroup(of: (String, Int?, Int?).self) { group in
            for server in servers {
                group.addTask {
                    let outcome = await self.call(server: server) { api in
                        let streams = try await api.sessions().count
                        let requests: Int?
                        do {
                            requests = try await api.requestCounts().needsApproval
                        } catch let error as WidgetAPIError where error.isMissing || error.isForbidden {
                            requests = nil
                        }
                        return (streams, requests)
                    }
                    if case .success(let value) = outcome { return (server.id, value.0, value.1) }
                    return (server.id, nil, nil)
                }
            }
            var found: [String: (streams: Int?, requests: Int?)] = [:]
            for await (id, streams, requests) in group where streams != nil || requests != nil {
                found[id] = (streams, requests)
            }
            return found
        }
    }

    // MARK: One server

    enum CallOutcome<Value: Sendable>: Sendable {
        case success(Value)
        case signedOut
        case unavailable
        case unreachable
        case deviceLocked
    }

    /// Runs `body` against one server with its sign-in. A 401 earns one refresh and one more try.
    func call<Value: Sendable>(
        server: WidgetServer, _ body: @Sendable (any WidgetServerAPI) async throws -> Value
    ) async -> CallOutcome<Value> {
        guard let origin = server.origin, origin.scheme?.lowercased() == "https" else { return .unavailable }
        let credential: SharedCredential
        switch credentials.read(serverID: server.id) {
        case .missing: return .signedOut
        case .locked: return .deviceLocked
        case .found(let found): credential = found
        }
        do {
            return .success(try await body(api(origin, credential.accessToken)))
        } catch let error as WidgetAPIError where error.isUnauthorized {
            guard let token = await renewedToken(server: server, origin: origin, rejected: credential.accessToken) else {
                return .signedOut
            }
            do {
                return .success(try await body(api(origin, token)))
            } catch let retry as WidgetAPIError {
                return Self.outcome(for: retry)
            } catch {
                return .unreachable
            }
        } catch let error as WidgetAPIError {
            return Self.outcome(for: error)
        } catch {
            return .unreachable
        }
    }

    private static func outcome<Value: Sendable>(for error: WidgetAPIError) -> CallOutcome<Value> {
        if error.isUnauthorized { return .signedOut }
        if error.isMissing { return .unavailable }
        if error.isForbidden { return .unavailable }
        return .unreachable
    }

    /// Another access token for the server, or nil when the sign-in is over. Under the lock it first looks
    /// again at the shared item, because the app may have refreshed already; only then does it spend the
    /// refresh token, and it writes the rotated pair back before it lets go of the lock.
    private func renewedToken(server: WidgetServer, origin: URL, rejected: String) async -> String? {
        let held = await lock.acquire()
        defer { held.release() }
        guard case .found(let current) = credentials.read(serverID: server.id) else { return nil }
        if current.accessToken != rejected { return current.accessToken }
        guard let refreshToken = current.refreshToken, !refreshToken.isEmpty else { return nil }
        do {
            let pair = try await refresh(origin, refreshToken)
            try? credentials.write(
                SharedCredential(accessToken: pair.accessToken, refreshToken: pair.refreshToken, updatedAt: now(), source: .widget),
                serverID: server.id
            )
            return pair.accessToken
        } catch {
            return nil
        }
    }

    private func board<Item: Codable & Equatable & Sendable>(
        _ path: WritableKeyPath<WidgetDataCache, [String: ServerFeed<Item>]>,
        snapshot: AdminSnapshot?,
        serverID: String?,
        load: @escaping @Sendable (any WidgetServerAPI, WidgetServer) async throws -> Loaded<Item>
    ) async -> WidgetBoard<Item> {
        let servers = snapshot?.widgetServers(serverID: serverID) ?? []
        let cache = dataStore.load()
        let stored = cache[keyPath: path]
        let time = now()

        let feeds: [ServerFeed<Item>] = await withTaskGroup(of: (Int, ServerFeed<Item>).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    let prior = stored[server.id]
                    let outcome = await self.call(server: server) { api in try await load(api, server) }
                    return (index, Self.feed(for: server, prior: prior, outcome: outcome, at: time))
                }
            }
            var result: [(Int, ServerFeed<Item>)] = []
            for await pair in group { result.append(pair) }
            return result.sorted { $0.0 < $1.0 }.map(\.1)
        }

        // Re-read before saving: another widget may have written its own part since this one began.
        var latest = dataStore.load()
        var slice = latest[keyPath: path]
        for feed in feeds { slice[feed.serverID] = feed }
        latest[keyPath: path] = slice
        latest.keepOnly(serverIDs: Set((snapshot?.servers ?? []).map(\.id)))
        latest.updatedAt = time
        try? dataStore.save(latest)

        let chosen = serverID.flatMap { id in snapshot?.servers.first { $0.id == id } }
        return WidgetBoard(title: chosen?.name ?? String(localized: "All servers"), serverID: chosen?.id, feeds: feeds)
    }

    static func feed<Item: Codable & Equatable & Sendable>(
        for server: WidgetServer, prior: ServerFeed<Item>?, outcome: CallOutcome<Loaded<Item>>, at time: Date
    ) -> ServerFeed<Item> {
        switch outcome {
        case .success(let loaded):
            return ServerFeed(
                serverID: server.id, serverName: server.name, condition: .current,
                items: loaded.items, total: loaded.total, secondary: loaded.secondary, asOf: time
            )
        case .signedOut:
            return ServerFeed(serverID: server.id, serverName: server.name, condition: .signedOut, items: [], total: nil, asOf: nil)
        case .unavailable:
            return ServerFeed(serverID: server.id, serverName: server.name, condition: .unavailable, items: [], total: nil, asOf: nil)
        case .unreachable, .deviceLocked:
            var kept = prior ?? ServerFeed(serverID: server.id, serverName: server.name, condition: .current, items: [], total: nil, asOf: nil)
            kept.serverName = server.name
            if case .deviceLocked = outcome { kept.condition = .deviceLocked } else { kept.condition = .unreachable }
            return kept
        }
    }

    // MARK: Request actions

    /// Approves or declines one request. On success the request leaves the stored list; on failure the
    /// widget gets a note ("Couldn't approve, open the app") until the next read.
    func actOnRequest(_ action: WidgetRequestAction, requestID: String, serverID: String, snapshot: AdminSnapshot?) async -> Bool {
        // Exactly this server: an id that is not saved must never fall back to another server.
        guard let saved = snapshot?.servers.first(where: { $0.id == serverID }) else { return false }
        let server = WidgetServer(id: saved.id, name: saved.name, origin: saved.origin)
        let outcome = await call(server: server) { api in try await api.act(on: requestID, action) }
        var cache = dataStore.load()
        let time = now()
        if case .success = outcome {
            if var feed = cache.requests[serverID] {
                if feed.items.contains(where: { $0.id == requestID }) { feed.total = max(0, (feed.total ?? 1) - 1) }
                feed.items.removeAll { $0.id == requestID }
                cache.requests[serverID] = feed
            }
            cache.notice = nil
            try? dataStore.save(cache)
            return true
        }
        let text = action == .approve
            ? String(localized: "Couldn't approve, open the app")
            : String(localized: "Couldn't decline, open the app")
        cache.notice = WidgetActionNotice(requestID: requestID, serverID: serverID, text: text, at: time)
        try? dataStore.save(cache)
        return false
    }
}

// MARK: Mapping

/// A playing session as a card: the words and the order of the app's own session card (`StreamRowView`,
/// `SignalPath`), built from the same presentation rules, so the widget and the Now playing page cannot
/// drift apart.
enum WidgetStreamMapper {
    static func item(_ dto: WidgetSessionDTO, server: WidgetServer, readAt: Date) -> StreamItem {
        let session = dto.session
        let method = session.streamMethod
        let length = session.fileDuration.flatMap { $0 > 0 ? $0 : nil }
        let position = max(0, session.positionSeconds)
        let sourceValue = session.videoFlow.source ?? StreamFormat.codec(session.sourceAudioCodec)
        return StreamItem(
            id: session.sessionID, serverID: server.id, serverName: server.name, user: session.username,
            title: session.streamTitle,
            progress: length.map { min(1, max(0, position / $0)) },
            isPaused: session.isPaused,
            delivery: StreamDelivery(raw: session.effectivePlayMethod ?? session.playMethod),
            bitrateKbps: session.streamBitrateKbps,
            userLabel: session.streamUserLabel.cleaned,
            clientLine: session.streamClientLine,
            source: StreamFacts.dotted([sourceValue, session.sourceContainerLabel]),
            method: StreamMethodKind(method),
            transcodeDetail: method == .transcode
                ? StreamFacts.dotted([session.videoFlow.target, session.transcodeMode.map { StreamFacts.label(for: $0) }])
                : nil,
            positionSeconds: position,
            durationSeconds: length,
            readAt: readAt
        )
    }
}

enum WidgetLibraryMapper {
    static func items(
        libraries: [WidgetLibraryDTO], runs: [WidgetScanRunDTO], jobs: [WidgetRefreshJobDTO], server: WidgetServer
    ) -> [WidgetLibraryItem] {
        libraries.filter { $0.enabled ?? true }.map { library in
            var activity: LibraryScanActivity?
            let mine = runs.filter { $0.libraryID == library.id }
            if mine.contains(where: { $0.status == "running" }) {
                activity = LibraryScanActivity(phase: .running, progress: nil)
            } else if !mine.isEmpty {
                activity = LibraryScanActivity(phase: .queued, progress: nil)
            }
            if let job = jobs.first(where: { $0.libraryID == library.id && !($0.terminal ?? false) && $0.progress != nil }),
               let progress = job.progress, progress.total > 0 {
                activity = LibraryScanActivity(
                    phase: .running, progress: min(1, max(0, Double(progress.current) / Double(progress.total)))
                )
            }
            return WidgetLibraryItem(
                id: library.id, serverID: server.id, serverName: server.name, name: library.name ?? library.id,
                lastScannedAt: WidgetDates.parse(library.lastScannedAt),
                warning: library.scanWarningCode.flatMap { $0.isEmpty ? nil : warningHeadline($0) },
                activity: activity
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func warningHeadline(_ code: String) -> String {
        switch code {
        case "empty_root": String(localized: "The scan found no media files")
        case "dead_root": String(localized: "A library folder cannot be reached")
        default:
            code.replacingOccurrences(of: "_", with: " ").prefix(1).uppercased()
                + code.replacingOccurrences(of: "_", with: " ").dropFirst()
        }
    }
}

enum WidgetNodeMapper {
    static func item(_ node: WidgetNodeDTO, server: WidgetServer) -> NodeItem {
        let isTranscode = (node.type ?? "transcode") == "transcode"
        let health: NodeHealth
        if !node.enabled {
            health = .disabled
        } else if !node.healthy {
            health = .unhealthy
        } else if isTranscode, node.drainState == "drained" {
            health = .drained
        } else if isTranscode, node.drainRequested == true || (node.drainState ?? "none") == "draining" {
            health = .draining
        } else {
            health = .healthy
        }
        let system = node.resources?.system
        let memory: Int? = {
            guard let used = system?.memUsedMb, let total = system?.memTotalMb, total > 0 else { return nil }
            return Int((Double(used) / Double(total) * 100).rounded())
        }()
        let disk = system?.disks?.filter { $0.unavailable != true && $0.totalGb > 0 }
            .map { Int(($0.usedGb / $0.totalGb * 100).rounded()) }.max()
        return NodeItem(
            id: node.id, serverID: server.id, serverName: server.name, name: node.name, health: health,
            cpuPercent: system?.cpuPct, memoryPercent: memory, diskPercent: disk
        )
    }
}
