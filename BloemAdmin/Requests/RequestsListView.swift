import SwiftUI

/// A server's Requests page, as the web admin's queue: the four views with their counts, search by
/// title or TMDB ID, a media-type filter and a "requested by" filter, then one row per request with
/// the actions its view allows. A row opens the request's details.
struct RequestsListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @Environment(\.requestBadge) private var requestBadge
    @Environment(ShellRouter.self) private var router: ShellRouter?
    @State private var model = RequestQueueViewModel()
    @State private var prompt: RequestReasonPrompt?
    @State private var note = ""
    @State private var detail: MediaRequest?
    @State private var bulk = BulkTriageModel()
    @State private var confirmBulkDecline = false
    @State private var bulkNote = ""

    /// Only Needs approval can be answered in bulk, as on the web.
    private var canSelect: Bool { model.view == .needsApproval && model.hasLoaded && !selectableRequests.isEmpty }

    private var selectableRequests: [MediaRequest] { model.requests.filter(RequestQueue.canAnswerInBulk) }

    /// The shown rows that are selected; a row that left the view since is no longer counted.
    private var selectedItems: [BulkRequestItem] {
        selectableRequests.filter { bulk.isSelected($0.id) }.map { request in
            BulkRequestItem(
                key: request.id, requestID: request.id, title: request.title, serverID: nil,
                client: client, sessionState: sessionState
            )
        }
    }

    var body: some View {
        List {
            if !model.isUnavailable {
                Section {
                    RequestViewPicker(selection: model.view, counts: model.counts) { view in
                        bulk.endSelecting()
                        model.select(view: view)
                        Task { await model.load(client: client, sessionState: sessionState) }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    filters
                    if canSelect {
                        BulkSelectHeader(model: bulk, shownKeys: selectableRequests.map(\.id), selectedCount: selectedItems.count)
                    }
                }
            }
            if let notice = model.staleNotice {
                Section {
                    HStack {
                        Label(notice, icon: .clockAlert).bloemText(.bodyLarge)
                        Spacer(minLength: 8)
                        Button("Try again") { reload() }.buttonStyle(.bloemQuiet).frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("requests-stale-notice")
                }
            }
            if let progress = bulk.progress {
                Section {
                    BulkProgressBanner(progress: progress) { bulk.dismissResult() }
                }
            }
            if let message = model.actionErrorMessage {
                Section {
                    Label(message, icon: .triangleAlert)
                        .foregroundStyle(.bloemDanger)
                        .bloemText(.bodyLarge)
                }
            }
            Section {
                queueRows
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
        .navigationTitle("Requests")
        .searchable(text: $model.search, prompt: Text("Search by title or TMDB ID"))
        .onSubmit(of: .search) { reload() }
        .onChange(of: model.search) { _, text in
            if text.isEmpty { reload() }
        }
        .onChange(of: model.mediaFilter) { _, _ in reload() }
        // Read on open, on return to the foreground and on pull to refresh. The server has no channel for
        // requests (the `notifications` channel carries the requester's own inbox), so there is no timer.
        .liveRefresh(client: client, channels: []) {
            await model.load(client: client, sessionState: sessionState)
        }
        // The menu badge follows what this page reads, without waiting for its own minute.
        .onChange(of: model.counts) { _, counts in
            if let counts, let serverID = sessionState?.serverID { requestBadge?.record(counts.needsApproval, serverID) }
        }
        .refreshable { await model.load(client: client, sessionState: sessionState) }
        // A link that names a request (a tapped notification) opens its details once the list has it.
        .onChange(of: router?.itemFocus, initial: true) { _, _ in openFocusedRequest() }
        .onChange(of: model.requests.map(\.id)) { _, _ in openFocusedRequest() }
        .onChange(of: model.hasLoaded) { _, _ in openFocusedRequest() }
        .requestReasonAlert($prompt, note: $note) { prompt, reason in
            Task { await model.perform(prompt.action, on: prompt.request, reason: reason, client: client, sessionState: sessionState) }
        }
        .sheet(item: $detail) { request in
            NavigationStack {
                RequestDetailView(
                    request: model.requests.first { $0.id == request.id } ?? request,
                    client: client,
                    requester: model.requester(for: request),
                    perform: { action, reason in
                        await model.perform(action, on: request, reason: reason, client: client, sessionState: sessionState)
                    },
                    actionError: { model.actionErrorMessage }
                )
            }
        }
    }

    /// Opens the details of the request a link named. A request the list does not have after it has loaded
    /// is dropped, so a later load never opens it by surprise.
    private func openFocusedRequest() {
        guard let router, let focus = router.itemFocus, focus.pageID == DeepLinkPage.requests else { return }
        if let request = model.requests.first(where: { $0.id == focus.itemID }) {
            _ = router.takeItemFocus(for: DeepLinkPage.requests)
            detail = request
        } else if model.hasLoaded {
            _ = router.takeItemFocus(for: DeepLinkPage.requests)
        }
    }

    @ViewBuilder
    private var filters: some View {
        Picker("Media type", selection: $model.mediaFilter) {
            ForEach(RequestMediaFilter.allCases) { filter in
                Text(filter.label).tag(filter)
            }
        }
        if model.userFilter != nil {
            Button {
                model.clearUserFilter()
                reload()
            } label: {
                HStack {
                    Label(requestedByText, icon: .circleUser)
                    Spacer()
                    IconImage(.circleX, size: .inline).foregroundStyle(.bloemMuted)
                }
            }
            .accessibilityHint(Text("Show requests from every account"))
        }
    }

    private var requestedByText: String {
        guard let id = model.userFilter else { return "" }
        let name = model.requesterNames[id] ?? String(localized: "User \(id)")
        return String(localized: "Requested by \(name)")
    }

    @ViewBuilder
    private var queueRows: some View {
        if !model.hasLoaded {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.vertical, 24)
        } else if model.isUnavailable {
            RequestsUnavailableView()
        } else if let failure = model.loadFailure, model.requests.isEmpty {
            LoadFailureView(failure: failure) { reload() }
        } else if model.requests.isEmpty {
            if model.isFiltered {
                BloemEmptyState(
                    "No matching requests", icon: .listFilter,
                    description: Text("No request in this view matches the filters")
                )
            } else {
                BloemEmptyState("All clear", icon: .circleCheck, description: Text(model.view.emptyText))
            }
        } else {
            ForEach(model.requests) { request in
                RequestQueueRow(
                    request: request,
                    requester: model.requester(for: request),
                    busy: model.isBusy(request),
                    onAction: { action in act(action, on: request) },
                    onOpen: { detail = request },
                    onFilterUser: request.requestedByUserID.map { id in
                        { model.filter(byUser: id); reload() }
                    },
                    selection: bulk.isSelecting && RequestQueue.canAnswerInBulk(request)
                        ? RequestRowSelection(isSelected: bulk.isSelected(request.id)) { bulk.toggle(request.id) }
                        : nil
                )
            }
            if model.moreFailed {
                Text("More requests couldn't be loaded. Try again.").bloemText(.bodySmall).foregroundStyle(.bloemDanger)
            }
            if model.nextCursor != nil {
                Button {
                    Task { await model.loadMore(client: client, sessionState: sessionState) }
                } label: {
                    HStack {
                        Spacer()
                        if model.isLoadingMore { ProgressView() } else { Text("Load more") }
                        Spacer()
                    }
                }
                .disabled(model.isLoadingMore)
            }
        }
    }

    private func act(_ action: RequestQueueAction, on request: MediaRequest) {
        if action.asksForReason {
            note = ""
            prompt = RequestReasonPrompt(action: action, request: request)
        } else {
            Task { await model.perform(action, on: request, client: client, sessionState: sessionState) }
        }
    }

    private func reload() {
        Task { await model.load(client: client, sessionState: sessionState) }
    }

    /// Answers every selected request, then reads the queue again so answered requests leave Needs approval.
    private func runBulk(_ action: BulkRequestAction, note: String?) {
        let items = selectedItems
        Task {
            await bulk.run(action, on: items, note: note)
            await model.load(client: client, sessionState: sessionState)
        }
    }
}
