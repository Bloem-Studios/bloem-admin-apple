import Foundation
import Observation

/// Where a library's "Check the mount" stands.
enum MountCheckState: Equatable, Sendable {
    case checking
    case answered(MountCheck)
    case failed(String)
}

/// The Libraries page of one server: the libraries, what their scans and metadata refreshes are doing, and the
/// actions on them. The page reads the server when it opens and each time the server's `scans` or `jobs` channel
/// says something changed; POST /api/v2/scan answers only "accepted", so the scan runs are the only way to see
/// a scan queue, run, finish or fail.
@Observable
@MainActor
final class LibrariesViewModel {
    private(set) var libraries: [AdminLibrary] = []
    private(set) var activeRuns: [ScanRun] = []
    private(set) var recentRuns: [ScanRun] = []
    private(set) var refreshJobs: [LibraryRefreshJob] = []
    private(set) var scanAvailable = true
    /// Why the scan results could not be read, when the libraries could.
    private(set) var scanResultsError: String?
    private(set) var refreshJobsError: String?
    /// Why the first read failed, by kind; drives the full-page failure view.
    private(set) var loadFailure: ServerSectionFailure?
    private(set) var hasLoaded = false
    /// Set by an action that failed; kept apart from `loadFailure` so it shows over the list instead of replacing it.
    private(set) var actionErrorMessage: String?
    /// What the last action did, when it has something to say.
    private(set) var noticeMessage: String?
    /// Libraries with an action in flight; their buttons wait.
    private(set) var busyLibraryIDs: Set<String> = []

    let serverName: String?
    private var requestID = 0
    /// A scan the server accepted, by library: shown as Queued until a read that began after it replaces the guess.
    private var pendingScans: [String: Int] = [:]
    private var mountChecks: [String: MountCheckState] = [:]
    /// A refresh the server accepted, by library, with the read it was accepted before. It shows until the job
    /// list does, or until a later read of the list that does not have it.
    private var acceptedJobs: [String: (job: LibraryRefreshJob, token: Int)] = [:]

    var errorMessage: String? { loadFailure?.message }

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    // MARK: Reading

    func beginLoad() -> Int {
        requestID += 1
        return requestID
    }

