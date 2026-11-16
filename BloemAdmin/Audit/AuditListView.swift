import SwiftUI

/// Read-only audit trail (`GET /api/v2/admin/logs/audit`). Deliberately does NOT poll on a timer: a
/// historical log a reviewer pages through with "Load more", where a timed reset to page one would
/// get in the way. One load on appear, one on every filter change, and pull to refresh.
///
/// Each row leads with what was done: the action and its before and after lines; the request
/// (METHOD and path) comes second. A tap opens the entry's details. Filter by person, picked by name.
struct AuditListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var viewModel = AuditViewModel()
    @State private var options = UserPickerOptions()
    @State private var userID = ""
    @State private var selected: AuditLogEntry?
    /// True once the first `load` call has completed — gates the initial spinner, which pull to
    /// refresh must not bring back.
    @State private var hasLoadedOnce = false

    private var filter: AuditFilter { AuditFilter(userID: userID) }

    var body: some View {
        List {
            Section {
                PersonFilterPicker(userID: $userID, options: options, identifier: "audit-person")
                if let failure = options.usersFailure {
                    Text(failure).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
            Section {
                ForEach(viewModel.entries) { entry in
                    Button { selected = entry } label: { AuditEntryRow(entry: entry) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("audit-row-\(entry.id)")
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
        }
        .overlay {
            if !hasLoadedOnce && viewModel.entries.isEmpty && viewModel.errorMessage == nil {
                ProgressView()
            } else if let failure = viewModel.loadFailure {
                LoadFailureView(failure: failure) { Task { await reload() } }
            } else if viewModel.entries.isEmpty {
                BloemEmptyState(
                    "No audit entries",
                    icon: .shieldCheck,
                    description: Text(filter.isEmpty
                        ? "No administrator requests have been recorded."
                        : "No audit entries match this person.")
                )
            }
        }
        .navigationTitle("Audit")
        .sheet(item: $selected) { entry in
            AuditDetailSheet(entry: entry)
        }
        .task { await options.loadUsers(client: client, sessionState: sessionState) }
        .task { await reload() }
        .onChange(of: userID) { Task { await reload() } }
        .refreshable { await reload() }
    }

    private func reload() async {
        await viewModel.load(filter: filter, client: client, sessionState: sessionState)
        hasLoadedOnce = true
    }
}

/// One audit entry: what was done, then the request that did it.
struct AuditEntryRow: View {
    let entry: AuditLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.headline).bloemText(.titleMedium)
            ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                Text(change.line(targetType: entry.targetType))
                    .bloemText(.bodyMedium)
                    .foregroundStyle(.bloemMuted)
            }
            if let target = entry.targetLabel {
                Text(target).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            }
            Text(entry.requestLine)
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
                .lineLimit(2)
            Text(footer)
                .bloemText(.bodySmall)
                .foregroundStyle(.bloemMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "14 Nov, 22:42 · 204 · User 7": when, how it ended, who.
    private var footer: String {
        let time = entry.timestamp.formatted(date: .abbreviated, time: .standard)
        let status = entry.statusCode >= 400 ? String(localized: "Failed with \(entry.statusCode)") : String(entry.statusCode)
        return [time, status, entry.actorText].compactMap { $0 }.joined(separator: " · ")
    }
}
