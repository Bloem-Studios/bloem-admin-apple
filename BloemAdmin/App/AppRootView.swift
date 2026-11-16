import SwiftUI

/// The signed-in app: one `ShellRouter` decides whether All servers or one server is showing; each is a
/// menu-driven shell (`ShellLayout`) with a one-row top bar. Manage servers and Add Server open over it; Settings is a
/// page of the shell.
struct AppRootView: View {
    @State private var store: ServerStore
    @State private var sessionState = AdminSessionState()
    @State private var router: ShellRouter
    @State private var persistenceErrorMessage: String?
    /// Each saved server's administrator contexts (`discoverAdminContexts`): the dropdown lists their
    /// organizations under the server, and choosing one opens it.
    @State private var contextsByServer: [String: [AdminContext]] = [:]
    /// What the switcher sheet asked for, run once the sheet is gone (another sheet cannot open over a closing one).
    @State private var afterSwitcher: (() -> Void)?

    init() {
        let store = ServerStore(mirror: .live)
        store.pushLifecycle = PushRuntime.shared
        _store = State(initialValue: store)
        let preferences = ShellScopePreferences()
        let savedIDs = Set(store.servers.map(\.id))
        _router = State(initialValue: ShellRouter(
            scope: preferences.startScope(savedIDs: savedIDs),
            preferences: preferences
        ))
    }

