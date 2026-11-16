import SwiftUI

/// All servers › Organizations: one section per saved server with that server's organizations. Search and the status
/// filter apply to every server. Tapping an organization opens its page on its own server, which names the server and
/// writes only to it; a server with more than one page of organizations offers its own page for the rest.
struct AggregatePlatformOrganizationsView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var model = AggregatePlatformOrganizationsModel()
    @State private var reAuthServer: AdminServer?
    @State private var hasLoaded = false
    @Environment(ShellRouter.self) private var router

    private struct Search: Equatable {
        let query: String
        let status: PlatformOrganizationStatusFilter
    }

    var body: some View {
        List {
            Section {
                Picker("Status", selection: $model.statusFilter) {
                    ForEach(PlatformOrganizationStatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("platform-organizations-status")
            }
            // A plain Silo server has no organizations: it gets no section, and no line saying so.
            ForEach(servers.filter { model.state(for: $0) != .unavailable }) { server in
                Section {
                    sectionContent(for: server)
                } header: {
                    Text(server.displayName)
                }
            }
        }
        .searchable(text: $model.query, prompt: Text("Search name or slug"))
        .task(id: Search(query: model.query, status: model.statusFilter)) {
            if hasLoaded {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            hasLoaded = true
            await reloadAll()
        }
        .refreshable { await reloadAll() }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await reload(server) }
            }
        }
        .accessibilityIdentifier("platform-organizations-all-servers")
    }

    private func reloadAll() async {
        await model.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
    }

    private func reload(_ server: AdminServer) async {
        await model.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
    }

    @ViewBuilder
    private func sectionContent(for server: AdminServer) -> some View {
        switch model.state(for: server) {
        case .loading:
            ProgressView()
        case .unavailable:
            EmptyView()
        case .failed(let failure):
            ServerSectionFailureView(
                failure: failure, server: server,
                onSignIn: { reAuthServer = server },
                onRetry: { Task { await reload(server) } }
            )
        case .loaded(let organizations, let hasMore):
            if organizations.isEmpty {
                Text(isFiltering ? "No organizations match these filters" : "No organizations on this server yet")
                    .foregroundStyle(.bloemMuted)
            }
            ForEach(organizations, id: \.id) { organization in
                NavigationLink {
                    PlatformOrganizationDetailView(server: server, client: resolveClient(server), sessionState: sessionState, organization: organization)
                } label: {
                    PlatformOrganizationRow(organization: organization)
                }
            }
            if hasMore {
                Button("Show all on \(server.displayName)") {
                    router.select(scope: .server(server.id))
                    router.select(destinationID: AdminDestination.organizations.id)
                }
                .frame(minHeight: 44)
            }
        }
    }

    private var isFiltering: Bool {
        !model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.statusFilter != .all
    }
}
