import Foundation
import Observation

/// Drives the All servers dashboard: one `DashboardViewModel` per server, the exact type the
/// single-server screen uses, so every section keeps its own loading, last-good-value and error
/// behavior per server. A server that is signed out, expired or unreachable shows that on its own
/// section and never touches another server's.
///
/// Servers load independently (each polls on its own), so one slow or dead server never delays the
/// others. Only sampled metrics are retained here; session rows come from the server's own client.
@Observable
@MainActor
final class AggregateDashboardViewModel {
    private(set) var orderedServers: [AdminServer] = []
    private var models: [String: DashboardViewModel] = [:]

    /// Pure lookup for `body`: nil until `reconcile` has run for this server.
    func model(for server: AdminServer) -> DashboardViewModel? {
        models[server.id]
    }

    /// Keeps one model per server in `servers`, creating the new ones and dropping the removed.
    func reconcile(servers: [AdminServer]) {
        orderedServers = servers
        let ids = Set(servers.map(\.id))
        models = models.filter { ids.contains($0.key) }
        for server in servers where models[server.id] == nil {
            models[server.id] = DashboardViewModel()
        }
    }

    /// Reads one server's sections. A server with no stored sign-in, or whose token already
    /// expired, is not asked: its section offers Sign In instead.
    func load(
        server: AdminServer,
        store: ServerStore,
        sessionState: AdminSessionState,
        resolveClient: ServerClientResolver,
        forceRefresh: Bool = false
    ) async {
        if models[server.id] == nil { reconcile(servers: orderedServers + [server]) }
        guard let model = models[server.id] else { return }
        guard store.accessToken(for: server.id) != nil else {
            model.reportUnavailable(.signedOut(message: String(localized: "Not signed in"), requestIdentity: nil))
            return
        }
        guard !sessionState.isTokenExpired(for: server.id) else { return }
        await model.load(
            client: resolveClient(server),
            sessionState: sessionState.scoped(to: server.id),
            forceRefresh: forceRefresh
        )
    }

    /// Reads a chart window just chosen on one server, without re-reading the rest.
    func loadCharts(
        server: AdminServer,
        sessionState: AdminSessionState,
        resolveClient: ServerClientResolver
    ) async {
        guard let model = models[server.id], !sessionState.isTokenExpired(for: server.id) else { return }
        await model.loadCharts(client: resolveClient(server), sessionState: sessionState.scoped(to: server.id))
    }

    /// Reads every server at once, each independently; used by pull to refresh.
    func loadAll(
        servers: [AdminServer],
        store: ServerStore,
        sessionState: AdminSessionState,
        resolveClient: @escaping ServerClientResolver,
        forceRefresh: Bool = false
    ) async {
        reconcile(servers: servers)
        await runConcurrently(servers.map { server in
            { await self.load(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient, forceRefresh: forceRefresh) }
        })
    }

    /// Reads one server's session list alone, for a `sessions` signal. A server that is signed out or
    /// whose token expired is not asked.
    func refreshSessions(
        server: AdminServer,
        sessionState: AdminSessionState,
        resolveClient: ServerClientResolver
    ) async {
        guard let model = models[server.id], !sessionState.isTokenExpired(for: server.id) else { return }
        await model.refreshSessions(client: resolveClient(server), sessionState: sessionState.scoped(to: server.id))
    }

}
