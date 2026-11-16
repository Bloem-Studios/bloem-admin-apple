import SwiftUI

/// The libraries of one server with their scan and refresh feedback, then the recent scans. A single server's page
/// shows one; All servers shows one per server, each acting on its own server through `client`.
struct LibrariesSectionView: View {
    let viewModel: LibrariesViewModel
    let client: APIClient
    let sessionState: ServerScopedSession?

    @State private var pendingStop: AdminLibrary?
    @State private var pendingRefreshAll: AdminLibrary?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            messages
            if viewModel.libraries.isEmpty {
                EmptyLine(text: String(localized: "No libraries configured"))
                    .accessibilityIdentifier("libraries-empty")
            }
            ForEach(viewModel.libraries) { library in
                LibraryCard(
                    library: library, viewModel: viewModel,
                    onScan: { Task { await viewModel.scan(library, client: client, sessionState: sessionState) } },
                    onStop: { pendingStop = library },
                    onCheckMount: { Task { await viewModel.checkMount(library, client: client, sessionState: sessionState) } },
                    onRefreshMissing: {
                        Task { await viewModel.refreshMetadata(library, mode: .missingOnly, client: client, sessionState: sessionState) }
                    },
                    onRefreshAll: { pendingRefreshAll = library },
                    onCancelRefresh: { job in
                        Task { await viewModel.cancelRefresh(job, library: library, client: client, sessionState: sessionState) }
                    }
                )
                // The id a link to this library scrolls to.
                .id(library.id)
            }
            if !viewModel.libraries.isEmpty || viewModel.scanResultsError != nil {
                RecentScansCard(viewModel: viewModel)
            }
        }
        .confirmationDialog(
            pendingStop.map { String(localized: "Stop scans of \($0.name)?") } ?? "",
            isPresented: Binding(get: { pendingStop != nil }, set: { if !$0 { pendingStop = nil } }),
            titleVisibility: .visible,
            presenting: pendingStop
        ) { library in
            Button("Stop scans", role: .destructive) {
                Task { await viewModel.stopScans(library, client: client, sessionState: sessionState) }
            }
            Button("Keep scanning", role: .cancel) {}
        } message: { library in
            Text("This stops the scans of \(library.name) that are queued or running. You can start a new scan at any time.")
        }
        .confirmationDialog(
            pendingRefreshAll.map { String(localized: "Refresh all metadata for \($0.name)?") } ?? "",
            isPresented: Binding(get: { pendingRefreshAll != nil }, set: { if !$0 { pendingRefreshAll = nil } }),
            titleVisibility: .visible,
            presenting: pendingRefreshAll
        ) { library in
            Button("Refresh all metadata") {
                Task { await viewModel.refreshMetadata(library, mode: .all, client: client, sessionState: sessionState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { library in
            Text("Every item in \(library.name) is fetched again from its metadata providers. Large libraries can take hours. Locked fields and artwork stay as they are.")
        }
    }

    @ViewBuilder
    private var messages: some View {
        if let message = viewModel.actionErrorMessage {
            Label(message, icon: .triangleAlert)
                .bloemText(.bodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("libraries-action-error")
        }
        if let notice = viewModel.noticeMessage {
            Label(notice, icon: .circleCheck)
                .bloemText(.bodyMedium)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("libraries-notice")
        }
    }
}

// MARK: - One library

private struct LibraryCard: View {
    let library: AdminLibrary
    let viewModel: LibrariesViewModel
    let onScan: () -> Void
    let onStop: () -> Void
    let onCheckMount: () -> Void
    let onRefreshMissing: () -> Void
    let onRefreshAll: () -> Void
    let onCancelRefresh: (LibraryRefreshJob) -> Void

    private var scanState: LibraryScanState { viewModel.scanState(for: library) }
    private var refreshJob: LibraryRefreshJob? { viewModel.activeRefreshJob(for: library) }
    private var busy: Bool { viewModel.busyLibraryIDs.contains(library.id) }

    var body: some View {
        DetailCard(library.name) {
            VStack(alignment: .leading, spacing: 8) {
                facts
                if let warning = library.scanWarning { WarningBlock(warning: warning) }
                scanLine
                refreshLine
                mountLine
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("library-\(library.id)")
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(sentenceCased(library.type)) · \(pathCountText(library.pathCount)) · \(library.enabled ? String(localized: "Enabled") : String(localized: "Disabled"))")
                .bloemText(.bodyMedium)
                .accessibilityIdentifier("library-facts-\(library.id)")
            Text(library.lastScannedAt.map { String(localized: "Last scanned \(formatRelativeTime($0))") } ?? String(localized: "Never scanned"))
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
                .accessibilityIdentifier("library-last-scanned-\(library.id)")
        }
    }

    @ViewBuilder
    private var scanLine: some View {
        let state = scanState
        if let label = state.label {
            VStack(alignment: .leading, spacing: 4) {
                Text(scanLineText(state, label: label))
                    .bloemText(.bodyMedium)
                    .accessibilityIdentifier("library-scan-state-\(library.id)")
                // The warning block above says it already when a scan failed because a root cannot be reached.
                if let detail = state.detail, !ScanDetail.repeats(detail, of: library.scanWarning?.message) {
                    Text(detail).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                if case .finished(let run) = state, let result = run.result {
                    Text(ScanCounts.text(result)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
        }
    }

    private func scanLineText(_ state: LibraryScanState, label: String) -> String {
        switch state {
        case .queued(let count) where count > 1: String(localized: "Scan: \(label), \(count) scans")
        case .running(_, let queued) where queued > 0: String(localized: "Scan: \(label), \(queued) more queued")
        case .finished(let run):
            run.completedAt.map { String(localized: "Last scan: \(label), \(formatRelativeTime($0))") } ?? String(localized: "Last scan: \(label)")
        default: String(localized: "Scan: \(label)")
        }
    }

    @ViewBuilder
    private var refreshLine: some View {
        if let job = refreshJob {
            VStack(alignment: .leading, spacing: 4) {
                Text("Metadata refresh: \(job.state.label)")
                    .bloemText(.bodyMedium)
                    .accessibilityIdentifier("library-refresh-state-\(library.id)")
                if let progress = job.progressText {
                    Text(progress).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        .accessibilityIdentifier("library-refresh-progress-\(library.id)")
                }
                if job.cancelable && job.state != .canceling {
                    Button("Cancel refresh", action: { onCancelRefresh(job) })
                        .libraryButtonStyle()
                        .disabled(busy)
                        .accessibilityIdentifier("library-cancel-refresh-\(library.id)")
                }
            }
        } else if let last = viewModel.lastRefreshJob(for: library) {
            Text(lastRefreshText(last))
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
                .accessibilityIdentifier("library-last-refresh-\(library.id)")
        }
    }

    private func lastRefreshText(_ job: LibraryRefreshJob) -> String {
        if let result = job.resultText { return String(localized: "Last metadata refresh: \(job.state.label), \(result)") }
        return String(localized: "Last metadata refresh: \(job.state.label)")
    }

    @ViewBuilder
    private var mountLine: some View {
        switch viewModel.mountCheck(for: library) {
        case nil:
            EmptyView()
        case .checking:
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking the mount").bloemText(.bodyMedium)
            }
        case .answered(let check):
            VStack(alignment: .leading, spacing: 4) {
                Text(check.verdict.headline)
                    .bloemText(.titleSmall)
                    .accessibilityIdentifier("library-mount-answer-\(library.id)")
                if !check.summary.isEmpty {
                    Text(check.summary).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                ForEach(check.problemRoots, id: \.path) { root in
                    Text(rootText(root)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
        case .failed(let message):
            Text(message)
                .bloemText(.bodyMedium)
                .accessibilityIdentifier("library-mount-error-\(library.id)")
        }
    }

    private func rootText(_ root: MountCheck.Root) -> String {
        if !root.reachable {
            if let reason = root.errorMessage, !reason.isEmpty { return String(localized: "\(root.path): not reachable, \(reason)") }
            return String(localized: "\(root.path): not reachable")
        }
        return String(localized: "\(root.path): reachable but empty")
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
            if !viewModel.scanAvailable {
                Text("This server cannot start or stop scans")
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        Button("Scan", action: onScan)
            .libraryButtonStyle()
            .disabled(busy || !viewModel.scanAvailable)
            .accessibilityIdentifier("library-scan-\(library.id)")
        Button("Stop", action: onStop)
            .libraryButtonStyle()
            .disabled(busy || !viewModel.scanAvailable || !(scanState.isActive || viewModel.scanResultsError != nil))
            .accessibilityIdentifier("library-stop-\(library.id)")
        Button("Check the mount", action: onCheckMount)
            .libraryButtonStyle()
            .disabled(busy)
            .accessibilityIdentifier("library-check-mount-\(library.id)")
        Menu("Refresh metadata") {
            Button("Refresh missing metadata", action: onRefreshMissing)
            Button("Refresh all metadata", action: onRefreshAll)
        }
        .libraryButtonStyle()
        .disabled(busy || refreshJob != nil)
        .accessibilityIdentifier("library-refresh-\(library.id)")
    }
}

private extension View {
    func libraryButtonStyle() -> some View {
        buttonStyle(.bloemSecondary).frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum ScanDetail {
    /// Whether a scan's detail only says again what the library's warning says (a failed scan and an unreachable root
    /// report the same sentence, one in capitals the other not). Showing both read as two problems.
    static func repeats(_ detail: String, of warning: String?) -> Bool {
        guard let warning else { return false }
        let said = detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let already = warning.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return !said.isEmpty && !already.isEmpty && (said == already || already.contains(said) || said.contains(already))
    }
}

private struct WarningBlock: View {
    let warning: LibraryScanWarning

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(warning.headline, icon: .triangleAlert)
                .bloemText(.titleSmall)
            if let message = warning.message, !message.isEmpty {
                Text(message).bloemText(.bodySmall)
            }
            if let raisedAt = warning.raisedAt {
                Text("Since \(formatRelativeTime(raisedAt))").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("library-warning")
    }
}

private func pathCountText(_ count: Int) -> String {
    count == 1 ? String(localized: "1 path") : String(localized: "\(count) paths")
}

// MARK: - Recent scans

enum ScanCounts {
    /// "New 12 · Updated 3 · Missing 2 · Errors 1": figures keep their width, words need no plural.
    static func text(_ result: ScanRunResult) -> String {
        String(localized: "New \(result.new) · Updated \(result.updated) · Missing \(result.missing) · Errors \(result.errors)")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : (seconds >= 60 ? [.minute, .second] : [.second])
        formatter.unitsStyle = .abbreviated
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: max(1, seconds.rounded())) ?? ""
    }
}

private struct RecentScansCard: View {
    let viewModel: LibrariesViewModel

    private var runs: [ScanRun] {
        Array((viewModel.activeRuns + viewModel.recentRuns).prefix(APIClient.recentScanLimit))
    }

    var body: some View {
        DetailCard(String(localized: "Recent scans")) {
            if let error = viewModel.scanResultsError {
                Text("Scan results are not available: \(error)")
                    .bloemText(.bodyMedium)
                    .accessibilityIdentifier("recent-scans-error")
            } else if runs.isEmpty {
                Text("No scans yet").bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            }
            ForEach(runs) { run in
                RunRow(run: run, libraryName: viewModel.name(ofLibraryID: run.libraryID))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recent-scans")
    }
}

private struct RunRow: View {
    let run: ScanRun
    let libraryName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(libraryName): \(run.status.label)").bloemText(.titleSmall)
            Text(subtitle).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if let result = run.result {
                Text(ScanCounts.text(result)).bloemText(.bodySmall)
            }
            if run.status == .failed, let message = run.errorMessage {
                Text(message).bloemText(.bodySmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scan-run-\(run.id)")
    }

    private var subtitle: String {
        var parts = [run.triggerLabel]
        if let when = run.completedAt ?? run.startedAt ?? run.requestedAt { parts.append(formatRelativeTime(when)) }
        if let duration = run.duration { parts.append(ScanCounts.duration(duration)) }
        return parts.joined(separator: " · ")
    }
}