    /// Applies one read, unless a newer one has begun since `token`.
    func apply(_ result: Result<LibrariesSnapshot, Error>, token: Int, sessionState: ServerScopedSession?) {
        guard token == requestID else { return }
        switch result {
        case .success(let snapshot):
            libraries = snapshot.libraries
            activeRuns = snapshot.activeRuns
            recentRuns = snapshot.recentRuns
            refreshJobs = snapshot.refreshJobs
            scanAvailable = snapshot.scanAvailable
            scanResultsError = snapshot.scanResultsError
            refreshJobsError = snapshot.refreshJobsError
            loadFailure = nil
            hasLoaded = true
            AdminJobActivityTracker.shared.librariesRead(
                serverID: sessionState?.serverID, activeRuns: snapshot.activeRuns, recentRuns: snapshot.recentRuns
            )
            pendingScans = pendingScans.filter { $0.value >= token }
            let listed = Set(snapshot.refreshJobs.map(\.id))
            let listRead = snapshot.refreshJobsError == nil
            acceptedJobs = acceptedJobs.filter { _, accepted in
                !listed.contains(accepted.job.id) && !(listRead && token > accepted.token)
            }
        case .failure(let error):
            loadFailure = ErrorMessage.failure(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not load libraries. Check the connection and try again."),
                serverName: serverName
            )
        }
    }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        let token = beginLoad()
        do {
            apply(.success(try await client.librariesSnapshot()), token: token, sessionState: sessionState)
        } catch {
            apply(.failure(error), token: token, sessionState: sessionState)
        }
    }

    // MARK: What a row shows

    func scanState(for library: AdminLibrary) -> LibraryScanState {
        LibraryScanState.resolve(
            libraryID: library.id, active: activeRuns, recent: recentRuns, pending: pendingScans[library.id] != nil
        )
    }

    func activeRefreshJob(for library: AdminLibrary) -> LibraryRefreshJob? {
        refreshJobsForLibrary(library).first { $0.isActive }
    }

    /// The newest refresh that has finished, for the line under the library once nothing is running.
    func lastRefreshJob(for library: AdminLibrary) -> LibraryRefreshJob? {
        refreshJobsForLibrary(library).filter { !$0.isActive }
            .max { ($0.finishedAt ?? $0.createdAt ?? .distantPast) < ($1.finishedAt ?? $1.createdAt ?? .distantPast) }
    }

    func mountCheck(for library: AdminLibrary) -> MountCheckState? { mountChecks[library.id] }

    func name(ofLibraryID id: String) -> String {
        libraries.first { $0.id == id }?.name ?? String(localized: "Library \(id)")
    }

    private func refreshJobsForLibrary(_ library: AdminLibrary) -> [LibraryRefreshJob] {
        var jobs = refreshJobs.filter { $0.libraryID == library.id }
        if let accepted = acceptedJobs[library.id]?.job, !jobs.contains(where: { $0.id == accepted.id }) {
            jobs.insert(accepted, at: 0)
        }
        return jobs
    }

    func dismissMessages() {
        actionErrorMessage = nil
        noticeMessage = nil
    }

    // MARK: Actions

    /// POST /api/v2/scan. The row shows Queued at once, then what the server's scan runs say.
    func scan(_ library: AdminLibrary, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard beginAction(on: library) else { return }
        defer { busyLibraryIDs.remove(library.id) }
        do {
            try await client.startScan(libraryID: library.id)
        } catch {
            fail(error, library: library, sessionState: sessionState, template: { name, detail in
                String(localized: "Could not scan \(name): \(detail). Try again in a moment.")
            })
            return
        }
        await load(client: client, sessionState: sessionState)
        pendingScans[library.id] = requestID
        AdminJobActivityTracker.shared.scanStarted(serverID: sessionState?.serverID, libraryID: library.id, libraryName: library.name)
    }

    /// POST /api/v2/scan/cancel: stops the library's queued and local scans.
    func stopScans(_ library: AdminLibrary, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard beginAction(on: library) else { return }
        defer { busyLibraryIDs.remove(library.id) }
        let stopped: Int
        do {
            stopped = try await client.stopScans(libraryID: library.id)
        } catch {
            fail(error, library: library, sessionState: sessionState, template: { name, detail in
                String(localized: "Could not stop the scans of \(name): \(detail). Try again.")
            })
            return
        }
        pendingScans[library.id] = nil
        let name = library.name
        noticeMessage = ErrorMessage.named(
            stopped == 0
                ? String(localized: "No scans of \(name) were queued or running")
                : stopped == 1
                ? String(localized: "Stopped the scan of \(name)")
                : String(localized: "Stopped \(stopped) scans of \(name)"),
            serverName: serverName
        )
        await load(client: client, sessionState: sessionState)
    }

    /// POST /api/v2/libraries/{id}/check-mount. A healthy answer also clears the library's dead-root or
    /// empty-root warning on the server, so the list is read again.
    func checkMount(_ library: AdminLibrary, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard beginAction(on: library) else { return }
        defer { busyLibraryIDs.remove(library.id) }
        mountChecks[library.id] = .checking
        do {
            mountChecks[library.id] = .answered(try await client.checkMount(libraryID: library.id))
        } catch {
            let detail = errorDetail(error, sessionState: sessionState)
            let name = library.name
            mountChecks[library.id] = .failed(
                ErrorMessage.named(String(localized: "Could not check the mount of \(name): \(detail). Try again."), serverName: serverName)
            )
            return
        }
        await load(client: client, sessionState: sessionState)
    }

    /// POST /api/v2/libraries/{id}/refresh-metadata; the returned job is tracked from here on.
    func refreshMetadata(_ library: AdminLibrary, mode: LibraryRefreshMode, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard beginAction(on: library) else { return }
        defer { busyLibraryIDs.remove(library.id) }
        let job: LibraryRefreshJob
        do {
            job = try await client.refreshLibraryMetadata(libraryID: library.id, mode: mode)
        } catch {
            fail(error, library: library, sessionState: sessionState, template: { name, detail in
                String(localized: "Could not refresh the metadata of \(name): \(detail). Wait for the running refresh to finish, or try again.")
            })
            return
        }
        await load(client: client, sessionState: sessionState)
        acceptedJobs[library.id] = (job.naming(libraryID: library.id, libraryName: library.name), requestID)
    }

    /// POST /api/v2/admin/jobs/{id}/cancel: asks the server to stop the refresh; it finishes the item it is on.
    func cancelRefresh(_ job: LibraryRefreshJob, library: AdminLibrary, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard beginAction(on: library) else { return }
        defer { busyLibraryIDs.remove(library.id) }
        do {
            try await client.cancelAdminJob(id: job.id)
        } catch {
            fail(error, library: library, sessionState: sessionState, template: { name, detail in
                String(localized: "Could not cancel the metadata refresh of \(name): \(detail). Try again.")
            })
            return
        }
        acceptedJobs[library.id] = nil
        await load(client: client, sessionState: sessionState)
    }

    // MARK: Helpers

    private func beginAction(on library: AdminLibrary) -> Bool {
        guard !busyLibraryIDs.contains(library.id) else { return false }
        busyLibraryIDs.insert(library.id)
        actionErrorMessage = nil
        noticeMessage = nil
        return true
    }

    private func errorDetail(_ error: Error, sessionState: ServerScopedSession?) -> String {
        let text = ErrorMessage.text(
            for: error, sessionState: sessionState,
            fallback: String(localized: "The server did not answer")
        )
        return text.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercasedFirst
    }

    private func fail(_ error: Error, library: AdminLibrary, sessionState: ServerScopedSession?, template: (String, String) -> String) {
        actionErrorMessage = ErrorMessage.named(
            template(library.name, errorDetail(error, sessionState: sessionState)), serverName: serverName
        )
    }
}

private extension String {
    /// "Request failed" reads as "request failed" inside a sentence; a name or an acronym keeps its capitals.
    var lowercasedFirst: String {
        guard let first, first.isUppercase, dropFirst().first?.isLowercase ?? true else { return self }
        return first.lowercased() + dropFirst()
    }
}
