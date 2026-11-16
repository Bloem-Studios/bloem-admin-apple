import Foundation
import Observation

/// Drives the All servers Settings page: one row per server with its restart state and uptime, read
/// concurrently with `fanOut`. The settings themselves are per server: a row opens that server's own
/// named pages. Mirrors `AggregateStreamsViewModel`'s shape, including NOT owning a per-server
/// `APIClient` cache; see that type's doc comment.
@Observable
@MainActor
final class AggregateServerConfigViewModel {
    private(set) var statuses: [String: ServerStatus] = [:]
    private var recoveryState = ServerSectionRecoveryState()

    func failure(for server: AdminServer) -> ServerSectionFailure? { recoveryState.failure(serverID: server.id) }

    func status(for server: AdminServer) -> ServerStatus? { statuses[server.id] }

    func loadAll(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState, resolveClient: @escaping ServerClientResolver, session: URLSession = .shared) async {
        recoveryState.retainServers(Set(servers.map(\.id)))
        statuses = statuses.filter { id, _ in servers.contains { $0.id == id } }
        var recoveryGenerations: [String: UInt64] = [:]
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
                switch result {
                case .success(let status): self.statuses[sectionResult.server.id] = status
                case .failure(let error): _ = ErrorMessage.text(for: error, sessionState: sessionState.scoped(to: sectionResult.server.id), fallback: "")
                }
            },
            resolveClient: resolveClient,
            request: { (_, client: APIClient) async throws -> ServerStatus in
                try await client.serverStatus()
            }
        )
    }

    /// Reloads just one server's row, after a re-login.
    func reload(server: AdminServer, store: ServerStore, sessionState: AdminSessionState, resolveClient: ServerClientResolver, session: URLSession = .shared) async {
        let sectionClient = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let recoveryGeneration = recoveryState.begin(serverID: server.id)
        let typedResult: Result<ServerStatus, ServerSectionFailure>
        do {
            typedResult = .success(try await sectionClient.serverStatus())
        } catch {
            typedResult = .failure(ServerSectionFailure.classify(error, fallback: String(localized: "This server's settings couldn't be loaded. Try again")))
        }
        guard let result = recoveryState.apply(typedResult, serverID: server.id, generation: recoveryGeneration, sessionState: scoped) else { return }
        switch result {
        case .success(let status): statuses[server.id] = status
        case .failure(let error): _ = ErrorMessage.text(for: error, sessionState: scoped, fallback: "")
        }
    }
}
