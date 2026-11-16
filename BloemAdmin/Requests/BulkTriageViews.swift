import SwiftUI

/// The checkbox of a row in select mode. The state is said in words for VoiceOver, not by colour alone.
struct RequestSelectionMark: View {
    let isSelected: Bool

    var body: some View {
        IconImage(isSelected ? .circleCheck : .circle, size: .bar)
            .foregroundStyle(isSelected ? Theme.accent : Theme.muted)
            .frame(width: 44, height: 44)
            .accessibilityHidden(true)
    }
}

/// How a queue row behaves while select mode is on: tapping it toggles it, and its own buttons wait.
struct RequestRowSelection {
    let isSelected: Bool
    let toggle: () -> Void
}

/// Above the rows of Needs approval: Select to start, then how many are selected with Select all and Done.
struct BulkSelectHeader: View {
    let model: BulkTriageModel
    /// The rows a selection can hold (those shown now) and how many of them are selected.
    let shownKeys: [String]
    let selectedCount: Int

    private var shownCount: Int { shownKeys.count }
    private var allSelected: Bool { shownCount > 0 && selectedCount == shownCount }

    var body: some View {
        HStack(spacing: 12) {
            if model.isSelecting {
                Text(BulkTriageText.selected(count: selectedCount))
                    .bloemText(.bodyMedium)
                    .foregroundStyle(.bloemMuted)
                    .accessibilityIdentifier("bulk-selected-count")
                Spacer(minLength: 8)
                Button(allSelected ? String(localized: "Clear") : BulkTriageText.selectAll(count: shownCount)) {
                    if allSelected { model.deselectAll() } else { model.selectAll(shownKeys) }
                }
                .buttonStyle(.bloemQuiet)
                .frame(minHeight: 44)
                .disabled(model.isRunning || shownCount == 0)
                .accessibilityIdentifier("bulk-select-all")
                Button("Done") { model.endSelecting() }
                    .buttonStyle(.bloemQuiet)
                    .bloemText(.titleMedium)
                    .frame(minHeight: 44)
                    .disabled(model.isRunning)
                    .accessibilityIdentifier("bulk-done")
            } else {
                Spacer(minLength: 0)
                Button("Select") { model.beginSelecting() }
                    .buttonStyle(.bloemQuiet)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("bulk-select")
            }
        }
    }
}

/// Pinned under the queue while select mode is on: Approve N and Decline N for what is selected.
struct BulkActionBar: View {
    let model: BulkTriageModel
    let selectedCount: Int
    let onApprove: () -> Void
    let onDecline: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onApprove) {
                Text(BulkTriageText.approveButton(count: selectedCount)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bloemProminent)
            .accessibilityIdentifier("bulk-approve")
            Button(action: onDecline) {
                Text(BulkTriageText.declineButton(count: selectedCount)).frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bloemSecondary)
            .accessibilityIdentifier("bulk-decline")
        }
        .disabled(selectedCount == 0 || model.isRunning)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Progress while a run is going, then its result: how many went through, and each failure with its reason.
struct BulkProgressBanner: View {
    let progress: BulkProgress
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if progress.isRunning {
                Text(BulkTriageText.running(progress.action, done: progress.done, total: progress.total))
                    .bloemText(.bodyMedium)
                ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                    .accessibilityLabel(progress.action == .approve ? String(localized: "Approving requests") : String(localized: "Declining requests"))
                    .accessibilityValue(Text(Double(progress.done) / Double(max(progress.total, 1)), format: .percent))
            } else {
                HStack(alignment: .firstTextBaseline) {
                    Text(BulkTriageText.result(progress.action, total: progress.total, failed: progress.failures.count))
                        .bloemText(.titleSmall)
                    Spacer(minLength: 8)
                    Button("Dismiss", action: onDismiss).buttonStyle(.bloemQuiet).frame(minHeight: 44)
                }
                ForEach(progress.failures) { failure in
                    let name = [failure.title, failure.serverName].compactMap { $0 }.joined(separator: " · ")
                    Text(BulkTriageText.failureLine(title: name, message: failure.message))
                        .bloemText(.bodySmall)
                        .foregroundStyle(.bloemMuted)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bulk-progress")
    }
}

extension View {
    /// Asks for the one optional note a bulk decline sends to every requester. `onConfirm` gets the note.
    func bulkDeclineAlert(
        isPresented: Binding<Bool>, count: Int, note: Binding<String>, onConfirm: @escaping (String) -> Void
    ) -> some View {
        alert(BulkTriageText.declineTitle(count: count), isPresented: isPresented) {
            TextField("Note (optional)", text: note)
            Button(BulkTriageText.declineButton(count: count), role: .destructive) {
                let entered = note.wrappedValue
                note.wrappedValue = ""
                onConfirm(entered)
            }
            Button("Keep requests", role: .cancel) { note.wrappedValue = "" }
        } message: {
            Text(BulkTriageText.declineMessage(count: count))
        }
    }
}
