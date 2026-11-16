import Foundation
import Observation

@Observable
@MainActor
final class InvitationsViewModel {
    private(set) var invitations: [Invitation] = []
    /// `load()` failures only; drives the full-screen failure page.
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// Send, resend and revoke failures, kept apart from `errorMessage` so a failed action does
    /// not also trigger the list's full-screen overlay.
    private(set) var actionErrorMessage: String?
    /// The create or resend response that holds the one-time claim link. It is stored before the
    /// list reloads, so cancelling that reload cannot lose the link, and it stays until dismissed.
    private(set) var pendingDelivery: InvitationDelivery?

    func dismissDelivery() {
        pendingDelivery = nil
    }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        do {
            invitations = try await client.listInvitations()
            loadFailure = nil
        } catch {
            // A cancelled reload (the screen went away) is not a failure to show.
            if error is CancellationError || Task.isCancelled { return }
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "Invitations couldn't be loaded. Try again."))
        }
    }

    /// Creates an invitation. On success the response (with the one-time `claim_url`) is stored in
    /// `pendingDelivery` first, then the list reloads. Returns the response, or nil on failure
    /// with `actionErrorMessage` set to the server's own message.
    @discardableResult
    func send(email: String, role: String, note: String?, client: APIClient, sessionState: ServerScopedSession? = nil) async -> InvitationDelivery? {
        do {
            let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
            let delivery = try await client.createInvitation(
                CreateInvitationRequest(email: email, role: role, note: (trimmedNote?.isEmpty ?? true) ? nil : trimmedNote)
            )
            actionErrorMessage = nil
            pendingDelivery = delivery
            await load(client: client, sessionState: sessionState)
            return delivery
        } catch {
            actionErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The invitation couldn't be sent. Try again."))
            return nil
        }
    }

    /// Replaces the claim link of a pending invitation. Same ordering as `send`.
    @discardableResult
    func resend(_ invitation: Invitation, client: APIClient, sessionState: ServerScopedSession? = nil) async -> InvitationDelivery? {
        do {
            let delivery = try await client.resendInvitation(id: invitation.id)
            actionErrorMessage = nil
            pendingDelivery = delivery
            await load(client: client, sessionState: sessionState)
            return delivery
        } catch {
            actionErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The invitation couldn't be resent. Try again."))
            return nil
        }
    }

    /// Does not reload; the caller reloads when `actionErrorMessage` is nil afterwards.
    func revoke(_ invitation: Invitation, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        do {
            try await client.revokeInvitation(id: invitation.id)
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The invitation couldn't be revoked. Try again."))
        }
    }
}
