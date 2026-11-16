import Foundation
import Observation

/// Drives the "All servers" aggregate Activity tab: one section per server,
/// each backed by its OWN `ActivityViewModel` instance (the exact same type
/// single-server mode uses), so the already-tested pagination/filter/error
/// handling is reused as-is. Mirrors `AggregateStreamsViewModel`'s shape —
/// including NOT owning its own per-server `APIClient` cache; see that
/// type's doc comment (Stage 2 review C1/C2).
///
/// Pagination is deliberately per-section, NOT merged: each server's
/// "Load more" only ever calls that server's own `ActivityViewModel.loadMore`
/// directly (from the view), continuing that section's own cursor — this
/// view model only ever drives first-page loads via `loadAll`/`reload`.
///
/// The periodic poll respects each server's OWN active filter (review
/// finding I1) — `fanOut`'s `request` closure now receives the `AdminServer`
/// alongside its client, so `loadAll` can look up that server's filter from
/// `filters` and build the right query per server, instead of every section
/// being forced through one shared, unparameterized query.
@Observable
@MainActor
final class AggregateActivityViewModel {
    private(set) var orderedServers: [AdminServer] = []
    private var viewModelsByServer: [String: ActivityViewModel] = [:]
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

    func viewModel(for server: AdminServer) -> ActivityViewModel {
        if let existing = viewModelsByServer[server.id] { return existing }
        let created = ActivityViewModel()
        viewModelsByServer[server.id] = created
        return created
    }

    /// Pure, non-mutating lookup for the view's `body` — see
    /// `AggregateStreamsViewModel`'s identical doc comment (review finding
    /// I4): never insert into this cache from inside a SwiftUI body.
    func existingViewModel(for server: AdminServer) -> ActivityViewModel? { viewModelsByServer[server.id] }

    /// With `merging` (the periodic poll) a section that has paged on keeps its rows and cursor.
/// Fans the first-page GET out to every server concurrently (bounded by
    /// `fanOut`'s per-server timeout), using EACH server's own filter from
    /// `filters` (missing/absent means unfiltered), and applies each result
    /// to that server's own `ActivityViewModel` as soon as it arrives. Each
    /// call resets every INCLUDED section back to page one — callers (the
    /// view) both filter `servers` down to sections that haven't paged past
    /// page one AND pass each section's own currently-active filter, so the
    /// periodic poll neither truncates pagination nor silently drops a
    /// section's filter (review finding I1).
    func loadAll(filters: [String: HistoryFilter], servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, resolveClient: @escaping ServerClientResolver, merging: Bool = false, session: URLSession = .shared) async {
        orderedServers = servers
        recoveryState.retainServers(Set(servers.map(\.id)))
        for server in servers { _ = viewModel(for: server) }
        // Resolve + apply each server's CURRENT token to its shared client
        // fresh, right before firing the batch (review round 4).
        var tokens: [String: Int] = [:]
        var recoveryGenerations: [String: UInt64] = [:]
        for server in servers { tokens[server.id] = viewModel(for: server).beginLoad(filter: filters[server.id] ?? HistoryFilter()) }
        for server in servers { recoveryGenerations[server.id] = recoveryState.begin(serverID: server.id) }
        _ = await fanOut(
            servers: servers,
            store: store,
            session: session,
            onResult: { [weak self] sectionResult in
                guard let self, !Task.isCancelled else { return }
                let scoped = sessionState.scoped(to: sectionResult.server.id)
                let filter = filters[sectionResult.server.id] ?? HistoryFilter()
                let sectionViewModel = self.viewModel(for: sectionResult.server)
                guard merging || !sectionViewModel.isLoadingMore else { return }
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
                    merge: merging,
                    sessionState: scoped
                )
            },
            resolveClient: resolveClient,
            request: { (server: AdminServer, client: APIClient) async throws -> APICollection<PlaybackHistoryEntry> in
                try await client.playbackHistory(filter: filters[server.id] ?? HistoryFilter(), cursor: nil)
            }
        )
    }

    /// Reloads just ONE server's section back to page one — used by that
    /// section's own "Filter" button and per-section re-login.
    func reload(server: AdminServer, filter: HistoryFilter, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        let sectionClient = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let sectionViewModel = viewModel(for: server)
        let token = sectionViewModel.beginLoad(filter: filter)
        let recoveryGeneration = recoveryState.begin(serverID: server.id)
        let typedResult: Result<APICollection<PlaybackHistoryEntry>, ServerSectionFailure>
        do {
            let page: APICollection<PlaybackHistoryEntry> = try await sectionClient.playbackHistory(filter: filter, cursor: nil)
            typedResult = .success(page)
        } catch {
            typedResult = .failure(ServerSectionFailure.classify(error, fallback: String(localized: "Playback history couldn't be loaded. Try again.")))
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

    func resumeAfterReauthentication(server: AdminServer, filter: HistoryFilter, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        guard let origin = reauthenticationOriginsByServer.removeValue(forKey: server.id) else { return }
        switch origin {
        case .initialLoad:
            await reload(server: server, filter: filter, store: store, sessionState: sessionState, resolveClient: resolveClient, session: session)
        case .pagination:
            await loadMore(server: server, sessionState: sessionState, resolveClient: resolveClient)
        }
    }
}
