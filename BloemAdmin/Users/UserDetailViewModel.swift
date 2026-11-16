import Foundation
import Observation

/// What the User page needs from the list that opened it. The single-server list and the All
/// Servers list each write through their own `UsersViewModel` (one per server), which keeps the
/// in-flight guards and the list reloads; the page itself never knows which server it is on
/// beyond `serverName`, and every write goes through `client`, the one server's own client.
@MainActor
struct UserAdmin {
    let viewModel: UsersViewModel
    let client: APIClient
    let sessionState: ServerScopedSession?
    /// The All Servers list reloads just this server's section; the single-server list reloads itself.
    var refreshList: (@MainActor () async -> Void)?

    /// The server's name in All Servers; nil in a single-server view.
    var serverName: String? { viewModel.serverName }

    func refresh() async {
        if let refreshList {
            await refreshList()
        } else {
            await viewModel.load(client: client, sessionState: sessionState)
        }
    }
}

/// What the User page shows in place of its content until the account is read.
enum UserPageState: Equatable {
    case loading
    /// `validator` is the ETag of this read; the Access tab's form keeps it until it is saved or reloaded.
    case ready(AdminUser, validator: String?)
    case failed(String)
    /// Another admin deleted the account after the list was read.
    case gone

    static func == (lhs: UserPageState, rhs: UserPageState) -> Bool {
        switch (lhs, rhs) {
        case (.loading, .loading), (.gone, .gone): true
        case (.failed(let a), .failed(let b)): a == b
        case (.ready(let a, let av), .ready(let b, let bv)): a.id == b.id && av == bv
        default: false
        }
    }
}

/// State of one open User page. Created per (server, user), so a different user never shows the
/// previous one's data. Reads the account fresh when it opens, and again after every write, so each
/// guarded write carries the version the admin last saw.
@Observable
@MainActor
final class UserDetailViewModel {
    let admin: UserAdmin
    let userID: String

    private(set) var state: UserPageState = .loading
    private(set) var viewer: Viewer?
    private(set) var capabilities: UserCapabilities?
    /// True while an action of this page is running; buttons that start another one wait.
    private(set) var isBusy = false

    // What the Access & limits tab chooses from. Read when the tab is first shown, not when the page opens.
    private(set) var groups: LoadState<[AccessGroup]> = .loading
    private(set) var libraries: LoadState<[LibraryChoice]> = .loading
    private(set) var policyDefaults: LoadState<UserPolicyDefaults> = .loading

    /// The Access & limits form. It lives here, not in the tab, so switching tabs keeps an edit.
    private(set) var accessDraft = UserAccessDraft(
        limits: EditedUserQuotas.initial(from: AdminUser(id: "", username: "", email: "", role: "user", enabled: true, maxStreams: nil, maxTranscodes: nil)),
        access: UserAccessEdit(groupID: nil, libraryIDs: nil, permissions: [])
    )
    private(set) var accessOutcome: AccessSaveOutcome?

    init(admin: UserAdmin, userID: String) {
        self.admin = admin
        self.userID = userID
    }

    var user: AdminUser? {
        if case .ready(let user, _) = state { return user }
        return nil
    }

    var validator: String? {
        if case .ready(_, let validator) = state { return validator }
        return nil
    }

    /// What the signed-in admin may do here; nothing until the viewer is known.
    var actions: UserActions {
        guard let user else { return .none }
        return UserActions.resolve(for: user, viewer: viewer)
    }

    /// Downloads is offered only when the server says account downloads exist.
    var tabs: [UserTab] {
        UserTab.visible(
            accountDownloads: capabilities?.accountDownloads == true,
            profileManagement: capabilities?.profileManagement == true
        )
    }

    var serverName: String? { admin.serverName }
    var actionErrorMessage: String? { admin.viewModel.actionErrorMessage }

    func dismissActionError() { admin.viewModel.dismissActionError() }

    /// Opens the page: the account, who is looking at it, and what the server supports.
    func open() async {
        await reload()
        await loadViewer()
        await loadCapabilities()
    }

    /// Reads the account again. A failed re-read leaves the account already on screen.
    func reload() async {
        let read = await admin.viewModel.loadUserForEdit(id: userID, client: admin.client, sessionState: admin.sessionState)
        switch read {
        case .ready(let user, let validator):
            state = .ready(user, validator: validator)
            accessDraft = .initial(from: user)
        case .failed(let message, let notFound):
            if notFound {
                state = .gone
            } else if user == nil {
                state = .failed(message)
            }
        }
    }

