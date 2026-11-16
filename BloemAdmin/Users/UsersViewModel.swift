import Foundation
import Observation

/// What the User page opens with: the user as the server has it now and the ETag of that read
/// (nil when the server sent none, so no guarded write can be made), or why it could not be read.
enum UserEditLoad {
    case ready(AdminUser, validator: String?)
    /// `notFound` means the server answered 404: another admin deleted the user after the list was read.
    case failed(message: String, notFound: Bool)
}

/// The outcome of a write the page makes and shows inline (the access save, Set password).
enum UserUpdateResult: Equatable {
    case success
    case failure(message: String, isConflict: Bool)
}

/// Body that sets the account's password. The server also turns password sign-in back on, and with
/// `requireChange` the account must choose its own password at its next sign-in. A password is a
/// credential: it goes only into the request body, never into an error text or a log.
struct SetPasswordRequest: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let password: String
    let requireChange: Bool

    /// Printing or dumping the request never shows the password.
    var description: String { "SetPasswordRequest(password: <redacted>, requireChange: \(requireChange))" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["password": "<redacted>", "requireChange": requireChange], displayStyle: .struct) }

    private enum CodingKeys: String, CodingKey {
        case password
        case requireChange = "require_password_change"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(password, forKey: .password)
        if requireChange { try container.encode(true, forKey: .requireChange) }
    }
}

@Observable
@MainActor
final class UsersViewModel {
    private(set) var users: [AdminUser] = []
    /// Reserved for `load()` failures only — drives the full-screen
    /// failure page on UsersListView.
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// Set by setEnabled/createUser/delete on failure, kept
    /// distinct from `errorMessage` so a failed action surfaced inline on
    /// UserDetailView (or the Add User sheet) doesn't also trigger the list
    /// screen's full-screen overlay after navigating back. Mirrors
    /// ServerConfigViewModel's errorMessage/actionErrorMessage split.
    private(set) var actionErrorMessage: String?
    /// Set in All Servers mode so an action error shown on the user's own screen names its server.
    let serverName: String?

    init(serverName: String? = nil) {
        self.serverName = serverName
    }

