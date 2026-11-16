import SwiftUI

/// The "All servers" pages: the same menu-driven shell as a single server (`ShellLayout`), scoped to every
/// added server at once instead of one. There is deliberately no `AdminGateView`-style single
/// admin-access gate here — each server's own admin-check happens implicitly per-section inside every
/// page (a server that fails its check just renders a "tap to sign in" section instead of blocking the
/// other servers).
///
/// Every page except Dashboard is a real aggregate implementation, each following the same
/// fan-out-per-section pattern `AggregateStreamsView`/`AggregateStreamsViewModel` established: `fanOut`
/// (bounded, incremental, cancellation-safe) drives the periodic/initial load, per-server child view
/// models (the exact same types single-server mode uses) back each section, and a failed section offers
/// the shared `SectionReLoginView` sign-in sheet.
///
/// This view owns one shared, credential-provider-backed `APIClient` per
/// server and hands it to every aggregate page. Each request obtains one
/// atomic credential snapshot immediately before constructing its
/// `URLRequest`, so principal changes are visible without a scheduled token
/// propagation step.
///
/// `clientsByServer` MUST be `@State` (review round 3 finding "New Critical
/// B"), not a plain `let` populated in `init` — this view is constructed
/// fresh by its parent's `body` (`AppRootView`)
/// on every re-render of that parent (adding/removing
/// a server, toggling the add-server sheet, any `store.servers` mutation),
/// which re-runs `init` every time. A plain `let` would silently rebuild
/// brand-new `APIClient` instances on each of those re-renders, breaking
/// the shared-client invariant. `@State`'s storage is boxed and tied
/// to this view's STABLE identity in the view tree, not to how many times
/// the struct value itself gets reconstructed, so `_clientsByServer =
/// State(initialValue:)` in `init` below only actually takes effect once,
/// on this view's first appearance — exactly mirroring how single-server
/// `SingleServerPages` declares `@State private var client`
/// and assigns it via `_client = State(initialValue: store.client(for:
/// server))` in ITS `init`.
struct AllServersView: View {
    let servers: [AdminServer]
    let store: ServerStore
    /// ONE shared session-state instance for the whole aggregate session,
    /// keyed internally by server id (see AdminSessionState's doc comment)
    /// — this is what lets, say, a re-login on server B leave server A's
    /// state alone while both are visible in the same Now playing page.
    let sessionState: AdminSessionState

    /// See this type's doc comment for why this MUST be `@State`.
    @State private var clientsByServer: [String: APIClient]
    /// Whether at least one saved server is a Bloem server, which is what puts Organizations in the menu. Plain
    /// Silo servers have no such page. Starts from what the store already knows and is settled by `.task` below.
    @State private var organizationsVisible: Bool
    @Environment(ShellRouter.self) private var router
    /// What waits for approval on every server together, for the Requests menu item.
    @State private var requestBadge = RequestBadgeModel()

    init(servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState) {
        self.servers = servers
        self.store = store
        self.sessionState = sessionState
        _clientsByServer = State(initialValue: store.authenticatedClients(for: servers, sessionState: sessionState))
        _organizationsVisible = State(initialValue: store.bloemDetector.anyKnownBloem(in: servers.map(\.baseURL)))
    }

    /// Pure lookup handed down to every page as `resolveClient`. Falls back
    /// to a fresh, uncached client for a server this view's `@State` was
    /// initialized without (e.g. one added to `store` after this view's
    /// first appearance, given `@State`'s initial value is only applied
    /// once per this view's identity — see this type's doc comment)
    /// ONLY for the brief window before `.task(id: servers.map(\.id))`
    /// below has run and backfilled it — that task is what actually fixes
    /// review round 4's "New Breakage 2" (a late-added server getting a
    /// fresh, throwaway, never-cached client on every single `client(for:)`
    /// call, forever, since nothing ever wrote it into `clientsByServer`).
    private func client(for server: AdminServer) -> APIClient {
        clientsByServer[server.id] ?? store.client(for: server, sessionState: sessionState)
    }

    var body: some View {
        ShellLayout(
            destinations: AdminDestination.allServers(organizationsVisible: organizationsVisible), heading: String(localized: "All servers"),
            badges: [AdminDestination.requests.id: requestBadge.needsApproval]
        ) { destination in
            page(for: destination)
        }
        .requestBadgeRefresh(
            model: requestBadge,
            sources: servers.map { RequestBadgeSource(serverID: $0.id, client: client(for: $0)) }
        )
        // Asks each saved server once (then remembered) whether it is a Bloem server. Plain Silo servers get no
        // Organizations page and no request for one.
        .task(id: servers.map(\.id)) {
            organizationsVisible = await anyBloemServer()
        }
        // Backfills `clientsByServer` for any server not present at this
        // view's first appearance (review round 4, "New Breakage 2") — runs
        // outside body evaluation (a `.task`, not a computed property), so
        // mutating `@State` here is safe, unlike doing so from `client(for:)`
        // itself. Keyed on the server id LIST so it only re-runs when that
        // set actually changes, not on every unrelated re-render.
        .task(id: servers.map(\.id)) {
            for server in servers where clientsByServer[server.id] == nil {
                clientsByServer[server.id] = store.client(for: server, sessionState: sessionState)
            }
        }
    }

    /// True when at least one of the servers answers as a Bloem server. All are asked together.
    private func anyBloemServer() async -> Bool {
        let clients = servers.map { client(for: $0) }
        return await withTaskGroup(of: Bool.self) { group in
            for client in clients {
                group.addTask { await client.isBloemServer() }
            }
            var any = false
            for await isBloem in group { any = any || isBloem }
            return any
        }
    }

    @ViewBuilder
    private func page(for destination: AdminDestination) -> some View {
        if servers.isEmpty {
            // Every All servers page says the same when there is nothing to show yet.
            NoServersView { router.isAddingServer = true }
        } else {
            aggregatePage(for: destination)
        }
    }

    @ViewBuilder
    private func aggregatePage(for destination: AdminDestination) -> some View {
        switch destination.id {
        case AdminDestination.organizations.id:
            AggregatePlatformOrganizationsView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.nowPlaying.id:
            AggregateStreamsView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:), showClientIP: true)
        case AdminDestination.dashboard.id:
            AggregateDashboardView(
                servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:),
                onShowStreams: { router.select(destinationID: AdminDestination.nowPlaying.id) },
                onShowUsers: { router.select(destinationID: AdminDestination.users.id) },
                onShowNodes: { router.select(destinationID: AdminDestination.nodes.id) }
            )
        case AdminDestination.playbackHistory.id:
            AggregateActivityView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.libraries.id:
            AggregateLibrariesView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.requests.id:
            AggregateRequestsView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.scheduledTasks.id:
            AggregateJobsView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.nodes.id:
            AggregateNodesView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.backups.id:
            AggregateBackupsView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.plugins.id:
            AggregatePluginsView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.users.id:
            AggregateUsersView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.settings.id:
            AggregateServerConfigView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        case AdminDestination.audit.id:
            AggregateAuditView(servers: servers, store: store, sessionState: sessionState, resolveClient: client(for:))
        default:
            EmptyView()
        }
    }
}