    // Owner status is part of the viewer's own account, so it is read from there, as the web does.
    private func loadViewer() async {
        do {
            let me = try await admin.client.currentAccount()
            let owner: Bool
            if let shown = user, shown.id == me.id {
                owner = shown.isOwner
            } else {
                owner = (try? await admin.client.user(id: me.id).0.isOwner) ?? false
            }
            viewer = Viewer(id: me.id, isOwner: owner)
        } catch {
            // Without a viewer no action is offered; the next open tries again.
        }
    }

    private func loadCapabilities() async {
        // Unknown capabilities leave the core actions available and hide the optional sections.
        capabilities = try? await admin.client.userCapabilities()
    }

    /// Reads the access groups, the libraries and the server's policy defaults the Access & limits
    /// form chooses from, each on its own so one failing does not hide the others.
    func loadAccessChoices() async {
        async let groupsRead: Void = loadGroups()
        async let librariesRead: Void = loadLibraries()
        async let defaultsRead: Void = loadDefaults()
        _ = await (groupsRead, librariesRead, defaultsRead)
    }

    private func loadGroups() async {
        do { groups = .loaded(try await admin.client.accessGroups()) } catch {
            if groups.value == nil { groups = .failed(readFailure(error)) }
        }
    }

    private func loadLibraries() async {
        do { libraries = .loaded(try await admin.client.libraryChoices()) } catch {
            if libraries.value == nil { libraries = .failed(readFailure(error)) }
        }
    }

    private func loadDefaults() async {
        do { policyDefaults = .loaded(try await admin.client.userPolicyDefaults()) } catch {
            if policyDefaults.value == nil { policyDefaults = .failed(readFailure(error)) }
        }
    }

    private func readFailure(_ error: Error) -> String {
        ErrorMessage.text(
            for: error, sessionState: admin.sessionState,
            fallback: String(localized: "This section couldn't be loaded. Try again."), serverName: serverName
        )
    }

    private func busyWhile<T>(_ work: () async -> T) async -> T {
        isBusy = true
        defer { isBusy = false }
        return await work()
    }

    /// True when the Access & limits form holds a valid change that is not saved yet; leaving the
    /// page then asks first.
    var isAccessDirty: Bool {
        guard let user else { return false }
        return accessDraft.isDirty(against: user)
    }

    /// Applies an edit to the form and clears the last save's outcome.
    func editAccess(_ change: (inout UserAccessDraft) -> Void) {
        change(&accessDraft)
        accessOutcome = nil
    }

    /// Disables or enables the account against a fresh read, then reads the page again. Returns
    /// whether the write landed; a failure is shown in the page's banner.
    @discardableResult
    func setEnabled(_ enabled: Bool) async -> Bool {
        guard let user, !isBusy else { return false }
        return await busyWhile { () -> Bool in
            await admin.viewModel.setEnabled(enabled, for: user, client: admin.client, sessionState: admin.sessionState)
            let succeeded = admin.viewModel.actionErrorMessage == nil
            await reload()
            if succeeded { await admin.refresh() }
            return succeeded
        }
    }

    /// Deletes the account. On success the account is gone, so the page is not read again.
    @discardableResult
    func delete() async -> Bool {
        guard let user, !isBusy else { return false }
        return await busyWhile { () -> Bool in
            let deleted = await admin.viewModel.delete(user, client: admin.client, sessionState: admin.sessionState)
            if deleted {
                await admin.refresh()
            } else {
                await reload()
            }
            return deleted
        }
    }

    /// Saves the form against the ETag the page was read with, so an edit someone else made since
    /// is refused with a conflict instead of overwritten. After a save or a conflict the account is
    /// read again: the form then shows the server's current values and holds its new ETag, and the
    /// outcome (saved, or the conflict message) stays visible.
    func saveAccess() async {
        guard let user, let validator, !isBusy, accessDraft.isDirty(against: user) else { return }
        let request = accessDraft.request(against: user)
        accessOutcome = nil
        await busyWhile { () -> Void in
            let result = await admin.viewModel.updateUser(user, body: request, validator: validator, client: admin.client, sessionState: admin.sessionState)
            switch result {
            case .success:
                await reload()
                await admin.refresh()
                accessOutcome = .saved
            case .failure(let message, let isConflict):
                if isConflict { await reload() }
                accessOutcome = .failed(message)
            }
        }
    }

    func setPassword(_ password: String, requireChange: Bool) async -> UserUpdateResult? {
        guard let user, !isBusy else { return nil }
        return await busyWhile { () -> UserUpdateResult? in
            let result = await admin.viewModel.setPassword(
                password, requireChange: requireChange, for: user, client: admin.client, sessionState: admin.sessionState
            )
            if case .success = result {
                await reload()
                await admin.refresh()
            }
            return result
        }
    }
}
