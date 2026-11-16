import SwiftUI

/// One scheduled task: what it does, where it stands, Run and Cancel, its schedule in words with the
/// editor, and its recent runs. Run is offered only while the task is idle; Cancel asks first.
struct JobDetailView: View {
    let task: AdminTask
    let client: APIClient
    let viewModel: JobsViewModel
    var refreshAfterMutation: (@MainActor () async -> Void)? = nil
    @Environment(\.adminSessionState) private var sessionState

    @State private var mutationGate = PrivilegedMutationGate()
    @State private var showingCancelConfirm = false
    @State private var showingScheduleEditor = false
    @State private var history: HistoryPager<TaskExecution>

    init(
        task: AdminTask, client: APIClient, viewModel: JobsViewModel,
        refreshAfterMutation: (@MainActor () async -> Void)? = nil
    ) {
        self.task = task
        self.client = client
        self.viewModel = viewModel
        self.refreshAfterMutation = refreshAfterMutation
        _history = State(initialValue: HistoryPager<TaskExecution>.taskHistory(key: task.key))
    }

    /// Reflects live updates from `viewModel.tasks` after a successful
    /// action/reload, falling back to the task this view was pushed with.
    private var currentTask: AdminTask {
        viewModel.tasks.first { $0.id == task.id } ?? task
    }

    var body: some View {
        let row = TaskRowPresentation(task: currentTask, now: Date())
        Form {
            Section {
                if !currentTask.description.isEmpty {
                    Text(currentTask.description)
                }
                LabeledContent("Category", value: currentTask.category.capitalized)
            }
            Section("Status") {
                LabeledContent("State", value: row.stateText)
                if currentTask.state != "idle" {
                    if let progress = row.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if let message = currentTask.progressMessage, !message.isEmpty {
                    LabeledContent("Progress", value: message)
                }
                LabeledContent("Last run", value: row.lastResult)
                if let next = row.nextRun {
                    LabeledContent("Next run", value: next)
                }
            }
            Section {
                Button("Run now") {
                    Task { await runNow() }
                }
                .disabled(!row.canRun || mutationGate.isActive)
                .accessibilityIdentifier("task-run")
                if row.canCancel {
                    Button("Cancel run", role: .destructive) { showingCancelConfirm = true }
                        .disabled(mutationGate.isActive)
                        .accessibilityIdentifier("task-cancel")
                }
            } header: {
                Text("Actions")
            } footer: {
                // Action failures must be visible here, not just tracked in
                // viewModel state — this is where Run/Cancel are triggered,
                // and load()'s success/failure overlay lives on the list
                // screen, not this one.
                if let message = viewModel.actionErrorMessage {
                    Text(message)
                        .foregroundStyle(.bloemDanger)
                } else if !row.canRun {
                    Text("Run is available when the task is idle")
                }
            }
            scheduleSection
            historySection
        }
        .navigationTitle(currentTask.name)
        .sheet(isPresented: $showingScheduleEditor) {
            ScheduleEditorSheet(
                task: currentTask,
                serverName: viewModel.serverName,
                client: client,
                sessionState: sessionState
            ) {
                Task { await refreshList() }
            }
        }
        .confirmationDialog(
            "Cancel \(currentTask.name)? The run may have already changed server data",
            isPresented: $showingCancelConfirm,
            titleVisibility: .visible
        ) {
            Button("Cancel run", role: .destructive) {
                Task { await cancelJob() }
            }
            .disabled(mutationGate.isActive)
            Button("Keep running", role: .cancel) {}
        }
        .task { await history.load(client: client, sessionState: sessionState) }
        // A run that just ended has a new line in the history.
        .onChange(of: currentTask.state) { old, new in
            if old != "idle", new == "idle" {
                Task { await history.load(client: client, sessionState: sessionState) }
            }
        }
        .refreshable {
            await refreshList()
            await history.load(client: client, sessionState: sessionState)
        }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        Section {
            LabeledContent("Runs", value: TaskTrigger.words(for: currentTask.triggers))
                .accessibilityIdentifier("task-schedule-words")
            if currentTask.followsBackupSetting {
                Text("The backup time is set on the Backups page")
                    .foregroundStyle(.bloemMuted)
            } else if currentTask.manualOnly {
                Text("This task only runs when you start it")
                    .foregroundStyle(.bloemMuted)
            } else {
                Button("Edit schedule") { showingScheduleEditor = true }
                    .disabled(mutationGate.isActive)
                    .accessibilityIdentifier("task-edit-schedule")
            }
        } header: {
            Text("Schedule")
        }
    }

    @ViewBuilder
    private var historySection: some View {
        Section {
            if !history.hasLoaded {
                ProgressView()
            } else if let failure = history.loadFailure, history.items.isEmpty {
                Text(failure.message).foregroundStyle(.bloemMuted)
                Button("Try again") { Task { await history.load(client: client, sessionState: sessionState) } }
                    .frame(minHeight: 44)
            } else if history.items.isEmpty {
                Text("This task has not run yet").foregroundStyle(.bloemMuted)
            } else {
                ForEach(history.items) { run in
                    TaskRunRow(run: run)
                }
                HistoryFooter(pager: history, client: client, sessionState: sessionState, identifier: "task-history-load-more")
            }
        } header: {
            Text("Recent runs")
        }
    }

    private func refreshList() async {
        if let refreshAfterMutation {
            await refreshAfterMutation()
        } else {
            await viewModel.load(client: client, sessionState: sessionState)
        }
    }

    private func runNow() async {
        guard mutationGate.begin() else { return }
        defer { mutationGate.end() }
        await viewModel.run(currentTask, client: client, sessionState: sessionState)
        if viewModel.actionErrorMessage == nil {
            await refreshList()
        }
    }

    private func cancelJob() async {
        guard mutationGate.begin() else { return }
        defer { mutationGate.end() }
        await viewModel.cancel(currentTask, client: client, sessionState: sessionState)
        if viewModel.actionErrorMessage == nil {
            await refreshList()
        }
    }
}