    /// Pure client-side filter over the already-loaded `users` array — the
    /// list is read in full (all pages) before it is shown, so this never
    /// triggers a network call. Matches username OR email, case-insensitive substring. An
    /// empty/whitespace-only query returns every user unfiltered.
    func filteredUsers(matching query: String) -> [AdminUser] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return users }
        let needle = trimmed.lowercased()
        return users.filter {
            $0.username.lowercased().contains(needle) || $0.email.lowercased().contains(needle)
        }
    }

    /// See `ActivityViewModel.requestID`'s doc comment — identical
    /// stale-result guard, used by the aggregate "All servers" Users view
    /// model so a slow poll fetch can never clobber a fresher per-section
    /// reload (e.g. right after an enable/disable/delete
    /// action). No-op for single-server callers.
    private var requestID = 0

    func beginLoad() -> Int {
        requestID += 1
        return requestID
    }

    /// Applies an already-fetched user-list outcome, mirroring `load`'s own
    /// success/failure handling, but only if `token` is still current.
    func apply(_ result: Result<[AdminUser], Error>, token: Int, sessionState: ServerScopedSession?) {
        guard token == requestID else { return }
        switch result {
        case .success(let loaded):
            users = loaded
            loadFailure = nil
        case .failure(let error):
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "Users couldn't be loaded. Try again."))
        }
    }

    /// Routes through `beginLoad`/`apply` (see `apply`'s doc comment) so
    /// every load — including one triggered from `UserDetailView` after an
    /// enable/disable/delete action — is guarded against a
    /// slower, earlier fetch resolving afterward and clobbering it.
    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        let token = beginLoad()
        do {
            let loaded = try await client.users()
            apply(.success(loaded), token: token, sessionState: sessionState)
        } catch {
            apply(.failure(error), token: token, sessionState: sessionState)
        }
    }

    /// Deliberately does NOT reload the user list itself on success. Callers
    /// (UserDetailView) only reload when `actionErrorMessage == nil` after
    /// this returns, so a failed action's error is never silently
    /// overwritten by an unconditional follow-up GET. The user's ETag is read
    /// immediately before the write and sent as `If-Match`.
    func setEnabled(_ enabled: Bool, for user: AdminUser, client: APIClient, sessionState: ServerScopedSession? = nil) async {
        _ = await guardedWrite(
            user, client: client, sessionState: sessionState, fallback: String(localized: "The user couldn't be updated. Try again.")
        ) { validator in
            try await client.updateUser(id: user.id, body: UpdateUserRequest(enabled: enabled), validator: validator)
        }
    }

    /// Deliberately does NOT reload the user list itself, matching
    /// setEnabled's pattern above — the caller (the add-user sheet) only
    /// reloads via `load()` when this returns `true`.
    ///
    /// Returns success as an explicit `Bool` rather than only via
    /// `actionErrorMessage`, because a create can race with the Users tab's
    /// 30s poll. `actionErrorMessage` is still set on failure so the existing
    /// inline-error-footer pattern keeps working.
    @discardableResult
    func createUser(username: String, email: String, password: String, role: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        do {
            _ = try await client.createUser(CreateUserRequest(username: username, email: email, password: password, role: role))
            actionErrorMessage = nil
            return true
        } catch {
            setActionError(for: error, sessionState: sessionState, fallback: String(localized: "The user couldn't be created. Try again."))
            return false
        }
    }

    /// Reports success explicitly so a detail screen can treat deletion as
    /// terminal. A successful delete also removes the user immediately and
    /// invalidates any older list request, preventing a stale response from
    /// resurrecting the deleted row while the caller navigates away. The
    /// user's ETag is read immediately before the delete and sent as `If-Match`.
    @discardableResult
    func delete(_ user: AdminUser, client: APIClient, sessionState: ServerScopedSession? = nil) async -> Bool {
        let deleted = await guardedWrite(
            user, client: client, sessionState: sessionState, fallback: String(localized: "The user couldn't be deleted. Try again.")
        ) { validator in
            try await client.deleteUser(id: user.id, validator: validator)
        }
        guard deleted else { return false }
        _ = beginLoad()
        users.removeAll { $0.id == user.id }
        return true
    }

    func dismissActionError() {
        actionErrorMessage = nil
    }

    /// Reads `id` for the User page; the page keeps the result's validator and sends it with its
    /// next guarded write.
    func loadUserForEdit(id: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> UserEditLoad {
        do {
            let (user, validator) = try await client.user(id: id)
            return .ready(user, validator: validator.flatMap { $0.isEmpty ? nil : $0 })
        } catch {
            let notFound = (error as? APIError)?.statusCode == 404
            let message = ErrorMessage.text(
                for: error, sessionState: sessionState, fallback: String(localized: "This user couldn't be loaded. Try again."), serverName: serverName
            )
            return .failed(message: message, notFound: notFound)
        }
    }

    /// Saves the Access & limits form against the ETag the page was read with, which is not read
    /// again here: an edit someone else made since is refused with a conflict (412, or 428 when the
    /// tag is missing) instead of being overwritten. A conflict reloads the list and is never retried.
    func updateUser(_ user: AdminUser, body: some Encodable & Sendable, validator: String, client: APIClient, sessionState: ServerScopedSession? = nil) async -> UserUpdateResult {
        do {
            try await client.updateUser(id: user.id, body: body, validator: validator)
            return .success
        } catch {
            return await updateFailure(error, client: client, sessionState: sessionState)
        }
    }

    /// Sets the account's password against a fresh read, so the ETag is current.
    func setPassword(_ password: String, requireChange: Bool, for user: AdminUser, client: APIClient, sessionState: ServerScopedSession? = nil) async -> UserUpdateResult {
        do {
            let (_, validator) = try await client.user(id: user.id)
            guard let validator, !validator.isEmpty else {
                return .failure(
                    message: ErrorMessage.named(
                        String(localized: "The server did not allow this user to be changed safely. Try again later."), serverName: serverName
                    ),
                    isConflict: false
                )
            }
            try await client.updateUser(id: user.id, body: SetPasswordRequest(password: password, requireChange: requireChange), validator: validator)
            return .success
        } catch {
            return await updateFailure(error, client: client, sessionState: sessionState)
        }
    }

    private func updateFailure(_ error: Error, client: APIClient, sessionState: ServerScopedSession?) async -> UserUpdateResult {
        if let apiError = error as? APIError, apiError.statusCode == 412 || apiError.statusCode == 428 {
            await load(client: client, sessionState: sessionState)
            return .failure(
                message: ErrorMessage.named(
                    String(localized: "This user changed since it was loaded. Review it and try again."), serverName: serverName
                ),
                isConflict: true
            )
        }
        return .failure(
            message: ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "The user couldn't be updated. Try again."), serverName: serverName),
            isConflict: false
        )
    }

    /// Reads the user's ETag right before a one-tap write and sends it with the write. A response
    /// without an ETag refuses the write. A 412 (or 428) means someone else changed the user first:
    /// the list is reloaded, a conflict message is shown, and the write is not retried.
    private func guardedWrite(
        _ user: AdminUser,
        client: APIClient,
        sessionState: ServerScopedSession?,
        fallback: String,
        write: (String) async throws -> Void
    ) async -> Bool {
        do {
            let (_, validator) = try await client.user(id: user.id)
            guard let validator, !validator.isEmpty else {
                actionErrorMessage = ErrorMessage.named(
                    String(localized: "The server did not allow this user to be changed safely. Try again later."),
                    serverName: serverName
                )
                return false
            }
            try await write(validator)
            actionErrorMessage = nil
            return true
        } catch let error as APIError where error.statusCode == 412 || error.statusCode == 428 {
            actionErrorMessage = ErrorMessage.named(
                String(localized: "This user changed on the server before your change was saved. The list was reloaded; check it and try again."),
                serverName: serverName
            )
            await load(client: client, sessionState: sessionState)
            return false
        } catch {
            setActionError(for: error, sessionState: sessionState, fallback: fallback)
            return false
        }
    }

    private func setActionError(for error: Error, sessionState: ServerScopedSession?, fallback: String) {
        actionErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
    }
}
