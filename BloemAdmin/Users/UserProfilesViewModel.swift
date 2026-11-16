import Foundation
import Observation

/// What a profile's name and PIN may be, by the server's limits (`profiles.go`: a name is 1 to 64 characters after
/// trimming, a PIN is 1 to 72 bytes).
enum ProfileInput {
    enum Problem: Equatable {
        case empty
        case tooLong
    }

    static let maxNameLength = 64
    static let maxPINBytes = 72

    static func nameProblem(_ raw: String) -> Problem? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .empty }
        return name.count > maxNameLength ? .tooLong : nil
    }

    static func pinProblem(_ pin: String) -> Problem? {
        if pin.isEmpty { return .empty }
        return pin.utf8.count > maxPINBytes ? .tooLong : nil
    }
}

/// The Profiles tab of the User page in platform mode: an account's profiles, and add, rename, set or remove a
/// PIN, and delete, through the admin profile routes (`/api/v2/admin/users/{id}/profiles`). Writes go one at a
/// time, each sent once; after every write, a failed one included, the list is read again so the tab shows what
/// the server holds.
@Observable
@MainActor
final class UserProfilesViewModel {
    private(set) var profiles: LoadState<[UserProfile]> = .loading
    private(set) var isBusy = false
    /// What the last write did, in words; cleared by the next write.
    private(set) var notice: String?
    /// Why the last write failed, in the server's words.
    private(set) var errorMessage: String?

    private let userID: String
    private let serverName: String?
    private let client: APIClient
    private let sessionState: ServerScopedSession?

    init(userID: String, serverName: String?, client: APIClient, sessionState: ServerScopedSession?) {
        self.userID = userID
        self.serverName = serverName
        self.client = client
        self.sessionState = sessionState
    }

    func load() async {
        do {
            profiles = .loaded(try await client.userProfiles(userID: userID))
        } catch {
            if profiles.value == nil { profiles = .failed(text(for: error, fallback: String(localized: "Could not load the profiles."))) }
        }
    }

    func dismissMessages() {
        notice = nil
        errorMessage = nil
    }

    @discardableResult
    func add(name: String, pin: String?) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = pin?.isEmpty == false ? pin : nil
        return await write(
            failure: String(localized: "The profile couldn't be added. Check the profiles below and try again."),
            success: String(localized: "Profile \(trimmed) added")
        ) { client, userID in
            _ = try await client.createUserProfile(userID: userID, name: trimmed, pin: secret)
        }
    }

    @discardableResult
    func rename(_ profile: UserProfile, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return await write(
            failure: String(localized: "The new name couldn't be saved. Check the profile and try again."),
            success: String(localized: "Profile renamed to \(trimmed)")
        ) { client, userID in
            try await client.renameUserProfile(userID: userID, profileID: profile.id, name: trimmed)
        }
    }

    @discardableResult
    func setPIN(_ profile: UserProfile, to pin: String) async -> Bool {
        await write(
            failure: String(localized: "The PIN couldn't be set. Check the profile and try again."),
            success: String(localized: "PIN set on \(profile.name)")
        ) { client, userID in
            try await client.setUserProfilePIN(userID: userID, profileID: profile.id, pin: pin)
        }
    }

    @discardableResult
    func clearPIN(_ profile: UserProfile) async -> Bool {
        await write(
            failure: String(localized: "The PIN couldn't be cleared. Check the profile and try again."),
            success: String(localized: "PIN cleared on \(profile.name)")
        ) { client, userID in
            try await client.clearUserProfilePIN(userID: userID, profileID: profile.id)
        }
    }

    @discardableResult
    func remove(_ profile: UserProfile) async -> Bool {
        await write(
            failure: String(localized: "The profile couldn't be removed. Check the profiles below and try again."),
            success: String(localized: "Profile \(profile.name) removed")
        ) { client, userID in
            try await client.deleteUserProfile(userID: userID, profileID: profile.id)
        }
    }

    /// One write, sent once. Refused while another is running.
    private func write(
        failure: String, success: String, _ send: (APIClient, String) async throws -> Void
    ) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        notice = nil
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await send(client, userID)
            await load()
            notice = success
            return true
        } catch {
            let message = text(for: error, fallback: failure)
            await load()
            errorMessage = message
            return false
        }
    }

    private func text(for error: Error, fallback: String) -> String {
        ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback, serverName: serverName)
    }
}
