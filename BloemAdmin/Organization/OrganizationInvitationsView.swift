import SwiftUI

/// Invitations: send, resend, revoke, and the one-time claim link. Nothing is emailed: the administrator gets a link
/// and hands it over. The link is held in memory until dismissed and is copied through the same local-only,
/// expiring pasteboard writer the platform invitations use.
struct OrganizationInvitationsView: View {
    let session: OrganizationSession
    @State private var model = OrganizationInvitationsViewModel()
    @State private var showsForm = false
    @State private var pendingRevoke: OrganizationInvitation?

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.invitations.isEmpty,
            emptyTitle: String(localized: "Invitations"),
            emptyMessage: String(localized: "No invitations yet. Invite someone to get started."),
            emptyIcon: .mail, errorMessage: model.errorMessage, noticeMessage: nil,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: { model.dismissError() }
        ) {
            Section {
                ForEach(model.invitations) { invitation in
                    row(invitation)
                }
            } footer: {
                Text("Invite members to this organization. No email is sent: you get a one-time link to pass on.")
            }
        }
        .accessibilityIdentifier("organization-page-invitations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showsForm = true } label: { Label("Invite someone", icon: .mailPlus) }
                    .disabled(model.isBusy)
            }
            .bloemFlat()
        }
        .task { await model.load(session: session) }
        .refreshable { await model.load(session: session) }
        .sheet(isPresented: $showsForm) {
            OrganizationInviteForm(session: session, model: model)
        }
        .sheet(item: Binding(get: { model.claimLink }, set: { if $0 == nil { model.dismissClaimLink() } })) { link in
            OrganizationClaimLinkView(link: link) { model.dismissClaimLink() }
        }
        .onDisappear { model.closeSurface() }
        .confirmationDialog(
            "Revoke invitation", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
            titleVisibility: .visible, presenting: pendingRevoke
        ) { invitation in
            Button("Revoke", role: .destructive) { Task { await model.revoke(session: session, invitation: invitation) } }
            Button("Cancel", role: .cancel) {}
        } message: { invitation in
            let address = invitation.email.isEmpty ? String(localized: "Link invitation") : invitation.email
            Text("Revoke the invitation for \(address)? Their link will stop working immediately.")
        }
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "pending": String(localized: "Pending")
        case "accepted": String(localized: "Accepted")
        case "revoked": String(localized: "Revoked")
        case "expired": String(localized: "Expired")
        default: OrganizationVocabulary.sentenceCase(status)
        }
    }

    @ViewBuilder
    private func row(_ invitation: OrganizationInvitation) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(invitation.email.isEmpty ? String(localized: "Link invitation") : invitation.email).bloemText(.titleMedium)
                Spacer(minLength: 8)
                StatusLabel(statusText(invitation.status))
            }
            if !invitation.invitedByName.isEmpty {
                Text("Invited by \(invitation.invitedByName)").bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            }
            Text("Expires \(OrganizationText.when(invitation.expiresAt))").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if !invitation.note.isEmpty { Text(invitation.note).bloemText(.bodySmall).foregroundStyle(.bloemMuted) }
            if invitation.isPending {
                OrganizationFlowLayout(spacing: 8) {
                    Button("Resend with a fresh link") {
                        Task { _ = await model.resend(session: session, invitation: invitation) }
                    }
                    Button("Revoke", role: .destructive) { pendingRevoke = invitation }
                }
                .buttonStyle(.bloemSecondary)
                .disabled(model.isBusy)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct OrganizationInviteForm: View {
    let session: OrganizationSession
    let model: OrganizationInvitationsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var groupID: Int64?
    @State private var note = ""
    @State private var errorMessage: String?
    @State private var gate = PrivilegedMutationGate()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email address", text: $email, prompt: Text("them@example.com"))
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                        .accessibilityIdentifier("organization-invite-email")
                    Picker("Access group", selection: $groupID) {
                        Text("Organization default").tag(Int64?.none)
                        ForEach(model.groups, id: \.id) { group in
                            Text(group.name).tag(group.numericID)
                        }
                    }
                    TextField("Personal note (optional)", text: $note)
                }
                .disabled(gate.isActive)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.bloemDanger).accessibilityIdentifier("organization-error")
                }
            }
            .navigationTitle("Invite someone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(gate.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        gate.submit { Task { await send() } }
                    } label: {
                        if gate.isActive { ProgressView() } else { Text("Create invite link") }
                    }
                    .disabled(gate.isActive || email.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(gate.isActive)
    }

    private func send() async {
        defer { gate.end() }
        errorMessage = nil
        // On success the view model keeps the claim link, which the list shows once this form is gone.
        switch await model.send(session: session, email: email, accessGroupID: groupID, note: note) {
        case .sent: dismiss()
        case .failed(let message): errorMessage = message
        }
    }
}

/// The only time the link is shown: the server stores a hash, not the token.
struct OrganizationClaimLinkView: View {
    let link: ClaimLink
    let onDone: () -> Void
    private let actions: InvitationClaimLinkActions

    init(
        link: ClaimLink,
        pasteboardWriter: any ClaimURLPasteboardWriting = LocalOnlyExpiringPasteboardWriter(),
        onDone: @escaping () -> Void
    ) {
        self.link = link
        self.onDone = onDone
        self.actions = InvitationClaimLinkActions(pasteboardWriter: pasteboardWriter)
    }

    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("No email was sent. Deliver this one-time link yourself. It works once and expires in 7 days; resending makes a fresh link and ends this one.")
                        .foregroundStyle(.bloemMuted)
                }
                Section {
                    LabeledContent("Email", value: link.invitation.email.isEmpty ? String(localized: "Link invitation") : link.invitation.email)
                    Text(link.url)
                        .bloemText(.bodySmall)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("organization-claim-url")
                    Button {
                        actions.copy(link.url)
                        copied = true
                    } label: {
                        Label(copied ? String(localized: "Link copied") : String(localized: "Copy link"), icon: .copy)
                    }
                    ShareLink(item: link.url) { Label("Share link", icon: .share) }
                } header: {
                    Text("Invite link")
                }
            }
            .navigationTitle("Invitation link ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .interactiveDismissDisabled(false)
        .accessibilityIdentifier("organization-claim-link")
    }
}
