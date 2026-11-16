import Foundation

/// Body of `PUT /api/v2/admin/users/{id}/settings/values/{key}`.
private struct SettingValueBody: Encodable {
    let value: JSONValue
}

/// Body of `POST /api/v2/admin/users/{id}/profiles`; the PIN is left out when there is none.
private struct ProfileCreateBody: Encodable {
    let name: String
    let pin: String?
}

/// Body of `PATCH .../profiles/{profile_id}` that renames.
private struct ProfileRenameBody: Encodable {
    let name: String
}

/// Body of `PATCH .../profiles/{profile_id}` that sets or replaces the PIN (1 to 72 bytes).
private struct ProfilePINBody: Encodable {
    let pin: String
}

/// The calls the User page makes beyond the list and the account itself (`UsersAPI.swift`).
extension APIClient {
    private static func profilePath(_ userID: String, _ profileID: String) -> String {
        "/api/v2/admin/users/\(APIPath.segment(userID))/profiles/\(APIPath.segment(profileID))"
    }

    /// Adds a profile to the account (`POST /api/v2/admin/users/{id}/profiles`). Only the server Owner may
    /// change the Owner's or another admin's profiles.
    func createUserProfile(userID: String, name: String, pin: String?) async throws -> UserProfile {
        try await post(Self.userPath(userID, "/profiles"), body: ProfileCreateBody(name: name, pin: pin))
    }

    func renameUserProfile(userID: String, profileID: String, name: String) async throws {
        let _: UserProfile = try await patch(Self.profilePath(userID, profileID), body: ProfileRenameBody(name: name))
    }

    /// Sets or replaces a profile's PIN; the server ends the profile's tokens for the old PIN.
    func setUserProfilePIN(userID: String, profileID: String, pin: String) async throws {
        let _: UserProfile = try await patch(Self.profilePath(userID, profileID), body: ProfilePINBody(pin: pin))
    }

    /// Removes a profile's PIN, the way a forgotten PIN is reset, the main profile's included.
    func clearUserProfilePIN(userID: String, profileID: String) async throws {
        let _: UserProfile = try await patch(Self.profilePath(userID, profileID), body: ClearProfilePINRequest())
    }

    /// Deletes a profile and its per-profile data. The main profile cannot be deleted (409).
    func deleteUserProfile(userID: String, profileID: String) async throws {
        try await delete(Self.profilePath(userID, profileID))
    }

    private static func userPath(_ id: String, _ suffix: String = "") -> String {
        "/api/v2/admin/users/\(APIPath.segment(id))\(suffix)"
    }

    /// The signed-in account; the User page needs its id to hide actions an admin cannot take on
    /// themselves.
    func currentAccount() async throws -> ViewerAccount {
        try await get("/api/v2/account/me")
    }

    /// What the server supports for account administration.
    func userCapabilities() async throws -> UserCapabilities {
        try await get("/api/v2/admin/users/capabilities")
    }

    /// What unset policy fields resolve to for an admin and for an account without a group.
    func userPolicyDefaults() async throws -> UserPolicyDefaults {
        try await get("/api/v2/admin/users/policy-defaults")
    }

    /// Every access group, for the account's group picker and for what a group allows.
    func accessGroups() async throws -> [AccessGroup] {
        try await readAllPages("/api/v2/admin/access-groups")
    }

    /// The libraries the access form and the preferences levels name.
    func libraryChoices() async throws -> [LibraryChoice] {
        let collection: APICollection<LibraryChoice> = try await getCollection("/api/v2/libraries")
        return collection.items
    }

    /// The user's profiles; the list is not paginated.
    func userProfiles(userID: String) async throws -> [UserProfile] {
        let collection: APICollection<UserProfile> = try await getCollection(Self.userPath(userID, "/profiles"))
        return collection.items
    }

    /// Plays and watch time over the last `days` days (1 to 365).
    func userWatchSummary(userID: String, days: Int = 30) async throws -> WatchSummary {
        try await get(Self.userPath(userID, "/watch-summary"), query: ["days": String(days)])
    }

    /// The addresses the user signed in from over the last `days` days (1 to 365), newest first.
    func userIPs(userID: String, days: Int = 30, limit: Int = 50) async throws -> [UserIP] {
        let collection: APICollection<UserIP> = try await getCollection(
            Self.userPath(userID, "/ips"), query: ["days": String(days), "limit": String(limit)]
        )
        return collection.items
    }

    /// One page of the user's downloads. `cursor` is the previous page's `next_cursor`; nil asks for the first.
    func userDownloads(userID: String, cursor: String?, limit: Int = 50) async throws -> APICollection<UserDownload> {
        try await getCollection(Self.userPath(userID, "/downloads"), query: ["limit": String(limit), "cursor": cursor ?? ""])
    }

    func userDownloadSummary(userID: String) async throws -> UserDownloadSummary {
        try await get(Self.userPath(userID, "/downloads/summary"))
    }

    /// One submission: a reset link whose outcome is uncertain must not be issued twice. `.link` answers with the
    /// link in `reset_url` once, for the admin to hand over; `.email` has the server send it.
    func requestPasswordReset(userID: String, delivery: ResetDelivery = .email) async throws -> PasswordResetReceipt {
        try await post(Self.userPath(userID, "/password-reset"), body: PasswordResetRequest(delivery: delivery))
    }

    /// Every setting the account's people saved, at every scope.
    func userSettingValues(userID: String) async throws -> [UserSettingEntry] {
        try await readAllPages(Self.userPath(userID, "/settings/values"))
    }

    /// Stores `value` for `key` at exactly `identity`; the server checks it against the setting's own schema.
    func setUserSettingValue(userID: String, key: String, identity: SettingIdentity, value: JSONValue) async throws {
        try await put(
            Self.userPath(userID, "/settings/values/\(APIPath.segment(key))"),
            query: identity.query,
            body: SettingValueBody(value: value)
        )
    }

    /// Removes the row at exactly `identity`, so the setting falls back to the level below it.
    func deleteUserSettingValue(userID: String, key: String, identity: SettingIdentity) async throws {
        try await delete(Self.userPath(userID, "/settings/values/\(APIPath.segment(key))"), query: identity.query)
    }

    /// The settings contract: every setting's type, scopes, default and wording.
    func settingsContract() async throws -> SettingsContract {
        try await get("/api/v2/settings/contract")
    }
}