    var body: some View {
        @Bindable var router = router
        content
            .environment(router)
            .environment(\.scopeControl, scopeControl)
            .environment(\.settingsPage, { AnyView(AppSettingsView(servers: store.servers)) })
            .deepLinkHandling(router: router, savedServerIDs: Set(store.servers.map(\.id)))
            .snapshotSync(store: store, sessionState: sessionState)
            .jobActivityFollow(store: store, sessionState: sessionState)
            .fullScreenCover(isPresented: $router.isManagingServers) {
                ManageServersView(
                    store: store,
                    sessionState: sessionState,
                    onOpenAllServers: { router.select(scope: .allServers) },
                    onOpenServer: { router.select(scope: .server($0.id)) }
                )
            }
            .sheet(isPresented: $router.isAddingServer) {
                AddServerView(store: store)
            }
            .sheet(isPresented: $router.isSwitchingContext, onDismiss: {
                let next = afterSwitcher
                afterSwitcher = nil
                next?()
            }) {
                ContextSwitcherSheet(
                    control: scopeControl,
                    onClose: { router.isSwitchingContext = false },
                    onAddServer: { afterSwitcher = { router.isAddingServer = true } }
                )
                .presentationDetents([.medium, .large])
            }
            .alert(
                signOutTitle,
                isPresented: $router.isConfirmingSignOut
            ) {
                Button("Sign out", role: .destructive) { signOut() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(signOutMessage)
            }
            .alert(
                "Saved data couldn't be updated",
                isPresented: Binding(
                    get: { persistenceErrorMessage != nil },
                    set: { if !$0 { persistenceErrorMessage = nil } }
                )
            ) {
                Button("Done", role: .cancel) { persistenceErrorMessage = nil }
            } message: {
                Text(persistenceErrorMessage ?? "")
            }
            .onAppear {
                if let initializationError = store.initializationError {
                    persistenceErrorMessage = initializationError.localizedDescription
                }
                PushRuntime.shared.attach(store: store, sessionState: sessionState)
            }
            // Push follows the saved servers and their sign-ins: registered when one signs in or its token is
            // refreshed, stopped when one signs out. Nothing here asks for permission.
            .task(id: store.servers.map(\.id).joined(separator: ",") + "#\(store.credentialRevision)") {
                await PushRuntime.shared.reconcile(.changed)
            }
            // A removed server cannot stay the scope.
            .onChange(of: store.servers) { _, servers in
                router.reconcile(savedServerIDs: Set(servers.map(\.id)))
            }
            // Read again whenever the saved servers or their credentials change, as Android does.
            .task(id: store.servers.map(\.id).joined(separator: ",") + "#\(store.credentialRevision)") {
                await discoverOrganizations()
            }
            .onAppear {
                router.onSelectOrganization = { organization in
                    router.select(scope: .server(organization.serverID))
                    router.selectedOrganizationID = organization.organizationID
                }
            }
    }

    /// The servers "Sign out" ends the sign-in of: the open server, or on All servers every saved server that is
    /// signed in. They stay in the list; only this device's sign-in goes.
    private var signOutTargets: [AdminServer] {
        switch router.scope {
        case .server(let id): store.servers.filter { $0.id == id }
        case .allServers: store.servers
        }
    }

    private var signOutTitle: String {
        guard case .server = router.scope else { return String(localized: "Sign out of all servers?") }
        let name = signOutTargets.first?.displayName ?? ""
        return String(localized: "Sign out of \(name)?")
    }

    private var signOutMessage: String {
        String(localized: "This removes the sign-in from this device. The server stays in your list, and you can sign in again.")
    }

    private func signOut() {
        _ = store.credentialRevision
        for server in signOutTargets where store.accessToken(for: server.id) != nil {
            do {
                try store.signOut(server.id, sessionState: sessionState)
            } catch {
                persistenceErrorMessage = error.localizedDescription
            }
        }
    }

    /// Best effort per server: a server that cannot be asked keeps no organizations in the dropdown, and its
    /// own gate still says why when it is opened.
    private func discoverOrganizations() async {
        var found: [String: [AdminContext]] = [:]
        for server in store.servers {
            let client = store.client(for: server, sessionState: sessionState)
            if let contexts = try? await client.discoverAdminContexts() {
                found[server.id] = contexts
            }
        }
        guard !Task.isCancelled else { return }
        contextsByServer = found
        router.organizations = OrganizationScopes.list(servers: store.servers, contexts: found)
        // An organization the server no longer lists closes back to the server.
        if let open = router.selectedOrganizationID, case .server(let id) = router.scope,
           OrganizationScopes.context(serverID: id, organizationID: open, in: found) == nil {
            router.selectedOrganizationID = nil
        }
    }

    @ViewBuilder
    private var content: some View {
        switch router.scope {
        case .allServers:
            AllServersView(servers: store.servers, store: store, sessionState: sessionState)
        case .server(let id):
            if let server = store.servers.first(where: { $0.id == id }) {
                if let organizationID = router.selectedOrganizationID,
                   let context = OrganizationScopes.context(serverID: id, organizationID: organizationID, in: contextsByServer) {
                    // An organization chosen in the dropdown: its pages under the shell's bar, as an
                    // organization-only administrator sees them after the gate.
                    PreNavigationScreen(title: context.name) {
                        OrganizationAdmissionView(server: server, store: store, sessionState: sessionState, contexts: [context])
                    }
                    .id("\(server.id)/\(organizationID)")
                } else {
                    AdminGateView(server: server, store: store, sessionState: sessionState) {
                        SingleServerPages(server: server, store: store, sessionState: sessionState)
                    }
                    // A different server starts from its own access check, never the previous one's.
                    .id(server.id)
                }
            } else {
                AllServersView(servers: store.servers, store: store, sessionState: sessionState)
            }
        }
    }

    /// The context dropdown: All servers and each saved server, with the organizations the server's account
    /// administers (`router.organizations`) listed under it.
    private var scopeControl: ScopeControl {
        let selectedServerID: String? = if case .server(let id) = router.scope { id } else { nil }
        let savedIDs = Set(store.servers.map(\.id))
        return ScopeControl(
            model: ContextDropdownModel(
                allServers: router.scope == .allServers,
                selectedServerID: selectedServerID,
                servers: store.servers.map { ScopeOption(id: $0.id, displayName: $0.displayName) },
                organizations: router.organizations,
                selectedOrganizationID: router.selectedOrganizationID
            ),
            onSelectAllServers: { router.select(scope: .allServers) },
            onSelectServer: { id in
                if savedIDs.contains(id) { router.select(scope: .server(id)) }
            },
            onSelectOrganization: { router.onSelectOrganization($0) },
            onOpenSwitcher: { router.openContextSwitcher() }
        )
    }
}
