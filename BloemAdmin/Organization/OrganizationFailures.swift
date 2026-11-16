import Foundation

/// What an organization call came to: a value, text to show, or the screen going away.
enum Outcome<Value> {
    case ok(Value)
    case failed(String)
    /// The task was cancelled (the screen went away): nothing to show.
    case cancelled
}

extension Outcome: Sendable where Value: Sendable {}

extension OrganizationSession {
    /// The one place an organization failure becomes text. A refusal of the organization itself (403, or
    /// `OrganizationAccessDenied`) also records why on `denial`, so the host can leave and the context list can drop
    /// the organization: a suspended organization reads differently from lost authority.
    func failureText(_ error: Error, fallback: String, refused: String? = nil) -> String {
        if let denied = error as? OrganizationAccessDenied {
            markDenied(denied.reason)
            return denied.reason.message
        }
        if let changed = error as? OrganizationStateChanged {
            return changed.wasConflict
                ? String(localized: "Someone else changed this just now. It has been reloaded; check it and try again.")
                : String(localized: "This organization changed. It has been reloaded; try again.")
        }
        if let api = error as? APIError {
            if api.statusCode == 403 {
                markDenied(api.denialReason)
                return api.denialReason.message
            }
            // The support routes' refusals say why (a protected person, a missing mailbox, a spent budget).
            if let text = OrganizationVocabulary.supportRefusal(api) { return text }
            if api.statusCode == 422, let refused { return refused }
            return ErrorMessage.text(for: api, sessionState: accountSession, fallback: fallback)
        }
        return fallback
    }

    /// Runs `block`; cancellation becomes `.cancelled`, anything else becomes `.failed` with text to show.
    func attempt<T>(
        fallback: String,
        refused: String? = nil,
        _ block: () async throws -> T
    ) async -> Outcome<T> {
        do {
            return .ok(try await block())
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            return .cancelled
        } catch {
            if Task.isCancelled { return .cancelled }
            return .failed(failureText(error, fallback: fallback, refused: refused))
        }
    }

    /// A read through the pass (renewed once on a 401).
    func attemptRead<T>(fallback: String, _ call: (APIClient) async throws -> T) async -> Outcome<T> {
        await attempt(fallback: fallback) { try await read(call) }
    }

    /// A write through the pass: sent once, with the policy revision to quote.
    func attemptWrite<T>(
        fallback: String,
        refused: String? = nil,
        _ call: (APIClient, Int64) async throws -> T
    ) async -> Outcome<T> {
        await attempt(fallback: fallback, refused: refused) { try await write(call) }
    }
}
