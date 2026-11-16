import SwiftUI

/// Sets a password the admin hands over (the web's Set password). On an account with no password sign-in, such
/// as one a sign-in provider manages, the server turns password sign-in back on when an admin writes one; on an
/// account that has it, the new password replaces the old. Either way it can be temporary: the person must
/// choose their own at the next sign-in. The password is held only in this sheet's state and sent in the
/// request body; it is never shown in an error.
struct SetPasswordView: View {
    let user: AdminUser
    /// True when the account already signs in with a password: the sheet then sets a temporary one.
    var hasPasswordSignIn = false
    let submit: @MainActor (String, Bool) async -> UserUpdateResult?
    let onDone: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var password = ""
    @State private var temporary = true
    @State private var errorMessage: String?
    @State private var isSubmitting = false

    private var problem: PasswordProblem? { PasswordProblem.check(password) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(SetPasswordCopy.intro(hasPasswordSignIn: hasPasswordSignIn, name: user.username))
                    SecureField("New password", text: $password)
                        .textContentType(.newPassword)
                        .frame(minHeight: 44)
                    if !password.isEmpty, let problem {
                        switch problem {
                        case .tooShort:
                            Text("The password needs at least 8 characters").foregroundStyle(.bloemDanger)
                        case .tooLong:
                            Text("The password can be at most 72 bytes").foregroundStyle(.bloemDanger)
                        }
                    }
                    Toggle("Require change at next sign-in", isOn: $temporary)
                        .disabled(isSubmitting)
                } footer: {
                    Text("At least 8 characters, at most 72 bytes. Share it with \(user.username) yourself.")
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.bloemDanger) }
                }
            }
            .navigationTitle(SetPasswordCopy.title(hasPasswordSignIn: hasPasswordSignIn))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Setting…" : "Set password") { Task { await send() } }
                        .disabled(problem != nil || isSubmitting)
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: password) { _, _ in errorMessage = nil }
    }

    private func send() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        switch await submit(password, temporary) {
        case .success?:
            // The password leaves this sheet's state with the sheet; nothing else holds it.
            password = ""
            onDone(temporary)
            dismiss()
        case .failure(let message, _)?:
            errorMessage = message
        case nil:
            errorMessage = String(localized: "Action in progress")
        }
    }
}

/// Resets an account's password in the way the server offers: an emailed one-time link, a link to hand over,
/// or a temporary password the admin sets. Each reset is issued once per time the sheet is open; a link
/// replaces any earlier one. A link to hand over is shown once, with Copy and Share, and is forgotten when
/// the sheet closes.
struct PasswordResetView: View {
    let user: AdminUser
    /// Offers Set temporary password, which the page opens once this sheet has closed. Nil: not offered.
    var onSetTemporaryPassword: (() -> Void)?
    @State private var model: PasswordResetViewModel
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss
    private let claimLinkActions = InvitationClaimLinkActions(pasteboardWriter: LocalOnlyExpiringPasteboardWriter())

    init(user: AdminUser, admin: UserAdmin, onSetTemporaryPassword: (() -> Void)? = nil) {
        self.user = user
        self.onSetTemporaryPassword = onSetTemporaryPassword
        _model = State(initialValue: PasswordResetViewModel(user: user, admin: admin))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let link = model.link {
                    linkSection(link)
                } else {
                    emailSection
                    if user.passwordLogin { linkOptionSection }
                    if let onSetTemporaryPassword { temporaryPasswordSection(onSetTemporaryPassword) }
                }
            }
            .navigationTitle("Reset password for \(user.username)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if model.link != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { finish() }.accessibilityIdentifier("reset-link-done")
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { finish() }.disabled(model.isBusy)
                    }
                }
            }
        }
        .task { await model.load() }
        .interactiveDismissDisabled(model.isBusy)
        // However the sheet goes away, the link goes with it.
        .onDisappear { model.forgetLink() }
        .accessibilityIdentifier("password-reset-sheet")
    }

    private func finish() {
        model.forgetLink()
        dismiss()
    }

    // MARK: Email

    @ViewBuilder
    private var emailSection: some View {
        Section {
            if model.isBusy { ProgressView() }
            if let receipt = model.receipt {
                Text(receipt.deliveryStatus == "sent"
                     ? "The mail server confirmed sending the reset email."
                     : "Email delivery was not confirmed. The reset link is still active. Check delivery before issuing another.")
                Text("Expires: \(receipt.expiresAt.formatted(date: .abbreviated, time: .shortened))")
            } else if model.isAvailable {
                Text("Send a one-time password reset link to this account's email address? This replaces any previous link.")
            } else if !model.isBusy {
                Text("Password reset email is unavailable. Check the server's public URL and mail configuration, or use web administration.")
            }
            if let message = model.errorMessage, model.isAvailable || model.receipt != nil || model.hasSubmitted {
                Text(message).foregroundStyle(.bloemDanger)
            }
            if model.receipt == nil, model.isAvailable || model.isBusy {
                Button("Send reset email") { Task { await model.send() } }
                    .frame(minHeight: 44)
                    .disabled(!model.canSend)
                    .accessibilityIdentifier("reset-send-email")
            }
        } header: {
            Text("Email")
        }
    }

    // MARK: Link to hand over

    @ViewBuilder
    private var linkOptionSection: some View {
        Section {
            if model.isLinkAvailable {
                Text("Create a one-time link and give it to \(user.username) yourself. You'll see it once. Any earlier link stops working.")
                Button("Create link") { Task { await model.createLink() } }
                    .frame(minHeight: 44)
                    .disabled(!model.canCreateLink)
                    .accessibilityIdentifier("reset-create-link")
            } else if !model.isBusy {
                Text("Reset links aren't available on this server. Set the server's public address on the web to turn them on.")
                    .foregroundStyle(.bloemMuted)
            }
            if !user.enabled {
                Text("This account is disabled. Enable it first to create a link.").foregroundStyle(.bloemMuted)
            }
        } header: {
            Text("Link to hand over")
        }
    }

    /// The link, once: copy it or share it, then it is gone. Anyone holding it can set the password, so it goes
    /// to the person only.
    private func linkSection(_ link: ResetLinkShown) -> some View {
        Group {
            Section {
                Text("Give this link to \(user.username) yourself. It works once, until \(link.expiresAt.formatted(date: .abbreviated, time: .shortened)). Anyone who has it can choose their password, so send it to them only. It isn't shown again.")
                    .foregroundStyle(.bloemMuted)
            }
            Section {
                Text(link.url)
                    .bloemText(.bodySmall)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("reset-link-url")
                Button {
                    claimLinkActions.copy(link.url)
                    copied = true
                } label: {
                    Label(copied ? String(localized: "Link copied") : String(localized: "Copy link"), icon: .copy)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .accessibilityIdentifier("reset-link-copy")
                if let url = URL(string: link.url) {
                    ShareLink(item: url) {
                        Label("Share link", icon: .share).frame(minHeight: 44, alignment: .leading)
                    }
                }
            } header: {
                Text("Reset link")
            }
        }
    }

    // MARK: Temporary password

    private func temporaryPasswordSection(_ open: @escaping () -> Void) -> some View {
        Section {
            Text("Choose a password yourself and share it. \(user.username) must change it at the next sign-in.")
            Button("Set temporary password") {
                open()
                dismiss()
            }
            .frame(minHeight: 44)
            .disabled(model.isBusy)
            .accessibilityIdentifier("reset-set-temporary")
        } header: {
            Text("Temporary password")
        }
    }
}
