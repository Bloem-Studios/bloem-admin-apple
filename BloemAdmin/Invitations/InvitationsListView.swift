import SwiftUI
import UIKit

protocol ClaimURLPasteboardWriting {
    func copy(_ claimURL: String)
}

struct LocalOnlyExpiringPasteboardWriter: ClaimURLPasteboardWriting {
    private let now: () -> Date
    private let setItems: ([[String: Any]], [UIPasteboard.OptionsKey: Any]) -> Void

    init(pasteboard: UIPasteboard = .general) {
        self.now = Date.init
        self.setItems = { items, options in
            pasteboard.setItems(items, options: options)
        }
    }

    init(
        now: @escaping () -> Date,
        setItems: @escaping ([[String: Any]], [UIPasteboard.OptionsKey: Any]) -> Void
    ) {
        self.now = now
        self.setItems = setItems
    }

    func copy(_ claimURL: String) {
        let expiry = now().addingTimeInterval(10 * 60)
        setItems(
            [[UIPasteboard.typeAutomatic: claimURL]],
            [.localOnly: true, .expirationDate: expiry]
        )
    }
}

struct InvitationClaimLinkActions {
    let pasteboardWriter: any ClaimURLPasteboardWriting

    func copy(_ claimURL: String) {
        pasteboardWriter.copy(claimURL)
    }
}

struct InvitationsListView: View {
    let client: APIClient
    @Environment(\.adminSessionState) private var sessionState
    @State private var viewModel = InvitationsViewModel()
    @State private var showingSendInvite = false
    @State private var pendingRevoke: Invitation?
    @State private var mutationGate = PrivilegedMutationGate()
    /// True once the first `load` call has completed — without this, "No
    /// Invitations" flashes on screen before the real response lands, which
    /// reads as a false claim rather than a loading state.
    @State private var hasLoadedOnce = false

    var body: some View {
        List(viewModel.invitations) { invitation in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(invitation.email.isEmpty ? String(localized: "Link invitation") : invitation.email).bloemText(.titleMedium)
                    Spacer()
                    statusBadge(for: invitation.status)
                }
                Text("\(Vocabulary.role(invitation.role)) · Expires \(invitation.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                if !invitation.note.isEmpty {
                    Text(invitation.note).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                if invitation.isPending && invitation.delivery == "email_unconfirmed" {
                    Text("Email delivery unconfirmed").bloemText(.bodySmall).foregroundStyle(.bloemWarn)
                }
            }
            .accessibilityElement(children: .combine)
            .swipeActions {
                if invitation.isPending {
                    Button("Revoke", role: .destructive) { pendingRevoke = invitation }
                        .disabled(mutationGate.isActive)
                    Button("Resend") {
                        mutationGate.submit {
                            Task { await resend(invitation) }
                        }
                    }
                    .disabled(mutationGate.isActive)
                }
            }
            .contextMenu {
                if invitation.isPending {
                    Button("Resend") {
                        mutationGate.submit {
                            Task { await resend(invitation) }
                        }
                    }
                    .disabled(mutationGate.isActive)
                    Button("Revoke", role: .destructive) { pendingRevoke = invitation }
                        .disabled(mutationGate.isActive)
                }
            }
        }
        .overlay {
            if !hasLoadedOnce && viewModel.invitations.isEmpty && viewModel.errorMessage == nil {
                ProgressView()
            } else if let failure = viewModel.loadFailure {
                LoadFailureView(failure: failure) { Task { await load() } }
            } else if viewModel.invitations.isEmpty {
                BloemEmptyState("No invitations", icon: .mail, description: Text("Invite a new user by email"))
            }
        }
        .navigationTitle("Invitations")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingSendInvite = true
                } label: {
                    Label("Invite user", icon: .mailPlus)
                }
                .disabled(mutationGate.isActive)
            }
            .bloemFlat()
        }
        .sheet(isPresented: $showingSendInvite) {
            SendInvitationView(client: client, viewModel: viewModel, sessionState: sessionState)
        }
        .sheet(item: Binding(
            get: { viewModel.pendingDelivery },
            set: { if $0 == nil { viewModel.dismissDelivery() } }
        )) { delivery in
            InvitationLinkResultView(delivery: delivery)
        }
        .confirmationDialog(
            "Revoke the invitation to \(pendingRevoke?.email ?? "")? This cannot be undone.",
            isPresented: Binding(
                get: { pendingRevoke != nil },
                set: { isPresented in if !isPresented { pendingRevoke = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Revoke invitation", role: .destructive) {
                if let invitation = pendingRevoke {
                    mutationGate.submit {
                        Task { await revoke(invitation) }
                    }
                }
                pendingRevoke = nil
            }
            .disabled(mutationGate.isActive)
            Button("Cancel", role: .cancel) { pendingRevoke = nil }
        }
        .safeAreaInset(edge: .bottom) {
            if let message = viewModel.actionErrorMessage {
                Text(message)
                    .foregroundStyle(.bloemDanger)
                    .bloemText(.bodySmall)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(Theme.surface)
            }
        }
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        await viewModel.load(client: client, sessionState: sessionState)
        hasLoadedOnce = true
    }

    private func resend(_ invitation: Invitation) async {
        defer { mutationGate.end() }
        await viewModel.resend(invitation, client: client, sessionState: sessionState)
    }

    private func revoke(_ invitation: Invitation) async {
        defer { mutationGate.end() }
        await viewModel.revoke(invitation, client: client, sessionState: sessionState)
        if viewModel.actionErrorMessage == nil {
            await viewModel.load(client: client, sessionState: sessionState)
        }
    }

    private func statusBadge(for status: String) -> some View {
        StatusLabel(Vocabulary.invitationStatus(status))
    }
}

