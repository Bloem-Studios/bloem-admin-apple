import SwiftUI

/// Where a push inside Settings goes.
enum SettingsRoute: Hashable {
    /// A named page, optionally scrolled to one setting (a search result).
    case page(String, focus: String?)
    /// The stored settings the catalogue does not name.
    case other
}

/// The page a catalogue entry opens, by how it gets its content.
struct SettingsPageContent: View {
    let page: SettingsPage
    let model: ServerSettingsModel
    let client: APIClient
    let sessionState: ServerScopedSession?
    var focusKey: String?

    var body: some View {
        switch page.kind {
        case .keys:
            SettingsPageView(page: page, model: model, client: client, sessionState: sessionState, focusKey: focusKey)
        case .requests:
            RequestSettingsView(client: client, sessionState: sessionState, serverName: model.serverName)
        case .networkAccess:
            NetworkAccessView(client: client, sessionState: sessionState, serverName: model.serverName)
        }
    }
}

/// Settings: the server's uptime and restart state, then a list of named pages (General, Network
/// access, Sign-in, Playback, Logging, Email, Notifications, Downloads, Requests), search that finds
/// single settings, and Other settings for any stored key the pages do not name.
struct ServerConfigView: View {
    let client: APIClient
    /// Set in All servers mode so errors and the restart question name the server.
    let serverName: String?
    private let explicitSession: ServerScopedSession?
    @Environment(\.adminSessionState) private var environmentSession
    @State private var model: ServerSettingsModel
    @State private var query = ""
    @State private var showingRestartConfirm = false

    init(client: APIClient, serverName: String? = nil, sessionState: ServerScopedSession? = nil) {
        self.client = client
        self.serverName = serverName
        self.explicitSession = sessionState
        _model = State(initialValue: ServerSettingsModel(serverName: serverName))
    }

    private var sessionState: ServerScopedSession? { explicitSession ?? environmentSession }

