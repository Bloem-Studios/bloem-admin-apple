import SwiftUI

/// The pages of one server once `AdminGateView` has let the person in: the menu-driven shell (`ShellLayout`)
/// over that server's Now playing, Dashboard, Playback history, Logs, Libraries, Requests, Scheduled tasks, Users,
/// Settings and Audit pages, and the Platform group (Organizations, and Support access for the server Owner).
struct SingleServerPages: View {
    let server: AdminServer
    let sessionState: AdminSessionState

    /// Built once in `init` and reused by every page. Each request reads one
    /// immutable credential snapshot from `sessionState`.
    @State private var client: APIClient
    /// A Bloem server gets Platform › Organizations for every platform administrator
    /// (`PlatformOrganizationsEligibility`).
    @State private var organizationsVisible = false
    /// The server Owner on a server with organization support gets Support Access (`SupportAccessEligibility`).
    @State private var supportAccessVisible = false
    /// What waits for approval on this server, for the Requests menu item.
    @State private var requestBadge = RequestBadgeModel()
    @Environment(ShellRouter.self) private var router

    init(server: AdminServer, store: ServerStore, sessionState: AdminSessionState) {
        self.server = server
        self.sessionState = sessionState
        _client = State(initialValue: store.client(for: server, sessionState: sessionState))
        // A server already known to be a Bloem server shows its Platform pages at once; `.task` below settles the rest.
        _organizationsVisible = State(initialValue: store.bloemDetector.cachedVerdict(for: server.baseURL)?.isBloem == true)
    }

    var body: some View {
        ShellLayout(
            destinations: AdminDestination.singleServer(tenantsVisible: organizationsVisible, supportAccessVisible: supportAccessVisible),
            heading: server.displayName,
            badges: [AdminDestination.requests.id: requestBadge.needsApproval]
        ) { destination in
            page(for: destination)
        }
        .requestBadgeRefresh(model: requestBadge, sources: [RequestBadgeSource(serverID: server.id, client: client)])
        .task(id: server.id) {
            organizationsVisible = await PlatformOrganizationsEligibility.check(client: client)
            supportAccessVisible = await SupportAccessEligibility.check(client: client)
        }
        // Hands each page a proxy pre-bound to THIS server's id, so their view models keep
        // reading/writing token-expiry through the same single-server-shaped API they always used —
        // see AdminSessionState.scoped(to:).
        .environment(\.adminSessionState, sessionState.scoped(to: server.id))
    }

    @ViewBuilder
    private func page(for destination: AdminDestination) -> some View {
        switch destination.id {
        case AdminDestination.nowPlaying.id: StreamsListView(client: client, showClientIP: true, onOpenLogs: { router.openLogs($0) })
        case AdminDestination.dashboard.id:
            DashboardView(
                client: client,
                onShowStreams: { router.select(destinationID: AdminDestination.nowPlaying.id) },
                onShowUsers: { router.select(destinationID: AdminDestination.users.id) },
                onShowNodes: { router.select(destinationID: AdminDestination.nodes.id) }
            )
        case AdminDestination.playbackHistory.id: ActivityListView(client: client, onOpenLogs: { router.openLogs($0) })
        case AdminDestination.logs.id: LogsListView(client: client)
        case AdminDestination.libraries.id: LibrariesListView(client: client)
        case AdminDestination.requests.id: RequestsListView(client: client)
        case AdminDestination.scheduledTasks.id: JobsListView(client: client)
        case AdminDestination.nodes.id: NodesView(client: client)
        case AdminDestination.backups.id: BackupsView(client: client)
        case AdminDestination.plugins.id: PluginsView(client: client)
        case AdminDestination.users.id: UsersListView(client: client)
        case AdminDestination.organizations.id: PlatformOrganizationsView(server: server, client: client, sessionState: sessionState)
        case AdminDestination.supportAccess.id: SupportAccessView(server: server, client: client, sessionState: sessionState)
        case AdminDestination.settings.id: ServerConfigView(client: client)
        case AdminDestination.apiKeys.id: APIKeysListView(client: client)
        case AdminDestination.audit.id: AuditListView(client: client)
        default: EmptyView()
        }
    }
}
