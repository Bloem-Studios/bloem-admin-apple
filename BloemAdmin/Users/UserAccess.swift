import Foundation

/// The signed-in admin as the User page sees them. Owner status is read from the viewer's own account.
struct Viewer: Equatable, Sendable {
    let id: String
    let isOwner: Bool
}

/// Why an account is view-only, shown above its actions.
enum ViewOnlyReason: Equatable, Sendable {
    case owner
    case anotherAdmin
}

/// What the signed-in admin may do with one account, mirroring the web's `lib/accountOwner.ts` and
/// `UserDetailHeader.tsx`. The server enforces the same rules; this only keeps the page from
/// offering actions it would refuse. With no `Viewer` yet, nothing is offered.
///
/// The owner is the platform admin; organization admins are the owner's customers and support
/// their own organization only, so an admin who is not the owner cannot change another admin.
struct UserActions: Equatable, Sendable {
    /// Edit, reset the password or manage sign-in.
    let manageable: Bool
    /// Change libraries, limits, downloads and requests. Only the owner changes an admin's,
    /// including their own.
    let policyManageable: Bool
    let ownAccount: Bool
    let canResetPassword: Bool
    /// Set a temporary password the admin hands over: any enabled account the admin may manage.
    let canSetPassword: Bool
    let canDisable: Bool
    let canEnable: Bool
    let canDelete: Bool
    /// Add, rename, set a PIN on or remove a profile. The server's rule is the same as for the account itself:
    /// an account may act on itself, and only the Owner changes the Owner's or another admin's profiles.
    let canManageProfiles: Bool
    let viewOnly: ViewOnlyReason?

    static let none = UserActions(
        manageable: false, policyManageable: false, ownAccount: false, canResetPassword: false,
        canSetPassword: false, canDisable: false, canEnable: false, canDelete: false, canManageProfiles: false, viewOnly: nil
    )

    static func resolve(for user: AdminUser, viewer: Viewer?) -> UserActions {
        guard let viewer else { return .none }
        let own = user.id == viewer.id
        let isAdmin = user.role == "admin"
        let manageable = own || (!user.isOwner && (!isAdmin || viewer.isOwner))
        let policyManageable = manageable && (!isAdmin || viewer.isOwner)
        let viewOnly: ViewOnlyReason?
        if manageable {
            viewOnly = nil
        } else if user.isOwner {
            viewOnly = .owner
        } else {
            viewOnly = .anotherAdmin
        }
        return UserActions(
            manageable: manageable,
            policyManageable: policyManageable,
            ownAccount: own,
            canResetPassword: manageable && user.passwordLogin,
            canSetPassword: manageable && user.enabled,
            canDisable: manageable && user.enabled && !user.isOwner && !own,
            canEnable: manageable && !user.enabled,
            canDelete: manageable && !user.isOwner && !own,
            canManageProfiles: manageable,
            viewOnly: viewOnly
        )
    }
}

/// A password the server accepts: at least 8 characters, at most 72 bytes.
enum PasswordProblem: Equatable, Sendable {
    case tooShort
    case tooLong

    static func check(_ password: String) -> PasswordProblem? {
        if password.count < 8 { return .tooShort }
        if password.utf8.count > 72 { return .tooLong }
        return nil
    }
}

/// The tabs of the User page, in the order the web shows them.
enum UserTab: String, CaseIterable, Identifiable, Sendable {
    case overview, profiles, access, signIn, activity, downloads, preferences

    var id: String { rawValue }

    /// Downloads is offered only when the server says account downloads exist, Profiles only when it says it can
    /// manage an account's profiles.
    static func visible(accountDownloads: Bool, profileManagement: Bool = false) -> [UserTab] {
        allCases.filter { ($0 != .downloads || accountDownloads) && ($0 != .profiles || profileManagement) }
    }
}

/// What the set-password sheet says, which depends on whether the account has password sign-in already.
enum SetPasswordCopy {
    static func title(hasPasswordSignIn: Bool) -> String {
        hasPasswordSignIn ? String(localized: "Set a temporary password") : String(localized: "Set a password")
    }

    static func intro(hasPasswordSignIn: Bool, name: String) -> String {
        hasPasswordSignIn
            ? String(localized: "This replaces \(name)'s password. Share the new one with \(name) yourself; they choose their own at the next sign-in.")
            : String(localized: "\(name) can't sign in with a password now. Setting one turns password sign-in back on for this account. A connected sign-in provider keeps working.")
    }
}

/// Turns a sideways drag on the page into a tab step. The page never leaves on a swipe: a drag
/// past either end of the tab row does nothing.
enum UserTabSwipe {
    /// Minimum horizontal travel, in points, that counts as a swipe.
    static let minimumDistance: Double = 60
    /// The drag must be this many times wider than tall, so scrolling up and down never changes tab.
    static let dominance: Double = 1.6

    /// +1 for the next tab (a swipe to the left), -1 for the previous one, nil when the drag is
    /// not a sideways swipe.
    static func step(width: Double, height: Double) -> Int? {
        guard abs(width) >= minimumDistance, abs(width) >= abs(height) * dominance else { return nil }
        return width < 0 ? 1 : -1
    }

    /// The tab a swipe lands on, or `current` when there is no tab that way.
    static func target(from current: UserTab, in tabs: [UserTab], width: Double, height: Double) -> UserTab {
        guard let step = step(width: width, height: height), let index = tabs.firstIndex(of: current) else { return current }
        let next = index + step
        return tabs.indices.contains(next) ? tabs[next] : current
    }
}
