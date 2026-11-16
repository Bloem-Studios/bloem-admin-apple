import SwiftUI

extension AdminServer {
    /// What the widget snapshot keeps of a server: its name and, for an HTTPS server, its origin.
    var snapshotInfo: SnapshotServerInfo {
        SnapshotServerInfo(id: id, name: displayName, origin: usesInsecureAddress ? nil : baseURL)
    }
}

enum SnapshotCountsMapper {
    /// A server that answered sets its counts; one that could not be asked (signed out, no access,
    /// unreachable) clears them, so a widget shows a dash and not an old number.
    static func updates(from results: [ServerSectionResult<SnapshotCounts>]) -> [String: SnapshotCountsUpdate] {
        var updates: [String: SnapshotCountsUpdate] = [:]
        for section in results {
            switch section.result {
            case .success(let counts): updates[section.server.id] = .set(counts)
            case .failure: updates[section.server.id] = .clear
            }
        }
        return updates
    }
}

/// Keeps the widget snapshot current while the app is open: the saved servers' names, and the two counts
/// that need a sign-in (active streams, requests waiting), read with the same sign-in the pages use.
@MainActor
enum SnapshotSync {
    static func write(
        servers: [AdminServer],
        counts: [String: SnapshotCountsUpdate] = [:],
        snapshots: any SnapshotStoring = SnapshotStores.shared,
        reloader: any WidgetTimelineReloading = SystemWidgetReloader(),
        now: Date = Date()
    ) {
        let snapshot = AdminSnapshot.make(
            previous: snapshots.load(), servers: servers.map(\.snapshotInfo), reachability: [:], counts: counts, now: now
        )
        try? snapshots.save(snapshot)
        reloader.reloadAll()
    }

    static func refreshCounts(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState) async {
        let askable = servers.filter { !$0.usesInsecureAddress }
        guard !askable.isEmpty else { return }
        let results: [ServerSectionResult<SnapshotCounts>] = await fanOut(
            servers: askable,
            store: store,
            timeout: 8,
            resolveClient: { server in store.client(for: server, sessionState: sessionState) },
            request: { _, client in
                async let sessions = client.listSessions()
                async let requests = client.requestCounts()
                return SnapshotCounts(streams: try await sessions.count, requests: try await requests.needsApproval)
            }
        )
        guard !Task.isCancelled else { return }
        write(servers: servers, counts: SnapshotCountsMapper.updates(from: results))
    }
}

private struct SnapshotSyncModifier: ViewModifier {
    let store: ServerStore
    let sessionState: AdminSessionState
    @Environment(\.scenePhase) private var scenePhase

    private struct Trigger: Hashable {
        let phase: ScenePhase
        let servers: [String]
        let credentialRevision: Int
    }

    func body(content: Content) -> some View {
        content.task(id: Trigger(
            phase: scenePhase,
            servers: store.servers.map { "\($0.id)|\($0.displayName)|\($0.baseURL.absoluteString)" },
            credentialRevision: store.credentialRevision
        )) {
            SnapshotSync.write(servers: store.servers)
            guard scenePhase == .active else { return }
            store.syncWidgetCredentials()
            WidgetSettingsSync.write()
            // Once each time the app opens, returns to the foreground or the servers change. Widgets keep
            // their own timeline after that; nothing here repeats.
            await SnapshotSync.refreshCounts(servers: store.servers, store: store, sessionState: sessionState)
        }
    }
}

extension View {
    func snapshotSync(store: ServerStore, sessionState: AdminSessionState) -> some View {
        modifier(SnapshotSyncModifier(store: store, sessionState: sessionState))
    }
}
