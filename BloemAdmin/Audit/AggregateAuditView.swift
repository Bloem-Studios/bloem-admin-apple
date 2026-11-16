import SwiftUI

/// "All servers" version of `AuditListView`: one section per server, each
/// with its OWN independent cursor-based "Load more" and its OWN person
/// filter (picked by name), fanned out concurrently via `AggregateAuditViewModel`. Matches
/// single-server Audit's design of loading once on appear (plus
/// pull-to-refresh) rather than polling on a timer.
struct AggregateAuditView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var viewModel = AggregateAuditViewModel()
    @State private var reAuthServer: AdminServer?
    @State private var filtersByServer: [String: AuditFilter] = [:]
    @State private var selected: AuditLogEntry?

    private func filter(for server: AdminServer) -> AuditFilter {
        filtersByServer[server.id] ?? AuditFilter()
    }

    var body: some View {
        List {
            ForEach(servers) { server in
                Section(server.displayName) {
                    if let sectionViewModel = viewModel.existingViewModel(for: server) {
                        AggregateAuditPerson(
                            client: resolveClient(server),
                            identifier: "audit-\(server.id)-person",
                            userID: Binding(
                                get: { filter(for: server).userID },
                                set: { filtersByServer[server.id] = AuditFilter(userID: $0) }
                            ),
                            onApply: { applied in
                                Task { await viewModel.reload(server: server, filter: AuditFilter(userID: applied), store: store, sessionState: sessionState, resolveClient: resolveClient) }
                            }
                        )
                        if let failure = viewModel.failure(for: server) {
                            ServerSectionFailureView(
                                failure: failure,
                                server: server,
                                onSignIn: {
                                    viewModel.beginReauthentication(for: server, origin: .initialLoad)
                                    reAuthServer = server
                                },
                                onRetry: {
                                    Task {
                                        await viewModel.reload(
                                            server: server,
                                            filter: filter(for: server),
                                            store: store,
                                            sessionState: sessionState,
                                            resolveClient: resolveClient
                                        )
                                    }
                                }
                            )
                        } else if sectionViewModel.entries.isEmpty {
                            Text(filter(for: server).isEmpty ? "No audit entries" : "No audit entries match this person").foregroundStyle(.bloemMuted)
                        } else {
                            ForEach(sectionViewModel.entries) { entry in
                                Button { selected = entry } label: { AuditEntryRow(entry: entry) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("audit-row-\(entry.id)")
                                    .accessibilityAddTraits(.isButton)
                            }
                            if sectionViewModel.hasMore {
                                Button {
                                    Task {
                                        await viewModel.loadMore(server: server, sessionState: sessionState, resolveClient: resolveClient)
                                    }
                                } label: {
                                    if sectionViewModel.isLoadingMore {
                                        ProgressView()
                                    } else {
                                        Text("Load more")
                                    }
                                }
                                .disabled(sectionViewModel.isLoadingMore)
                            }
                            if let failure = viewModel.paginationFailure(for: server) {
                                ServerSectionFailureView(
                                    failure: failure,
                                    server: server,
                                    onSignIn: {
                                        viewModel.beginReauthentication(for: server, origin: .pagination)
                                        reAuthServer = server
                                    },
                                    onRetry: { Task { await viewModel.loadMore(server: server, sessionState: sessionState, resolveClient: resolveClient) } }
                                )
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle("Audit · All servers")
        .task {
            await viewModel.loadAll(filters: filtersByServer, servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
        }
        .refreshable {
            await viewModel.loadAll(filters: filtersByServer, servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
        }
        .sheet(item: $selected) { entry in
            AuditDetailSheet(entry: entry)
        }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task {
                    await viewModel.resumeAfterReauthentication(
                        server: server,
                        filter: filter(for: server),
                        store: store,
                        sessionState: sessionState,
                        resolveClient: resolveClient
                    )
                }
            }
        }
    }
}

/// One server's person filter in All servers: its own user list, applied as soon as a person is picked.
private struct AggregateAuditPerson: View {
    let client: APIClient
    let identifier: String
    @Binding var userID: String
    let onApply: (String) -> Void
    @State private var options = UserPickerOptions()

    var body: some View {
        PersonFilterPicker(userID: $userID, options: options, identifier: identifier)
            .task { await options.loadUsers(client: client) }
            .onChange(of: userID) { onApply(userID) }
    }
}
