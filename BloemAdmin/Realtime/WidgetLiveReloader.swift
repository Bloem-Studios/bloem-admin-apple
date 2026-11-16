import Foundation

/// At most one reload per widget kind every `interval` seconds. The first change reloads at once; changes inside
/// the interval after it are one reload, at the end of the interval. Plain values on a caller-supplied clock, so
/// the rule is tested without waiting.
struct WidgetReloadThrottle: Sendable {
    struct Decision: Equatable, Sendable {
        /// Reload these now.
        var reloadNow: Set<SiloWidgetKind>
        /// Ask again after this many seconds, when changes are waiting; nil when nothing is.
        var checkAgainIn: TimeInterval?
    }

    /// Timing is never exact; a wake this much early still counts as due.
    private static let tolerance: TimeInterval = 0.05

    let interval: TimeInterval
    private var lastReload: [SiloWidgetKind: TimeInterval] = [:]
    private var pending: Set<SiloWidgetKind> = []

    init(interval: TimeInterval = 10) {
        self.interval = interval
    }

    mutating func offer(_ kinds: Set<SiloWidgetKind>, at now: TimeInterval) -> Decision {
        var immediate: Set<SiloWidgetKind> = []
        for kind in kinds {
            if let last = lastReload[kind], now - last < interval - Self.tolerance {
                pending.insert(kind)
            } else {
                immediate.insert(kind)
                lastReload[kind] = now
                pending.remove(kind)
            }
        }
        return Decision(reloadNow: immediate, checkAgainIn: nextCheck(at: now))
    }

    mutating func flush(at now: TimeInterval) -> Decision {
        let due = pending.filter { kind in lastReload[kind].map { now - $0 >= interval - Self.tolerance } ?? true }
        for kind in due {
            pending.remove(kind)
            lastReload[kind] = now
        }
        return Decision(reloadNow: due, checkAgainIn: nextCheck(at: now))
    }

    private func nextCheck(at now: TimeInterval) -> TimeInterval? {
        pending.compactMap { kind in lastReload[kind].map { max(0, $0 + interval - now) } }.min()
    }
}

/// Reloads the widgets while the app is open: when the app's live socket reports a change in something a placed
/// widget shows (sessions, scans, jobs, tasks), the widgets that show it get a new timeline, at most once every
/// 10 seconds per kind. Widgets never open a socket of their own; the app's single events socket per server is the
/// only one, and this only listens to it.
@MainActor
final class WidgetLiveReloader {
    static let shared = WidgetLiveReloader()

    /// WidgetKit, except in a test host, where nothing should ask the system to reload.
    static let systemReload: @MainActor (Set<SiloWidgetKind>) -> Void = { kinds in
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        WidgetReload.reload(kinds)
    }

    private var throttle: WidgetReloadThrottle
    private let clock: any LiveClock
    private let reload: @MainActor (Set<SiloWidgetKind>) -> Void
    private var waiting: Task<Void, Never>?

    init(
        interval: TimeInterval = 10, clock: any LiveClock = SystemLiveClock(),
        reload: @escaping @MainActor (Set<SiloWidgetKind>) -> Void = WidgetLiveReloader.systemReload
    ) {
        throttle = WidgetReloadThrottle(interval: interval)
        self.clock = clock
        self.reload = reload
    }

    /// The live socket reported a change on `channel`.
    func note(_ channel: LiveChannel) {
        note(kinds: WidgetReload.kinds(forChannels: [channel.rawValue]))
    }

    func note(kinds: Set<SiloWidgetKind>) {
        guard !kinds.isEmpty else { return }
        let decision = throttle.offer(kinds, at: clock.now())
        if !decision.reloadNow.isEmpty { reload(decision.reloadNow) }
        arm(after: decision.checkAgainIn)
    }

    /// One waiting task for all pending kinds: re-armed on every change, so the earliest due kind is never late.
    private func arm(after delay: TimeInterval?) {
        waiting?.cancel()
        waiting = nil
        guard let delay else { return }
        waiting = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                do { try await self?.clock.sleep(for: wait) } catch { return }
                guard let self else { return }
                let decision = self.throttle.flush(at: self.clock.now())
                if !decision.reloadNow.isEmpty { self.reload(decision.reloadNow) }
                guard let next = decision.checkAgainIn else { return }
                wait = next
            }
        }
    }
}
