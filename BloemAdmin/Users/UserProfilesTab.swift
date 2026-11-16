import SwiftUI

/// What the Profiles tab is asking the admin about.
private enum ProfileSheet: Identifiable {
    case add
    case rename(UserProfile)
    case pin(UserProfile)

    var id: String {
        switch self {
        case .add: "add"
        case .rename(let profile): "rename-" + profile.id
        case .pin(let profile): "pin-" + profile.id
        }
    }
}

private enum ProfileConfirmation: Identifiable {
    case clearPIN(UserProfile)
    case remove(UserProfile)

    var id: String {
        switch self {
        case .clearPIN(let profile): "clear-" + profile.id
        case .remove(let profile): "remove-" + profile.id
        }
    }
}

/// Profiles, in platform mode: the account's profiles with what each one is in words (main, children's, PIN set),
/// and add, rename, set or remove a PIN, and delete. Offered only where the server has `profile_management`
/// (`UserTab.visible`). `canManage` follows the server's Owner rule: an account may act on itself, and only the
/// Owner changes the Owner's or another admin's profiles.
struct UserProfilesTab: View {
    let user: AdminUser
    let canManage: Bool
    @State private var model: UserProfilesViewModel
    @State private var sheet: ProfileSheet?
    @State private var confirmation: ProfileConfirmation?
    @State private var succeeded = false

