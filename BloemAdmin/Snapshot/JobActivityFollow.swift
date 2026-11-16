import SwiftUI

/// Keeps the scan and backup Live Activities current while the app is in the foreground: for each server
/// with a followed job it subscribes to `scans`, `jobs` and `tasks` (a backup is the `backup` task) on the
/// shared live connection and reads what the activity needs when one of them changes. It does nothing in
/// the background, and nothing when no activity is followed. In the background the activity is not updated
/// at all (no socket, no timer, no polling); it goes stale and is dismissed. Push is the background path.
enum JobActivityFollowing {
    static let channels: Set<LiveChannel> = [.scans, .jobs, .tasks]

    /// Runs until cancelled. One subscription per server, each reading only that server's followed jobs.
    @MainActor
    static func run(
        servers: [(id: String, client: APIClient)],
        tracker: AdminJobActivityTracker,
        connection: @MainActor (APIClient) -> LiveConnection = { LiveHub.shared.connection(for: $0) },
        clock: any LiveClock = SystemLiveClock()
    ) async {
        let runs = servers.map { server -> Task<Void, Never> in
            let id = server.id
            let client = server.client
            let live = connection(client)
            return Task { @MainActor in
                await LiveRefreshDriver.run(
                    connection: live, channels: channels, clock: clock,
                    initial: { await tracker.refresh(serverID: id, client: client) },
                    onSignals: { _ in await tracker.refresh(serverID: id, client: client) }
                )
            }
        }
        await withTaskCancellationHandler {
            for run in runs { await run.value }
        } onCancel: {
            for run in runs { run.cancel() }
        }
    }
}

struct JobActivityFollow: ViewModifier {
    let store: ServerStore
    let sessionState: AdminSessionState
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Hashable {
        let active: Bool
        let followed: [String]
    }

    func body(content: Content) -> some View {
        let tracker = AdminJobActivityTracker.shared
        let followed = tracker.followedServerIDs
        return content.task(id: Key(active: scenePhase == .active, followed: followed.sorted())) {
            guard scenePhase == .active, !followed.isEmpty else { return }
            let servers = store.servers.filter { followed.contains($0.id) }.map {
                (id: $0.id, client: store.client(for: $0, sessionState: sessionState))
            }
            await JobActivityFollowing.run(servers: servers, tracker: tracker)
        }
    }
}

extension View {
    func jobActivityFollow(store: ServerStore, sessionState: AdminSessionState) -> some View {
        modifier(JobActivityFollow(store: store, sessionState: sessionState))
    }
}
