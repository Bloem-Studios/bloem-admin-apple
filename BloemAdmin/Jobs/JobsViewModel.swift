import Foundation
import Observation

@Observable
@MainActor
final class JobsViewModel {
    private(set) var tasks: [AdminTask] = []
    /// Reserved for `load()` failures only — drives the full-screen
    /// failure page on JobsListView.
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// Set by run/cancel on failure, kept distinct from `errorMessage` so a
    /// failed action surfaced inline on JobDetailView doesn't also trigger
    /// the list screen's full-screen overlay after navigating back. Mirrors
    /// ServerConfigViewModel's errorMessage/actionErrorMessage split.
    private(set) var actionErrorMessage: String?
    /// Set for a server's section in All Servers mode, so action errors shown on the detail
    /// screen (outside the section) say which server they came from.
    let serverName: String?

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    /// See `ActivityViewModel.requestID`'s doc comment — identical
    /// stale-result guard, used by the aggregate "All servers" Jobs view
    /// model so a slow signal-driven read can never clobber a fresher per-section
    /// reload (e.g. immediately after a Run/Cancel action). No-op for
    /// single-server callers.
    private var requestID = 0

    func beginLoad() -> Int {
        requestID += 1
        return requestID
    }

    /// Applies an already-fetched task-list outcome, mirroring `load`'s own
    /// success/failure handling, but only if `token` is still current.
    func apply(_ result: Result<[AdminTask], Error>, token: Int, sessionState: ServerScopedSession?) {
        guard token == requestID else { return }
        switch result {
        case .success(let loaded):
            tasks = loaded
            loadFailure = nil
        case .failure(let error):
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "Scheduled tasks couldn't be loaded. Try again."))
        }
    }

    /// Routes through `beginLoad`/`apply` (rather than writing `tasks`/
    /// `errorMessage` directly) so THIS instance's own token-guard sees
    /// every load, including ones triggered from `JobDetailView` after a
    /// Run/Cancel action on an aggregate section — otherwise a slower,
    /// earlier aggregate poll fetch resolving afterward could still clobber
    /// that fresher, action-triggered reload despite the guard existing.
    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        let token = beginLoad()
        do {
            let loaded = try await client.tasks()
            apply(.success(loaded), token: token, sessionState: sessionState)
        } catch {
            apply(.failure(error), token: token, sessionState: sessionState)
        }
    }

    /// Deliberately does NOT reload the task list itself. Callers
    /// (JobDetailView) only reload when `actionErrorMessage == nil` after
    /// this returns, so a failed action's error is never silently
    /// overwritten by an unconditional follow-up GET. Mirrors
    /// StreamsViewModel's run/cancel-vs-load split from Task 4.
    func run(_ task: AdminTask, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        do {
            try await client.runTask(key: task.key)
            actionErrorMessage = nil
        } catch {
            setActionError(ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The task couldn't be started. Try again.")))
        }
    }

    /// Same no-auto-reload contract as `run`.
    func cancel(_ task: AdminTask, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        do {
            try await client.cancelTask(key: task.key)
            actionErrorMessage = nil
        } catch {
            setActionError(ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The task couldn't be cancelled. Try again.")))
        }
    }

    private func setActionError(_ message: String) {
        actionErrorMessage = ErrorMessage.named(message, serverName: serverName)
    }
}
