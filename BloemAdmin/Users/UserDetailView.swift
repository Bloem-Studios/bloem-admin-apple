import SwiftUI

extension UserTab {
    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .profiles: String(localized: "Profiles")
        case .access: String(localized: "Access & limits")
        case .signIn: String(localized: "Sign-in")
        case .activity: String(localized: "Activity")
        case .downloads: String(localized: "Downloads")
        case .preferences: String(localized: "Preferences")
        }
    }
}

/// Whether the User page may show client IP addresses. Organization context never does: the
/// owner is the platform admin, organization admins support their own organization only.
private struct ShowsClientIPsKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var showsClientIPs: Bool {
        get { self[ShowsClientIPsKey.self] }
        set { self[ShowsClientIPsKey.self] = newValue }
    }
}

/// The User page: one account, reached by tapping its row in a Users list. Works the same from the
/// single-server list and from All Servers, where `admin.serverName` names the server the account
/// lives on and every write goes only there.
///
/// A sideways swipe changes the tab and never leaves the page: the system back swipe is off, and
/// the back button asks first when the Access & limits form holds unsaved edits. Closing returns
/// to the list, which keeps its search and scroll position because it stays mounted underneath.
struct UserDetailView: View {
    let user: AdminUser
    @State private var model: UserDetailViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var tab: UserTab = .overview
    @State private var confirmDisable = false
    @State private var confirmDelete = false
    @State private var confirmDiscard = false
    @State private var showReset = false
    @State private var showSetPassword = false
    /// Set by the reset sheet's Set temporary password: the password sheet opens once the reset sheet has closed.
    @State private var openSetPasswordAfterReset = false
    @State private var notice: String?
    @State private var deleteSucceeded = false

    init(user: AdminUser, admin: UserAdmin) {
        self.user = user
        _model = State(initialValue: UserDetailViewModel(admin: admin, userID: user.id))
    }

    private var shownUser: AdminUser { model.user ?? user }

