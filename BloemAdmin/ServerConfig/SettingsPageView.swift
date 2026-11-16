import SwiftUI

/// One named settings page: its sections of typed controls, the tests it offers, and a save bar that
/// writes the page's edited settings in one request. A save that loses a race keeps the edits on screen
/// and says the settings changed on the server.
struct SettingsPageView: View {
    let page: SettingsPage
    let model: ServerSettingsModel
    let client: APIClient
    let sessionState: ServerScopedSession?
    /// A setting to scroll to when the page opens (a search result).
    var focusKey: String?

    @State private var tests: SettingsTestRunners
    @State private var showsDiscardConfirmation = false

    init(page: SettingsPage, model: ServerSettingsModel, client: APIClient, sessionState: ServerScopedSession?, focusKey: String? = nil) {
        self.page = page
        self.model = model
        self.client = client
        self.sessionState = sessionState
        self.focusKey = focusKey
        _tests = State(initialValue: SettingsTestRunners(serverName: model.serverName))
    }

    private var dirtyCount: Int { model.dirtyKeys(in: page.keys).count }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if model.showsConflict { SettingsConflictSection(model: model) }
                if let notice = model.lastSave { SettingsSavedNotice(notice: notice) }
                ForEach(page.sections) { section in
                    Section {
                        ForEach(section.settings) { spec in
                            ServerSettingRow(spec: spec, model: model)
                                .id(spec.key)
                        }
                    } header: {
                        if let title = section.title { Text(title) }
                    } footer: {
                        if let footer = section.footer { Text(footer) }
                    }
                }
                SettingsExtrasView(page: page, model: model, client: client, sessionState: sessionState, tests: tests)
            }
            .onAppear {
                guard let focusKey else { return }
                DispatchQueue.main.async { withAnimation { proxy.scrollTo(focusKey, anchor: .center) } }
            }
        }
        .navigationTitle(page.titleText)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if dirtyCount > 0 || model.isSaving {
                SettingsSaveBar(
                    count: dirtyCount, isSaving: model.isSaving, error: model.saveError,
                    onSave: { Task { _ = await model.save(keys: page.keys, client: client, sessionState: sessionState) } },
                    onDiscard: { showsDiscardConfirmation = true }
                )
            }
        }
        .confirmationDialog("Discard your changes?", isPresented: $showsDiscardConfirmation, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { model.discard(keys: page.keys) }
            Button("Keep editing", role: .cancel) {}
        }
        // Unsaved edits keep the shell still, so a swipe or the menu cannot leave them behind.
        .shellInteractionLocked(model.hasUnsavedEdits || model.isSaving)
        .refreshable { await model.load(client: client, sessionState: sessionState) }
    }
}

/// The bar under a page with edits: how many, Discard, Save, and the reason a save failed.
struct SettingsSaveBar: View {
    let count: Int
    let isSaving: Bool
    let error: String?
    let onSave: () -> Void
    let onDiscard: () -> Void
    /// Replaces the count line ("2 unsaved") where a page has no count of its own.
    var summary: String?
    var canSave = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error {
                Label(error, icon: .triangleAlert)
                    .bloemText(.bodySmall)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.saveError")
            }
            HStack(spacing: 12) {
                Text(summary ?? String(localized: "\(count) unsaved"))
                    .bloemText(.bodyMedium)
                    .accessibilityIdentifier("settings.saveCount")
                Spacer()
                Button("Discard", action: onDiscard)
                    .buttonStyle(.bloemSecondary)
                    .disabled(isSaving)
                    .accessibilityIdentifier("settings.discard")
                Button(action: onSave) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("Save changes")
                    }
                }
                .buttonStyle(.bloemProminent)
                .disabled(isSaving || count == 0 || !canSave)
                .accessibilityIdentifier("settings.save")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.saveBar")
    }
}

/// The settings changed on the server while the person had edits: say so, and offer to keep the edits
/// on top of the server's values or take the server's values for what changed.
struct SettingsConflictSection: View {
    let model: ServerSettingsModel

    var body: some View {
        Section {
            Label(
                model.serverName.map { String(localized: "Settings changed on \($0)") } ?? String(localized: "Settings changed on the server"),
                icon: .triangleAlert
            )
            .bloemText(.titleMedium)
            Text("Your edits are still here. Keep them to save over the server's values, or take the server's values for the settings that changed")
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
            Button("Keep my changes") { model.keepMyChanges() }
                .accessibilityIdentifier("settings.keepMine")
            Button("Use the server's values") { model.useServerValues() }
                .accessibilityIdentifier("settings.useServer")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.conflict")
    }
}

/// What a save did: which settings were saved and which of them wait for a restart.
struct SettingsSavedNotice: View {
    let notice: SettingsSaveNotice

    var body: some View {
        Section {
            Label("Saved", icon: .circleCheck)
                .accessibilityIdentifier("settings.saved")
            if notice.restartRequired {
                let names = notice.restartLabels.isEmpty
                    ? String(localized: "Some of these settings apply after a restart")
                    : String(localized: "Applies after a restart: \(notice.restartLabels.formatted(.list(type: .and)))")
                Label(names, icon: .rotateCw)
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
        }
    }
}
