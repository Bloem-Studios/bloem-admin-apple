import Foundation

/// What the alert logic remembers about one server between checks.
struct ServerAlertState: Codable, Equatable, Sendable {
    var consecutiveFailures = 0
    /// True once a "can't reach" notice was sent, until the server answers again.
    var isReportedDown = false
    var firstFailureAt: Date?
    var lastCheckAt: Date?
    var lastFailure: HealthFailure?
}

enum AlertAction: Equatable, Sendable {
    case none
    case serverDown(since: Date?, reason: HealthFailure?)
    case serverBack
}

/// Flap suppression. A server is reported down after two failed checks in a row, and reported back only
/// when it had been reported down. A check the phone could not make (no network) changes nothing, and a
/// failure within a minute of the previous failed check counts once: the app turns inactive and active
/// again in seconds around Face ID and the notification shade.
enum AlertDecider {
    static let failuresBeforeAlert = 2
    static let minimumSpacing: TimeInterval = 60

    static func apply(
        _ result: HealthProbeResult, to state: ServerAlertState, at now: Date
    ) -> (state: ServerAlertState, action: AlertAction) {
        switch result {
        case .inconclusive:
            return (state, .none)

        case .up:
            return (ServerAlertState(lastCheckAt: now), state.isReportedDown ? .serverBack : .none)

        case .down(let failure):
            if state.consecutiveFailures > 0, let last = state.lastCheckAt {
                let gap = now.timeIntervalSince(last)
                if gap >= 0, gap < minimumSpacing { return (state, .none) }
            }
            var next = state
            next.consecutiveFailures += 1
            next.firstFailureAt = state.firstFailureAt ?? now
            next.lastCheckAt = now
            next.lastFailure = failure
            guard next.consecutiveFailures >= failuresBeforeAlert, !state.isReportedDown else {
                return (next, .none)
            }
            next.isReportedDown = true
            return (next, .serverDown(since: next.firstFailureAt, reason: failure))
        }
    }
}
