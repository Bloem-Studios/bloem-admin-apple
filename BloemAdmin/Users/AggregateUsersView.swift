import SwiftUI

/// "All servers" version of `UsersListView`: one section per server, fanned
/// out concurrently via `AggregateUsersViewModel`. Search is client-side and
/// PER-SECTION — the shared `searchText` is applied independently to each
/// server's own already-loaded list via `filteredUsers(matching:)`, never
/// merging results across servers.
///
/// Tapping a user pushes the same `UserDetailView` the single-server list uses, scoped to that
/// row's own server: the page names the server and every write goes only there. Each row's
/// session state is its own `ServerScopedSession` slice.
struct AggregateUsersView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var viewModel = AggregateUsersViewModel()
    @State private var reAuthServer: AdminServer?
    @State private var addUserServer: AdminServer?
    @State private var searchText = ""

    var body: some View {
        List {
            ForEach(servers) { server in
                Section {
                    if let sectionViewModel = viewModel.existingViewModel(for: server) {
                        if let failure = viewModel.failure(for: server) {
                            ServerSectionFailureView(
                                failure: failure,
                                server: server,
                                onSignIn: { reAuthServer = server },
                                onRetry: {
                                    Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) }
                                }
                            )
                        } else {
                            let filtered = sectionViewModel.filteredUsers(matching: searchText)
                            if filtered.isEmpty {
                                Text(searchText.isEmpty ? "No users" : "No matching users").foregroundStyle(.bloemMuted)
                            } else {
                                ForEach(filtered) { user in
                                    NavigationLink {
                                        UserDetailView(
                                            user: user,
                                            admin: UserAdmin(
                                                viewModel: sectionViewModel,
                                                client: resolveClient(server),
                                                sessionState: sessionState.scoped(to: server.id),
                                                refreshList: {
                                                    await viewModel.refreshAfterDetailMutation(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
                                                }
                                            )
                                        )
                                        .environment(\.adminSessionState, sessionState.scoped(to: server.id))
                                    } label: {
                                        UserListRow(user: user)
                                    }
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                } header: {
                    HStack {
                        Text(server.displayName)
                        Spacer()
                        Button {
                            addUserServer = server
                        } label: {
                            Label("Add user to \(server.displayName)", icon: .plus)
                                .labelStyle(.iconOnly)
                        }
                        .disabled(viewModel.failure(for: server) != nil)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Username or email")
        .navigationTitle("Users · All servers")
        // Read on open and on return to the foreground; no channel carries user changes, so pull to refresh does the rest.
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: [],
            initial: { await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) },
            onSignals: { _, _ in }
        )
        .refreshable { await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) }
            }
        }
        .sheet(item: $addUserServer) { server in
            // Pure lookup only (review finding I4, mirrored from
            // AggregateStreamsView) — `loadAll` has always already
            // pre-populated the per-server view-model cache by the time this
            // sheet can be presented (Add User is only reachable from a
            // rendered section header), so `existingViewModel` never
            // actually falls through in practice.
            if let sectionViewModel = viewModel.existingViewModel(for: server) {
                AddUserView(
                    client: resolveClient(server),
                    viewModel: sectionViewModel,
                    sessionState: sessionState.scoped(to: server.id)
                )
            }
        }
    }
}
