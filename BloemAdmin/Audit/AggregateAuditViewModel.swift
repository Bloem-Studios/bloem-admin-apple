import Foundation
import Observation

/// Drives the "All servers" aggregate Audit tab: one section per server,
/// each backed by its OWN `AuditViewModel` instance, so the already-tested
/// cursor-based pagination + user-id filter logic is reused as-is. Mirrors
/// `AggregateActivityViewModel`'s shape (the other read-only, paginated
/// aggregate tab) — pagination here is per-section too: each server's
/// "Load more" continues that server's own cursor, never a merged feed.
/// Does NOT own its own per-server `APIClient` cache; see
/// `AggregateStreamsViewModel`'s doc comment (Stage 2 review C1/C2).
@Observable
@MainActor
final class AggregateAuditViewModel {
    private(set) var orderedServers: [AdminServer] = []
    private var viewModelsByServer: [String: AuditViewModel] = [:]
    private var recoveryState = ServerSectionRecoveryState()
    private var reauthenticationOriginsByServer: [String: ServerSectionReauthenticationOrigin] = [:]

    func failure(for server: AdminServer) -> ServerSectionFailure? { recoveryState.failure(serverID: server.id) }
    func paginationFailure(for server: AdminServer) -> ServerSectionFailure? { existingViewModel(for: server)?.loadMoreFailure }
    func reauthenticationOrigin(for server: AdminServer) -> ServerSectionReauthenticationOrigin? {
        reauthenticationOriginsByServer[server.id]
    }

    func beginReauthentication(for server: AdminServer, origin: ServerSectionReauthenticationOrigin) {
        reauthenticationOriginsByServer[server.id] = origin
    }

    func viewModel(for server: AdminServer) -> AuditViewModel {
        if let existing = viewModelsByServer[server.id] { return existing }
        let created = AuditViewModel()
        viewModelsByServer[server.id] = created
        return created
    }

    func existingViewModel(for server: AdminServer) -> AuditViewModel? { viewModelsByServer[server.id] }

    /// Fans the first-page GET out to every server concurrently, using each
    /// server's own filter from `filters` (missing/absent means
    /// unfiltered). Unlike Activity, single-server Audit deliberately
    /// doesn't poll on a timer (see `AuditListView`'s doc comment — a
    /// historical log a reviewer pages through shouldn't reset mid-review),
    /// so this is only ever called once on appear and from pull-to-refresh/
    /// per-section re-login, never from a repeating `.task(id:)` loop.
    func loadAll(filters: [String: AuditFilter], servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, resolveClient: @escaping ServerClientResolver, session: URLSession = .shared) async {
        orderedServers = servers
        recoveryState.retainServers(Set(servers.map(\.id)))
        for server in servers { _ = viewModel(for: server) }
        // Resolve + apply each server's CURRENT token to its shared client
        // fresh, right before firing the batch (review round 4).
        var tokens: [String: Int] = [:]
        var recoveryGenerations: [String: UInt64] = [:]
        for server in servers { tokens[server.id] = viewModel(for: server).beginLoad(filter: filters[server.id] ?? AuditFilter()) }
        for server in servers { recoveryGenerations[server.id] = recoveryState.begin(serverID: server.id) }
        _ = await fanOut(
            servers: servers,
            store: store,
            session: session,
            onResult: { [weak self] sectionResult in
                guard let self, !Task.isCancelled else { return }
                let scoped = sessionState.scoped(to: sectionResult.server.id)
                let filter = filters[sectionResult.server.id] ?? AuditFilter()
                let sectionViewModel = self.viewModel(for: sectionResult.server)
                guard !sectionViewModel.isLoadingMore else { return }
                guard let result = self.recoveryState.apply(
                    sectionResult.result,
                    serverID: sectionResult.server.id,
                    generation: recoveryGenerations[sectionResult.server.id] ?? 0,
                    sessionState: scoped
                ) else { return }
                sectionViewModel.apply(
                    filter: filter,
                    result,
                    token: tokens[sectionResult.server.id] ?? 0,
                    sessionState: scoped
                )
            },
            resolveClient: resolveClient,
            request: { (server: AdminServer, client: APIClient) async throws -> APICollection<AuditLogEntry> in
                try await client.auditLogs(filter: filters[server.id] ?? AuditFilter(), cursor: nil, limit: AuditViewModel.pageSize)
            }
        )
    }

    /// Reloads just ONE server's section back to page one — used by that
    /// section's own "Filter" button and per-section re-login.
    func reload(server: AdminServer, filter: AuditFilter, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        let sectionClient = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let sectionViewModel = viewModel(for: server)
        let token = sectionViewModel.beginLoad(filter: filter)
        let recoveryGeneration = recoveryState.begin(serverID: server.id)
        let typedResult: Result<APICollection<AuditLogEntry>, ServerSectionFailure>
        do {
            let response = try await sectionClient.auditLogs(
                filter: filter,
                cursor: nil,
                limit: AuditViewModel.pageSize
            )
            typedResult = .success(response)
        } catch {
            typedResult = .failure(ServerSectionFailure.classify(error, fallback: String(localized: "The audit log couldn't be loaded. Try again.")))
        }
        guard !sectionViewModel.isLoadingMore else { return }
        guard let result = recoveryState.apply(typedResult, serverID: server.id, generation: recoveryGeneration, sessionState: scoped) else { return }
        sectionViewModel.apply(filter: filter, result, token: token, sessionState: scoped)
    }

    func loadMore(server: AdminServer, sessionState: AdminSessionState, resolveClient: ServerClientResolver) async {
        await viewModel(for: server).loadMore(
            client: resolveClient(server),
            sessionState: sessionState.scoped(to: server.id)
        )
    }

    func resumeAfterReauthentication(server: AdminServer, filter: AuditFilter, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        guard let origin = reauthenticationOriginsByServer.removeValue(forKey: server.id) else { return }
        switch origin {
        case .initialLoad:
            await reload(server: server, filter: filter, store: store, sessionState: sessionState, resolveClient: resolveClient, session: session)
        case .pagination:
            await loadMore(server: server, sessionState: sessionState, resolveClient: resolveClient)
        }
    }
}