    init(user: AdminUser, admin: UserAdmin, canManage: Bool) {
        self.user = user
        self.canManage = canManage
        _model = State(initialValue: UserProfilesViewModel(
            userID: user.id, serverName: admin.serverName, client: admin.client, sessionState: admin.sessionState
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailCard(String(localized: "Profiles")) {
                if let message = model.errorMessage {
                    Label(message, icon: .triangleAlert)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("profiles-error")
                }
                if let notice = model.notice {
                    Text(notice).foregroundStyle(.bloemMuted).accessibilityIdentifier("profiles-notice")
                }
                LoadStateBody(state: model.profiles, retry: { Task { await model.load() } }) { list in
                    if list.isEmpty { Text("No profiles").foregroundStyle(.bloemMuted) }
                    ForEach(list) { profile in
                        row(profile)
                        if profile.id != list.last?.id { Divider() }
                    }
                }
                if canManage {
                    Button {
                        sheet = .add
                    } label: {
                        Label("Add profile", icon: .plus).frame(minHeight: 44, alignment: .leading)
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("profiles-add")
                } else {
                    Text("Only the server owner can change this account's profiles. You can view them.")
                        .bloemText(.bodySmall)
                        .foregroundStyle(.bloemMuted)
                }
            }
        }
        .task { await model.load() }
        .sensoryFeedback(.success, trigger: succeeded)
        .sheet(item: $sheet) { current in
            switch current {
            case .add:
                ProfileNameSheet(mode: .add) { name, pin in
                    if await model.add(name: name, pin: pin) { succeeded.toggle() }
                }
            case .rename(let profile):
                ProfileNameSheet(mode: .rename(profile)) { name, _ in
                    if await model.rename(profile, to: name) { succeeded.toggle() }
                }
            case .pin(let profile):
                ProfilePINSheet(profile: profile) { pin in
                    if await model.setPIN(profile, to: pin) { succeeded.toggle() }
                }
            }
        }
        // Alerts, not confirmation dialogs: on iOS 26 a dialog shows as a popover with no Cancel button.
        .alert(confirmationTitle, isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let confirmation {
                switch confirmation {
                case .clearPIN(let profile):
                    Button("Clear PIN") { run { await model.clearPIN(profile) } }
                case .remove(let profile):
                    Button("Remove profile", role: .destructive) { run { await model.remove(profile) } }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private func run(_ work: @escaping () async -> Bool) {
        Task { if await work() { succeeded.toggle() } }
    }

    // MARK: Rows

    private func row(_ profile: UserProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profile.name).bloemText(.titleMedium)
            Text(facts(profile)).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            if canManage {
                FlowLayout(spacing: 8) {
                    rowButton(String(localized: "Rename"), id: "rename", profile) { sheet = .rename(profile) }
                    rowButton(profile.hasPIN ? String(localized: "Change PIN") : String(localized: "Set PIN"), id: "pin", profile) {
                        sheet = .pin(profile)
                    }
                    if profile.hasPIN {
                        rowButton(String(localized: "Clear PIN"), id: "clear-pin", profile) { confirmation = .clearPIN(profile) }
                    }
                    if profile.canRemove {
                        rowButton(String(localized: "Remove"), id: "remove", profile, destructive: true) { confirmation = .remove(profile) }
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("profile-row-\(profile.id)")
    }

    private func rowButton(
        _ title: String, id: String, _ profile: UserProfile, destructive: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(role: destructive ? .destructive : nil, action: action) {
            Text(title).padding(.horizontal, 8).frame(minHeight: 44)
        }
        .buttonStyle(.bloemSecondary)
        .disabled(model.isBusy)
        .accessibilityLabel("\(title): \(profile.name)")
        .accessibilityIdentifier("profile-\(id)-\(profile.id)")
    }

    /// "Main profile · PIN set · last seen Feb 3": what the profile is, said in words.
    private func facts(_ profile: UserProfile) -> String {
        var parts: [String] = []
        if profile.isPrimary { parts.append(String(localized: "Main profile")) }
        if profile.isChild { parts.append(String(localized: "Children's profile")) }
        parts.append(profile.hasPIN ? String(localized: "PIN set") : String(localized: "No PIN"))
        if let seen = UserFormat.date(profile.lastSeenAt) { parts.append(String(localized: "Last seen \(seen)")) }
        return parts.joined(separator: " · ")
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .clearPIN(let profile): String(localized: "Clear the PIN on \(profile.name)?")
        case .remove(let profile): String(localized: "Remove \(profile.name)?")
        case nil: ""
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .clearPIN(let profile):
            profile.isPrimary
                ? String(localized: "This is the account's main profile: anyone using the account can open it until a new PIN is set.")
                : String(localized: "The profile opens without a PIN until a new one is set.")
        case .remove:
            String(localized: "Its watch history and collections are deleted, and anyone signed in to it is signed out. This can't be undone. A stream already playing on it isn't stopped.")
        case nil: ""
        }
    }
}

/// Name a new profile (with an optional PIN), or rename one.
private struct ProfileNameSheet: View {
    enum Mode {
        case add
        case rename(UserProfile)
    }

    let mode: Mode
    let onSave: @MainActor (String, String?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var pin = ""
    @State private var isSaving = false

    private var isAdding: Bool {
        if case .add = mode { return true }
        return false
    }

    private var nameProblem: ProfileInput.Problem? { ProfileInput.nameProblem(name) }
    private var pinProblem: ProfileInput.Problem? { pin.isEmpty ? nil : ProfileInput.pinProblem(pin) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("profile-name-field")
                } footer: {
                    if nameProblem == .tooLong {
                        Text("Use at most \(ProfileInput.maxNameLength) characters.")
                    }
                }
                if isAdding {
                    Section {
                        SecureField("PIN (optional)", text: $pin)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("profile-pin-field")
                    } footer: {
                        Text(pinProblem == .tooLong
                             ? String(localized: "A PIN can be at most \(ProfileInput.maxPINBytes) bytes.")
                             : String(localized: "Leave it empty for a profile that opens without a PIN."))
                    }
                }
            }
            .navigationTitle(isAdding ? String(localized: "Add profile") : String(localized: "Rename profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdding ? String(localized: "Add") : String(localized: "Save changes")) {
                        isSaving = true
                        Task {
                            await onSave(name, pin.isEmpty ? nil : pin)
                            dismiss()
                        }
                    }
                    .disabled(nameProblem != nil || pinProblem != nil || isSaving)
                    .accessibilityIdentifier("profile-sheet-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
        .onAppear {
            if case .rename(let profile) = mode { name = profile.name }
        }
    }
}

/// Sets or replaces a profile's PIN. The PIN lives only in this sheet's state and the request body.
private struct ProfilePINSheet: View {
    let profile: UserProfile
    let onSave: @MainActor (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var isSaving = false

    private var problem: ProfileInput.Problem? { ProfileInput.pinProblem(pin) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("profile-pin-field")
                } footer: {
                    Text(problem == .tooLong
                         ? String(localized: "A PIN can be at most \(ProfileInput.maxPINBytes) bytes.")
                         : String(localized: "Anyone signed in to \(profile.name) with the old PIN is signed out of it."))
                }
            }
            .navigationTitle(profile.hasPIN ? String(localized: "Change PIN") : String(localized: "Set PIN"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save changes") {
                        isSaving = true
                        Task {
                            await onSave(pin)
                            pin = ""
                            dismiss()
                        }
                    }
                    .disabled(problem != nil || isSaving)
                    .accessibilityIdentifier("profile-sheet-save")
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }
}
