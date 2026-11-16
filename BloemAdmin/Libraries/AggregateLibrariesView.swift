import SwiftUI

/// The All servers Libraries page: one section per server, each acting on its own server. A server that cannot
/// be read shows its own sign-in or retry row and leaves the others alone.
struct AggregateLibrariesView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var viewModel = AggregateLibrariesViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var reAuthServer: AdminServer?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ForEach(servers) { server in
                    VStack(alignment: .leading, spacing: 12) {
                        Text(server.displayName)
                            .bloemText(.titleLarge)
                            .accessibilityAddTraits(.isHeader)
                        section(for: server)
                    }
                    .accessibilityIdentifier("libraries-server-\(server.id)")
                }
            }
            .padding()
        }
        .refreshable { await loadAll() }
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: LibrariesLive.channels,
            initial: { await loadAll() },
            onSignals: { server, _ in
                await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
            }
        )
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) }
            }
        }
    }

    @ViewBuilder
    private func section(for server: AdminServer) -> some View {
        if let sectionViewModel = viewModel.existingViewModel(for: server) {
            if let failure = viewModel.failure(for: server) {
                ServerSectionFailureView(
                    failure: failure,
                    server: server,
                    onSignIn: { reAuthServer = server },
                    onRetry: { Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) } }
                )
            } else if sectionViewModel.hasLoaded {
                LibrariesSectionView(
                    viewModel: sectionViewModel,
                    client: resolveClient(server),
                    sessionState: sessionState.scoped(to: server.id)
                )
            } else {
                ProgressView()
            }
        } else {
            ProgressView()
        }
    }

    private func loadAll() async {
        await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
    }
}
