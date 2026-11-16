import Foundation
import Observation

/// Drives the "All servers" aggregate Streams tab: one section per server,
/// each backed by its OWN `StreamsViewModel` instance (the exact same type
/// single-server mode uses), so the already-tested pause/resume/stop/
/// terminate + error-surfacing logic is reused as-is rather than
/// re-implemented for the aggregate case.
///
/// The initial/periodic load fans every server's `GET .../sessions` call out
/// concurrently via `fanOut` (item 2), then routes each server's outcome to
/// that server's own `StreamsViewModel.apply(_:sessionState:)` — a server
/// that fails to load produces that section's `errorMessage` (rendered by
/// the view as a "tap to sign in" row) without touching any other server's
/// section or crashing the aggregate load.
///
/// Unlike Stage 1, this view model does NOT own its own per-server
/// `APIClient` cache anymore. Every one of the seven aggregate tabs used to
/// build/cache its OWN client per server via `store.client(for:)`, so an
/// token change applied by one tab (e.g. Users) was invisible to
/// every other tab's cached client for the same server. `AllServersView`
/// now owns ONE shared `APIClient` per server and hands it down as
/// `resolveClient` to every tab, so identity is consistent across tabs.
///
/// The shared clients use credential providers, so every request captures
/// the current principal and generation atomically at construction time.
@Observable
@MainActor
final class AggregateStreamsViewModel {
    private(set) var orderedServers: [AdminServer] = []
    private var viewModelsByServer: [String: StreamsViewModel] = [:]
    private var recoveryState = ServerSectionRecoveryState()

    func failure(for server: AdminServer) -> ServerSectionFailure? {
        recoveryState.failure(serverID: server.id)
    }

    /// The per-server view model backing one section — created on first
    /// access and reused thereafter, so a section's state (its sessions,
    /// its errorMessage, any in-flight action) survives across polls. Only
    /// ever call this from `loadAll`/`reload`, never from `body` (review
    /// finding I4: mutating this `@Observable` class's stored storage from
    /// inside a SwiftUI body evaluation is undefined-behavior-adjacent) —
    /// use `existingViewModel(for:)` there instead.
    func viewModel(for server: AdminServer) -> StreamsViewModel {
        if let existing = viewModelsByServer[server.id] {
            return existing
        }
        let created = StreamsViewModel(serverName: server.displayName)
        viewModelsByServer[server.id] = created
        return created
    }

    /// Pure, non-mutating lookup for `AggregateStreamsView.body` (I4): a
    /// section renders a loading placeholder until `loadAll`'s pre-populate
    /// pass below has run at least once, rather than the body itself ever
    /// inserting into `viewModelsByServer`.
    func existingViewModel(for server: AdminServer) -> StreamsViewModel? {
        viewModelsByServer[server.id]
    }

    /// Fans the sessions GET out to every server concurrently and applies
    /// each result to that server's own `StreamsViewModel` AS SOON AS it
    /// arrives (via `fanOut`'s `onResult`), rather than waiting for the
    /// slowest/timed-out server before any section updates (review finding
    /// I1). Safe to call repeatedly (e.g. every 15s from the aggregate
    /// Streams view's poll loop) — each call is a fresh, independent
    /// fan-out. `resolveClient` supplies `fanOut`'s per-server client
    /// (see this type's doc comment) — passed through unchanged, never
    /// cached here.
    func loadAll(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, resolveClient: @escaping ServerClientResolver, session: URLSession = .shared) async {
        orderedServers = servers
        recoveryState.retainServers(Set(servers.map(\.id)))
        // Pre-populate the per-server view-model cache up front,
        // synchronously, before any network I/O — this is what lets `body`
        // use the pure lookup (I4) instead of lazily inserting mid-render.
        for server in servers {
            _ = viewModel(for: server)
        }
        // Resolve each server's shared provider-backed client for this batch.
        var recoveryGenerations: [String: UInt64] = [:]
        for server in servers {
            recoveryGenerations[server.id] = recoveryState.begin(serverID: server.id)
        }
        _ = await fanOut(
            servers: servers,
            store: store,
            session: session,
            onResult: { [weak self] sectionResult in
                // Backgrounding/navigating away mid-poll cancels this Task;
                // a result that races past that point must not write a
                // stale update into a section (review finding I2 — fanOut
                // itself already drops genuinely cancelled child requests,
                // this is the belt-and-suspenders check on the apply side).
                guard let self, !Task.isCancelled else { return }
                guard let result = self.recoveryState.apply(
                    sectionResult.result,
                    serverID: sectionResult.server.id,
                    generation: recoveryGenerations[sectionResult.server.id] ?? 0,
                    sessionState: sessionState.scoped(to: sectionResult.server.id)
                ) else { return }
                self.viewModel(for: sectionResult.server).apply(
                    result,
                    sessionState: sessionState.scoped(to: sectionResult.server.id)
                )
            },
            resolveClient: resolveClient,
            request: { _, client in
                try await client.listSessions()
            }
        )
    }

    /// Reloads just ONE server's section — used after a successful
    /// re-authentication of a previously-failed section, so the other
    /// sections' state (and any in-flight polling) is left untouched.
    /// Resolves the shared provider-backed client immediately before firing.
    func reload(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        let sectionClient = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let generation = recoveryState.begin(serverID: server.id)
        let typedResult: Result<[AdminSession], ServerSectionFailure>
        do {
            typedResult = .success(try await sectionClient.listSessions())
        } catch {
            typedResult = .failure(ServerSectionFailure.classify(
                error,
                fallback: String(localized: "Now playing couldn't be loaded. Try again.")
            ))
        }
        guard let result = recoveryState.apply(typedResult, serverID: server.id, generation: generation, sessionState: scoped) else { return }
        viewModel(for: server).apply(result, sessionState: scoped)
    }

    func refreshAfterDetailMutation(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver) async {
        await reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
    }
}
