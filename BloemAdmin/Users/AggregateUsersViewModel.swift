import Foundation
import Observation

/// Drives the "All servers" aggregate Users tab: one section per server,
/// each backed by its OWN `UsersViewModel` instance, so the already-tested
/// search/enable/disable/delete/create/quota logic (all of
/// `UserDetailView`, unchanged) is reused as-is. Mirrors
/// `AggregateStreamsViewModel`'s shape — including NOT owning its own
/// per-server `APIClient` cache; see that type's doc comment.
@Observable
@MainActor
final class AggregateUsersViewModel {
    private(set) var orderedServers: [AdminServer] = []
    private var viewModelsByServer: [String: UsersViewModel] = [:]
    private var recoveryState = ServerSectionRecoveryState()

    func failure(for server: AdminServer) -> ServerSectionFailure? { recoveryState.failure(serverID: server.id) }

    func viewModel(for server: AdminServer) -> UsersViewModel {
        if let existing = viewModelsByServer[server.id] { return existing }
        let created = UsersViewModel(serverName: server.displayName)
        viewModelsByServer[server.id] = created
        return created
    }

    func existingViewModel(for server: AdminServer) -> UsersViewModel? { viewModelsByServer[server.id] }

    func loadAll(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, resolveClient: @escaping ServerClientResolver, session: URLSession = .shared) async {
        orderedServers = servers
        recoveryState.retainServers(Set(servers.map(\.id)))
        for server in servers { _ = viewModel(for: server) }
        // Resolve + apply each server's CURRENT token to its shared client
        // fresh, right before firing the batch (review round 4), without
        // depending on anything else to have already synced it.
        var tokens: [String: Int] = [:]
        var recoveryGenerations: [String: UInt64] = [:]
        for server in servers { tokens[server.id] = viewModel(for: server).beginLoad() }
        for server in servers { recoveryGenerations[server.id] = recoveryState.begin(serverID: server.id) }
        _ = await fanOut(
            servers: servers,
            store: store,
            session: session,
            onResult: { [weak self] sectionResult in
                guard let self, !Task.isCancelled else { return }
                guard let result = self.recoveryState.apply(
                    sectionResult.result,
                    serverID: sectionResult.server.id,
                    generation: recoveryGenerations[sectionResult.server.id] ?? 0,
                    sessionState: sessionState.scoped(to: sectionResult.server.id)
                ) else { return }
                self.viewModel(for: sectionResult.server).apply(
                    result,
                    token: tokens[sectionResult.server.id] ?? 0,
                    sessionState: sessionState.scoped(to: sectionResult.server.id)
                )
            },
            resolveClient: resolveClient,
            request: { _, client in
                try await client.users()
            }
        )
    }

    /// Reloads just ONE server's section — used after a per-section action
    /// (enable/disable/delete/create) succeeds, or a per-section
    /// re-login, leaving every other section's users
    /// untouched. Resolves + applies the CURRENT token to the shared client
    /// FRESH, synchronously, immediately before firing (review round 4),
    /// rather than depending on a separately-scheduled sync task to have
    /// already caught up.
    func reload(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        let sectionClient = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let sectionViewModel = viewModel(for: server)
        let token = sectionViewModel.beginLoad()
        let recoveryGeneration = recoveryState.begin(serverID: server.id)
        let typedResult: Result<[AdminUser], ServerSectionFailure>
        do {
            let users = try await sectionClient.users()
            typedResult = .success(users)
        } catch {
            typedResult = .failure(ServerSectionFailure.classify(error, fallback: String(localized: "Users couldn't be loaded. Try again.")))
        }
        guard let result = recoveryState.apply(typedResult, serverID: server.id, generation: recoveryGeneration, sessionState: scoped) else { return }
        sectionViewModel.apply(result, token: token, sessionState: scoped)
    }

    func refreshAfterDetailMutation(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver) async {
        await reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
    }
}
