import SwiftUI

/// Operational/application log viewer (`GET /api/v2/admin/logs/app`), a DIFFERENT endpoint from
/// Audit's request trail. A historical log paged with "Load more": one load on appear, one on every
/// filter change, and pull to refresh back to page one.
///
/// Filters: severity, message text, component, request ID and playback session. Opened from a stream
/// or a Playback history row the page starts on that playback session (and for FFmpeg logs on the
/// `ffmpeg` component), with the session's summary on top. A tap on a row opens its details.
struct LogsListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @Environment(ShellRouter.self) private var router
    @State private var viewModel = LogsViewModel()
    @State private var levelFilter: LogLevelFilter = .all
    @State private var searchText = ""
    @State private var component = ""
    @State private var requestID = ""
    @State private var playbackSessionID = ""
    @State private var selected: OperationalLogEntry?
    @State private var summary: PlaybackSessionSummary?
    @State private var summaryFailure: String?
    /// Debounces typed filters: cancelled and replaced on every change so only the last change in a
    /// burst reloads. Held in `@State` rather than `.task(id:)` so it can sit beside the initial load.
    @State private var debounceTask: Task<Void, Never>?
    /// True once the first `load` call has completed — gates the initial spinner so it doesn't
    /// reappear on pull-to-refresh or a filter change.
    @State private var hasLoadedOnce = false
    @State private var tookFocus = false
    /// The filter page one was last loaded with, so a debounced change that lands on it reloads nothing.
    @State private var lastLoaded: LogFilter?
    @State private var showingLogSettings = false

    /// The filter the fields describe now.
    private var currentFilter: LogFilter {
        LogFilter(level: levelFilter.queryValue, q: searchText, component: component, requestID: requestID, playbackSessionID: playbackSessionID)
    }

    private var sessionFocus: String { playbackSessionID.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        List {
            Section {
                Picker("Level", selection: $levelFilter) {
                    ForEach(LogLevelFilter.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("logs-level")
                TextField("Search messages", text: $searchText)
                    .accessibilityIdentifier("logs-search")
                    .accessibilityHint("Reloads the log filtered to messages matching this text")
                HStack {
                    TextField("Component", text: $component)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("logs-component")
                    Menu {
                        ForEach(LogComponentSuggestions.all, id: \.self) { name in
                            Button(name) { component = name }
                        }
                    } label: {
                        Label("Choose component", icon: .chevronsUpDown).labelStyle(.iconOnly)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityIdentifier("logs-component-menu")
                }
                TextField("Request ID", text: $requestID)
                    .bloemText(.bodyLarge)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("logs-request-id")
                TextField("Playback session", text: $playbackSessionID)
                    .bloemText(.bodyLarge)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("logs-playback-session")
            }
            if !sessionFocus.isEmpty {
                Section {
                    PlaybackSessionSummaryView(
                        playbackSessionID: sessionFocus,
                        summary: summary,
                        failureMessage: summaryFailure,
                        ffmpegOnly: component.trimmingCharacters(in: .whitespacesAndNewlines) == "ffmpeg",
                        onToggleFFmpeg: { component = component.trimmingCharacters(in: .whitespacesAndNewlines) == "ffmpeg" ? "" : "ffmpeg" },
                        onClearSession: { playbackSessionID = ""; component = "" }
                    )
                }
            }
            Section {
                ForEach(viewModel.entries) { entry in
                    Button { selected = entry } label: { LogEntryRow(entry: entry) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("log-row-\(entry.id)")
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
            // Below the log, so the filters, the session summary and the first lines stay on one screen.
            Section {
                Button { showingLogSettings = true } label: {
                    Label("Log level and retention", icon: .slidersHorizontal)
                }
                .accessibilityIdentifier("logs.settings")
            }
        }
        .sheet(isPresented: $showingLogSettings) {
            SettingsPageSheet(page: SettingsCatalogue.logging, client: client, sessionState: sessionState)
        }
        .overlay {
            if !hasLoadedOnce && viewModel.entries.isEmpty && viewModel.errorMessage == nil {
                ProgressView()
            } else if let failure = viewModel.loadFailure {
                LoadFailureView(failure: failure) { Task { await reload(force: true) } }
            } else if viewModel.entries.isEmpty {
                BloemEmptyState(
                    "No log entries",
                    icon: .fileSearch,
                    description: currentFilter.isEmpty
                        ? Text("This server has no operational log entries")
                        : Text("No log entries match the selected filters")
                )
            }
        }
        .navigationTitle("Logs")
        .sheet(item: $selected) { entry in
            LogDetailSheet(entry: entry) { session in
                playbackSessionID = session
            }
        }
        .task {
            if !tookFocus {
                tookFocus = true
                if let focus = router.takeLogsFocus() {
                    let filter = LogFilter(focus: focus)
                    playbackSessionID = filter.playbackSessionID
                    component = filter.component
                }
            }
            await reload()
        }
        .task(id: sessionFocus) { await loadSummary() }
        .onChange(of: currentFilter) {
            debounceTask?.cancel()
            debounceTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                await reload()
            }
        }
        .refreshable { await reload(force: true) }
    }

    /// Loads page one for the fields as they are now. A change that lands on the filter already
    /// loaded is skipped unless `force` (pull to refresh, Try again).
    private func reload(force: Bool = false) async {
        let filter = currentFilter
        if !force, filter == lastLoaded { return }
        lastLoaded = filter
        await viewModel.load(filter: filter, client: client, sessionState: sessionState)
        hasLoadedOnce = true
    }

    private func loadSummary() async {
        let session = sessionFocus
        summary = nil
        summaryFailure = nil
        guard !session.isEmpty else { return }
        do {
            let loaded = try await PlaybackSessionSummary.load(playbackSessionID: session, client: client)
            guard session == sessionFocus else { return }
            summary = loaded
        } catch is CancellationError {
            return
        } catch {
            guard session == sessionFocus else { return }
            summaryFailure = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "Could not load the session summary."))
        }
    }
}

/// The components the web's log filter suggests (adminLogsFilters.ts). The server emits more; any
/// name can be typed.
enum LogComponentSuggestions {
    static let all = [
        "access", "activitylog", "adminjob", "ai", "api", "app", "audiobooks", "auth", "autoscan", "catalog",
        "chapterthumbs", "diagnostics", "downloads", "ebooks", "ffmpeg", "historyimport", "jellycompat",
        "libraryingest", "manga", "metadata", "nodeconfig", "nodepool", "noderecipe", "nodesessions",
        "notifications", "opslog", "playback", "plugins", "policy", "proxy", "ratelimit", "recommendations",
        "requests", "scanner", "scanqueue", "sections", "settings", "taskmanager", "telemetry", "transcodenode",
        "watchlist", "watchsync", "webhook_sync", "webhooksync", "worker",
    ]
}

private struct LogEntryRow: View {
    let entry: OperationalLogEntry
    /// Failures read as failures and warnings as warnings; every other level is quiet text.
    private var levelTone: StatusLabel.Tone {
        switch entry.level.lowercased() {
        case "error": .failure
        case "warn", "warning": .warning
        default: .normal
        }
    }

    private var levelName: String {
        switch entry.level.lowercased() {
        case "error": String(localized: "Error")
        case "warn", "warning": String(localized: "Warning")
        case "debug": String(localized: "Debug")
        case "info": String(localized: "Info")
        default: Vocabulary.sentenceCase(entry.level)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                StatusLabel(levelName, tone: levelTone)
                Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    .bloemText(.bodyMedium)
                    .foregroundStyle(.bloemMuted)
            }
            Text(entry.message).bloemText(.bodyLarge)
            Text(detail).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "scanner · User 5 · node-a": where it came from and who it was for.
    private var detail: String {
        var parts = [entry.component]
        if let userID = entry.userID { parts.append(String(localized: "User \(userID)")) }
        if let nodeID = entry.nodeID { parts.append(nodeID) }
        return parts.joined(separator: " · ")
    }
}
