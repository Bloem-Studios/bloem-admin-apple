import SwiftUI

/// One row of the Scheduled tasks list: the name and state, a progress bar while it runs, the last
/// result with its duration, and Next run or Overdue. Status is said in words; no colour carries it.
struct TaskRowView: View {
    let task: AdminTask
    let now: Date

    var body: some View {
        let row = TaskRowPresentation(task: task, now: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.name).bloemText(.titleMedium)
                Spacer(minLength: 8)
                if row.isRunning {
                    // A running task is live: the tally dot.
                    LiveLabel(row.stateText)
                } else {
                    Text(row.stateText)
                        .bloemText(.bodyMedium)
                        .foregroundStyle(.bloemMuted)
                }
            }
            if row.isRunning || task.state == "cancelling" {
                if let progress = row.progress {
                    ProgressView(value: progress)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                }
            }
            Label(row.lastResult, icon: row.lastResultFailed ? .triangleAlert : .history)
                .bloemText(row.lastResultFailed ? .labelMedium : .bodySmall)
                .foregroundStyle(row.lastResultFailed ? Theme.text : Theme.muted)
            if let next = row.nextRun {
                Label(next, icon: row.isOverdue ? .circleAlert : .calendar)
                    .bloemText(row.isOverdue ? .labelMedium : .bodySmall)
                    .foregroundStyle(row.isOverdue ? Theme.text : Theme.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("task-row-\(task.key)")
    }
}

/// One finished run in a task's history: status, start, duration, the error and the failed steps.
struct TaskRunRow: View {
    let run: TaskExecution

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(run.statusText)
                    .bloemText(.titleSmall)
                Spacer(minLength: 8)
                Text(AdminDuration.text(milliseconds: run.durationMs))
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
            if let started = AdminTimestamp.displayText(run.startedAt) {
                Text("Started \(started)")
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
            if let error = run.errorMessage, !error.isEmpty {
                Text(error).bloemText(.bodySmall)
            }
            if !run.failedSteps.isEmpty {
                Text("Failed steps: \(run.failedSteps.map(\.name).joined(separator: ", "))")
                    .bloemText(.bodySmall)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The end of a paged list: Load more, or what went wrong with the next page and a way to try it again.
struct HistoryFooter<Item: Decodable & Identifiable & Sendable>: View where Item.ID == String {
    let pager: HistoryPager<Item>
    let client: APIClient
    let sessionState: ServerScopedSession?
    var identifier = "history-load-more"

    var body: some View {
        if pager.hasMore || pager.moreFailure != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let message = pager.moreFailure {
                    Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                if pager.isLoadingMore {
                    ProgressView()
                } else {
                    Button(pager.moreFailure == nil ? "Load more" : "Try again") {
                        Task { await pager.loadMore(client: client, sessionState: sessionState) }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(identifier)
                }
            }
        }
    }
}

/// Every background job the server has kept: what ran, on what, how it ended. Cursor paged.
struct JobHistoryView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var pager = HistoryPager<AdminJob>.jobHistory()

    var body: some View {
        let now = Date()
        List {
            ForEach(pager.items) { job in
                JobHistoryRow(row: JobRowPresentation(job: job, now: now))
            }
            HistoryFooter(pager: pager, client: client, sessionState: sessionState, identifier: "job-history-load-more")
        }
        .overlay {
            if !pager.hasLoaded {
                ProgressView()
            } else if let failure = pager.loadFailure, pager.items.isEmpty {
                LoadFailureView(failure: failure) { Task { await pager.load(client: client, sessionState: sessionState) } }
            } else if pager.items.isEmpty {
                BloemEmptyState(
                    "No background jobs",
                    icon: .clockCheck,
                    description: Text("Library refreshes, restores and exports appear here after they run")
                )
            }
        }
        .navigationTitle("Job history")
        .navigationBarTitleDisplayMode(.inline)
        .task { await pager.load(client: client, sessionState: sessionState) }
        .refreshable { await pager.load(client: client, sessionState: sessionState) }
        .accessibilityIdentifier("job-history")
    }
}

struct JobHistoryRow: View {
    let row: JobRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title).bloemText(.titleSmall)
                Spacer(minLength: 8)
                Text(row.stateText).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            }
            if let target = row.target {
                Text(target).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if let progress = row.progress {
                ProgressView(value: progress)
            }
            if let progressText = row.progressText {
                Text(progressText).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            Text(row.when).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if let failure = row.failure {
                Text(failure).bloemText(.bodySmall)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
