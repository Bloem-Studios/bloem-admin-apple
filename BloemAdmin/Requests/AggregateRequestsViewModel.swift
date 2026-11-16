import Foundation
import Observation

/// Drives the "All servers" aggregate Requests tab: one section per server,
/// each backed by its OWN `RequestsViewModel` instance, so the already-tested
/// approve/decline/retry/cancel logic (including RequestDetailView's
/// confirmation dialogs) is reused as-is. Mirrors `AggregateStreamsViewModel`
/// — including NOT owning its own per-server `APIClient` cache; see that
/// type's doc comment (Stage 2 review C1/C2).
@Observable
@MainActor
final class AggregateRequestsViewModel {
    private(set) var orderedServers: [AdminServer] = []
    private var viewModelsByServer: [String: RequestsViewModel] = [:]
    private var recoveryState = ServerSectionRecoveryState()
    /// Account id to username, per server; a server whose account list could not be read has no entry
    /// and its requesters read "User 12". Account ids are only unique within one server.
    private var namesByServer: [String: [String: String]] = [:]
    /// "<server id>/<request id>" of every action in flight, so a row cannot send a second one.
    private(set) var busyKeys: Set<String> = []

    /// Servers that said they run no request administration. Their section says so and has nothing to retry;
    /// the poll leaves them alone until a pull to refresh asks again.
    private var unavailableServerIDs: Set<String> = []

    func failure(for server: AdminServer) -> ServerSectionFailure? { recoveryState.failure(serverID: server.id) }

    func isUnavailable(_ server: AdminServer) -> Bool { unavailableServerIDs.contains(server.id) }

    /// One server's read: its requests, or the word that it has no request administration.
    fileprivate enum RequestsRead: Sendable {
        case rows([MediaRequest])
        case unavailable
    }

    nonisolated private static func read(_ client: APIClient) async throws -> RequestsRead {
        do {
            return .rows(try await client.mediaRequests())
        } catch where RequestAvailability.isUnavailable(error) {
            return .unavailable
        }
    }

    /// Hands one server's read to its section.
    private func apply(
        _ result: Result<RequestsRead, Error>, to server: AdminServer, token: Int, sessionState: ServerScopedSession
    ) {
        switch result {
        case .success(.rows(let loaded)):
            unavailableServerIDs.remove(server.id)
            viewModel(for: server).apply(.success(loaded), token: token, sessionState: sessionState)
        case .success(.unavailable):
            unavailableServerIDs.insert(server.id)
            viewModel(for: server).apply(.success([]), token: token, sessionState: sessionState)
        case .failure(let error):
            viewModel(for: server).apply(.failure(error), token: token, sessionState: sessionState)
        }
    }

    func viewModel(for server: AdminServer) -> RequestsViewModel {
        if let existing = viewModelsByServer[server.id] { return existing }
        let created = RequestsViewModel(serverName: server.displayName)
        viewModelsByServer[server.id] = created
        return created
    }

    func existingViewModel(for server: AdminServer) -> RequestsViewModel? { viewModelsByServer[server.id] }

    /// Reads every server's requests at once. The poll leaves servers that have no request administration alone;
    /// `includeUnavailable` (a pull to refresh) asks them again.
    func loadAll(
        servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState,
        resolveClient: @escaping ServerClientResolver, session: URLSession = .shared, includeUnavailable: Bool = false
    ) async {
        orderedServers = servers
        recoveryState.retainServers(Set(servers.map(\.id)))
        unavailableServerIDs.formIntersection(servers.map(\.id))
        for server in servers { _ = viewModel(for: server) }
        let asked = includeUnavailable ? servers : servers.filter { !unavailableServerIDs.contains($0.id) }
        // Resolve + apply each server's CURRENT token to its shared client
        // fresh, right before firing the batch (review round 4).
        var tokens: [String: Int] = [:]
        var recoveryGenerations: [String: UInt64] = [:]
        for server in asked { tokens[server.id] = viewModel(for: server).beginLoad() }
        for server in asked { recoveryGenerations[server.id] = recoveryState.begin(serverID: server.id) }
        _ = await fanOut(
            servers: asked,
            store: store,
            session: session,
            onResult: { [weak self] (sectionResult: ServerSectionResult<RequestsRead>) in
                guard let self, !Task.isCancelled else { return }
                guard let result = self.recoveryState.apply(
                    sectionResult.result,
                    serverID: sectionResult.server.id,
                    generation: recoveryGenerations[sectionResult.server.id] ?? 0,
                    sessionState: sessionState.scoped(to: sectionResult.server.id)
                ) else { return }
                self.apply(
                    result, to: sectionResult.server, token: tokens[sectionResult.server.id] ?? 0,
                    sessionState: sessionState.scoped(to: sectionResult.server.id)
                )
            },
            resolveClient: resolveClient,
            request: { _, client in
                try await Self.read(client)
            }
        )
    }

