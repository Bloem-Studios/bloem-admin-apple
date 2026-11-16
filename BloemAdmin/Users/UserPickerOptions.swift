import Foundation
import Observation

/// The names behind a "pick a person" control: the server's user list, and one person's profiles
/// once a person is picked. Playback history and Audit filter by name with it, so nobody has to
/// know a numeric user ID. Reads `GET /api/v2/admin/users` and `GET /api/v2/admin/users/{id}/profiles`.
@Observable
@MainActor
final class UserPickerOptions {
    private(set) var users: [AdminUser] = []
    private(set) var profiles: [UserProfile] = []
    private(set) var isLoadingUsers = false
    /// Why the user list could not be read, in words; nil while it is fine.
    private(set) var usersFailure: String?
    private var profileRequest = 0

    func userName(forID id: String) -> String? {
        users.first { $0.id == id }?.username
    }

    func loadUsers(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard !isLoadingUsers else { return }
        isLoadingUsers = true
        defer { isLoadingUsers = false }
        do {
            let all = try await client.users()
            users = all.sorted { $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending }
            usersFailure = nil
        } catch {
            usersFailure = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "Could not load the user list."))
        }
    }

    /// Reads the profiles of `userID`; an empty ID clears them without a request. A reply for a
    /// person who is no longer the one picked is dropped.
    func loadProfiles(userID: String, client: APIClient) async {
        profileRequest += 1
        let request = profileRequest
        guard !userID.isEmpty else {
            profiles = []
            return
        }
        do {
            let loaded = try await client.userProfiles(userID: userID)
            guard request == profileRequest else { return }
            profiles = loaded
        } catch {
            guard request == profileRequest else { return }
            profiles = []
        }
    }
}
