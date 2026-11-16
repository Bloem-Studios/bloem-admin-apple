import Foundation
import Observation

/// One row of `GET /api/v2/admin/access-groups`: what a member inherits. `libraryIDs` nil means
/// every library; `allowedPermissions` nil means every permission is allowed.
struct AccessGroup: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let libraryIDs: [String]?
    let allowedPermissions: [String]?
    let maxStreams: Int
    let maxPlaybackQuality: String
    let memberCount: Int

    enum CodingKeys: String, CodingKey {
        case id, name
        case libraryIDs = "library_ids"
        case allowedPermissions = "allowed_permissions"
        case maxStreams = "max_streams"
        case maxPlaybackQuality = "max_playback_quality"
        case memberCount = "member_count"
    }

    init(
        id: String, name: String, libraryIDs: [String]? = nil, allowedPermissions: [String]? = nil,
        maxStreams: Int = 0, maxPlaybackQuality: String = "", memberCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.libraryIDs = libraryIDs
        self.allowedPermissions = allowedPermissions
        self.maxStreams = maxStreams
        self.maxPlaybackQuality = maxPlaybackQuality
        self.memberCount = memberCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        libraryIDs = try container.decodeIfPresent([String].self, forKey: .libraryIDs)
        allowedPermissions = try container.decodeIfPresent([String].self, forKey: .allowedPermissions)
        maxStreams = try container.decodeIfPresent(Int.self, forKey: .maxStreams) ?? 0
        maxPlaybackQuality = try container.decodeIfPresent(String.self, forKey: .maxPlaybackQuality) ?? ""
        memberCount = try container.decodeIfPresent(Int.self, forKey: .memberCount) ?? 0
    }
}

/// A library as the access form lists it.
struct LibraryChoice: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

/// The libraries an unset field resolves to for admins and for regular accounts outside every group.
struct PolicyDefaultsHint: Decodable, Equatable, Sendable {
    let libraryIDs: [String]?

    enum CodingKeys: String, CodingKey { case libraryIDs = "library_ids" }

    init(libraryIDs: [String]?) { self.libraryIDs = libraryIDs }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        libraryIDs = try container.decodeIfPresent([String].self, forKey: .libraryIDs)
    }
}

/// `GET /api/v2/admin/users/policy-defaults`: what unset policy fields resolve to without a group.
struct UserPolicyDefaults: Decodable, Equatable, Sendable {
    let admin: PolicyDefaultsHint?
    let ungrouped: PolicyDefaultsHint?
}

/// The permissions an admin can assign to one account, as the server names them.
enum AssignablePermission: String, CaseIterable, Identifiable, Sendable {
    case markerEdit = "marker_edit"
    case metadataCuration = "metadata_curation"
    case watchLiveTV = "watch_live_tv"

    var id: String { rawValue }
}

/// What the Access & limits tab edits besides the limits: the access group, the library allowlist
/// and the permissions assigned to the account. `groupID` nil is "no group"; `libraryIDs` nil inherits.
struct UserAccessEdit: Equatable, Sendable {
    var groupID: String?
    var libraryIDs: [String]?
    var permissions: [String]

    static func initial(from user: AdminUser) -> UserAccessEdit {
        UserAccessEdit(groupID: user.accessGroupID, libraryIDs: user.libraryIDs, permissions: user.permissions.sorted())
    }
}

/// Whether a group keeps an account from using a permission: the server intersects the two sets.
struct PermissionLock: Equatable, Sendable {
    let locked: Bool
    let groupName: String?

    init(locked: Bool, groupName: String? = nil) {
        self.locked = locked
        self.groupName = groupName
    }
}

/// The libraries an account that does not set its own list would see.
enum InheritedLibraries: Equatable, Sendable {
    /// The source is not loaded yet (or the group was deleted), so nothing true can be said.
    case unknown
    case all
    case some([String])

    fileprivate init(_ ids: [String]?) {
        self = ids.map(InheritedLibraries.some) ?? .all
    }
}

enum AccessPolicy {
    /// Admins are never grouped: the server clears the group of an admin, so a form never offers
    /// or sends one.
    static func effectiveGroupID(role: String, groupID: String?) -> String? {
        role == "admin" ? nil : groupID
    }