/// Minimal invite-by-email form, deliberately keeping the same scope as
/// `AddUserView`: email + role + an optional note. Access-group/library
/// scoping is intentionally out of scope for this v1 form even though the
/// real server endpoint accepts it — the server defaults those fields.
struct SendInvitationView: View {
    let client: APIClient
    let viewModel: InvitationsViewModel
    let sessionState: ServerScopedSession?

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var role = "user"
    @State private var note = ""
    @State private var mutationGate = PrivilegedMutationGate()
    @State private var errorMessage: String?

    private let roles = ["user", "admin"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Role", selection: $role) {
                        ForEach(roles, id: \.self) { Text(Vocabulary.role($0)).tag($0) }
                    }
                    TextField("Note (optional)", text: $note)
                }
                .disabled(mutationGate.isActive)
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.bloemDanger)
                }
            }
            .navigationTitle("Invite user")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(mutationGate.isActive)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        mutationGate.submit {
                            Task { await save() }
                        }
                    } label: {
                        if mutationGate.isActive {
                            ProgressView()
                        } else {
                            Text("Send")
                        }
                    }
                    .disabled(mutationGate.isActive || email.isEmpty)
                }
            }
        }
        .interactiveDismissDisabled(mutationGate.isActive)
    }

    private func save() async {
        defer { mutationGate.end() }
        errorMessage = nil
        // On success the view model keeps the claim link in `pendingDelivery`, which the list
        // presents once this sheet is gone.
        guard await viewModel.send(email: email, role: role, note: note, client: client, sessionState: sessionState) != nil else {
            errorMessage = viewModel.actionErrorMessage ?? String(localized: "The invitation couldn't be sent. Try again.")
            return
        }
        dismiss()
    }
}

/// Follow-up sheet shown after a successful send/resend — this is the ONLY
/// time the server ever hands back the raw claim link (it only stores a
/// hash), so it must be surfaced here rather than assumed recoverable via a
/// later fetch.
struct InvitationLinkResultView: View {
    let delivery: InvitationDelivery
    private let claimLinkActions: InvitationClaimLinkActions
    @Environment(\.dismiss) private var dismiss

    init(
        delivery: InvitationDelivery,
        pasteboardWriter: any ClaimURLPasteboardWriting = LocalOnlyExpiringPasteboardWriter()
    ) {
        self.delivery = delivery
        self.claimLinkActions = InvitationClaimLinkActions(pasteboardWriter: pasteboardWriter)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Email", value: delivery.invitation.email)
                    LabeledContent("Role", value: Vocabulary.role(delivery.invitation.role))
                }
                Section {
                    if delivery.emailSent {
                        Label("Invitation email sent", icon: .circleCheck)
                            .foregroundStyle(.bloemOK)
                    } else if delivery.deliveryFailed {
                        Label("The email may not have been delivered. Share the link yourself.", icon: .triangleAlert)
                            .foregroundStyle(.bloemWarn)
                    } else if delivery.deliveryStatus == "not_configured" {
                        Label("Invitation email not sent", icon: .triangleAlert)
                            .foregroundStyle(.bloemWarn)
                    }
                }
                if let claimURL = delivery.claimLink {
                    Section {
                        Text(claimURL)
                            .bloemText(.bodySmall)
                        Button {
                            claimLinkActions.copy(claimURL)
                        } label: {
                            Label("Copy link", icon: .copy)
                        }
                        ShareLink(item: claimURL) {
                            Label("Share link", icon: .share)
                        }
                    } header: {
                        Text("Invite link")
                    } footer: {
                        Text("This link is shown only once — the server doesn't store it in a retrievable form.")
                    }
                } else if !delivery.emailSent {
                    Text("No link is available and the email wasn't sent. Use Resend to try again.")
                        .foregroundStyle(.bloemMuted)
                }
            }
            .navigationTitle("Invitation created")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
