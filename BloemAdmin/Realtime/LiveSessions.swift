import Foundation
import Observation

/// The live sessions behind Now playing and the dashboard: the list read from
/// `GET /api/v2/admin/sessions`, kept current by the `sessions` channel of the server's shared live
/// connection (a read on every cue) and, only while that socket is down, by a read at most once a minute.
/// A port of Android's `LiveSessionsRepository`.
///
/// `run()` is the foreground lifetime: start it when the screen is active and cancel it when the app
/// leaves the foreground. The socket is always a cue and never data, so the list a person sees is the
/// REST list.
@Observable
@MainActor
final class LiveSessions {
    /// The last list read; nil until the first read, and after a lost sign-in.
    private(set) var sessions: [AdminSession]?
    /// The latest list read's failure, by kind; the last good rows stay beside it.
    private(set) var readFailure: ServerSectionFailure?
    /// Told about a 401 or 403 so the app can route to sign-in. Set by the screen before `run()`.
    @ObservationIgnored var sessionState: ServerScopedSession?

    private static let channels: Set<LiveChannel> = [.sessions]

    @ObservationIgnored private let connection: LiveConnection
    @ObservationIgnored private let read: @Sendable () async throws -> [AdminSession]
    @ObservationIgnored private let clock: any LiveClock

    private var terminated = false
    @ObservationIgnored private var readCounter = 0
    @ObservationIgnored private var lastPublishedRead = 0
    @ObservationIgnored private var inFlight: Task<Bool, Never>?

    init(
        connection: LiveConnection,
        read: @escaping @Sendable () async throws -> [AdminSession],
        clock: any LiveClock = SystemLiveClock()
    ) {
        self.connection = connection
        self.read = read
        self.clock = clock
    }

    convenience init(client: APIClient) {
        self.init(connection: LiveHub.shared.connection(for: client), read: { try await client.listSessions() })
    }

    /// Where the source stands: the shared connection's state, unless the server does not serve sessions.
    var state: RealtimeState {
        terminated ? .signInRequired : connection.realtimeState(for: Self.channels)
    }

    /// Why the socket is not live, for the caption under the label.
    var failure: SessionFailure? {
        terminated ? .signInRequired : connection.failure(for: Self.channels)
    }

    /// Runs until cancelled (the app left the foreground) or the sign-in is lost.
    func run() async {
        terminated = false
        await LiveRefreshDriver.run(
            connection: connection, channels: Self.channels, clock: clock,
            until: { self.terminated },
            initial: { _ = await self.refresh() },
            onSignals: { signals in
                if signals.contains(.signInRequired) {
                    self.terminate(authError: self.connection.authError)
                } else {
                    // A cue may mean a change newer than a read already in flight.
                    _ = await self.refresh(force: true)
                }
            }
        )
    }

    /// Reads the list now and publishes it. `force` starts a new read even when one is in flight (after a
    /// change the person made, whose result an older read cannot show). True unless the read failed.
    @discardableResult
    func refresh(force: Bool = false) async -> Bool {
        if terminated { return true }
        if !force, let inFlight { return await inFlight.value }
        readCounter += 1
        let id = readCounter
        let task = Task { await self.perform(read: id) }
        inFlight = task
        let ok = await task.value
        if inFlight == task { inFlight = nil }
        return ok
    }

    // MARK: Reading

    private func perform(read id: Int) async -> Bool {
        do {
            let rows = try await read()
            // A read that finishes after the sign-in was lost must not bring the rows back.
            if Task.isCancelled || terminated { return true }
            if id > lastPublishedRead {
                lastPublishedRead = id
                sessions = rows
                readFailure = nil
            }
            return true
        } catch {
            if Task.isCancelled || error is CancellationError || terminated { return true }
            guard id > lastPublishedRead else { return false }
            let typed = ErrorMessage.failure(
                for: error, sessionState: sessionState, fallback: String(localized: "Now playing couldn't be loaded. Try again.")
            )
            readFailure = typed
            if let apiError = error as? APIError, apiError.statusCode == 401 || apiError.statusCode == 403 {
                terminate(authError: nil)
            }
            return false
        }
    }

    private func terminate(authError: APIError?) {
        if let authError { _ = sessionState?.handleAuthenticationFailure(authError) }
        terminated = true
        sessions = nil
    }
}
