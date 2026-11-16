import SwiftUI

/// The Plan card of an organization: what it is on now, a picker for another plan, and Preview changes, which asks
/// the server what the plan would change and opens a confirmation that says it setting by setting.
struct PlatformPlanSection: View {
    @Bindable var model: PlatformPlanModel
    let sessionState: ServerScopedSession
    @State private var confirming = false

    var body: some View {
        DetailCard(String(localized: "Plan")) {
            if let failure = model.failure {
                Text(failure.message).foregroundStyle(.bloemMuted)
                Button("Try again") { Task { await model.load(sessionState: sessionState) } }
                    .frame(minHeight: 44)
            } else if model.isLoading {
                ProgressView("Loading…")
            } else {
                current
                Divider()
                chooser
            }
        }
        .sheet(isPresented: $confirming) {
            PlatformPlanConfirmationSheet(model: model, sessionState: sessionState) { confirming = false }
        }
    }

    // MARK: What it is on now

    @ViewBuilder
    private var current: some View {
        LabeledContent("Current plan") {
            Text(model.currentPlanText).accessibilityIdentifier("platform-plan-current")
        }
        if model.currentPlanUnavailable {
            Text("Current plan is no longer offered").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        }
        LabeledContent("Organization limits") { Text(model.limitsText) }
        LabeledContent("Last applied") { Text(model.lastAppliedText ?? String(localized: "Not yet")) }
        if model.currentSettings.isEmpty {
            LabeledContent("Default settings for members") { Text("None yet") }
        } else {
            Text("Default settings for members").bloemText(.titleSmall)
            ForEach(model.currentSettings, id: \.label) { row in
                LabeledContent(row.label) { Text(row.value) }
                    .bloemText(.bodyMedium)
            }
        }
    }

    // MARK: Choosing another

    @ViewBuilder
    private var chooser: some View {
        Text("Choosing a plan changes the organization's default settings for members. Access groups the organization made itself are never changed. You see the changes before they apply.")
            .bloemText(.bodySmall)
            .foregroundStyle(.bloemMuted)
        if model.hasNoPlans {
            Text("No plans are offered yet. Plans are set up in the web admin.").foregroundStyle(.bloemMuted)
        } else {
            Picker("Plan", selection: $model.selectedKey) {
                Text("Choose a plan").tag("")
                ForEach(model.plans) { plan in
                    Text("\(plan.name) (revision \(plan.revision))").tag(plan.key)
                }
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("platform-plan-picker")
            Button {
                Task {
                    await model.preview(sessionState: sessionState)
                    confirming = model.confirmation != nil
                }
            } label: {
                HStack {
                    Text("Preview changes")
                    if model.isPreviewing { ProgressView() }
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bloemSecondary)
            .disabled(!model.canPreview)
            .accessibilityIdentifier("platform-plan-preview")
        }
        if let note = model.previewNote {
            Text(note).bloemText(.bodyMedium).accessibilityIdentifier("platform-plan-note")
        }
        if let notice = model.notice {
            Label(notice, icon: .circleCheck)
                .bloemText(.bodyMedium)
                .accessibilityIdentifier("platform-plan-notice")
        }
        if let problem = model.actionError, !confirming {
            Label(problem, icon: .triangleAlert)
                .bloemText(.titleSmall)
                .accessibilityIdentifier("platform-plan-error")
        }
    }
}

/// What applying the previewed plan changes, in words, with Apply. Opens only for a preview that changes something.
private struct PlatformPlanConfirmationSheet: View {
    let model: PlatformPlanModel
    let sessionState: ServerScopedSession
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if let confirmation = model.confirmation {
                    Section {
                        ForEach(confirmation.changes) { change in
                            Text(change.sentence)
                        }
                    } header: {
                        Text(confirmation.headline).textCase(nil)
                    } footer: {
                        Text(confirmation.reach)
                    }
                    if !confirmation.warnings.isEmpty {
                        Section("Warnings") {
                            ForEach(confirmation.warnings, id: \.self) { Text($0) }
                        }
                    }
                } else {
                    Section { Text("This preview is no longer current. Close this and preview the change again.") }
                }
                if model.previewExpired {
                    Section { Text("This preview has expired. Close this and preview the change again.") }
                }
                if let problem = model.actionError {
                    Section {
                        Label(problem, icon: .triangleAlert)
                            .bloemText(.titleSmall)
                            .accessibilityIdentifier("platform-plan-confirm-error")
                    }
                }
            }
            .navigationTitle("Confirm plan change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onClose).disabled(model.isApplying)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            await model.apply(sessionState: sessionState)
                            if model.confirmation == nil && model.actionError == nil { onClose() }
                        }
                    } label: {
                        if model.isApplying { ProgressView() } else { Text("Apply") }
                    }
                    .disabled(!model.canApply)
                    .accessibilityIdentifier("platform-plan-apply")
                }
            }
        }
        .accessibilityIdentifier("platform-plan-confirmation")
        .interactiveDismissDisabled(model.isApplying)
        // A preview that was thrown away (stale, or the access was renewed) leaves the sheet with its reason shown
        // on the page behind it.
        .onChange(of: model.confirmation == nil) { _, gone in
            if gone && model.actionError != nil { onClose() }
        }
    }
}
