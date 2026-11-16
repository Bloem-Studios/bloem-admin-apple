import Foundation
import Observation
import SwiftUI

/// Monotonic time and a sleep, so a test can move a stream forward without waiting.
@MainActor
protocol StreamTickClock: AnyObject {
    /// Seconds on a monotonic clock.
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

@MainActor
final class SystemStreamTickClock: StreamTickClock {
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(for seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }
}

/// Hands a stream row its clock. A provider rather than the clock itself so the environment value
/// is Sendable while the clock stays on the main actor.
struct StreamTickClockProvider: Sendable {
    let make: @MainActor @Sendable () -> any StreamTickClock

    static let system = StreamTickClockProvider { SystemStreamTickClock() }
}

private struct StreamTickClockProviderKey: EnvironmentKey {
    static let defaultValue = StreamTickClockProvider.system
}

extension EnvironmentValues {
    /// The clock a stream row's progress ticks on. Tests provide their own.
    var streamTickClockProvider: StreamTickClockProvider {
        get { self[StreamTickClockProviderKey.self] }
        set { self[StreamTickClockProviderKey.self] = newValue }
    }
}

/// Where a playing stream is now, between polls.
///
/// A poll reports a position; from that moment the ticker projects the position forward while the
/// stream plays and holds it while paused. A new report replaces the projection (it never adds to
/// it). `run` ticks once a second; whether it should (`shouldTick`) is the caller's to ask, so the
/// ticking stays off while the app is not in front, while paused and under Reduce Motion.
@Observable
@MainActor
final class StreamProgressTicker {
    private(set) var position: Double
    private(set) var duration: Double?
    private var paused: Bool

    private var reportedPosition: Double
    private var anchor: TimeInterval
    /// Observed, so the view redraws on each tick.
    private var current: TimeInterval
    private let clock: any StreamTickClock
    static let tickInterval: TimeInterval = 1

    init(clock: any StreamTickClock, position: Double = 0, duration: Double? = nil, paused: Bool = false) {
        self.clock = clock
        self.reportedPosition = position
        self.position = position
        self.duration = duration
        self.paused = paused
        let start = clock.now()
        anchor = start
        current = start
        self.position = projected()
    }

    var fraction: Double? { StreamFormat.progressFraction(position: position, duration: duration) }
    var remaining: Double? { StreamFormat.remainingSeconds(position: position, duration: duration) }

    /// Starts the projection over from a newly polled position.
    func report(position: Double, duration: Double?, paused: Bool) {
        reportedPosition = position
        self.duration = duration
        self.paused = paused
        let start = clock.now()
        anchor = start
        current = start
        self.position = projected()
    }

    /// Ticks once a second until cancelled; returns at once when `ticking` is false. Time that
    /// passes while it is not running still counts: the stream kept playing.
    func run(ticking: Bool) async {
        guard ticking else { return }
        refresh()
        while !Task.isCancelled {
            do { try await clock.sleep(for: Self.tickInterval) } catch { return }
            refresh()
        }
    }

    /// Only a playing stream, with the app in front and motion allowed, moves between polls.
    static func shouldTick(paused: Bool, reduceMotion: Bool, foreground: Bool) -> Bool {
        !paused && !reduceMotion && foreground
    }

    private func refresh() {
        current = clock.now()
        position = projected()
    }

    private func projected() -> Double {
        StreamFormat.projectedPosition(position: reportedPosition, duration: duration, paused: paused, elapsed: current - anchor)
    }
}
