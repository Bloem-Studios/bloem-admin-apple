import BackgroundTasks
import Foundation

protocol BackgroundTaskSubmitting: Sendable {
    func submit(identifier: String, earliestBeginDate: Date) throws
    func cancel(identifier: String)
}

/// The system's scheduler. iOS decides when a requested check actually runs; the date is the earliest.
struct SystemBackgroundTaskScheduler: BackgroundTaskSubmitting {
    func submit(identifier: String, earliestBeginDate: Date) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }

    func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

/// Decides whether a background check is wanted and asks for the next one. One request is pending at a
/// time (the identifier is the same), and none when alerts are off or no saved server has them on, so a
/// removed server stops the background work.
struct BackgroundCheckPlanner: Sendable {
    /// Declared in `project.yml` under `BGTaskSchedulerPermittedIdentifiers`.
    static let identifier = "com.bloemstudios.admin.health-check"
    static let interval: TimeInterval = 15 * 60

    let scheduler: any BackgroundTaskSubmitting
    let now: @Sendable () -> Date

    /// True when a check was requested.
    @discardableResult
    func reschedule(preferences: AlertPreferences, savedServerIDs: Set<String>) -> Bool {
        guard !preferences.checkableServerIDs(saved: savedServerIDs).isEmpty else {
            scheduler.cancel(identifier: Self.identifier)
            return false
        }
        do {
            try scheduler.submit(identifier: Self.identifier, earliestBeginDate: now().addingTimeInterval(Self.interval))
            return true
        } catch {
            // The system refuses when background refresh is off for the app or unavailable (Simulator).
            // A foreground check still runs whenever the app opens.
            return false
        }
    }
}
