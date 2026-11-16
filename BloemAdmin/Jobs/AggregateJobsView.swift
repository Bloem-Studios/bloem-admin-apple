import SwiftUI

/// "All servers" version of `JobsListView`: one section per server, fanned
/// out concurrently via `AggregateJobsViewModel`. Tapping a task pushes the
/// existing single-server `JobDetailView` UNCHANGED — reused exactly like
/// `AggregateStreamsView` reuses `StreamDetailView` — with the environment's
/// `adminSessionState` scoped to that row's own server, so Run/Cancel/
/// trigger-schedule edits there target only that server's client and view
/// model.
struct AggregateJobsView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var viewModel = AggregateJobsViewModel()
    @State private var reAuthServer: AdminServer?

    /// The server's own Job history, read with that server's client and sign-in.
    private func historyLink(for server: AdminServer) -> some View {
        NavigationLink {
            JobHistoryView(client: resolveClient(server))
                .environment(\.adminSessionState, sessionState.scoped(to: server.id))
        } label: {
            Label("Job history", icon: .history)
        }
        .accessibilityIdentifier("job-history-link-\(server.id)")
    }

    var body: some View {
        List {
            ForEach(servers) { server in
                Section(server.displayName) {
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
                        } else if sectionViewModel.tasks.isEmpty {
                            Text("No scheduled tasks").foregroundStyle(.bloemMuted)
                            historyLink(for: server)
                        } else {
                            historyLink(for: server)
                            ForEach(sectionViewModel.tasks) { task in
                                NavigationLink {
                                    JobDetailView(
                                        task: task,
                                        client: resolveClient(server),
                                        viewModel: sectionViewModel,
                                        refreshAfterMutation: {
                                            await viewModel.refreshAfterDetailMutation(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
                                        }
                                    )
                                    .environment(\.adminSessionState, sessionState.scoped(to: server.id))
                                } label: {
                                    TaskRowView(task: task, now: Date())
                                }
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle("Scheduled tasks · All servers")
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: [.tasks],
            initial: { await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) },
            onSignals: { server, _ in
                await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
            }
        )
        .refreshable { await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) }
            }
        }
    }
}
