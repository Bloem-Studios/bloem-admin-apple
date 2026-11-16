import SwiftUI

/// "All servers" version of `ActivityListView`: one section per server, each
/// with its OWN independent "Load more" (never a merged cross-server feed —
/// each section pages through its own server's history at its own offset)
/// and its OWN filters (person, profile, completed or partial), fanned out concurrently via
/// `AggregateActivityViewModel`. A server whose section failed to load
/// renders the same typed recovery affordance as Aggregate Streams.
struct AggregateActivityView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var viewModel = AggregateActivityViewModel()
    @State private var reAuthServer: AdminServer?
    @State private var filtersByServer: [String: HistoryFilter] = [:]
    @State private var selected: PlaybackHistoryEntry?

    private func filter(for server: AdminServer) -> HistoryFilter {
        filtersByServer[server.id] ?? HistoryFilter()
    }

    var body: some View {
        List {
            ForEach(servers) { server in
                Section(server.displayName) {
                    if let sectionViewModel = viewModel.existingViewModel(for: server) {
                        AggregateHistoryFilter(
                            client: resolveClient(server),
                            identifierPrefix: "history-\(server.id)",
                            filter: Binding(
                                get: { filter(for: server) },
                                set: { filtersByServer[server.id] = $0 }
                            ),
                            onApply: { applied in
                                Task { await viewModel.reload(server: server, filter: applied, store: store, sessionState: sessionState, resolveClient: resolveClient) }
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
                            Text(filter(for: server).isEmpty ? "No playback history" : "No plays match these filters").foregroundStyle(.bloemMuted)
                        } else {
                            ForEach(sectionViewModel.entries) { entry in
                                Button { selected = entry } label: { HistoryRowView(entry: entry) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("history-row-\(entry.sessionID)")
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
        .navigationTitle("Playback history · All servers")
        // Read on open and on return to the foreground, with no timer: each NOT-YET-PAGINATED section goes
        // back to page one (skipping any section a user has already paged past, like the single-server
        // screen's `hasLoadedBeyondFirstPage` gate), using THAT SECTION'S OWN currently-applied filter.
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: [],
            initial: {
                let applied = Dictionary(uniqueKeysWithValues: servers.map { ($0.id, viewModel.existingViewModel(for: $0)?.appliedFilter ?? HistoryFilter()) })
                await viewModel.loadAll(filters: applied, servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient, merging: true)
            },
            onSignals: { _, _ in }
        )
        .refreshable {
            await viewModel.loadAll(filters: filtersByServer, servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
        }
        .sheet(item: $selected) { entry in
            // Logs belong to one server's menu, so there is no Logs shortcut in All servers.
            HistoryDetailSheet(entry: entry, onOpenLogs: nil)
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

/// One server's filters in All servers: its own user list and profiles, applied as soon as they change.
private struct AggregateHistoryFilter: View {
    let client: APIClient
    let identifierPrefix: String
    @Binding var filter: HistoryFilter
    let onApply: (HistoryFilter) -> Void
    @State private var options = UserPickerOptions()

    var body: some View {
        HistoryFilterControls(filter: $filter, options: options, client: client, identifierPrefix: identifierPrefix)
            .task { await options.loadUsers(client: client) }
            .onChange(of: filter) { onApply(filter) }
    }
}
