import SwiftUI

/// "All servers" Settings: settings are per server, so this lists every server with its uptime and
/// whether it waits for a restart, and a row opens that server's own Settings pages.
struct AggregateServerConfigView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var viewModel = AggregateServerConfigViewModel()
    @State private var reAuthServer: AdminServer?

    var body: some View {
        List {
            Section {
                ForEach(servers) { server in
                    row(for: server)
                }
            } footer: {
                Text("Settings belong to one server. Pick a server to see and change them")
            }
        }
        .navigationTitle("Settings · All servers")
        .navigationBarTitleDisplayMode(.inline)
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
    }

    @ViewBuilder
    private func row(for server: AdminServer) -> some View {
        if let failure = viewModel.failure(for: server) {
            VStack(alignment: .leading, spacing: 8) {
                Text(server.displayName).bloemText(.titleMedium)
                ServerSectionFailureView(
                    failure: failure, server: server,
                    onSignIn: { reAuthServer = server },
                    onRetry: { Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) } }
                )
            }
        } else {
            NavigationLink {
                ServerConfigView(
                    client: resolveClient(server), serverName: server.displayName,
                    sessionState: sessionState.scoped(to: server.id)
                )
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.displayName)
                    if let status = viewModel.status(for: server) {
                        Text(subtitle(for: status))
                            .bloemText(.bodySmall)
                            .foregroundStyle(.bloemMuted)
                    } else {
                        Text("Reading the server")
                            .bloemText(.bodySmall)
                            .foregroundStyle(.bloemMuted)
                    }
                }
            }
            .accessibilityIdentifier("settings.server.\(server.id)")
        }
    }

    private func subtitle(for status: ServerStatus) -> String {
        let uptime = String(localized: "Up \(RestartStatus.uptime(for: status))")
        guard status.restartRequired else { return uptime }
        return uptime + " · " + String(localized: "Restart needed")
    }
}
