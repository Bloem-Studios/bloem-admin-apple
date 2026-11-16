import SwiftUI

/// "All servers" version of `DashboardView`: one section per server, each laid out exactly like
/// the single-server dashboard under the server's name. A server that needs signing in shows a
/// Sign In row, one that failed shows its reason with Retry, and neither affects the others.
struct AggregateDashboardView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    /// The ONE shared `APIClient` per server, owned by `AllServersView`.
    let resolveClient: ServerClientResolver
    /// Opens the Streams tab (Now playing).
    var onShowStreams: (() -> Void)?
    /// Opens the Users tab.
    var onShowUsers: (() -> Void)?
    /// Opens Nodes from a server's health strip.
    var onShowNodes: (() -> Void)?
    @State private var viewModel = AggregateDashboardViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var reAuthServer: AdminServer?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if servers.isEmpty {
                    BloemEmptyState("No servers", icon: .server, description: Text("Add a server to see its dashboard"))
                }
                ForEach(servers) { server in
                    ServerDashboardSection(
                        server: server,
                        model: viewModel.model(for: server),
                        signInRequired: sessionState.isTokenExpired(for: server.id),
                        onSignIn: { reAuthServer = server },
                        onRetry: { Task { await reload(server) } },
                        onShowStreams: onShowStreams,
                        onShowUsers: onShowUsers,
                        onShowNodes: onShowNodes,
                        loadCharts: { await viewModel.loadCharts(server: server, sessionState: sessionState, resolveClient: resolveClient) }
                    )
                }
            }
            .padding()
        }
        .navigationTitle("Dashboard · All servers")
        // Every server is read when the screen opens and when the app returns. After that only a server's
        // `sessions` channel moves the live tiles, one server at a time, so a slow or unreachable server
        // never delays another. A server whose socket has been down for three attempts is read in full,
        // at most once a minute.
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: [.sessions],
            initial: { await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) },
            onSignals: { server, signals in
                if signals.contains(.fallback) {
                    await viewModel.load(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
                } else {
                    await viewModel.refreshSessions(server: server, sessionState: sessionState, resolveClient: resolveClient)
                }
            }
        )
        .refreshable {
            await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient, forceRefresh: true)
        }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await reload(server) }
            }
        }
    }

    private func reload(_ server: AdminServer) async {
        await viewModel.load(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient, forceRefresh: true)
    }
}

/// One server's heading and either its sections or its sign-in/failure state.
private struct ServerDashboardSection: View {
    let server: AdminServer
    let model: DashboardViewModel?
    let signInRequired: Bool
    let onSignIn: () -> Void
    let onRetry: () -> Void
    let onShowStreams: (() -> Void)?
    let onShowUsers: (() -> Void)?
    let onShowNodes: (() -> Void)?
    let loadCharts: () async -> Void

    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let model {
                summary(model)
                if signInRequired {
                    ServerSectionFailureView(
                        failure: .signedOut(message: String(localized: "Sign in again to include this server"), requestIdentity: nil),
                        server: server, onSignIn: onSignIn, onRetry: onRetry
                    )
                } else {
                    if let failure = model.serverFailure {
                        ServerSectionFailureView(failure: failure, server: server, onSignIn: onSignIn, onRetry: onRetry)
                    }
                    if expanded, failureShowsSections(model) {
                        DashboardSectionsView(model: model, onShowStreams: onShowStreams, onShowUsers: onShowUsers, onShowNodes: onShowNodes)
                    }
                }
            } else {
                Text(server.displayName)
                    .bloemText(.headlineSmall)
                    .accessibilityAddTraits(.isHeader)
                ProgressView()
            }
        }
        .accessibilityIdentifier("dashboard-server-\(server.id)")
        // A chart's new window is read as soon as it is chosen; a server that needs sign-in is not asked.
        .task(id: model?.ranges) {
            guard model != nil, !signInRequired else { return }
            await loadCharts()
        }
    }

    /// The server as one row: its name, then streams, egress and errors in the last 24 hours. Tapping it
    /// opens that server's whole dashboard under the row, and again closes it.
    private func summary(_ model: DashboardViewModel) -> some View {
        let streams = model.sessions.value.map { String($0.count) } ?? "—"
        let egress = model.tiles().first { $0.id == .egressNow }?.value ?? "—"
        let errors = model.insights.status.value?.health.map { String($0.errors24h) } ?? "—"
        let errorCount = model.insights.status.value?.health?.errors24h ?? 0
        return Button {
            expanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack {
                    Text(server.displayName).bloemText(.titleMedium).foregroundStyle(.bloemText).lineLimit(2)
                    Spacer(minLength: Theme.Space.s)
                    IconImage(expanded ? .chevronUp : .chevronDown, size: .inline)
                        .bloemText(.bodySmall).foregroundStyle(.bloemMuted).accessibilityHidden(true)
                }
                EqualColumns(
                    items: [
                        SummaryFigure(label: String(localized: "Streams"), value: streams, live: (Int(streams) ?? 0) > 0),
                        SummaryFigure(label: String(localized: "Egress"), value: egress, live: false),
                        SummaryFigure(label: String(localized: "Errors · 24h"), value: errors, live: false, warn: errorCount > 0),
                    ],
                    columns: typeSize.isAccessibilitySize ? 1 : 3, spacing: Theme.Space.m
                ) { figure in
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: Theme.Space.s) {
                            if figure.live { TallyDot() }
                            Text(figure.label).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                        Text(figure.value).bloemText(.titleSmall)
                            .foregroundStyle(figure.warn ? Color.bloemDanger : Color.bloemText)
                    }
                    .wrapsAtAnySize()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            }
            .padding(Theme.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .bloemCard()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(server.displayName): \(streams) streams, \(egress), \(errors) errors in 24 hours")
        .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
        .accessibilityHint(expanded ? Text("Hides this server's dashboard") : Text("Shows this server's dashboard"))
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("dashboard-server-summary-\(server.id)")
    }

    private struct SummaryFigure: Identifiable {
        let label: String
        let value: String
        let live: Bool
        var warn = false
        var id: String { label }
    }

    /// A server that has never answered has nothing to lay out; one with earlier values keeps them
    /// beside its failure, except when it needs signing in, which hides them.
    private func failureShowsSections(_ model: DashboardViewModel) -> Bool {
        guard let failure = model.serverFailure else { return true }
        return failure.kind != .signedOut && model.hasAnyValue
    }
}
