import Foundation
import Observation

/// How a `LiveConnection` opens a socket. The default mints a ticket and opens the server's events socket;
/// tests supply their own.
struct LiveEndpoint: Sendable {
    var connect: @Sendable () async throws -> any EventsSocket

    static func events(client: APIClient) -> LiveEndpoint {
        LiveEndpoint { try await LiveSocketConnector.connect(client: client) }
    }
}

/// The timings of the client rules in `bloem-staff-live.md`.
struct LiveTimings: Sendable {
    /// How long the first connect may take to reach "subscribed".
    var initialTimeout: TimeInterval = 15
    /// No frame, pong included, for this long means the socket is dead.
    var watchdog: TimeInterval = 60
    /// A WebSocket ping this often keeps the watchdog fed on a server with nothing to say (Silo sends no
    /// heartbeat frame).
    var pingInterval: TimeInterval = 25
    /// How long the socket stays after the app leaves the foreground, or after the last screen unsubscribes.
    var grace: TimeInterval = 10
    var backoffBase: TimeInterval = 1
    var backoffCeiling: TimeInterval = 60
    /// Failed connects in a row before the visible screens are polled.
    var failuresBeforeFallback = 3
    /// The most often a visible screen is polled while the socket is down.
    var fallbackInterval: TimeInterval = 60
}

/// What a screen holds while it is visible. It is told about the channels it named, and (while the socket
/// is down) about poll ticks. Cancel it when the screen goes.
@MainActor
final class LiveSubscription {
    let channels: Set<LiveChannel>
    /// What the screen does while the server does not serve its channels.
    let whenNotOffered: LiveWhenNotOffered
    /// Yields (and coalesces) whenever there is something to `take()`.
    let wake: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private var pending: [LiveSignal] = []
    private weak var owner: LiveConnection?
    fileprivate let id: Int
    private var cancelled = false

