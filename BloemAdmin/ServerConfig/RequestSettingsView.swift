import SwiftUI

/// The Requests settings page: allow requests, approval, the default limit and window, watchlist
/// requests and 4K, through `GET/PUT /api/v2/admin/request-settings` with `If-Match`.
struct RequestSettingsView: View {
    let client: APIClient
    let sessionState: ServerScopedSession?
    let serverName: String?

    @State private var model: RequestSettingsModel
    @State private var showsDiscardConfirmation = false

    init(client: APIClient, sessionState: ServerScopedSession?, serverName: String? = nil) {
        self.client = client
        self.sessionState = sessionState
        self.serverName = serverName
        _model = State(initialValue: RequestSettingsModel(serverName: serverName))
    }

    var body: some View {
        Group {
            if let failure = model.loadFailure {
                LoadFailureView(failure: failure) { Task { await model.load(client: client, sessionState: sessionState) } }
            } else if let draft = model.draft {
                form(draft)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(SettingsCatalogue.requests.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load(client: client, sessionState: sessionState) }
        .refreshable { await model.load(client: client, sessionState: sessionState) }
        .shellInteractionLocked(model.isDirty || model.isSaving)
    }

    private func form(_ draft: RequestSettings) -> some View {
        Form {
            if model.showsConflict {
                Section {
                    Label(
                        serverName.map { String(localized: "Settings changed on \($0)") } ?? String(localized: "Settings changed on the server"),
                        icon: .triangleAlert
                    )
                    .bloemText(.titleMedium)
                    Text("Your edits are still here. Keep them to save over the server's values, or take the server's values")
                        .bloemText(.bodySmall)
                        .foregroundStyle(.bloemMuted)
                    Button("Keep my changes") { model.keepMyChanges() }
                        .accessibilityIdentifier("settings.keepMine")
                    Button("Use the server's values") { model.useServerValues() }
                        .accessibilityIdentifier("settings.useServer")
                }
                .accessibilityIdentifier("settings.conflict")
            }
            if model.didSave {
                Section { Label("Saved", icon: .circleCheck).accessibilityIdentifier("settings.saved") }
            }
            if let refreshError = model.refreshError {
                Section { Label(refreshError, icon: .triangleAlert).bloemText(.bodySmall) }
            }
            Section {
                Toggle(isOn: binding(\.requestsEnabled)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Allow requests")
                        Text("People can ask for movies and series the server does not have")
                            .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
                .accessibilityIdentifier("requestSettings.allow")
                Picker(selection: binding(\.globalAutoApprovalEnabled)) {
                    Text("An admin approves").tag(false)
                    Text("Approve automatically").tag(true)
                } label: {
                    Text("Approval")
                }
                .accessibilityIdentifier("requestSettings.approval")
            } header: {
                Text("General")
            } footer: {
                Text("The server-wide defaults. Access groups and accounts can override them")
            }
            Section {
                IntegerField(
                    title: "Request limit", unit: "requests", value: binding(\.globalMaxRequests),
                    problem: model.limitProblem, identifier: "requestSettings.limit",
                    help: "How many titles one account can request in the window below. Declined and failed requests don't count. At 0, only accounts with a group or account limit of their own can request"
                )
                IntegerField(
                    title: "Limit window", unit: "days", value: binding(\.globalWindowDays),
                    problem: model.windowProblem, identifier: "requestSettings.window", help: nil
                )
            } header: {
                Text("Limits")
            }
            Section {
                if draft.watchlistRequests != nil {
                    Toggle(isOn: Binding(
                        get: { model.draft?.watchlistRequests ?? false },
                        set: { value in model.edit { $0.watchlistRequests = value } }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Request titles added to a watchlist")
                            Text("When someone adds a title the library doesn't have to their watchlist, it is requested for them. Each profile can turn this off for itself")
                                .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                    }
                    .accessibilityIdentifier("requestSettings.watchlist")
                }
                Toggle(isOn: binding(\.forceDualQuality)) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Also request a 4K version of every title")
                        Text("Normally a 4K version is requested only for people whose playback limit allows 4K, and only when a server takes 4K. With this on, every request also asks for 4K")
                            .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
                .accessibilityIdentifier("requestSettings.4k")
            } header: {
                Text("Titles")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isDirty || model.isSaving {
                SettingsSaveBar(
                    count: 1, isSaving: model.isSaving, error: model.saveError,
                    onSave: { Task { _ = await model.save(client: client, sessionState: sessionState) } },
                    onDiscard: { showsDiscardConfirmation = true },
                    summary: String(localized: "Unsaved changes"), canSave: model.canSave
                )
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { model.discard() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<RequestSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.draft![keyPath: keyPath] },
            set: { value in model.edit { $0[keyPath: keyPath] = value } }
        )
    }
}

private struct IntegerField: View {
    let title: LocalizedStringKey
    let unit: LocalizedStringKey
    @Binding var value: Int
    let problem: String?
    let identifier: String
    let help: LocalizedStringKey?
    @State private var text = ""
    @State private var didStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 8) {
                    TextField("Value", text: $text)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 60)
                        .accessibilityIdentifier(identifier)
                    Text(unit).foregroundStyle(.bloemMuted)
                }
            } label: {
                Text(title)
            }
            if let help {
                Text(help).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if let problem {
                Label(problem, icon: .triangleAlert).bloemText(.bodySmall)
            } else if Int(text.trimmingCharacters(in: .whitespaces)) == nil, !text.isEmpty {
                Label("Use a whole number", icon: .triangleAlert).bloemText(.bodySmall)
            }
        }
        .onAppear {
            guard !didStart else { return }
            didStart = true
            text = String(value)
        }
        .onChange(of: text) { _, newText in
            if let parsed = Int(newText.trimmingCharacters(in: .whitespaces)), parsed != value { value = parsed }
        }
        .onChange(of: value) { _, newValue in
            if Int(text.trimmingCharacters(in: .whitespaces)) != newValue { text = String(newValue) }
        }
    }
}
