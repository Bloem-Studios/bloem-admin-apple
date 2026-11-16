import SwiftUI

/// Playback history of one server (`GET /api/v2/admin/playback-history`): past plays with when they
/// ended, watch time out of length, profile, play method and episode code. Filter by person, profile
/// and completed or partial; a tap opens the play's details, from where Logs and FFmpeg logs open for
/// its playback session.
struct ActivityListView: View {
    let client: APIClient
    /// Opens Logs for a playback session. SingleServerPages passes it; fixtures leave it nil.
    var onOpenLogs: ((LogsFocus) -> Void)?
    @Environment(\.adminSessionState) private var sessionState
    @State private var viewModel = ActivityViewModel()
    @State private var options = UserPickerOptions()
    @State private var filter = HistoryFilter()
    @State private var selected: PlaybackHistoryEntry?
    /// True once the first `load` call has completed — gates the initial
    /// spinner so it never re-shows on a routine 30s poll tick.
    @State private var hasLoadedOnce = false

    var body: some View {
        List {
            Section {
                HistoryFilterControls(filter: $filter, options: options, client: client)
                if let failure = options.usersFailure {
                    Text(failure).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
            Section {
                ForEach(viewModel.entries) { entry in
                    Button { selected = entry } label: { HistoryRowView(entry: entry) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("history-row-\(entry.sessionID)")
                        .accessibilityAddTraits(.isButton)
                }
                if viewModel.hasMore {
                    Button {
                        Task { await viewModel.loadMore(client: client, sessionState: sessionState) }
                    } label: {
                        if viewModel.isLoadingMore {
                            ProgressView()
                        } else {
                            Text("Load more")
                        }
                    }
                    .disabled(viewModel.isLoadingMore)
                }
            } footer: {
                if let message = viewModel.loadMoreErrorMessage {
                    Text(message).foregroundStyle(.bloemDanger)
                }
            }
        }
        .overlay {
            if !hasLoadedOnce && viewModel.entries.isEmpty && viewModel.errorMessage == nil {
                ProgressView()
            } else if let failure = viewModel.loadFailure {
                LoadFailureView(failure: failure) { Task { await reload() } }
            } else if viewModel.entries.isEmpty {
                BloemEmptyState(
                    "No playback history",
                    icon: .history,
                    description: Text(filter.isEmpty
                        ? "This server has no playback history."
                        : "No plays match these filters.")
                )
            }
        }
        .navigationTitle("Playback history")
        .sheet(item: $selected) { entry in
            HistoryDetailSheet(entry: entry, onOpenLogs: onOpenLogs)
        }
        .task { await options.loadUsers(client: client, sessionState: sessionState) }
        // History is read on open, on return to the foreground and on pull to refresh, with no timer. A
        // return refreshes page one under the APPLIED filter; if the user has paged on, the appended pages
        // and their cursor are kept.
        .liveRefresh(client: client, channels: []) {
            if hasLoadedOnce {
                await viewModel.pollRefresh(client: client, sessionState: sessionState)
            } else {
                await reload()
            }
        }
        .onChange(of: filter) { Task { await reload() } }
        .refreshable { await reload() }
    }

    private func reload() async {
        await viewModel.load(filter: filter, client: client, sessionState: sessionState)
        hasLoadedOnce = true
    }
}
