import Foundation

typealias ServerClientResolver = @MainActor @Sendable (AdminServer) -> APIClient

/// One server's outcome from a `fanOut` call — either the decoded value the
/// `request` closure returned, or the error that stopped it (a missing
/// stored token, a 401/403 from the server, a network failure, etc). Kept as
/// a `Result` (not a thrown error) specifically so ONE dead/unauthenticated
/// server never prevents the rest of `fanOut`'s callers from getting their
/// results — every "All servers" section renders independently off its own
/// `ServerSectionResult`.
struct ServerSectionResult<T: Sendable>: Sendable {
    let server: AdminServer
    let result: Result<T, ServerSectionFailure>
}

/// Synthetic error `fanOut` uses for a server with no stored Keychain token
/// at all, so that case produces a `.failure` section (a "tap to sign in"
/// row) without making a network call that would just 401 anyway.
struct NotSignedInError: LocalizedError, Sendable {
    var errorDescription: String? { "Not signed in" }
}

/// Thrown internally when a single server's request exceeds `timeout` and
/// converted into an ordinary `.failure` for THAT server — no worse than a
/// network error, and never allowed to hold up any other server's section.
/// See review finding I1: `URLSession.shared`'s default
/// `timeoutIntervalForRequest` is 60s, and without a much shorter per-child
/// bound here, one unresponsive server would stall the whole fan-out (and
/// the aggregate screen's 15s poll) for up to a minute.
/// True for a cancelled request (the app backgrounded or the user navigated
/// away mid-poll) — as opposed to a genuine failure. See review finding I2:
/// a cancelled child must never be materialized as a section error, since
/// that would flash a bogus "Connection lost" into every section the moment
/// `scenePhase` changes, purely as an artifact of the poll loop being torn
/// down rather than any real problem with the server.
private func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}

/// Races `operation` against a `seconds`-long `Task.sleep`, cancelling
/// whichever loses (the loser's task is cancelled via `group.cancelAll()`,
/// which cooperatively cancels an in-flight `URLSession` request too).
private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
            throw URLError(.timedOut)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw URLError(.timedOut)
        }
        return result
    }
}

/// Runs `request` concurrently against every server in `servers`, using each
/// server's own stored client (`ServerStore.client(for:)`), and collects a
/// per-server `Result` rather than throwing on — or waiting for — the first
/// failure. This is the shared building block behind every "All servers"
/// aggregate screen: each server is queried in parallel via `withTaskGroup`,
/// bounded independently by `timeout` (default 10s, well under
/// `URLSession.shared`'s 60s default) so one unresponsive server can never
/// stall the others, and a server with no stored token, or whose call fails
/// (401/403/network/timeout), produces a `.failure` `ServerSectionResult`
/// for its own section instead of aborting the other servers' sections or
/// crashing the aggregate view. A cancelled child (app backgrounded, view
/// torn down mid-poll) is dropped entirely rather than surfaced as a
/// failure — see `isCancellation`.
///
/// `onResult`, if supplied, is invoked on the caller's actor (via `await`,
/// so a `@MainActor` closure is safe to pass) as soon as EACH server's
/// result is available, rather than only after every server has answered —
/// this is what lets a caller like `AggregateStreamsViewModel.loadAll`
/// update a fast server's section immediately instead of waiting on a slow
/// or timed-out sibling. The final returned array is still fully collected
/// and reordered to match `servers` (not completion order), for callers
/// that just want the whole batch at once.
///
/// `session` defaults to `.shared` (the production path) and is only ever
/// overridden in tests, so a `MockURLProtocol`-backed session can be
/// injected without giving any production caller a reason to pass one.
///
/// `resolveClient`, if supplied, is asked for the `APIClient` to use for
/// EACH server instead of `fanOut` building a fresh one itself via
/// `store.client(for:)` — this is what lets a caller (`AllServersView`)
/// hand every aggregate tab the SAME shared, credential-provider-backed
/// client per server. `nil` (the default) preserves the original behavior
/// for any caller that has no shared client to hand in.
///
/// `request` receives the `AdminServer` alongside its `APIClient` (Stage 2
/// review I1) so a caller whose query varies per server — e.g. Activity's
/// per-section user-id filter — can build the right request without
/// abandoning `fanOut`'s bounded/concurrent/incremental-delivery guarantees
/// to fall back to one shared, unparameterized query for every server.
func fanOut<T: Sendable>(
    servers: [AdminServer],
    store: ServerStore,
    session: URLSession = .shared,
    timeout: TimeInterval = 10,
    onResult: (@MainActor @Sendable (ServerSectionResult<T>) -> Void)? = nil,
    resolveClient: ServerClientResolver? = nil,
    request: @escaping @Sendable (AdminServer, APIClient) async throws -> T
) async -> [ServerSectionResult<T>] {
    await withTaskGroup(of: ServerSectionResult<T>?.self) { group in
        for server in servers {
            group.addTask {
                guard store.accessToken(for: server.id) != nil else {
                    return ServerSectionResult(
                        server: server,
                        result: .failure(.signedOut(message: String(localized: "Not signed in"), requestIdentity: nil))
                    )
                }
                let client: APIClient
                if let resolveClient {
                    client = await resolveClient(server)
                } else {
                    client = store.client(for: server, session: session)
                }
                do {
                    let value = try await withTimeout(seconds: timeout) {
                        try await request(server, client)
                    }
                    return ServerSectionResult(server: server, result: .success(value))
                } catch {
                    if isCancellation(error) { return nil }
                    return ServerSectionResult(
                        server: server,
                        result: .failure(ServerSectionFailure.classify(
                            error,
                            fallback: String(localized: "Could not reach this server")
                        ))
                    )
                }
            }
        }
        var byServerID: [String: ServerSectionResult<T>] = [:]
        for await sectionResult in group {
            guard let sectionResult else { continue }
            byServerID[sectionResult.server.id] = sectionResult
            if let onResult {
                await onResult(sectionResult)
            }
        }
        return servers.compactMap { byServerID[$0.id] }
    }
}
