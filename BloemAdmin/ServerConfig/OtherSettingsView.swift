import SwiftUI

/// Every stored setting the catalogue does not name, each opening the one-setting editor. Nothing the
/// server holds is out of reach, even before it has a page.
struct OtherSettingsView: View {
    let model: ServerSettingsModel
    let client: APIClient
    let sessionState: ServerScopedSession?

    @State private var query = ""
    @State private var editing: EditingKey?
    @State private var notice: String?

    private struct EditingKey: Identifiable {
        let key: String
        var id: String { key }
    }

    private var keys: [String] {
        let all = model.otherKeys
        let tokens = PageSearch.tokens(query)
        guard !tokens.isEmpty else { return all }
        return all.filter { key in
            let text = PageSearch.normalize(key + " " + model.value(for: key))
            return tokens.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        List {
            if let notice {
                Section { Text(notice).bloemText(.bodySmall).foregroundStyle(.bloemMuted).accessibilityIdentifier("settings.other.notice") }
            }
            Section {
                ForEach(keys, id: \.self) { key in
                    Button { editing = EditingKey(key: key) } label: {
                        LabeledContent {
                            Text(model.value(for: key))
                                .foregroundStyle(.bloemMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(ServerStatus.humanize(key)).foregroundStyle(.primary)
                                Text(key).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("settings.other.\(key)")
                }
            } footer: {
                Text("These settings have no page in the app yet. Some only take effect after the server restarts")
            }
        }
        .overlay {
            if model.otherKeys.isEmpty {
                BloemEmptyState("No other settings", icon: .slidersHorizontal, description: Text("Every stored setting has a page"))
            } else if keys.isEmpty {
                BloemEmptyState.search(text: query)
            }
        }
        .navigationTitle("Other settings")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search by key or value"))
        .sheet(item: $editing) { editing in
            SettingEditorSheet(key: editing.key, serverName: model.serverName, client: client, sessionState: sessionState) { receipt in
                let name = ServerStatus.humanize(receipt.key)
                notice = receipt.restartRequired
                    ? String(localized: "Saved \(name). It applies after a restart")
                    : String(localized: "Saved \(name)")
                Task { await model.load(client: client, sessionState: sessionState) }
            }
        }
    }
}

/// One settings page in a sheet, for a link from another page (the Logs page links to Logging). It owns
/// its own read of the settings and offers Done.
struct SettingsPageSheet: View {
    let page: SettingsPage
    let client: APIClient
    let sessionState: ServerScopedSession?
    @State private var model = ServerSettingsModel()
    @State private var showsDiscardConfirmation = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let failure = model.loadFailure, !model.hasLoaded {
                    LoadFailureView(failure: failure) { Task { await model.load(client: client, sessionState: sessionState) } }
                } else if model.hasLoaded {
                    SettingsPageContent(page: page, model: model, client: client, sessionState: sessionState)
                } else {
                    ProgressView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        if model.hasUnsavedEdits { showsDiscardConfirmation = true } else { dismiss() }
                    }
                    .accessibilityIdentifier("settings.sheet.done")
                }
            }
            .confirmationDialog("Discard your changes?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
        }
        .task { await model.load(client: client, sessionState: sessionState) }
        .interactiveDismissDisabled(model.hasUnsavedEdits)
    }
}
