import Foundation
import Observation

@Observable
@MainActor
final class RequestsViewModel {
    private(set) var requests: [MediaRequest] = []
    /// Reserved for `load()` failures only — drives the full-screen
    /// "Connection lost" overlay on RequestsListView.
    private(set) var errorMessage: String?
    /// Set by approve/decline/retry/cancel on failure, kept distinct from
    /// `errorMessage` so a failed action surfaced inline on
    /// RequestDetailView doesn't also trigger the list screen's full-screen
    /// overlay after navigating back. Mirrors ServerConfigViewModel's
    /// errorMessage/actionErrorMessage split.
    private(set) var actionErrorMessage: String?
    /// Set for a server's section in All Servers mode, so action errors shown on the detail
    /// screen (outside the section) say which server they came from.
    let serverName: String?

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    /// See `ActivityViewModel.requestID`'s doc comment — identical
    /// stale-result guard, used by the aggregate "All servers" Requests view
    /// model so a slow poll fetch can never clobber a fresher per-section
    /// reload. No-op for single-server callers.
    private var requestID = 0

    func beginLoad() -> Int {
        requestID += 1
        return requestID
    }

    /// Applies an already-fetched request-list outcome, mirroring `load`'s
    /// own success/failure handling, but only if `token` is still current.
    func apply(_ result: Result<[MediaRequest], Error>, token: Int, sessionState: ServerScopedSession?) {
        guard token == requestID else { return }
        switch result {
        case .success(let loaded):
            requests = loaded
            errorMessage = nil
        case .failure(let error):
            if let apiError = error as? APIError {
                if let sessionState, let message = sessionState.handleAuthenticationFailure(apiError) {
                    errorMessage = message
                } else {
                    errorMessage = apiError.message
                }
            } else if let notSignedIn = error as? NotSignedInError {
                errorMessage = notSignedIn.errorDescription
            } else {
                errorMessage = String(localized: "Requests couldn't be loaded. Try again.")
            }
        }
    }

    /// Routes through `beginLoad`/`apply` (see `apply`'s doc comment) so
    /// every load — including one triggered from `RequestDetailView` after
    /// an approve/decline/retry/cancel action — is guarded against a
    /// slower, earlier fetch resolving afterward and clobbering it.
    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        let token = beginLoad()
        do {
            apply(.success(try await client.mediaRequests()), token: token, sessionState: sessionState)
        } catch {
            apply(.failure(error), token: token, sessionState: sessionState)
        }
    }

    func approve(_ request: MediaRequest, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await act(.approve, on: request, client: client, sessionState: sessionState)
    }
    /// `reason` is optional; blank text is not sent.
    func decline(_ request: MediaRequest, reason: String?, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        await act(.decline, reason: trimmed?.isEmpty == false ? trimmed : nil, on: request, client: client, sessionState: sessionState)
    }
    func retry(_ request: MediaRequest, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await act(.retry, on: request, client: client, sessionState: sessionState)
    }
    /// `reason` is optional, as for decline; blank text is not sent.
    func cancel(_ request: MediaRequest, reason: String? = nil, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        await act(.cancel, reason: trimmed?.isEmpty == false ? trimmed : nil, on: request, client: client, sessionState: sessionState)
    }

    /// Deliberately does NOT reload the request list itself. Callers
    /// (RequestDetailView) only reload when `actionErrorMessage == nil`
    /// after this returns, so a failed action's error is never silently
    /// overwritten by an unconditional follow-up GET.
    private func act(_ action: RequestAction, reason: String? = nil, on request: MediaRequest, client: APIClient, sessionState: ServerScopedSession?) async {
        do {
            try await client.actOnRequest(id: request.id, action: action, reason: reason)
            actionErrorMessage = nil
        } catch {
            let text: String
            if let apiError = error as? APIError {
                text = sessionState?.handleAuthenticationFailure(apiError) ?? apiError.message
            } else if let notSignedIn = error as? NotSignedInError, let description = notSignedIn.errorDescription {
                text = description
            } else {
                text = String(localized: "The action didn't go through. Try again.")
            }
            if let serverName {
                actionErrorMessage = String(localized: "\(serverName): \(text)")
            } else {
                actionErrorMessage = text
            }
        }
    }
}
