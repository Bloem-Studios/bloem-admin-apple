import Foundation

/// A unit of main-actor work the dashboard runs alongside others.
typealias DashboardJob = @MainActor @Sendable () async -> Void

/// Runs every job at once and returns when all have finished. Cancelling the caller cancels them.
func runConcurrently(_ jobs: [DashboardJob]) async {
    await withTaskGroup(of: Void.self) { group in
        for job in jobs { group.addTask(operation: job) }
    }
}
