import Foundation

/// Everything the Libraries page shows after one read. The libraries are the page; the scan runs and refresh
/// jobs are extras whose failure is reported next to them instead of hiding the libraries.
struct LibrariesSnapshot: Sendable {
    var libraries: [AdminLibrary]
    /// Queued and running scan runs, every library.
    var activeRuns: [ScanRun]
    /// The latest finished scan runs, newest first.
    var recentRuns: [ScanRun]
    var refreshJobs: [LibraryRefreshJob]
    var scanAvailable: Bool
    var scanResultsError: String?
    var refreshJobsError: String?
}

extension APIClient {
    /// One read of the page: libraries first (their failure fails the read), the rest alongside.
    func librariesSnapshot() async throws -> LibrariesSnapshot {
        async let libraries = listAdminLibraries()
        async let capability = capture { try await self.scanControlsAvailable() }
        async let queued = capture { try await self.scanRuns(status: "accepted", limit: Self.activeScanLimit) }
        async let running = capture { try await self.scanRuns(status: "running", limit: Self.activeScanLimit) }
        async let recent = capture { try await self.scanRuns(status: nil, limit: Self.recentScanLimit) }
        async let jobs = capture { try await self.libraryRefreshJobs() }

        let loadedLibraries = try await libraries
        let queuedResult = await queued
        let runningResult = await running
        let recentResult = await recent
        let jobsResult = await jobs
        let capabilityResult = await capability
        let runResults = [queuedResult, runningResult, recentResult]
        var seen = Set<String>()
        var runs: [ScanRun] = []
        for case .success(let page) in runResults {
            for run in page where seen.insert(run.id).inserted { runs.append(run) }
        }
        let active = runs.filter { $0.status.isActive }
            .sorted { $0.latestActivity > $1.latestActivity }
        let finished: [ScanRun]
        if case .success(let page) = recentResult {
            finished = page.filter { !$0.status.isActive }
        } else {
            finished = []
        }
        var scanError: String?
        for case .failure(let error) in runResults {
            scanError = (error as? APIError)?.message ?? String(localized: "The scan results could not be read")
            break
        }
        let loadedJobs: [LibraryRefreshJob]
        var jobsError: String?
        switch jobsResult {
        case .success(let value): loadedJobs = value
        case .failure(let error):
            loadedJobs = []
            jobsError = (error as? APIError)?.message ?? String(localized: "The metadata refreshes could not be read")
        }
        // A failed capability check leaves the controls on: the server refuses a scan it cannot run.
        var available = true
        if case .success(let value) = capabilityResult { available = value }
        return LibrariesSnapshot(
            libraries: loadedLibraries, activeRuns: active, recentRuns: finished, refreshJobs: loadedJobs,
            scanAvailable: available, scanResultsError: scanError, refreshJobsError: jobsError
        )
    }

    private func capture<T: Sendable>(_ operation: @Sendable () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await operation()) } catch { return .failure(error) }
    }
}
