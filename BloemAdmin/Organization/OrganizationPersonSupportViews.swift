import SwiftUI

/// The person page's support sections: a reset link, sign-ins and devices to sign out of, and the profile edits.
/// Each shows only what the server says it can do (`OrganizationPersonViewModel.support`). The sections ask the page
/// to confirm (`OrganizationPersonConfirmation`); the page holds the one dialog, outside the list's rows.

/// Something on the person page that asks first.
enum OrganizationPersonConfirmation: Identifiable, Equatable {
    case reset(PasswordResetDelivery)
    case signOutEverywhere
    case signOutDevice(SupportDevice)
    case clearPIN(ProfileSummary)
    case removeProfile(ProfileSummary)

    var id: String {
        switch self {
        case .reset(let delivery): "reset-" + delivery.rawValue
        case .signOutEverywhere: "everywhere"
        case .signOutDevice(let device): "device-" + device.deviceID
        case .clearPIN(let profile): "pin-" + profile.id
        case .removeProfile(let profile): "remove-" + profile.id
        }
    }

    func title(for person: PersonSummary) -> String {
        switch self {
        case .reset(.email): String(localized: "Email a reset link to \(person.email)?")
        case .reset(.link): String(localized: "Create a reset link for \(person.label)?")
        case .signOutEverywhere: String(localized: "Sign \(person.label) out everywhere?")
        case .signOutDevice(let device): String(localized: "Sign out of \(OrganizationText.deviceName(device.name))?")
        case .clearPIN(let profile): String(localized: "Clear the PIN on \(profile.name)?")
        case .removeProfile(let profile): String(localized: "Remove \(profile.name)?")
        }
    }

    var actionTitle: String {
        switch self {
        case .reset(.email): String(localized: "Send email")
        case .reset(.link): String(localized: "Create link")
        case .signOutEverywhere: String(localized: "Sign out everywhere")
        case .signOutDevice: String(localized: "Sign out of this device")
        case .clearPIN: String(localized: "Clear PIN")
        case .removeProfile: String(localized: "Remove profile")
        }
    }

    var isDestructive: Bool {
        switch self {
        case .reset, .clearPIN: false
        case .signOutEverywhere, .signOutDevice, .removeProfile: true
        }
    }

    var message: Text {
        switch self {
        case .reset(.email): Text("Any earlier reset link stops working. They aren't signed out.")
        case .reset(.link): Text("You'll see the link once, to hand to them yourself. They also get an email saying a reset was issued. Any earlier link stops working.")
        case .signOutEverywhere: Text("Every app they're signed in to asks them to sign in again")
        case .signOutDevice: Text("Its sessions end and the device is forgotten, with its settings. A stream already playing on it isn't stopped. Their other devices stay signed in.")
        case .clearPIN(let profile):
            profile.isPrimary
                ? Text("This is the household's main profile: anyone using the account can open it until a new PIN is set. They choose the new PIN themselves.")
                : Text("The profile opens without a PIN until they choose a new one themselves.")
        case .removeProfile: Text("Its watch history and collections are deleted, and anyone signed in to it is signed out. This can't be undone. A stream already playing on it isn't stopped; stop it on Now playing first.")
        }
    }

    @MainActor
    func perform(model: OrganizationPersonViewModel, session: OrganizationSession) async {
        switch self {
        case .reset(let delivery): await model.issueReset(session: session, delivery: delivery)
        case .signOutEverywhere: await model.signOutEverywhere(session: session)
        case .signOutDevice(let device): await model.signOut(session: session, of: device)
        case .clearPIN(let profile): await model.clearPIN(session: session, profile: profile)
        case .removeProfile(let profile): await model.removeProfile(session: session, profile: profile)
        }
    }
}

// MARK: - Password

struct OrganizationResetSection: View {
    let model: OrganizationPersonViewModel
    let person: PersonSummary
    let confirm: (OrganizationPersonConfirmation) -> Void

    var body: some View {
        Section {
            if model.support.passwordReset.email {
                Button { confirm(.reset(.email)) } label: {
                    Label("Email a reset link", icon: .mailPlus)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(model.isPending || person.email.isEmpty)
                .accessibilityIdentifier("organization-reset-email")
            }
            if model.support.passwordReset.link {
                Button { confirm(.reset(.link)) } label: {
                    Label("Create a reset link to hand over", icon: .link)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(model.isPending)
                .accessibilityIdentifier("organization-reset-link")
            }
        } header: {
            Text("Password")
        } footer: {
            Text("They choose a new password themselves; you never see it. An emailed link works for 24 hours; a link you hand over works once, for 4 hours. A new link replaces any earlier one.")
        }
    }
}

/// The link, once: copy it or share it, then it is gone. Anyone holding it can set the password, so it goes to the
/// person only.
struct OrganizationResetLinkSheet: View {
    let link: ResetLinkHandoff
    let onDone: () -> Void
    private let actions = InvitationClaimLinkActions(pasteboardWriter: LocalOnlyExpiringPasteboardWriter())
    @State private var copied = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Give this link to \(link.personLabel) yourself. It works once, until \(OrganizationText.when(link.expiresAt)). Anyone who has it can choose their password, so send it to them only. It isn't shown again.")
                        .foregroundStyle(.bloemMuted)
                }
                Section {
                    Text(link.url)
                        .bloemText(.bodySmall)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("organization-reset-url")
                    Button {
                        actions.copy(link.url)
                        copied = true
                    } label: {
                        Label(copied ? String(localized: "Link copied") : String(localized: "Copy link"), icon: .copy)
                    }
                    if let url = URL(string: link.url) {
                        ShareLink(item: url) { Label("Share link", icon: .share) }
                    }
                } header: {
                    Text("Reset link")
                }
            }
            .navigationTitle("Reset link ready")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .accessibilityIdentifier("organization-reset-link-sheet")
    }
}

