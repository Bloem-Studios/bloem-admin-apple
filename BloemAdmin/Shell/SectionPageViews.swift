import Observation
import SwiftUI

/// Loads a `SectionModel` when the page appears and when the app returns to the foreground, on pull to
/// refresh, and (for a page with `channels`) when one of those channels of the server's live socket changes.
/// It covers the page with a spinner or the typed failure while there are no rows. No timer.
struct SectionLoading<Payload: Sendable>: ViewModifier {
    let model: SectionModel<Payload>
    let client: APIClient
    var channels: Set<LiveChannel> = []
    @Environment(\.adminSessionState) private var sessionState
    @State private var hasLoaded = false

    func body(content: Content) -> some View {
        content
            .overlay {
                if model.payload == nil {
                    if let failure = model.loadFailure {
                        LoadFailureView(failure: failure) {
                            Task { await model.load(client: client, sessionState: sessionState) }
                        }
                    } else if !hasLoaded {
                        ProgressView()
                    }
                }
            }
            .liveRefresh(client: client, channels: channels) {
                await model.load(client: client, sessionState: sessionState)
                hasLoaded = true
            }
            .refreshable { await model.load(client: client, sessionState: sessionState) }
    }
}

extension View {
    func sectionLoading<Payload: Sendable>(_ model: SectionModel<Payload>, client: APIClient, channels: Set<LiveChannel> = []) -> some View {
        modifier(SectionLoading(model: model, client: client, channels: channels))
    }
}

/// A failed write, said where the write was made. Not shown when there is none.
struct ActionErrorRow: View {
    let message: String?

    var body: some View {
        if let message {
            Label(message, icon: .triangleAlert)
                .bloemText(.bodySmall)
                .accessibilityIdentifier("action-error")
        }
    }
}

/// One `SectionModel` per server for the All servers pages, read together through `fanOut` and applied
/// as each server answers. Mirrors `AggregateJobsViewModel`, for any page whose rows are one payload.
@Observable
@MainActor
final class AggregateSectionsModel<Payload: Sendable> {
    private(set) var orderedServers: [AdminServer] = []
    private var models: [String: SectionModel<Payload>] = [:]
    private var recovery = ServerSectionRecoveryState()
    @ObservationIgnored private let make: @MainActor (String) -> SectionModel<Payload>
    @ObservationIgnored private let fetch: @Sendable (APIClient) async throws -> Payload
    @ObservationIgnored private let loadFallback: String

    init(
        loadFallback: String,
        make: @escaping @MainActor (String) -> SectionModel<Payload>,
        fetch: @escaping @Sendable (APIClient) async throws -> Payload
    ) {
        self.loadFallback = loadFallback
        self.make = make
        self.fetch = fetch
    }

    func failure(for server: AdminServer) -> ServerSectionFailure? { recovery.failure(serverID: server.id) }
    func existing(for server: AdminServer) -> SectionModel<Payload>? { models[server.id] }

    func model(for server: AdminServer) -> SectionModel<Payload> {
        if let existing = models[server.id] { return existing }
        let created = make(server.displayName)
        models[server.id] = created
        return created
    }

    func loadAll(
        servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState,
        resolveClient: @escaping ServerClientResolver, session: URLSession = .shared
    ) async {
        orderedServers = servers
        recovery.retainServers(Set(servers.map(\.id)))
        for server in servers { _ = model(for: server) }
        var tokens: [String: Int] = [:]
        var generations: [String: UInt64] = [:]
        for server in servers { tokens[server.id] = model(for: server).beginLoad() }
        for server in servers { generations[server.id] = recovery.begin(serverID: server.id) }
        let fetch = self.fetch
        _ = await fanOut(
            servers: servers, store: store, session: session,
            onResult: { [weak self] section in
                guard let self, !Task.isCancelled else { return }
                let scoped = sessionState.scoped(to: section.server.id)
                guard let result = self.recovery.apply(
                    section.result, serverID: section.server.id,
                    generation: generations[section.server.id] ?? 0, sessionState: scoped
                ) else { return }
                self.model(for: section.server).apply(result, token: tokens[section.server.id] ?? 0, sessionState: scoped)
            },
            resolveClient: resolveClient,
            request: { _, client in try await fetch(client) }
        )
    }

    /// Reads one server again, after a write on its rows or a new sign-in.
    func reload(
        server: AdminServer, sessionState: AdminSessionState, resolveClient: ServerClientResolver
    ) async {
        let client = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let section = model(for: server)
        let token = section.beginLoad()
        let generation = recovery.begin(serverID: server.id)
        let typed: Result<Payload, ServerSectionFailure>
        do {
            typed = .success(try await fetch(client))
        } catch {
            typed = .failure(ServerSectionFailure.classify(error, fallback: loadFallback))
        }
        guard let result = recovery.apply(typed, serverID: server.id, generation: generation, sessionState: scoped) else { return }
        section.apply(result, token: token, sessionState: scoped)
    }
}

/// An All servers page: one section per server, each with its own failure, sign-in and rows. `rows` draws
/// a server's loaded payload with that server's own model and client, so a write goes only to that server.
struct AggregateSectionsView<Payload: Sendable, Rows: View>: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    var channels: Set<LiveChannel> = []
    let emptyText: LocalizedStringKey
    let isEmpty: (Payload) -> Bool
    @State private var model: AggregateSectionsModel<Payload>
    @ViewBuilder let rows: (AdminServer, SectionModel<Payload>, Payload, APIClient) -> Rows
    @State private var reAuthServer: AdminServer?

    init(
        servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState,
        resolveClient: @escaping ServerClientResolver, channels: Set<LiveChannel> = [],
        emptyText: LocalizedStringKey, isEmpty: @escaping (Payload) -> Bool,
        makeModel: @escaping () -> AggregateSectionsModel<Payload>,
        @ViewBuilder rows: @escaping (AdminServer, SectionModel<Payload>, Payload, APIClient) -> Rows
    ) {
        self.servers = servers
        self.store = store
        self.sessionState = sessionState
        self.resolveClient = resolveClient
        self.channels = channels
        self.emptyText = emptyText
        self.isEmpty = isEmpty
        _model = State(initialValue: makeModel())
        self.rows = rows
    }

    var body: some View {
        List {
            ForEach(servers) { server in
                Section(server.displayName) {
                    if let section = model.existing(for: server) {
                        ActionErrorRow(message: section.actionErrorMessage)
                        if let failure = model.failure(for: server) {
                            ServerSectionFailureView(
                                failure: failure, server: server,
                                onSignIn: { reAuthServer = server },
                                onRetry: { Task { await model.reload(server: server, sessionState: sessionState, resolveClient: resolveClient) } }
                            )
                        }
                        if let payload = section.payload {
                            if isEmpty(payload) {
                                Text(emptyText).foregroundStyle(.bloemMuted)
                            } else {
                                // Writes on these rows are checked against this server's sign-in only.
                                rows(server, section, payload, resolveClient(server))
                                    .environment(\.adminSessionState, sessionState.scoped(to: server.id))
                            }
                        } else if model.failure(for: server) == nil {
                            ProgressView()
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: channels,
            initial: { await model.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) },
            onSignals: { server, _ in
                if !channels.isEmpty { await model.reload(server: server, sessionState: sessionState, resolveClient: resolveClient) }
            }
        )
        .refreshable { await model.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await model.reload(server: server, sessionState: sessionState, resolveClient: resolveClient) }
            }
        }
    }
}
