import SwiftUI

/// "All servers" version of `RequestsListView`: the same four views and rows, one section per
/// server, fanned out concurrently via `AggregateRequestsViewModel`. Each server's requests are read
/// whole, so the views and their counts are worked out here with the web's rule
/// (`RequestQueue.view(for:)`). Actions and details run against the row's own server.
struct AggregateRequestsView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver
    @State private var viewModel = AggregateRequestsViewModel()
    @Environment(\.requestBadge) private var requestBadge
    @State private var reAuthServer: AdminServer?
    @State private var selectedView: RequestQueueView?
    @State private var prompt: AggregatePrompt?
    @State private var note = ""
    @State private var detail: AggregateDetail?
    @State private var bulk = BulkTriageModel()
    @State private var confirmBulkDecline = false
    @State private var bulkNote = ""

    private struct AggregatePrompt {
        let reason: RequestReasonPrompt
        let server: AdminServer
    }

    private struct AggregateDetail: Identifiable {
        let request: MediaRequest
        let server: AdminServer
        var id: String { "\(server.id)/\(request.id)" }
    }

    /// Opens on what needs approval anywhere, else what is under way, until a view is picked.
    private var view: RequestQueueView { selectedView ?? RequestQueue.defaultView(counts) }

    private var counts: RequestCounts {
        var counts = RequestCounts(needsApproval: 0, inProgress: 0, failed: 0, done: 0)
        for server in servers {
            for request in viewModel.existingViewModel(for: server)?.requests ?? [] {
                switch RequestQueue.view(for: request) {
                case .needsApproval: counts.needsApproval += 1
                case .inProgress: counts.inProgress += 1
                case .failed: counts.failed += 1
                case .done: counts.done += 1
                }
            }
        }
        return counts
    }

    /// Every request that can be answered in bulk, across the servers whose list loaded, with its server.
    private var selectableRows: [(server: AdminServer, request: MediaRequest)] {
        guard view == .needsApproval else { return [] }
        return servers.flatMap { server -> [(server: AdminServer, request: MediaRequest)] in
            guard viewModel.failure(for: server) == nil, let model = viewModel.existingViewModel(for: server) else { return [] }
            return model.requests
                .filter { RequestQueue.view(for: $0) == .needsApproval && RequestQueue.canAnswerInBulk($0) }
                .map { (server: server, request: $0) }
        }
    }

    private func bulkKey(_ request: MediaRequest, on server: AdminServer) -> String { "\(server.id)/\(request.id)" }

    /// The selected rows that are still shown, each with the client and sign-in of its own server.
    private var selectedItems: [BulkRequestItem] {
        selectableRows.filter { bulk.isSelected(bulkKey($0.request, on: $0.server)) }.map { row in
            BulkRequestItem(
                key: bulkKey(row.request, on: row.server), requestID: row.request.id, title: row.request.title,
                serverID: row.server.id, serverName: row.server.displayName,
                client: resolveClient(row.server), sessionState: sessionState.scoped(to: row.server.id)
            )
        }
    }

    var body: some View {
        List {
            Section {
                RequestViewPicker(selection: view, counts: counts) {
                    bulk.endSelecting()
                    selectedView = $0
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                if !selectableRows.isEmpty {
                    BulkSelectHeader(
                        model: bulk, shownKeys: selectableRows.map { bulkKey($0.request, on: $0.server) },
                        selectedCount: selectedItems.count
                    )
                }
            }
            if let progress = bulk.progress {
                Section {
                    BulkProgressBanner(progress: progress) { bulk.dismissResult() }
                }
            }
            ForEach(servers) { server in
                Section(server.displayName) {
                    section(for: server)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            if bulk.isSelecting {
                BulkActionBar(
                    model: bulk, selectedCount: selectedItems.count,
                    onApprove: { runBulk(.approve, note: nil) },
                    onDecline: { confirmBulkDecline = true }
                )
            }
        }
        .bulkDeclineAlert(isPresented: $confirmBulkDecline, count: selectedItems.count, note: $bulkNote) { note in
            runBulk(.decline, note: note)
        }
        .navigationTitle("Requests · All servers")
        // Read on open, on return to the foreground and on pull to refresh; the server has no channel for requests.
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: [],
            initial: {
                await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
                await viewModel.loadNames(servers: servers, resolveClient: resolveClient)
            },
            onSignals: { _, _ in }
        )
        // A pull to refresh also asks the servers that said they have no request administration.
        .refreshable {
            await viewModel.loadAll(
                servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient, includeUnavailable: true
            )
        }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await reload(server) }
            }
        }
        .requestReasonAlert(reasonBinding, note: $note) { reasonPrompt, reason in
            guard let server = prompt?.server else { return }
            Task { _ = await perform(reasonPrompt.action, on: reasonPrompt.request, reason: reason, server: server) }
        }
        .sheet(item: $detail) { detail in
            NavigationStack {
                RequestDetailView(
                    request: currentRequest(detail.request, on: detail.server),
                    client: resolveClient(detail.server),
                    requester: viewModel.requester(for: detail.request, on: detail.server),
                    serverName: detail.server.displayName,
                    perform: { action, reason in
                        await perform(action, on: detail.request, reason: reason, server: detail.server)
                    },
                    actionError: { viewModel.existingViewModel(for: detail.server)?.actionErrorMessage }
                )
                .environment(\.adminSessionState, sessionState.scoped(to: detail.server.id))
            }
        }
    }

    @ViewBuilder
    private func section(for server: AdminServer) -> some View {
        if let sectionViewModel = viewModel.existingViewModel(for: server) {
            if viewModel.isUnavailable(server) {
                RequestsUnavailableView(compact: true)
            } else if let failure = viewModel.failure(for: server) {
                ServerSectionFailureView(
                    failure: failure,
                    server: server,
                    onSignIn: { reAuthServer = server },
                    onRetry: { Task { await reload(server) } }
                )
            } else {
                let rows = sectionViewModel.requests.filter { RequestQueue.view(for: $0) == view }
                if let message = sectionViewModel.actionErrorMessage {
                    Text(message).bloemText(.bodyLarge).foregroundStyle(.bloemDanger)
                }
                if rows.isEmpty {
                    Text(view.emptyText).foregroundStyle(.bloemMuted)
                } else {
                    ForEach(rows) { request in
                        RequestQueueRow(
                            request: request,
                            requester: viewModel.requester(for: request, on: server),
                            busy: viewModel.isBusy(request, on: server),
                            onAction: { action in act(action, on: request, server: server) },
                            onOpen: { detail = AggregateDetail(request: request, server: server) },
                            selection: bulk.isSelecting && RequestQueue.canAnswerInBulk(request)
                                ? RequestRowSelection(isSelected: bulk.isSelected(bulkKey(request, on: server))) {
                                    bulk.toggle(bulkKey(request, on: server))
                                }
                                : nil
                        )
                    }
                }
            }
        } else {
            ProgressView()
        }
    }

    private var reasonBinding: Binding<RequestReasonPrompt?> {
        Binding(get: { prompt?.reason }, set: { if $0 == nil { prompt = nil } })
    }

    private func currentRequest(_ request: MediaRequest, on server: AdminServer) -> MediaRequest {
        viewModel.existingViewModel(for: server)?.requests.first { $0.id == request.id } ?? request
    }

    private func act(_ action: RequestQueueAction, on request: MediaRequest, server: AdminServer) {
        if action.asksForReason {
            note = ""
            prompt = AggregatePrompt(reason: RequestReasonPrompt(action: action, request: request), server: server)
        } else {
            Task { _ = await perform(action, on: request, reason: nil, server: server) }
        }
    }

    /// Runs the action on the row's own server, then reloads only that server's section.
    private func perform(_ action: RequestQueueAction, on request: MediaRequest, reason: String?, server: AdminServer) async -> Bool {
        let succeeded = await viewModel.perform(
            action, on: request, reason: reason, server: server,
            store: store, sessionState: sessionState, resolveClient: resolveClient
        )
        if succeeded { requestBadge?.refresh() }
        return succeeded
    }

    /// Answers every selected request on its own server, then reads just those servers again.
    private func runBulk(_ action: BulkRequestAction, note: String?) {
        let items = selectedItems
        Task {
            let touched = await bulk.run(action, on: items, note: note)
            for server in servers where touched.contains(server.id) { await reload(server) }
            requestBadge?.refresh()
        }
    }

    private func reload(_ server: AdminServer) async {
        await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
    }
}