// MARK: - Sign-ins and devices

struct OrganizationSignInsSection: View {
    let model: OrganizationPersonViewModel
    let session: OrganizationSession
    let confirm: (OrganizationPersonConfirmation) -> Void

    var body: some View {
        Section {
            if let message = model.sessionsMessage {
                Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if let sessions = model.sessions {
                if sessions.isEmpty {
                    Text("Not signed in anywhere").foregroundStyle(.bloemMuted)
                }
                ForEach(sessions) { signIn in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(OrganizationText.deviceName(signIn.deviceName)).bloemText(.titleMedium)
                        Text(details(signIn)).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                        if let seen = signIn.lastSeenAt, !seen.isEmpty {
                            Text("Last seen \(OrganizationText.when(seen))").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                        Button(role: .destructive) {
                            Task { await model.signOut(session: session, of: signIn) }
                        } label: {
                            Text("Sign out of this session").frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bloemQuiet)
                        .disabled(model.isPending)
                        .accessibilityLabel(String(localized: "Sign out of \(OrganizationText.deviceName(signIn.deviceName))"))
                    }
                    .accessibilityIdentifier("organization-session-\(signIn.id)")
                }
                Button(role: .destructive) { confirm(.signOutEverywhere) } label: {
                    Label("Sign out everywhere", icon: .logOut)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(model.isPending)
                .accessibilityIdentifier("organization-sign-out-everywhere")
            } else if model.sessionsMessage == nil {
                ProgressView()
            }
        } header: {
            Text("Signed in")
        } footer: {
            Text("Signing out everywhere ends every session: they sign in again on each device. Their personal API keys keep working.")
        }
    }

    private func details(_ signIn: SupportSession) -> String {
        let profile = signIn.profileName.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Account sign-in")
        return [signIn.devicePlatform.isEmpty ? nil : OrganizationText.platform(signIn.devicePlatform), profile]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct OrganizationDevicesSection: View {
    let model: OrganizationPersonViewModel
    let confirm: (OrganizationPersonConfirmation) -> Void

    var body: some View {
        Section {
            if let message = model.devicesMessage {
                Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if let devices = model.devices {
                if devices.isEmpty {
                    Text("No devices").foregroundStyle(.bloemMuted)
                }
                ForEach(devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(OrganizationText.deviceName(device.name)).bloemText(.titleMedium)
                        Text(details(device)).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                        if !device.lastSeenAt.isEmpty {
                            Text("Last seen \(OrganizationText.when(device.lastSeenAt))").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                        Button(role: .destructive) { confirm(.signOutDevice(device)) } label: {
                            Text("Sign out of this device").frame(minHeight: 44, alignment: .leading)
                        }
                        .buttonStyle(.bloemQuiet)
                        .disabled(model.isPending)
                        .accessibilityLabel(String(localized: "Sign out of \(OrganizationText.deviceName(device.name))"))
                    }
                    .accessibilityIdentifier("organization-device-\(device.deviceID)")
                }
            } else if model.devicesMessage == nil {
                ProgressView()
            }
        } header: {
            Text("Devices")
        }
    }

    private func details(_ device: SupportDevice) -> String {
        let profiles = device.profiles.map(\.profileName).filter { !$0.isEmpty }.joined(separator: ", ")
        return [device.platform.isEmpty ? nil : OrganizationText.platform(device.platform), profiles.isEmpty ? nil : profiles]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - Profiles

/// What the profile editor is asked to do.
enum OrganizationProfileEdit: Identifiable, Equatable {
    case add
    case rename(ProfileSummary)

    var id: String {
        switch self {
        case .add: "add"
        case .rename(let profile): "rename-" + profile.id
        }
    }
}

/// Name a new profile (and choose its access group), or rename one. The administrator never sets a PIN or age limits.
struct OrganizationProfileNameSheet: View {
    let edit: OrganizationProfileEdit
    let groups: [OrganizationAccessGroup]
    let onSave: @MainActor (String, Int64?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var groupID: Int64?

    static let maxLength = 100

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { !trimmed.isEmpty && trimmed.count <= Self.maxLength }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Profile name", text: $name)
                        .textInputAutocapitalization(.words)
                        .accessibilityIdentifier("organization-profile-name")
                } footer: {
                    if trimmed.count > Self.maxLength {
                        Text("Use at most \(Self.maxLength) characters")
                    } else if case .add = edit {
                        Text("They set a PIN on the profile themselves, if they want one")
                    }
                }
                if case .add = edit, !groups.isEmpty {
                    Section("Access group") {
                        Picker("Access group", selection: $groupID) {
                            Text("Same as their other profiles").tag(Int64?.none)
                            ForEach(groups, id: \.id) { group in
                                Text(group.name).tag(group.numericID)
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
            }
            .navigationTitle(isAdding ? String(localized: "Add profile") : String(localized: "Rename profile"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isAdding ? String(localized: "Add") : String(localized: "Save changes")) {
                        onSave(trimmed, isAdding ? groupID : nil)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
        .onAppear {
            if case .rename(let profile) = edit { name = profile.name }
        }
    }

    private var isAdding: Bool {
        if case .add = edit { return true }
        return false
    }
}