    static func permissionLock(role: String, groupID: String?, groups: [AccessGroup], permission: String) -> PermissionLock {
        guard let id = effectiveGroupID(role: role, groupID: groupID),
              let group = groups.first(where: { $0.id == id }) else { return PermissionLock(locked: false) }
        let locked = group.allowedPermissions.map { !$0.contains(permission) } ?? false
        return PermissionLock(locked: locked, groupName: group.name)
    }

    /// The group's display name, or "#id" while the group list lacks it.
    static func groupName(_ id: String, in groups: [AccessGroup]) -> String {
        groups.first { $0.id == id }?.name ?? "#\(id)"
    }

    /// What "inherit" means for libraries under the group picked in the form, not the group last
    /// saved, so the label follows the picker. An admin or an ungrouped account takes the server's
    /// defaults; a grouped account takes its group's list. While the account is saved with the same
    /// group and inherits, the server's own resolved list is the freshest answer.
    static func inheritedLibraries(
        role: String,
        draftGroupID: String?,
        savedGroupID: String?,
        inheritsNow: Bool,
        effectiveLibraryIDs: [String]?,
        groups: [AccessGroup]?,
        defaults: UserPolicyDefaults?
    ) -> InheritedLibraries {
        let groupID = effectiveGroupID(role: role, groupID: draftGroupID)
        if inheritsNow, groupID == effectiveGroupID(role: role, groupID: savedGroupID) {
            return InheritedLibraries(effectiveLibraryIDs)
        }
        if role == "admin" {
            return defaults?.admin.map { InheritedLibraries($0.libraryIDs) } ?? .unknown
        }
        guard let groupID else {
            return defaults?.ungrouped.map { InheritedLibraries($0.libraryIDs) } ?? .unknown
        }
        guard let group = groups?.first(where: { $0.id == groupID }) else { return .unknown }
        return InheritedLibraries(group.libraryIDs)
    }

    /// Whether inherited libraries come from a group (true) or from the server's defaults (false).
    static func inheritsFromGroup(role: String, draftGroupID: String?) -> Bool {
        effectiveGroupID(role: role, groupID: draftGroupID) != nil
    }

    /// Library ids in the order of `all`, so a saved list does not depend on the order of the taps.
    static func toggleLibrary(selected: [String], all: [String], id: String, on: Bool) -> [String] {
        all.filter { candidate in candidate == id ? on : selected.contains(candidate) }
    }

    static func setAssignedPermission(_ permissions: [String], _ permission: String, on: Bool) -> [String] {
        var set = Set(permissions)
        if on { set.insert(permission) } else { set.remove(permission) }
        return set.sorted()
    }
}

extension UpdateUserQuotasRequest {
    /// The whole Access & limits save: the limits that changed plus the access group, libraries and
    /// permissions that changed, in one body. Only what differs from `original` is sent: libraries and
    /// permissions compare as sets, and the group is left out for an admin.
    static func diff(from original: AdminUser, limits: EditedUserQuotas, access: UserAccessEdit) -> UpdateUserQuotasRequest {
        var request = diff(from: original, to: limits)

        if original.role == "admin" || access.groupID == original.accessGroupID {
            request.accessGroupID = .unchanged
        } else if let group = access.groupID {
            request.accessGroupID = .set(group)
        } else {
            request.accessGroupID = .clear
        }

        switch (access.libraryIDs, original.libraryIDs) {
        case (nil, nil):
            request.libraryIDs = .unchanged
        case (nil, _):
            request.libraryIDs = .clear
        case (let edited?, let stored?) where Set(edited) == Set(stored):
            request.libraryIDs = .unchanged
        case (let edited?, _):
            request.libraryIDs = .set(Array(Set(edited)).sorted())
        }

        request.permissions = Set(access.permissions) == Set(original.permissions)
            ? .unchanged
            : .set(Array(Set(access.permissions)).sorted())
        return request
    }
}

/// Everything the Access & limits tab edits, as one draft: the limits and flags, the access group,
/// the library allowlist and the assigned permissions. The page keeps it, so switching tabs does
/// not lose an edit, and a save sends only what differs from the account as the server has it.
struct UserAccessDraft: Equatable, Sendable {
    var limits: EditedUserQuotas
    var access: UserAccessEdit

    static func initial(from user: AdminUser) -> UserAccessDraft {
        UserAccessDraft(limits: .initial(from: user), access: .initial(from: user))
    }

