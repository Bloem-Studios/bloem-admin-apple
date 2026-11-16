import SwiftUI

struct JobsListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var viewModel = JobsViewModel()
    /// True once the first `load` call has completed — gates the initial
    /// spinner so it never re-shows on a routine 15s poll tick.
    @State private var hasLoadedOnce = false

    var body: some View {
        let now = Date()
        List {
            Section {
                NavigationLink {
                    JobHistoryView(client: client)
                } label: {
                    Label("Job history", icon: .history)
                }
                .accessibilityIdentifier("job-history-link")
            }
            if hasLoadedOnce && viewModel.tasks.isEmpty && viewModel.errorMessage == nil {
                Section {
                    Text("This server has no scheduled or running tasks").foregroundStyle(.bloemMuted)
                }
            }
            Section {
                ForEach(viewModel.tasks) { task in
                    NavigationLink {
                        JobDetailView(task: task, client: client, viewModel: viewModel)
                    } label: {
                        TaskRowView(task: task, now: now)
                    }
                }
            }
        }
        .overlay {
            if !hasLoadedOnce && viewModel.tasks.isEmpty && viewModel.errorMessage == nil {
                ProgressView()
            } else if let failure = viewModel.loadFailure {
                LoadFailureView(failure: failure) { Task { await viewModel.load(client: client, sessionState: sessionState) } }
            }
        }
        .navigationTitle("Scheduled tasks")
        // Read on open and on return to the foreground, then whenever the server's `tasks` channel says a
        // task changed (started, progressed, finished). No timer; the socket is held only while the app is
        // in the foreground.
        .liveRefresh(client: client, channels: [.tasks]) {
            await viewModel.load(client: client, sessionState: sessionState)
            hasLoadedOnce = true
        }
        .refreshable { await viewModel.load(client: client, sessionState: sessionState) }
    }
}