    var body: some View {
        content
            .navigationTitle(shownUser.username)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                // A number pad has no Return key, so the limits need a way to put the keyboard away.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                    .accessibilityIdentifier("user-page-keyboard-done")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: requestClose) {
                        Label("Back to users", icon: .chevronLeft)
                            .labelStyle(.titleAndIcon)
                    }
                    .accessibilityIdentifier("user-page-back")
                }
            }
            .task { await model.open() }
            .onChange(of: model.tabs) { _, tabs in
                if !tabs.contains(tab) { tab = .overview }
            }
            .alert("Discard changes?", isPresented: $confirmDiscard) {
                Button("Discard", role: .destructive) { close() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your changes to this user's access and limits have not been saved")
            }
            .sensoryFeedback(.success, trigger: deleteSucceeded)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            ProgressView("Loading user…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            BloemEmptyState {
                Label("User didn't load", icon: .triangleAlert)
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.open() } }
            }
        case .gone:
            BloemEmptyState {
                Label("User not found", icon: .userX)
            } description: {
                Text("The account may have been deleted by another admin")
            } actions: {
                Button("Back to users", action: close)
            }
        case .ready(let account, let validator):
            page(account, validator: validator)
        }
    }

    private func page(_ account: AdminUser, validator: String?) -> some View {
        let actions = model.actions
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.actionErrorMessage {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message).foregroundStyle(.bloemDanger)
                        Button("Dismiss") { model.dismissActionError() }
                            .frame(minHeight: 44)
                    }
                }
                if let notice {
                    Text(notice).foregroundStyle(.bloemOK)
                }
                if actions.manageable && validator == nil {
                    Text("Changes to this account are unavailable: the server's response arrived without an ETag, which saving requires. A reverse proxy that removes or rewrites the ETag header causes this.")
                        .foregroundStyle(.bloemWarn)
                }
                header(account, actions: actions)
                tabBar
                tabContent(account, validator: validator, actions: actions)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            // The whole page answers the swipe, so it works from the header down to the last row.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("user-page-swipe")
        }
        .background(Theme.background)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                let next = UserTabSwipe.target(
                    from: tab, in: model.tabs, width: value.translation.width, height: value.translation.height
                )
                if next != tab { tab = next }
            }
        )
        .sheet(isPresented: $showReset, onDismiss: {
            if openSetPasswordAfterReset {
                openSetPasswordAfterReset = false
                showSetPassword = true
            }
        }) {
            PasswordResetView(
                user: account, admin: model.admin,
                onSetTemporaryPassword: actions.canSetPassword ? { openSetPasswordAfterReset = true } : nil
            )
        }
        .sheet(isPresented: $showSetPassword) {
            SetPasswordView(user: account, hasPasswordSignIn: account.passwordLogin) { password, requireChange in
                await model.setPassword(password, requireChange: requireChange)
            } onDone: { requireChange in
                showSetPassword = false
                notice = requireChange
                    ? String(localized: "\(account.username) can sign in with the new password and must change it at the next sign-in.")
                    : String(localized: "\(account.username) can sign in with the new password")
            }
        }
        // Alerts, not confirmation dialogs: on iOS 26 a dialog shows as a popover with no Cancel button.
        .alert("Disable \(account.username)?", isPresented: $confirmDisable) {
            Button("Disable account", role: .destructive) {
                Task { await model.setEnabled(false) }
            }
            .disabled(model.isBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They can't sign in until you enable the account again. Their profiles, history and downloads are kept.")
        }
        .alert("Delete \(account.username)?", isPresented: $confirmDelete) {
            Button("Delete account", role: .destructive) {
                Task {
                    if await model.delete() {
                        deleteSucceeded.toggle()
                        close()
                    }
                }
            }
            .disabled(model.isBusy)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes the account, its profiles and its history. This cannot be undone. To keep them, disable the account instead.")
        }
    }

    // MARK: - Header

    private func header(_ account: AdminUser, actions: UserActions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Quiet words; only what needs a look carries a dot. An enabled account is the normal state.
            FlowLayout(spacing: Theme.Space.m) {
                StatusLabel(Vocabulary.role(account.roleLabel))
                if !account.enabled {
                    StatusLabel("Disabled", tone: .warning)
                }
                StatusLabel(account.passwordLogin ? String(localized: "Password sign-in") : String(localized: "External sign-in"))
                if account.passwordChangeRequired {
                    StatusLabel("Temporary password", tone: .warning)
                }
            }
            if let serverName = model.serverName {
                Text("Server: \(serverName)").foregroundStyle(.bloemMuted)
            }
            if !account.email.isEmpty {
                Text(account.email).foregroundStyle(.bloemMuted)
            }
            if let joined = UserFormat.date(account.createdAt) {
                Text("Joined \(joined)").foregroundStyle(.bloemMuted)
            }
            if let last = UserFormat.date(account.lastActiveAt) {
                Text("Last active \(last)").foregroundStyle(.bloemMuted)
            } else {
                Text("No recorded activity").foregroundStyle(.bloemMuted)
            }
            switch actions.viewOnly {
            case .owner:
                Text("This is the server owner. Only the owner can change this account.").foregroundStyle(.bloemMuted)
            case .anotherAdmin:
                Text("Only the server owner can change another admin account. You can view it.").foregroundStyle(.bloemMuted)
            case nil:
                EmptyView()
            }
            if !account.enabled {
                Text("This account can't sign in. Its profiles and history are kept.").foregroundStyle(.bloemMuted)
            }
            FlowLayout(spacing: 8) {
                if actions.canResetPassword {
                    actionButton("Reset password") { showReset = true }
                }
                // An account with password sign-in gets its temporary password from inside Reset password.
                if actions.canSetPassword && !account.passwordLogin {
                    actionButton("Set password") { showSetPassword = true }
                }
                if actions.canEnable {
                    actionButton("Enable account") { Task { await model.setEnabled(true) } }
                }
                if actions.canDisable {
                    actionButton("Disable account") { confirmDisable = true }
                }
                if actions.canDelete {
                    actionButton("Delete account", destructive: true) { confirmDelete = true }
                }
            }
        }
    }

    private func actionButton(_ title: LocalizedStringKey, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Text(title).padding(.horizontal, 8)
        }
        .buttonStyle(.bloemSecondary)
        .tint(destructive ? Theme.danger : Theme.text)
        .frame(minHeight: Theme.minimumTarget)
        .disabled(model.isBusy)
    }

    // MARK: - Tabs

    private var tabBar: some View {
        ScrollingTabs(
            items: model.tabs, selection: tab,
            title: { $0.title },
            identifier: { "user-tab-\($0.rawValue)" },
            onSelect: { tab = $0 }
        )
    }

    @ViewBuilder
    private func tabContent(_ account: AdminUser, validator: String?, actions: UserActions) -> some View {
        switch tab {
        case .overview:
            UserOverviewTab(user: account, admin: model.admin, capabilities: model.capabilities)
        case .profiles:
            UserProfilesTab(user: account, admin: model.admin, canManage: actions.canManageProfiles)
        case .access:
            UserAccessTab(model: model, user: account, actions: actions)
        case .signIn:
            UserSignInTab(user: account, admin: model.admin, capabilities: model.capabilities, canRevoke: actions.manageable)
        case .activity:
            UserActivityTab(user: account, admin: model.admin)
        case .downloads:
            UserDownloadsTab(user: account, admin: model.admin)
        case .preferences:
            UserPreferencesTab(
                user: account, admin: model.admin,
                devicesAvailable: model.capabilities?.accountDevices == true, editable: actions.manageable
            )
            // Devices name the device levels; the tab starts over if the capabilities arrive late.
            .id(model.capabilities?.accountDevices == true)
        }
    }

    // MARK: - Leaving

    private func requestClose() {
        if model.isAccessDirty {
            confirmDiscard = true
        } else {
            close()
        }
    }

    private func close() {
        model.dismissActionError()
        dismiss()
    }
}