    var body: some View {
        List {
            if model.hasLoaded {
                if model.hasUnsavedEdits { unsavedSection }
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    statusSection
                    pagesSection
                    otherSection
                } else {
                    searchSection
                }
            }
        }
        .overlay {
            if let failure = model.loadFailure, !model.hasLoaded {
                LoadFailureView(failure: failure) { Task { await model.load(client: client, sessionState: sessionState) } }
            } else if !model.hasLoaded {
                ProgressView()
            }
        }
        .navigationTitle(serverName ?? String(localized: "Server settings"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search settings"))
        .navigationDestination(for: SettingsRoute.self) { route in
            switch route {
            case .page(let id, let focus):
                if let page = SettingsCatalogue.page(id: id) {
                    SettingsPageContent(page: page, model: model, client: client, sessionState: sessionState, focusKey: focus)
                }
            case .other:
                OtherSettingsView(model: model, client: client, sessionState: sessionState)
            }
        }
        // The page reads when it opens, on each return to the foreground and on pull to refresh. A restart or
        // save started here reads the status line itself (`refreshStatus`) when it finishes.
        .liveRefresh(client: client, channels: []) {
            await model.load(client: client, sessionState: sessionState)
        }
        .refreshable { await model.load(client: client, sessionState: sessionState) }
        .sensoryFeedback(trigger: model.restartNotice) { _, newValue in newValue != nil ? .success : nil }
        .shellInteractionLocked(model.hasUnsavedEdits || model.isSaving || model.isRestarting)
        .confirmationDialog(
            serverName.map { String(localized: "Restart \($0)?") } ?? String(localized: "Restart this server?"),
            isPresented: $showingRestartConfirm, titleVisibility: .visible
        ) {
            Button("Restart", role: .destructive) {
                Task { await model.restartServer(client: client, sessionState: sessionState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(restartQuestion)
        }
    }

    private var restartQuestion: String {
        guard let status = model.status, status.restartRequired else { return RestartStatus.confirmationMessage }
        let labels = RestartStatus.reasonLabels(for: status)
        guard !labels.isEmpty else { return RestartStatus.confirmationMessage }
        let applying = String(localized: "Applies: \(labels.formatted(.list(type: .and))). ")
        return applying + RestartStatus.confirmationMessage
    }

    // MARK: Sections

    private var statusSection: some View {
        Section {
            if let status = model.status {
                LabeledContent("Uptime") {
                    Text(RestartStatus.uptime(for: status))
                }
                .accessibilityIdentifier("settings.uptime")
                LabeledContent("Restart") {
                    Text(RestartStatus.summary(for: status))
                        .multilineTextAlignment(.trailing)
                }
                .accessibilityIdentifier("settings.restartStatus")
                Button("Restart server", role: .destructive) { showingRestartConfirm = true }
                    .disabled(model.isRestarting || status.restartRequested)
                    .accessibilityIdentifier("settings.restart")
            }
            if let notice = model.restartNotice {
                Text(notice).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("settings.restartNotice")
            }
            if let error = model.restartError {
                Label(error, icon: .triangleAlert).bloemText(.bodySmall)
                    .accessibilityIdentifier("settings.restartError")
            }
            if let refreshError = model.refreshError {
                Label(refreshError, icon: .triangleAlert).bloemText(.bodySmall)
            }
        } header: {
            Text("Server")
        } footer: {
            if let status = model.status, status.restartRequired, let since = status.restartRequiredDate {
                Text("Waiting since \(since.formatted(date: .abbreviated, time: .shortened))")
            }
        }
    }

    private var pagesSection: some View {
        Section {
            ForEach(SettingsCatalogue.pages) { page in
                NavigationLink(value: SettingsRoute.page(page.id, focus: nil)) {
                    SettingsPageRow(page: page)
                }
                .accessibilityIdentifier("settings.page.\(page.id)")
            }
        } header: {
            Text("Pages")
        }
    }

    private var otherSection: some View {
        Section {
            NavigationLink(value: SettingsRoute.other) {
                LabeledContent {
                    Text("\(model.otherKeys.count)")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Other settings")
                        Text("Stored settings that have no page yet")
                            .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
            }
            .accessibilityIdentifier("settings.other")
        }
    }

    private var unsavedSection: some View {
        Section {
            Label("You have unsaved changes", icon: .pencil)
            Button("Discard all changes", role: .destructive) { model.discard(keys: Array(model.drafts.keys)) }
                .accessibilityIdentifier("settings.discardAll")
        } footer: {
            Text("Open the page that shows them to save")
        }
    }

    @ViewBuilder
    private var searchSection: some View {
        let results = SettingsSearch.results(for: query, otherKeys: model.otherKeys)
        if results.isEmpty {
            BloemEmptyState.search(text: query)
        } else {
            Section {
                ForEach(results) { result in
                    NavigationLink(value: route(for: result)) {
                        SettingsSearchRow(result: result)
                    }
                    .accessibilityIdentifier("settings.result.\(result.id)")
                }
            }
        }
    }

    private func route(for result: SettingsSearchResult) -> SettingsRoute {
        switch result {
        case .page(let page): .page(page.id, focus: nil)
        case .setting(let page, let spec): .page(page.id, focus: spec.key)
        case .other: .other
        }
    }
}

private struct SettingsPageRow: View {
    let page: SettingsPage

    var body: some View {
        HStack(spacing: 12) {
            IconImage(page.icon, size: .row)
                .frame(width: 24)
                .foregroundStyle(Theme.muted)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(page.title)
                Text(page.summary)
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct SettingsSearchRow: View {
    let result: SettingsSearchResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch result {
            case .page(let page):
                Text(page.title)
                Text("Page").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            case .setting(let page, let spec):
                Text(spec.label)
                Text(page.title).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            case .other(let key):
                Text(ServerStatus.humanize(key))
                Text(key).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        }
    }
}
