import SwiftUI

/// Schedule form for one task, driven by `ScheduleEditor`. It reads the schedule when it opens;
/// a save that loses a race keeps the form and offers the current schedule for review.
struct ScheduleEditorSheet: View {
    @State private var editor: ScheduleEditor
    let client: APIClient
    let sessionState: ServerScopedSession?
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss

    init(task: AdminTask, serverName: String? = nil, client: APIClient, sessionState: ServerScopedSession?, onSaved: @escaping () -> Void) {
        _editor = State(initialValue: ScheduleEditor(task: task, serverName: serverName))
        self.client = client
        self.sessionState = sessionState
        self.onSaved = onSaved
    }

    var body: some View {
        NavigationStack {
            Form {
                if editor.snapshot != nil {
                    Section {
                        Toggle("Run on server startup", isOn: $editor.startupEnabled)
                        Toggle("Run on an interval", isOn: $editor.intervalEnabled)
                        LabeledContent("Run every (minutes)") {
                            TextField("Not set", text: $editor.intervalMinutesText)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .disabled(!editor.intervalEnabled)
                        }
                    } footer: {
                        if let validationError = editor.validationError {
                            Text(validationError).foregroundStyle(.bloemDanger)
                        }
                    }
                    timedSection
                }
                if editor.hasConflict {
                    Section {
                        Text(editor.conflictMessage)
                            .foregroundStyle(.bloemDanger)
                        Button("Review current schedule") {
                            Task { await editor.reviewCurrent(client: client, sessionState: sessionState) }
                        }
                        .disabled(editor.isBusy)
                        if let latest = editor.latest {
                            LabeledContent("Current schedule", value: ScheduleEditorSheet.summary(of: latest.triggers))
                            Button("Keep my edit and continue") { editor.adoptCurrent() }
                        }
                    }
                }
                if let message = editor.errorMessage {
                    Section { Text(message).foregroundStyle(.bloemDanger) }
                    if editor.snapshot == nil, !editor.task.manualOnly, !editor.isBusy {
                        Section {
                            Button("Try again") { Task { await editor.open(client: client, sessionState: sessionState) } }
                        }
                    }
                }
            }
            .overlay {
                if editor.isBusy && editor.snapshot == nil { ProgressView() }
            }
            .navigationTitle(editor.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
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

    /// Daily and weekly times, one block each, as the web's trigger form has them.
    @ViewBuilder
    private var timedSection: some View {
        let names = TimedTriggerDraft.weekdayNames()
        Section {
            ForEach($editor.timed) { $draft in
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Repeats", selection: $draft.kind) {
                        Text("Every day").tag(TimedTriggerDraft.Kind.daily)
                        Text("Every week").tag(TimedTriggerDraft.Kind.weekly)
                    }
                    if draft.kind == .weekly {
                        Picker("Day", selection: $draft.weekday) {
                            ForEach(names.indices, id: \.self) { Text(names[$0]).tag($0) }
                        }
                    }
                    DatePicker("Time", selection: timeBinding($draft), displayedComponents: .hourAndMinute)
                    LabeledContent("Longest run (minutes)") {
                        TextField("No limit", text: $draft.maxRuntimeText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                    if let message = draft.validationMessage {
                        Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                    Button("Remove time", role: .destructive) { editor.removeTimed(id: draft.id) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("schedule-timed-row")
            }
            Button("Add daily time") { editor.addTimed(.daily) }
                .accessibilityIdentifier("schedule-add-daily")
            Button("Add weekly time") { editor.addTimed(.weekly) }
                .accessibilityIdentifier("schedule-add-weekly")
        } header: {
            Text("Daily and weekly times")
        } footer: {
            Text("Times follow the server's clock, not this device's")
        }
    }

    private func timeBinding(_ draft: Binding<TimedTriggerDraft>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = draft.wrappedValue.minutes ?? 9 * 60
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                draft.wrappedValue.minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }

    static func summary(of triggers: [TaskTrigger]) -> String {
        triggers.isEmpty ? String(localized: "Not scheduled") : triggers.map(\.summary).joined(separator: ", ")
    }
}