    /// A limit that is not inherited needs a whole number.
    var hasInvalidValue: Bool {
        (!limits.maxStreamsInherited && Int(limits.maxStreamsText) == nil)
            || (!limits.maxTranscodesInherited && Int(limits.maxTranscodesText) == nil)
            || (!limits.maxProfilesInherited && Int(limits.maxProfilesText) == nil)
    }

    func request(against user: AdminUser) -> UpdateUserQuotasRequest {
        UpdateUserQuotasRequest.diff(from: user, limits: limits, access: access)
    }

    /// True when there is something valid to save.
    func isDirty(against user: AdminUser) -> Bool {
        !hasInvalidValue && !request(against: user).isEmpty
    }
}

/// What the last Access & limits save did, shown under the form. It outlives the reload that
/// follows a save or a conflict, because that reload resets the form to the server's values.
enum AccessSaveOutcome: Equatable, Sendable {
    case saved
    case failed(String)
}

/// The password-reset dialog's own state: whether the server can send a reset email, and the
/// one submission it allows.
@Observable
@MainActor
final class PasswordResetViewModel {
    /// The server can email a reset link.
    private(set) var isAvailable = false
    /// The server can return a reset link for the admin to hand over (it needs the server's public address).
    private(set) var isLinkAvailable = false
    private(set) var isBusy = true
    private(set) var errorMessage: String?
    private(set) var receipt: PasswordResetReceipt?
    /// The link to hand over, from `createLink`. Held only while the sheet shows it: `forgetLink` drops it.
    private(set) var link: ResetLinkShown?
    /// After a submission, closing and reopening the dialog is the only way to issue another link.
    private(set) var hasSubmitted = false

    private let user: AdminUser
    private let admin: UserAdmin

    init(user: AdminUser, admin: UserAdmin) {
        self.user = user
        self.admin = admin
    }

    var canSend: Bool {
        isAvailable && user.enabled && !user.email.isEmpty && !isBusy && !hasSubmitted
    }

    /// A link needs password sign-in on and an enabled account; the server refuses one for a disabled account.
    var canCreateLink: Bool {
        isLinkAvailable && user.enabled && user.passwordLogin && !isBusy && !hasSubmitted
    }

    func load() async {
        isBusy = true
        defer { isBusy = false }
        do {
            let capabilities = try await admin.client.userCapabilities()
            isAvailable = capabilities.passwordResetEmail
            isLinkAvailable = capabilities.passwordResetLink
        } catch {
            isAvailable = false
            errorMessage = String(localized: "Password reset email is unavailable. Check the server's public URL and mail configuration, or use web administration.")
        }
    }

    func send() async {
        guard canSend else { return }
        isBusy = true
        hasSubmitted = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            receipt = try await admin.client.requestPasswordReset(userID: user.id)
        } catch let error as APIError {
            errorMessage = ErrorMessage.text(
                for: error, sessionState: admin.sessionState,
                fallback: String(localized: "The result couldn't be confirmed. Check delivery before issuing another reset link."),
                serverName: admin.serverName
            )
        } catch {
            errorMessage = String(localized: "The result couldn't be confirmed. Check delivery before issuing another reset link.")
        }
    }

    /// Asks the server for a link to hand over, once. The link is shown by the sheet and forgotten with `forgetLink`.
    func createLink() async {
        guard canCreateLink else { return }
        isBusy = true
        hasSubmitted = true
        errorMessage = nil
        defer { isBusy = false }
        let fallback = String(localized: "The link couldn't be confirmed. Close this and create another one; it replaces any earlier link.")
        do {
            let issued = try await admin.client.requestPasswordReset(userID: user.id, delivery: .link)
            guard let url = issued.resetURL, !url.isEmpty else {
                errorMessage = String(localized: "The server didn't return a link. Close this and create another one.")
                return
            }
            link = ResetLinkShown(url: url, expiresAt: issued.expiresAt)
        } catch {
            errorMessage = ErrorMessage.text(for: error, sessionState: admin.sessionState, fallback: fallback, serverName: admin.serverName)
        }
    }

    /// Drops the link and everything that came with it. Called when the sheet closes.
    func forgetLink() {
        link = nil
        receipt = nil
    }
}
