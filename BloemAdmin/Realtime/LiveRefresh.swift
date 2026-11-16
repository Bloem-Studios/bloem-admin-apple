import SwiftUI

/// What a visible screen does with the live connection: read once when it opens, then again when the
/// socket says something changed (or, while the socket is down, at most once a minute). There is no timer
/// of its own. Signals that arrive while a read is running or in the minimum gap after one collapse into
/// one more read.
enum LiveRefreshDriver {
    /// The least time between two reads caused by signals, so a scan's stream of progress events is one
    /// read a second at most.
    static let minimumGap: TimeInterval = 1

    /// Runs until the task is cancelled (the screen went, or the app left the foreground).
    /// `initial` is the read on open; `onSignals` handles each batch of signals; `finished` ends it early.
    @MainActor
    static func run(
        connection: LiveConnection,
        channels: Set<LiveChannel>,
        whenNotOffered: LiveWhenNotOffered = .slowPoll,
        clock: any LiveClock = SystemLiveClock(),
        until finished: @MainActor () -> Bool = { false },
        initial: @MainActor () async -> Void,
        onSignals: @MainActor ([LiveSignal]) async -> Void
    ) async {
        let subscription = connection.subscribe(channels, whenNotOffered: whenNotOffered)
        defer { subscription.cancel() }
        await initial()
        for await _ in subscription.wake {
            if Task.isCancelled || finished() { break }
            let signals = subscription.take()
            guard !signals.isEmpty else { continue }
            await onSignals(signals)
            if finished() { break }
            do { try await clock.sleep(for: minimumGap) } catch { break }
        }
    }

    /// The same for a screen that shows several servers: one subscription per server, one `initial` read
    /// of all of them, and the signals of each server handled on their own.
    @MainActor
    static func runAggregate(
        servers: [AdminServer],
        resolveClient: ServerClientResolver,
        channels: Set<LiveChannel>,
        clock: any LiveClock = SystemLiveClock(),
        initial: @MainActor () async -> Void,
        onSignals: @escaping @MainActor (AdminServer, [LiveSignal]) async -> Void
    ) async {
        let subscriptions = servers.map { server in
            (server, LiveHub.shared.connection(for: resolveClient(server)).subscribe(channels))
        }
        defer { for (_, subscription) in subscriptions { subscription.cancel() } }
        await initial()
        let pumps = subscriptions.map { entry -> Task<Void, Never> in
            let server = entry.0
            let subscription = entry.1
            return Task { @MainActor in
                await pump(subscription, clock: clock) { signals in await onSignals(server, signals) }
            }
        }
        await withTaskCancellationHandler {
            for pump in pumps { await pump.value }
        } onCancel: {
            for pump in pumps { pump.cancel() }
        }
    }

    /// Hands a subscription's batches of signals to `handle`, pausing `minimumGap` after each.
    @MainActor
    private static func pump(
        _ subscription: LiveSubscription, clock: any LiveClock, handle: @MainActor ([LiveSignal]) async -> Void
    ) async {
        for await _ in subscription.wake {
            if Task.isCancelled { break }
            let signals = subscription.take()
            guard !signals.isEmpty else { continue }
            await handle(signals)
            do { try await clock.sleep(for: minimumGap) } catch { break }
        }
    }
}

extension View {
    /// Reads the screen when it opens and each time the app comes back, again when a channel it shows
    /// changes, and (only while the socket is down) at most once a minute. A screen with no channel is read
    /// on open and on pull to refresh only. Pull to refresh stays the screen's own `.refreshable`.
    func liveRefresh(
        client: APIClient,
        channels: Set<LiveChannel>,
        refresh: @escaping @MainActor () async -> Void
    ) -> some View {
        modifier(LiveRefreshModifier(client: client, channels: channels, refresh: refresh, onSignals: nil))
    }

    /// As `liveRefresh`, with a separate (usually cheaper) read for signals from a channel.
    func liveRefresh(
        client: APIClient,
        channels: Set<LiveChannel>,
        initial: @escaping @MainActor () async -> Void,
        onSignals: @escaping @MainActor ([LiveSignal]) async -> Void
    ) -> some View {
        modifier(LiveRefreshModifier(client: client, channels: channels, refresh: initial, onSignals: onSignals))
    }

    /// The same for the All servers screens: `initial` reads every server, `onSignals` one server.
    func liveRefreshAll(
        servers: [AdminServer],
        resolveClient: @escaping ServerClientResolver,
        channels: Set<LiveChannel>,
        initial: @escaping @MainActor () async -> Void,
        onSignals: @escaping @MainActor (AdminServer, [LiveSignal]) async -> Void
    ) -> some View {
        modifier(LiveRefreshAllModifier(
            servers: servers, resolveClient: resolveClient, channels: channels, initial: initial, onSignals: onSignals
        ))
    }
}

private struct LiveRefreshModifier: ViewModifier {
    let client: APIClient
    let channels: Set<LiveChannel>
    let refresh: @MainActor () async -> Void
    let onSignals: (@MainActor ([LiveSignal]) async -> Void)?
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        // Keyed on the phase: leaving the foreground cancels the subscription, coming back reads again.
        content.task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await LiveRefreshDriver.run(
                connection: LiveHub.shared.connection(for: client), channels: channels,
                initial: refresh,
                onSignals: { signals in
                    if let onSignals {
                        await onSignals(signals)
                    } else if !channels.isEmpty {
                        // A screen with no channel is read on open and on pull only.
                        await refresh()
                    }
                }
            )
        }
    }
}

private struct LiveRefreshAllModifier: ViewModifier {
    let servers: [AdminServer]
    let resolveClient: ServerClientResolver
    let channels: Set<LiveChannel>
    let initial: @MainActor () async -> Void
    let onSignals: @MainActor (AdminServer, [LiveSignal]) async -> Void
    @Environment(\.scenePhase) private var scenePhase

    private struct Key: Hashable {
        let phase: ScenePhase
        let servers: [String]
    }

    func body(content: Content) -> some View {
        content.task(id: Key(phase: scenePhase, servers: servers.map(\.id))) {
            guard scenePhase == .active else { return }
            await LiveRefreshDriver.runAggregate(
                servers: servers, resolveClient: resolveClient, channels: channels, initial: initial, onSignals: onSignals
            )
        }
    }
}
