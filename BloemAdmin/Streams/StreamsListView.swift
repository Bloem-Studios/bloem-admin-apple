import SwiftUI

struct StreamsListView: View {
    let client: APIClient
    /// The platform administrator's page passes true; an organization context never does.
    var showClientIP = false
    /// Opens Logs for a stream's playback session; the single-server page passes it.
    var onOpenLogs: ((LogsFocus) -> Void)?
    @Environment(\.adminSessionState) private var sessionState
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = StreamsViewModel()
    /// The list, kept current by the `sessions` channel of the shared events socket.
    @State private var live: LiveSessions
    /// True once the first list read has answered — gates the initial spinner so it never re-shows.
    @State private var hasLoadedOnce = false

    init(client: APIClient, showClientIP: Bool = false, onOpenLogs: ((LogsFocus) -> Void)? = nil) {
        self.client = client
        self.showClientIP = showClientIP
        self.onOpenLogs = onOpenLogs
        _live = State(initialValue: LiveSessions(client: client))
    }

    /// One state at a time (the quality audit, 2026-11-16): with nothing to list, the page is either loading or failed, as a
    /// full-page state of its own; the live-status lines and the failure view used to stack over each other, saying
    /// "reconnecting", "connection lost" and "loading" at once.
    private var showsFullPageState: Bool {
        viewModel.sessions.isEmpty && (viewModel.loadFailure != nil || !hasLoadedOnce)
    }

    var body: some View {
        List {
            if !showsFullPageState {
                Section {
                    LiveSessionsStatus(state: live.state, failure: live.failure, hasSessions: !viewModel.sessions.isEmpty)
                    if let failure = viewModel.loadFailure, !viewModel.sessions.isEmpty {
                        // Rows from the last good read stay on screen; the failure and the way to try again sit with them.
                        Text(failure.message).bloemText(.bodySmall).foregroundStyle(.bloemDanger)
                        Button("Try again") { Task { await live.refresh(force: true) } }
                            .buttonStyle(.bloemSecondary)
                    }
                }
            }
            if let message = viewModel.actionErrorMessage {
                StreamActionErrorRow(message: message) { viewModel.dismissActionError() }
            }
            ForEach(viewModel.sessions) { session in
                StreamControlledRow(
                    session: session, client: client, viewModel: viewModel, showClientIP: showClientIP, onOpenLogs: onOpenLogs,
                    refreshAfterMutation: { await live.refresh(force: true) }
                )
            }
        }
        .overlay {
            if viewModel.sessions.isEmpty {
                if let failure = viewModel.loadFailure {
                    LoadFailureView(failure: failure) { Task { await live.refresh(force: true) } }
                } else if !hasLoadedOnce {
                    ProgressView()
                } else {
                    BloemEmptyState(
                        "No active streams",
                        icon: .radio,
                        description: Text("No users are streaming from this server right now")
                    )
                }
            }
        }
        .navigationTitle("Now playing")
        // Keyed on scenePhase so the subscription ends the moment the app leaves .active and starts again
        // (with an immediate read) when it returns.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            live.sessionState = sessionState
            await live.run()
        }
        .onChange(of: live.sessions) { syncLive() }
        .onChange(of: live.readFailure) { syncLive() }
        .refreshable { await live.refresh(force: true) }
    }

    private func syncLive() {
        viewModel.applyLive(sessions: live.sessions, readFailure: live.readFailure)
        if live.sessions != nil || live.readFailure != nil { hasLoadedOnce = true }
        // The app's first page has shown data from a server: the one moment iOS may ask about notifications.
        if live.sessions != nil { PushRuntime.shared.firstPageLoaded() }
    }
}
