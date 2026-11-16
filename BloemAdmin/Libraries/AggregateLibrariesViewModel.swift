import Foundation
import Observation

/// The All servers Libraries page: one section per server, each backed by its own `LibrariesViewModel` (the type
/// a single server uses), so every action runs on the row's own server through that server's client. Like
/// `AggregateJobsViewModel` it does not own clients: `AllServersView` owns one shared client per server and
/// hands it down as `resolveClient`.
@Observable
@MainActor
final class AggregateLibrariesViewModel {
    private(set) var orderedServers: [AdminServer] = []
    private var viewModelsByServer: [String: LibrariesViewModel] = [:]
    private var recoveryState = ServerSectionRecoveryState()
    func failure(for server: AdminServer) -> ServerSectionFailure? { recoveryState.failure(serverID: server.id) }

    func viewModel(for server: AdminServer) -> LibrariesViewModel {
        if let existing = viewModelsByServer[server.id] { return existing }
        let created = LibrariesViewModel(serverName: server.displayName)
        viewModelsByServer[server.id] = created
        return created
    }

    func existingViewModel(for server: AdminServer) -> LibrariesViewModel? { viewModelsByServer[server.id] }

    /// Reads every server at once and applies each answer to its own section as soon as it arrives.
    func loadAll(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, resolveClient: @escaping ServerClientResolver, session: URLSession = .shared) async {
        orderedServers = servers
        recoveryState.retainServers(Set(servers.map(\.id)))
        for server in servers { _ = viewModel(for: server) }
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
                try await client.librariesSnapshot()
            }
        )
    }

    /// Reads just one server again: after a sign-in on its section, or its Try again.
    func reload(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        let sectionClient = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let sectionViewModel = viewModel(for: server)
        let token = sectionViewModel.beginLoad()
        let recoveryGeneration = recoveryState.begin(serverID: server.id)
        let typedResult: Result<LibrariesSnapshot, ServerSectionFailure>
        do {
            typedResult = .success(try await sectionClient.librariesSnapshot())
        } catch {
            typedResult = .failure(ServerSectionFailure.classify(error, fallback: String(localized: "Could not load libraries. Check the connection and try again.")))
        }
        guard let result = recoveryState.apply(typedResult, serverID: server.id, generation: recoveryGeneration, sessionState: scoped) else { return }
        sectionViewModel.apply(result, token: token, sessionState: scoped)
    }
}
