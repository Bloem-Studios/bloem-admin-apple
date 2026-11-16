import Foundation
import Observation

/// A failure the page words itself (a missing guard, say), as opposed to one the server answered.
struct SectionActionError: Error {
    let message: String
}

/// The state of one server's page of rows: what was last read, why a read failed, and the one write in
/// flight per item. The Nodes, Backups and Plugins pages each use one for a single server, and All
/// servers keeps one per server so a write on a row goes only to that server's client.
///
/// A failed read keeps the last good rows beside the failure. A failed write sets `actionErrorMessage`
/// and does not reload over it; a write that worked reloads. Reads from older requests never overwrite
/// newer ones.
@Observable
@MainActor
final class SectionModel<Payload: Sendable> {
    private(set) var payload: Payload?
    /// Why the last read failed, by kind; drives the full page failure while there are no rows.
    private(set) var loadFailure: ServerSectionFailure?
    private(set) var actionErrorMessage: String?
    /// Items with a write in flight.
    private(set) var busyIDs: Set<String> = []
    /// Set in All servers mode so errors say which server they came from.
    let serverName: String?

    @ObservationIgnored private let loadFallback: String
    @ObservationIgnored private let fetch: @Sendable (APIClient) async throws -> Payload
    @ObservationIgnored private var requestID = 0

    init(
        serverName: String? = nil,
        loadFallback: String,
        fetch: @escaping @Sendable (APIClient) async throws -> Payload
    ) {
        self.serverName = serverName
        self.loadFallback = loadFallback
        self.fetch = fetch
    }

    var errorMessage: String? { loadFailure?.message }

    func beginLoad() -> Int {
        requestID += 1
        return requestID
    }

    /// Applies a read that was fetched elsewhere (All servers' fan-out), if `token` is still current.
    func apply(_ result: Result<Payload, Error>, token: Int, sessionState: ServerScopedSession?) {
        guard token == requestID else { return }
        switch result {
        case .success(let value):
            payload = value
            loadFailure = nil
        case .failure(let error):
            loadFailure = ErrorMessage.failure(
                for: error, sessionState: sessionState, fallback: loadFallback, serverName: nil
            )
        }
    }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        let token = beginLoad()
        do {
            apply(.success(try await fetch(client)), token: token, sessionState: sessionState)
        } catch {
            if error is CancellationError { return }
            apply(.failure(error), token: token, sessionState: sessionState)
        }
    }

    func clearActionError() {
        actionErrorMessage = nil
    }

    /// Runs one write on item `id`, then reads again. Returns true when the write worked. A second write
    /// on the same item while one is in flight is ignored. `conflictMessage` words a 412 or 428.
    @discardableResult
    func act(
        id: String,
        fallback: String,
        conflictMessage: String? = nil,
        client: APIClient,
        sessionState: ServerScopedSession? = nil,
        _ work: @MainActor (APIClient) async throws -> Void
    ) async -> Bool {
        guard !busyIDs.contains(id) else { return false }
        busyIDs.insert(id)
        defer { busyIDs.remove(id) }
        do {
            try await work(client)
            actionErrorMessage = nil
        } catch {
            if error is CancellationError { return false }
            actionErrorMessage = Self.text(
                for: error, fallback: fallback, conflictMessage: conflictMessage,
                sessionState: sessionState, serverName: serverName
            )
            return false
        }
        await load(client: client, sessionState: sessionState)
        return true
    }

    private static func text(
        for error: Error, fallback: String, conflictMessage: String?,
        sessionState: ServerScopedSession?, serverName: String?
    ) -> String {
        if let own = error as? SectionActionError {
            return ErrorMessage.named(own.message, serverName: serverName)
        }
        if let conflictMessage, let api = error as? APIError, api.statusCode == 412 || api.statusCode == 428 {
            return ErrorMessage.named(conflictMessage, serverName: serverName)
        }
        return ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
    }
}
