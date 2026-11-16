import SwiftUI

/// What moves the Backups page: the backup task (the `tasks` channel) and its job.
enum BackupsLive {
    static let channels: Set<LiveChannel> = [.tasks, .jobs]
}

/// The Backups page of one server.
struct BackupsView: View {
    let client: APIClient
    @State private var model = SectionModel<BackupsPage>.backups()

    var body: some View {
        List {
            ActionErrorRow(message: model.actionErrorMessage)
            if let page = model.payload {
                BackupsRows(page: page, model: model, client: client)
            }
        }
        .navigationTitle("Backups")
        .sectionLoading(model, client: client, channels: BackupsLive.channels)
        .accessibilityIdentifier("backups-page")
    }
}

/// All servers: one section of backups per server.
struct AggregateBackupsView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    let resolveClient: ServerClientResolver

    var body: some View {
        AggregateSectionsView(
            servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient,
            channels: BackupsLive.channels, emptyText: "No backup information", isEmpty: { _ in false },
            makeModel: {
                AggregateSectionsModel(
                    loadFallback: String(localized: "Could not load backups."),
                    make: { SectionModel<BackupsPage>.backups(serverName: $0) },
                    fetch: { try await $0.backupsPage() }
                )
            }
        ) { _, section, page, client in
            BackupsRows(page: page, model: section, client: client)
        }
        .navigationTitle("Backups · All servers")
    }
}

/// The rows of one server's backups: status, Back up now, the schedule, and the saved backups.
struct BackupsRows: View {
    let page: BackupsPage
    let model: SectionModel<BackupsPage>
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var showingSchedule = false

    var body: some View {
        content.onChange(of: page) { _, new in
            AdminJobActivityTracker.shared.backupRead(serverID: sessionState?.serverID, overview: new.overview)
        }
    }

    @ViewBuilder
    private var content: some View {
        let view = BackupsPresentation(overview: page.overview, taskNextRunAt: page.taskNextRunAt, now: Date())
        let busy = model.busyIDs.contains("backup-now")
        Group {
            VStack(alignment: .leading, spacing: 8) {
                Text(view.lastSuccess).bloemText(.titleMedium)
                Text(view.nextRun).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                if let active = view.activeText {
                    Text(active).bloemText(.bodyMedium)
                    if let progress = view.activeProgress {
                        ProgressView(value: progress)
                    }
                    if let message = view.activeMessage {
                        Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
                if let lastRun = view.lastRun {
                    Label(lastRun, icon: view.lastRunFailed ? .triangleAlert : .info)
                        .bloemText(view.lastRunFailed ? .labelMedium : .bodySmall)
                }
                ForEach(Array(view.warnings.enumerated()), id: \.offset) { _, warning in
                    Label(warning.text, icon: warning.isInformation ? .info : .triangleAlert)
                        .bloemText(.bodySmall)
                        .foregroundStyle(warning.isInformation ? Theme.muted : Theme.text)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("backups-status")

            VStack(alignment: .leading, spacing: 8) {
                Button("Back up now") {
                    Task { await model.backUpNow(client: client, sessionState: sessionState) }
                }
                .buttonStyle(.bloemSecondary)
                .disabled(view.backUpNowBlocker != nil || busy)
                .accessibilityIdentifier("backup-now")
                if let blocker = view.backUpNowBlocker {
                    Text(blocker).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Nightly backups", value: page.overview.enabled ? String(localized: "On") : String(localized: "Off"))
                if let time = page.taskTimeOfDay {
                    LabeledContent("Backup time", value: time)
                }
                LabeledContent("Copies kept", value: String(page.overview.keep))
                Button("Edit schedule") { showingSchedule = true }
                    .accessibilityIdentifier("backup-edit-schedule")
                Text("Times follow the server's clock, not this device's")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            // A presentation belongs on one row; on the group it would attach to every row.
            .sheet(isPresented: $showingSchedule) {
                BackupSettingsSheet(client: client, sessionState: sessionState, serverName: model.serverName) {
                    Task { await model.load(client: client, sessionState: sessionState) }
                }
            }

            if view.rows.isEmpty {
                Text("No saved backups").foregroundStyle(.bloemMuted)
            } else {
                ForEach(view.rows) { row in
                    BackupRow(row: row, busy: model.busyIDs.contains(row.id)) {
                        Task { await model.deleteBackup(id: row.id, client: client, sessionState: sessionState) }
                    }
                }
            }
            Text("To restore a backup, use the web admin")
                .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        }
    }
}

struct BackupRow: View {
    let row: BackupRowPresentation
    let busy: Bool
    let onConfirmedDelete: () -> Void
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(row.kindText) backup").bloemText(.titleSmall)
                Spacer(minLength: 8)
                StatusLabel(row.statusText, tone: row.statusTone)
            }
            Text("\(row.createdText), \(row.sizeText)")
                .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if row.canDelete {
                Button("Delete", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.bloemQuiet)
                    .frame(minHeight: 44)
                    .disabled(busy)
                    .accessibilityIdentifier("backup-delete-\(row.id)")
            }
        }
        .accessibilityElement(children: .contain)
        .confirmationDialog("Delete this backup?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete backup", role: .destructive, action: onConfirmedDelete)
            Button("Keep backup", role: .cancel) {}
        } message: {
            Text("\(row.kindText) backup, \(row.createdText.lowercased()), \(row.sizeText). It cannot be restored after it is deleted")
        }
    }
}

/// Nightly backups on or off, the time and the copies kept, saved through the settings write.
struct BackupSettingsSheet: View {
    @State private var editor = BackupSettingsEditor()
    let client: APIClient
    let sessionState: ServerScopedSession?
    let serverName: String?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if editor.hasValues {
                    Section {
                        Toggle("Nightly backups", isOn: $editor.isEnabled)
                        DatePicker("Backup time", selection: timeBinding, displayedComponents: .hourAndMinute)
                        Stepper(value: $editor.keep, in: BackupSettingsEditor.keepRange) {
                            LabeledContent("Copies kept", value: String(editor.keep))
                        }
                    } footer: {
                        Text("Times follow the server's clock, not this device's")
                    }
                }
                if let message = editor.errorMessage {
                    Section {
                        Text(ErrorMessage.named(message, serverName: serverName))
                        if editor.hasConflict || !editor.hasValues {
                            Button(editor.hasConflict ? "Reload current values" : "Try again") {
                                Task { await editor.open(client: client, sessionState: sessionState) }
                            }
                            .disabled(editor.isBusy)
                        }
                    }
                }
            }
            .overlay {
                if editor.isBusy && !editor.hasValues { ProgressView() }
            }
            .navigationTitle("Backup schedule")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") {
                        Task {
                            if await editor.save(client: client, sessionState: sessionState) {
                                onSaved()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!editor.canSave)
                }
            }
        }
        .task { await editor.open(client: client, sessionState: sessionState) }
        .interactiveDismissDisabled(editor.isBusy)
    }

    private var timeBinding: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(bySettingHour: editor.minutes / 60, minute: editor.minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                editor.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
