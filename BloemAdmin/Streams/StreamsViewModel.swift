import Foundation
import Observation

@Observable
@MainActor
final class StreamsViewModel {
    private(set) var sessions: [AdminSession] = []
    /// Reserved for `load()` failures only — drives the full-screen
    /// failure page on StreamsListView.
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// Set by pause/resume/stop/terminate on failure. Kept distinct from
    /// `errorMessage` so a failed action, surfaced above the rows, doesn't also
    /// trigger the list screen's full-screen failure page — that
    /// overlay is reserved for genuine load() failures. Mirrors ServerConfigViewModel's
    /// errorMessage/actionErrorMessage split.
    private(set) var actionErrorMessage: String?

    /// Set by All Servers so an action error says which server it came from.
    let serverName: String?
    private let sequencer: PlaybackCommandSequencer

    init(serverName: String? = nil, sequencer: PlaybackCommandSequencer = PlaybackCommandSequencer()) {
        self.serverName = serverName
        self.sequencer = sequencer
    }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        do {
            let loaded = try await client.listSessions()
            apply(.success(loaded), sessionState: sessionState)
        } catch {
            apply(.failure(error), sessionState: sessionState)
        }
    }

    /// Applies an already-fetched load outcome directly, mirroring `load`'s
    /// own success/failure handling (including the same `sessionState` 401
    /// integration) without issuing a network call itself. Used by the
    /// aggregate "All servers" Streams view model, which fans every server's
    /// `GET .../sessions` call out concurrently via `fanOut` and then routes
    /// each server's outcome to that server's own `StreamsViewModel`
    /// instance — this is the seam that lets item 4 reuse this exact,
    /// already-tested error handling instead of re-deriving it.
    func apply(_ result: Result<[AdminSession], Error>, sessionState: ServerScopedSession?) {
        switch result {
        case .success(let loaded):
            sessions = loaded
            loadFailure = nil
        case .failure(let error):
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "Now playing couldn't be loaded. Try again."))
        }
    }

    /// Takes the live source's list and the failure of its latest read: a good read replaces the rows
    /// and clears the failure; a failed one keeps the last rows beside it.
    func applyLive(sessions rows: [AdminSession]?, readFailure: ServerSectionFailure?) {
        if let readFailure {
            loadFailure = readFailure
        } else if let rows {
            sessions = rows
            loadFailure = nil
        }
    }

    /// Clears a failed command's message once the admin has seen it.
    func dismissActionError() {
        actionErrorMessage = nil
    }

    func pause(_ session: AdminSession, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await act(.pause, on: session, client: client, sessionState: sessionState)
    }
    func resume(_ session: AdminSession, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await act(.resume, on: session, client: client, sessionState: sessionState)
    }
    func stop(_ session: AdminSession, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await act(.stop, on: session, client: client, sessionState: sessionState)
    }

    func terminate(_ session: AdminSession, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        do {
            try await client.terminateSession(sessionID: session.sessionID)
            actionErrorMessage = nil
        } catch {
            setActionError(ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "Couldn't end \(session.mediaTitle). Try again.")))
        }
    }

    private func act(_ action: PlaybackCommand, on session: AdminSession, client: APIClient, sessionState: ServerScopedSession?) async {
        let identity = sequencer.next(sessionId: session.sessionID)
        do {
            try await client.sendPlaybackCommand(sessionID: session.sessionID, action: action, identity: identity)
            actionErrorMessage = nil
        } catch {
            if let stale = staleMessage(for: error, sessionID: session.sessionID) {
                setActionError(stale)
            } else {
                let title = session.mediaTitle
                let fallback = switch action {
                case .pause: String(localized: "Couldn't pause \(title). Try again.")
                case .resume: String(localized: "Couldn't resume \(title). Try again.")
                case .stop: String(localized: "Couldn't stop \(title). Try again.")
                }
                setActionError(ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback))
            }
        }
    }

    /// A 409 carrying `X-Silo-Latest-Sequence` means another command reached the stream first. The
    /// sequencer moves above that value for the next attempt; nothing is retried automatically.
    private func staleMessage(for error: Error, sessionID: String) -> String? {
        guard let apiError = error as? APIError, apiError.statusCode == 409,
              let latest = apiError.latestSequence else { return nil }
        sequencer.observe(sessionId: sessionID, latest: latest)
        return String(localized: "Another command reached this stream first. Try again.")
    }

    private func setActionError(_ message: String) {
        actionErrorMessage = ErrorMessage.named(message, serverName: serverName)
    }

    /// Sends an admin message to a client. Uses a
    /// return-a-response-or-nil shape (rather than `act`'s fire-and-forget
    /// one) so the caller can show a brief success confirmation keyed to a
    /// specific send, without this view model needing to track "was the
    /// last send successful" as separate published state. Leaves
    /// `actionErrorMessage` set on failure and returns nil, same convention
    /// as every other action here — this view deliberately never reloads
    /// itself, since a message doesn't change anything `load()` would show.
    ///
    /// `title`/`reason` are passed through as `nil` when blank so the
    /// encoded body omits those JSON keys entirely (server treats a missing
    /// key and an empty string the same, but omitting is the cleaner wire
    /// shape for "the admin didn't set this").
    func sendMessage(to session: AdminSession, title: String, message: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> SessionCommandReceipt? {
        // Defense in depth: the message sheet already disables its Send
        // button until `message` is non-empty (the server 400s on a blank
        // message with no body), but this guard keeps that contract true of
        // the view model itself, not just of one caller's UI state.
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setActionError(String(localized: "Message can't be empty"))
            return nil
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let identity = sequencer.next(sessionId: session.sessionID)
        do {
            let response = try await client.sendSessionMessage(
                sessionID: session.sessionID,
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                message: message,
                identity: identity
            )
            actionErrorMessage = nil
            return response
        } catch let error as APIError where error.statusCode == 409 {
            if let stale = staleMessage(for: error, sessionID: session.sessionID) {
                setActionError(stale)
                return nil
            }
            // Real, expected state (the client isn't connected in real time
            // to receive a message) — not a bug, so it gets its own message
            // distinct from the generic fallbacks.
            setActionError(String(localized: "This client isn't currently connected, so it can't receive a message right now."))
            return nil
        } catch {
            setActionError(ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The message wasn't sent. The player may be offline; try again.")))
            return nil
        }
    }
}