    /// Reloads just ONE server's section — used after a per-section
    /// approve/decline/retry/cancel action succeeds, or a per-section
    /// re-login, leaving every other section untouched. Resolves + applies
    /// the CURRENT token fresh, synchronously, immediately before firing
    /// (review round 4).
    func reload(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        let sectionClient = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let sectionViewModel = viewModel(for: server)
        let token = sectionViewModel.beginLoad()
        let recoveryGeneration = recoveryState.begin(serverID: server.id)
        let typedResult: Result<RequestsRead, ServerSectionFailure>
        do {
            typedResult = .success(try await Self.read(sectionClient))
        } catch {
            typedResult = .failure(ServerSectionFailure.classify(error, fallback: String(localized: "Requests couldn't be loaded. Try again.")))
        }
        guard let result = recoveryState.apply(typedResult, serverID: server.id, generation: recoveryGeneration, sessionState: scoped) else { return }
        apply(result, to: server, token: token, sessionState: scoped)
    }

    func refreshAfterDetailMutation(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver) async {
        await reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
    }

    // MARK: Requester names

    func requester(for request: MediaRequest, on server: AdminServer) -> String {
        RequestQueue.requesterLabel(request, names: namesByServer[server.id] ?? [:])
    }

    /// Best effort: reads the account list of every server that has none yet, all at once. A server
    /// that cannot answer is tried again on the next call; its requesters read "User 12" meanwhile.
    func loadNames(servers: [AdminServer], resolveClient: ServerClientResolver) async {
        let missing = servers.filter { namesByServer[$0.id] == nil }
        let clients = missing.map { ($0, resolveClient($0)) }
        await withTaskGroup(of: (String, [String: String]?).self) { group in
            for (server, client) in clients {
                group.addTask {
                    guard let users = try? await client.users() else { return (server.id, nil) }
                    return (server.id, Dictionary(users.map { ($0.id, $0.username) }, uniquingKeysWith: { first, _ in first }))
                }
            }
            for await (serverID, names) in group {
                if let names { namesByServer[serverID] = names }
            }
        }
    }

    // MARK: Actions

    private func busyKey(_ request: MediaRequest, _ server: AdminServer) -> String { "\(server.id)/\(request.id)" }

    func isBusy(_ request: MediaRequest, on server: AdminServer) -> Bool { busyKeys.contains(busyKey(request, server)) }

    /// Runs `action` on the row's own server, then reloads only that server's section. A row that is
    /// already busy refuses a second action (false). A refused action answers false too; the reason is
    /// in that section's `actionErrorMessage`.
    func perform(
        _ action: RequestQueueAction, on request: MediaRequest, reason: String?, server: AdminServer,
        store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver
    ) async -> Bool {
        let key = busyKey(request, server)
        guard !busyKeys.contains(key) else { return false }
        busyKeys.insert(key)
        defer { busyKeys.remove(key) }
        let sectionViewModel = viewModel(for: server)
        let client = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        switch action {
        case .approve: await sectionViewModel.approve(request, client: client, sessionState: scoped)
        case .decline: await sectionViewModel.decline(request, reason: reason, client: client, sessionState: scoped)
        case .retry: await sectionViewModel.retry(request, client: client, sessionState: scoped)
        case .cancel: await sectionViewModel.cancel(request, reason: reason, client: client, sessionState: scoped)
        }
        guard sectionViewModel.actionErrorMessage == nil else { return false }
        await refreshAfterDetailMutation(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
        return true
    }
}