    fileprivate init(id: Int, channels: Set<LiveChannel>, whenNotOffered: LiveWhenNotOffered, owner: LiveConnection) {
        self.id = id
        self.channels = channels
        self.whenNotOffered = whenNotOffered
        self.owner = owner
        (wake, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    /// The signals since the last call, without repeats.
    func take() -> [LiveSignal] {
        defer { pending = [] }
        return pending
    }

    fileprivate func post(_ signal: LiveSignal) {
        guard !cancelled else { return }
        if !pending.contains(signal) { pending.append(signal) }
        continuation.yield()
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        continuation.finish()
        owner?.remove(id)
    }
}

/// The one live connection to one server. Screens subscribe to channels through it; it holds a single
/// socket for all of them, only while the app is in the foreground and some screen wants a channel.
///
/// The rules (`bloem-staff-live.md`, "Client rules"):
/// - Foreground only. It disconnects `timings.grace` seconds after the app (or the last subscriber) goes.
/// - Reconnect with exponential backoff and full jitter, at once when the network path changes or the app
///   comes back, and at once (once) when the server says `access_changed`.
/// - A watchdog: no frame for 60 s and the socket is dead. Silo has no heartbeat frame, so the client pings.
/// - Resume: Silo's protocol has no sequence numbers and no replay buffer, so each connect and each new
///   channel is followed by the server's snapshot, which is delivered as `.resync`: re-read the screen.
/// - Fallback: after three failed connects in a row (or on a server with no socket, or for a channel the
///   server refuses) each subscribed screen gets a `.fallback` tick at most once a minute, until the socket
///   is back. Nothing is polled otherwise.
@MainActor
@Observable
final class LiveConnection {
    /// Where the connection stands.
    private(set) var state: RealtimeState = .unavailable
    /// Why it is not live, when it is not.
    private(set) var failure: SessionFailure?
    /// Channels the server will not serve this account (not in its hello, or refused on subscribe).
    private(set) var unavailableChannels: Set<LiveChannel> = []
    /// Failed connects in a row.
    private(set) var consecutiveFailures = 0
    /// The sign-in problem the server's answer to the ticket request was, once `state == .signInRequired`.
    private(set) var authError: APIError?
    /// How many sockets this connection has opened (for tests and diagnostics).
    private(set) var connectCount = 0

    @ObservationIgnored var endpoint: LiveEndpoint
    @ObservationIgnored let timings: LiveTimings
    @ObservationIgnored private let clock: any LiveClock
    @ObservationIgnored private let jitter: @Sendable () -> Double

    @ObservationIgnored private var subs: [Int: LiveSubscription] = [:]
    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var foreground = false
    @ObservationIgnored private var backgroundedAt: TimeInterval?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var fallbackTask: Task<Void, Never>?
    /// The timers of screens that keep a pace of their own while the server does not serve their channels.
    @ObservationIgnored private var ownTimers: [Int: (every: TimeInterval, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var terminal: SessionFailure?
    @ObservationIgnored private var link: Link?
    @ObservationIgnored private var hasBeenLive = false
    @ObservationIgnored private var accessChangedStreak = 0
    @ObservationIgnored private var lastActivity: TimeInterval = 0
    @ObservationIgnored private var requestCounter = 0

    /// What one socket attempt knows.
    private final class Link {
        let socket: any EventsSocket
        var live = false
        var checkedProtocol = false
        var available: Set<LiveChannel>?
        var accepted: Set<LiveChannel> = []
        var refused: Set<LiveChannel> = []
        var asked: Set<LiveChannel> = []
        var requests: Set<String> = []
        /// Channels whose next snapshot repeats one the screen already has (the server re-sends every
        /// accepted channel on each subscribe).
        var suppressed: Set<LiveChannel> = []
        /// Snapshots the server still owes for the latest subscribe, and the resyncs held until they are in:
        /// a screen on several channels reads once for all of them, not once per snapshot.
        var owed: Set<LiveChannel> = []
        var held: [LiveChannel] = []
        var deadlineFired = false
        var watchdogFired = false
        var liveAt: TimeInterval = 0
        init(socket: any EventsSocket) { self.socket = socket }
    }

    private enum Outcome {
        case cancelled
        /// The server ended a connection that had been live for a while (its five-minute cap, a restart):
        /// reconnect at once, nothing failed.
        case closed
        case terminal(SessionFailure, APIError?)
        case failed(SessionFailure, wasLive: Bool)
    }

    init(
        endpoint: LiveEndpoint,
        timings: LiveTimings = LiveTimings(),
        clock: any LiveClock = SystemLiveClock(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.endpoint = endpoint
        self.timings = timings
        self.clock = clock
        self.jitter = jitter
    }

    convenience init(client: APIClient, timings: LiveTimings = LiveTimings()) {
        self.init(endpoint: .events(client: client), timings: timings)
    }

    // MARK: Subscribing

    /// Starts wanting `channels`. The socket opens (when the app is in the foreground) if it is not open.
    /// A subscription with no channels never opens a socket; it only receives `.fallback` ticks while the
    /// socket other screens asked for is down.
    func subscribe(_ channels: Set<LiveChannel>, whenNotOffered: LiveWhenNotOffered = .slowPoll) -> LiveSubscription {
        nextID += 1
        let subscription = LiveSubscription(id: nextID, channels: channels, whenNotOffered: whenNotOffered, owner: self)
        subs[nextID] = subscription
        // A server with no socket, or a login that was refused, is asked again whenever a screen opens.
        if loop == nil { terminal = nil }
        evaluate()
        return subscription
    }

    fileprivate func remove(_ id: Int) {
        guard subs.removeValue(forKey: id) != nil else { return }
        evaluate()
    }

    var subscriberCount: Int { subs.count }

    /// The state as a screen on `channels` should show it: live only when the server serves all of them.
    func realtimeState(for channels: Set<LiveChannel>) -> RealtimeState {
        state == .live && !channels.isDisjoint(with: unavailableChannels) ? .unavailable : state
    }

    func failure(for channels: Set<LiveChannel>) -> SessionFailure? {
        if state == .live { return channels.isDisjoint(with: unavailableChannels) ? nil : .unsupported }
        return failure
    }

    /// True when `channel` cannot be served by the socket right now, so a screen on it is polled instead.
    func isUnavailable(_ channel: LiveChannel) -> Bool {
        isFallback || unavailableChannels.contains(channel)
    }

    // MARK: Foreground and network

    func setForeground(_ value: Bool) {
        guard value != foreground else { return }
        foreground = value
        if value {
            let away = backgroundedAt.map { clock.now() - $0 }
            backgroundedAt = nil
            graceTask?.cancel()
            graceTask = nil
            terminal = nil
            accessChangedStreak = 0
            consecutiveFailures = 0
            if loop != nil, let away, away >= timings.grace {
                // The socket was due to close while the app was away (the system may have suspended its
                // timers), so it is replaced rather than trusted.
                restart()
            } else if loop != nil, state == .reconnecting {
                // Waiting out a backoff: the app is back, so try now.
                restart()
            } else {
                evaluate()
            }
        } else {
            backgroundedAt = clock.now()
            updateFallback()
            evaluate()
        }
    }

    /// The network path changed (a new interface, or it came back): reconnect at once, backoff skipped.
    func networkPathChanged() {
        guard wantsSocket else { return }
        terminal = nil
        accessChangedStreak = 0
        consecutiveFailures = 0
        restart()
    }

    private var wantsSocket: Bool { foreground && !desired.isEmpty }

    private var desired: Set<LiveChannel> {
        subs.values.reduce(into: Set<LiveChannel>()) { $0.formUnion($1.channels) }
    }

    // MARK: Lifecycle

    private func evaluate() {
        if wantsSocket {
            graceTask?.cancel()
            graceTask = nil
            if loop == nil, terminal == nil {
                start()
            } else {
                syncSubscription()
            }
        } else if loop != nil, graceTask == nil {
            graceTask = Task {
                do { try await clock.sleep(for: timings.grace) } catch { return }
                graceTask = nil
                if !wantsSocket { stop() }
            }
        }
        updateFallback()
    }

    private func start() {
        generation += 1
        let gen = generation
        if state != .reconnecting { state = .connecting }
        loop = Task { await self.run(gen) }
    }

    private func restart() {
        stop(resetState: false)
        evaluate()
    }

    /// Ends the current loop and socket. `consecutiveFailures` stays, so a restart keeps counting toward
    /// the fallback; going idle starts over.
    private func stop(resetState: Bool = true) {
        generation += 1
        loop?.cancel()
        loop = nil
        link?.socket.close()
        link = nil
        if resetState {
            state = .unavailable
            failure = nil
            consecutiveFailures = 0
            hasBeenLive = false
            unavailableChannels = []
        }
        updateFallback()
    }

    // MARK: The connect loop

    private func run(_ gen: Int) async {
        while !Task.isCancelled, gen == generation {
            let outcome = await attempt(gen)
            guard !Task.isCancelled, gen == generation else { return }
            switch outcome {
            case .cancelled:
                return
            case .closed:
                continue
            case .terminal(let reason, let auth):
                loop = nil
                terminal = reason
                failure = reason
                authError = auth
                state = reason == .signInRequired ? .signInRequired : .unavailable
                if reason == .signInRequired { for sub in subs.values { sub.post(.signInRequired) } }
                updateFallback()
                return
            case .failed(let reason, let wasLive):
                if wasLive {
                    consecutiveFailures = 0
                } else if reason != .accessChanged || accessChangedStreak > 0 {
                    consecutiveFailures += 1
                }
                state = .reconnecting
                failure = wasLive || reason == .accessChanged ? nil : reason
                if reason == .accessChanged {
                    // The login holds but the access changed: a new ticket at once, once. A second one
                    // before reaching live backs off like any other failure.
                    accessChangedStreak += 1
                    if accessChangedStreak == 1 { continue }
                }
                updateFallback()
                do { try await clock.sleep(for: backoff()) } catch { return }
            }
        }
    }

    /// Full jitter: anywhere from nothing to the ceiling, which doubles from 1 s up to 60 s. A connection
    /// that was live and dropped waits under a second.
    private func backoff() -> TimeInterval {
        let steps = max(consecutiveFailures - 1, 0)
        let ceiling = min(timings.backoffCeiling, timings.backoffBase * pow(2, Double(min(steps, 16))))
        return max(0.1, min(max(jitter(), 0), 1) * ceiling)
    }

    private func attempt(_ gen: Int) async -> Outcome {
        state = hasBeenLive || consecutiveFailures > 0 ? .reconnecting : .connecting
        let socket: any EventsSocket
        do {
            socket = try await endpoint.connect()
        } catch let error as SessionTransportError {
            switch error.failure {
            case .signInRequired, .unsupported: return .terminal(error.failure, error.authError)
            default: return .failed(error.failure, wasLive: false)
            }
        } catch {
            return Task.isCancelled || error is CancellationError ? .cancelled : .failed(.connection, wasLive: false)
        }
        guard !Task.isCancelled, gen == generation else {
            socket.close()
            return .cancelled
        }
        connectCount += 1
        let link = Link(socket: socket)
        self.link = link
        lastActivity = clock.now()

        let initial = Task {
            do { try await clock.sleep(for: timings.initialTimeout) } catch { return }
            guard !link.live else { return }
            link.deadlineFired = true
            socket.close()
        }
        let pinger = Task {
            while !Task.isCancelled {
                do { try await clock.sleep(for: timings.pingInterval) } catch { return }
                if (try? await socket.ping()) != nil { lastActivity = clock.now() }
            }
        }
        let watchdog = Task {
            while !Task.isCancelled {
                let remaining = timings.watchdog - (clock.now() - lastActivity)
                if remaining > 0 {
                    do { try await clock.sleep(for: remaining) } catch { return }
                    continue
                }
                link.watchdogFired = true
                socket.close()
                return
            }
        }
        defer {
            initial.cancel()
            pinger.cancel()
            watchdog.cancel()
            socket.close()
            if self.link === link { self.link = nil }
        }
        return await withTaskCancellationHandler {
            await read(link)
        } onCancel: {
            socket.close()
        }
    }

    private func read(_ link: Link) async -> Outcome {
        while true {
            let message: EventsSocketMessage
            do {
                message = try await link.socket.receive()
            } catch {
                if Task.isCancelled { return .cancelled }
                if link.deadlineFired || link.watchdogFired { return .failed(.deadline, wasLive: link.live) }
                let code = link.socket.closeCode
                if let code, Self.cleanCloseCodes.contains(code), link.live, clock.now() - link.liveAt >= Self.shortestLife {
                    return .closed
                }
                return .failed(code == 4001 ? .accessChanged : .connection, wasLive: link.live)
            }
            if Task.isCancelled { return .cancelled }
            lastActivity = clock.now()
            guard case .text(let text) = message else { return .failed(.protocolViolation, wasLive: link.live) }
            if !link.checkedProtocol {
                guard link.socket.negotiatedProtocol == EventsProtocol.name else { return .failed(.protocolViolation, wasLive: link.live) }
                link.checkedProtocol = true
            }
            let frame: EventsFrame
            do { frame = try EventsProtocol.decode(text) } catch { return .failed(.protocolViolation, wasLive: link.live) }
            switch frame {
            case .hello(let available):
                guard link.available == nil else { return .failed(.protocolViolation, wasLive: link.live) }
                link.available = available
                if desired.isEmpty {
                    markLive(link)
                } else if !sendSubscribe(on: link) {
                    // None of the channels wanted is offered to this account: the screens fall back to
                    // their slow refresh until a screen asks for one that is.
                    return .terminal(.unsupported, nil)
                }
            case .subscribed(let requestID, let accepted, let refused):
                guard link.requests.remove(requestID) != nil else { return .failed(.protocolViolation, wasLive: link.live) }
                link.suppressed = accepted.intersection(link.accepted)
                link.owed = accepted
                link.held = []
                link.accepted = accepted
                link.refused.formUnion(refused)
                refreshUnavailable(link)
                if !link.live { markLive(link) }
                // A new request may have been made while this one was on its way.
                syncSubscription()
            case .snapshot(let channel):
                guard link.live else { return .failed(.protocolViolation, wasLive: false) }
                if link.suppressed.remove(channel) == nil { link.held.append(channel) }
                link.owed.remove(channel)
                if link.owed.isEmpty { flushResyncs(link) }
            case .event(let channel):
                guard link.live else { return .failed(.protocolViolation, wasLive: false) }
                flushResyncs(link)
                if link.accepted.contains(channel) { deliver(.changed(channel)) }
            case .accessChanged:
                return .failed(.accessChanged, wasLive: link.live)
            case .ignored:
                break
            }
        }
    }

    /// Normal closure, going away, service restart, try again later: the server ending a connection.
    private static let cleanCloseCodes: Set<Int> = [1000, 1001, 1012, 1013]
    /// A connection that ends cleanly sooner than this after going live counts as a failure, so a server
    /// that closes every connection at once cannot be reconnected to in a tight loop.
    private static let shortestLife: TimeInterval = 5

    private func markLive(_ link: Link) {
        link.live = true
        link.liveAt = clock.now()
        hasBeenLive = true
        state = .live
        failure = nil
        consecutiveFailures = 0
        accessChangedStreak = 0
        updateFallback()
    }

    private func flushResyncs(_ link: Link) {
        let channels = link.held
        link.held = []
        for channel in channels { deliver(.resync(channel)) }
    }

    private func deliver(_ signal: LiveSignal) {
        let channel: LiveChannel
        switch signal {
        case .changed(let value), .resync(let value): channel = value
        case .fallback, .signInRequired: return
        }
        // A change the server reports is also a change in what a placed widget shows: tell the widgets (they
        // reload at most once every 10 seconds per kind). The snapshot after a connect is not a change.
        if case .changed = signal { WidgetLiveReloader.shared.note(channel) }
        for sub in subs.values where sub.channels.contains(channel) { sub.post(signal) }
    }

    // MARK: Subscribe frames

    /// Sends a subscribe frame for what is wanted now. False when nothing wanted is available.
    @discardableResult
    private func sendSubscribe(on link: Link) -> Bool {
        guard let available = link.available else { return true }
        let wanted = desired
        let ask = wanted.intersection(available).subtracting(link.refused)
        unavailableChannels = wanted.subtracting(ask)
        guard !ask.isEmpty else { return false }
        requestCounter += 1
        let id = "live-\(requestCounter)"
        link.requests.insert(id)
        link.asked = ask
        let frame = EventsProtocol.subscribe(requestID: id, channels: ask)
        let socket = link.socket
        Task { try? await socket.send(frame) }
        return true
    }

    /// The wanted channels changed: ask again (Silo's subscribe replaces the whole set, and there is no
    /// `unsubscribe`, so dropping a channel is a subscribe without it). The server answers a snapshot for
    /// every channel in the set; those the screens already have are not passed on.
    private func syncSubscription() {
        guard let link, link.available != nil, link.requests.isEmpty, link.live else { return }
        let ask = desired.intersection(link.available ?? []).subtracting(link.refused)
        refreshUnavailable(link)
        guard !ask.isEmpty, ask != link.accepted else { return }
        sendSubscribe(on: link)
    }

    private func refreshUnavailable(_ link: Link) {
        let available = link.available ?? []
        let wanted = desired
        unavailableChannels = wanted.filter { !available.contains($0) || link.refused.contains($0) }
        updateFallback()
    }

    // MARK: Fallback

    /// True once the socket cannot be relied on: three failed connects in a row, or a server with no socket.
    private var isFallback: Bool {
        terminal == .unsupported || consecutiveFailures >= timings.failuresBeforeFallback
    }

    /// How often `sub` is told to read on a timer right now, or nil for not at all. A screen that does not say
    /// otherwise gets one read a minute whenever the socket cannot be relied on, or the server does not serve its
    /// channels. A screen that does (`LiveWhenNotOffered`) keeps its own rule for the second case only: while the
    /// server has said it does not serve the channels, and the socket otherwise works.
    private func cadence(for sub: LiveSubscription) -> TimeInterval? {
        guard foreground else { return nil }
        let missing = !sub.channels.isEmpty && sub.channels.isSubset(of: unavailableChannels)
        if missing, consecutiveFailures < timings.failuresBeforeFallback {
            switch sub.whenNotOffered {
            case .slowPoll: break
            case .readOnOpenOnly: return nil
            case .every(let seconds): return seconds
            }
        }
        return isFallback || missing ? timings.fallbackInterval : nil
    }

    /// The subscriptions the shared once-a-minute loop reads.
    private func pollTargets() -> [LiveSubscription] {
        subs.values.filter { cadence(for: $0) == timings.fallbackInterval }
    }

    private func updateFallback() {
        var own: [Int: TimeInterval] = [:]
        var minute = false
        for (id, sub) in subs {
            guard let every = cadence(for: sub) else { continue }
            if every == timings.fallbackInterval { minute = true } else { own[id] = every }
        }
        if !minute {
            fallbackTask?.cancel()
            fallbackTask = nil
        } else if fallbackTask == nil {
            fallbackTask = Task { await self.fallbackLoop() }
        }
        // A screen with a pace of its own gets a timer of its own, and only while it applies.
        for (id, timer) in ownTimers where own[id] != timer.every {
            timer.task.cancel()
            ownTimers[id] = nil
        }
        for (id, every) in own where ownTimers[id] == nil {
            ownTimers[id] = (every, Task { await self.ownLoop(id, every: every) })
        }
    }

    private func fallbackLoop() async {
        while !Task.isCancelled {
            do { try await clock.sleep(for: timings.fallbackInterval) } catch { return }
            let targets = pollTargets()
            if targets.isEmpty {
                fallbackTask = nil
                return
            }
            for sub in targets { sub.post(.fallback) }
        }
    }

    private func ownLoop(_ id: Int, every: TimeInterval) async {
        while !Task.isCancelled {
            do { try await clock.sleep(for: every) } catch { return }
            guard let sub = subs[id], cadence(for: sub) == every else {
                ownTimers[id] = nil
                return
            }
            sub.post(.fallback)
        }
    }
}
