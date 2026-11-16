import SwiftUI

/// The Network access page: each installed overlay provider (Tailscale, NetBird) and the hosts that run
/// it, with their state, the address clients reach them at, Connect and Disconnect, and the page that
/// finishes enrolment.
struct NetworkAccessView: View {
    let client: APIClient
    let sessionState: ServerScopedSession?
    let serverName: String?

    @State private var model: NetworkAccessModel
    @State private var disconnecting: (provider: NetworkAccessProvider, host: NetworkAccessHost)?

    init(client: APIClient, sessionState: ServerScopedSession?, serverName: String? = nil) {
        self.client = client
        self.sessionState = sessionState
        self.serverName = serverName
        _model = State(initialValue: NetworkAccessModel(serverName: serverName))
    }

    var body: some View {
        Group {
            if let failure = model.loadFailure {
                LoadFailureView(failure: failure) { Task { await model.load(client: client, sessionState: sessionState) } }
            } else if !model.hasLoaded {
                ProgressView()
            } else {
                list
            }
        }
        .navigationTitle(SettingsCatalogue.networkAccess.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(client: client, sessionState: sessionState) }
        .refreshable { await model.load(client: client, sessionState: sessionState) }
        .confirmationDialog(
            "Disconnect this host?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
            titleVisibility: .visible, presenting: disconnecting
        ) { target in
            Button("Disconnect", role: .destructive) {
                Task { await model.disconnect(provider: target.provider, host: target.host, client: client, sessionState: sessionState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Apps that reach this server over the overlay network lose the connection until it is connected again")
        }
    }

    private var list: some View {
        List {
            Section {
                Text("Network access providers give this server an identity on an overlay network such as Tailscale, so clients can reach it without port forwarding or a public reverse proxy. Providers are plugins: install one from the web admin and it appears here")
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
            if let actionError = model.actionError {
                Section { Label(actionError, icon: .triangleAlert).bloemText(.bodySmall) }
                    .accessibilityIdentifier("networkAccess.error")
            }
            if model.entries.isEmpty {
                Section {
                    BloemEmptyState(
                        "No providers installed", icon: .network,
                        description: Text("No installed plugin provides network access. Install a network access provider from the web admin to connect this server to an overlay network")
                    )
                }
            }
            ForEach(model.entries) { entry in
                Section {
                    if let error = entry.error {
                        Label(error, icon: .triangleAlert).bloemText(.bodySmall)
                    } else if entry.hosts.isEmpty {
                        Text("No host runs this provider yet").foregroundStyle(.bloemMuted)
                    }
                    ForEach(entry.hosts) { host in
                        hostRow(host, entry.provider)
                    }
                } header: {
                    Text(entry.provider.displayName)
                }
            }
        }
    }

    private func hostRow(_ host: NetworkAccessHost, _ provider: NetworkAccessProvider) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.title)
                    Text(host.stateLabel)
                        .bloemText(.bodySmall)
                        .foregroundStyle(.bloemMuted)
                        .accessibilityIdentifier("networkAccess.\(host.id).state")
                }
                Spacer()
                if model.busyHostIDs.contains(host.id) {
                    ProgressView()
                } else if host.isOn {
                    Button("Disconnect", role: .destructive) { disconnecting = (provider, host) }
                        .buttonStyle(.bloemSecondary)
                        .accessibilityIdentifier("networkAccess.\(host.id).disconnect")
                } else {
                    Button("Connect") {
                        Task { await model.connect(provider: provider, host: host, client: client, sessionState: sessionState) }
                    }
                    .buttonStyle(.bloemSecondary)
                    .disabled(host.state == "unavailable")
                    .accessibilityIdentifier("networkAccess.\(host.id).connect")
                }
            }
            if host.state == "unavailable" {
                Text("Start the plugin from the web admin first")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if let origin = host.origin, !origin.isEmpty {
                Text("Clients reach this host at \(origin)")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    .textSelection(.enabled)
            }
            if let url = host.authorizationURL, host.state == "awaiting_authorization" {
                Link(destination: url) {
                    Label("Open the authorization page", icon: .compass)
                }
                .bloemText(.bodySmall)
                .accessibilityIdentifier("networkAccess.\(host.id).authorize")
            }
            if let error = host.error, !error.isEmpty {
                Text(error).bloemText(.bodySmall).foregroundStyle(.bloemMuted).fixedSize(horizontal: false, vertical: true)
            }
            if let updatedAt = host.updatedAt {
                Text("Last heard from \(updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("networkAccess.host.\(host.id)")
    }
}
