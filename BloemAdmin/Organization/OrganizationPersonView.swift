import SwiftUI

/// One person: the membership, each profile with its access group, and the changes made to this membership found
/// in the organization's newest activity (the server has no per-person activity route). Organization administrators
/// can suspend or reactivate a membership and move a profile to an access group. On a server with organization
/// support they can also send a reset link, sign the person out and edit their profiles; on an older server the page
/// says those are not available.
struct OrganizationPersonView: View {
    let session: OrganizationSession
    let route: OrganizationPersonRoute
    var onChanged: () -> Void = {}
    @State private var model = OrganizationPersonViewModel()
    @State private var pendingSuspend = false
    @State private var pendingReactivate = false
    @State private var profileEdit: OrganizationProfileEdit?
    /// The support action waiting for its confirmation; one dialog for all of them, outside the list's rows.
    @State private var confirming: OrganizationPersonConfirmation?

    var body: some View {
        List {
            if let notice = model.notice {
                Section { OrganizationMessageBanner(text: notice, isError: false, onDismiss: { model.dismissMessages() }) }
            }
            if let error = model.errorMessage {
                Section { OrganizationMessageBanner(text: error, isError: true, onDismiss: { model.dismissMessages() }) }
            }
            if model.isGone {
                Section {
                    Text("This person isn't in this organization any more").foregroundStyle(.bloemMuted)
                        .accessibilityIdentifier("organization-person-gone")
                }
            }
            if let person = model.person {
                let isSelf = person.isSelf(in: session.context)
                Section {
                    OrganizationPersonSummaryView(person: person, isSelf: isSelf)
                        .accessibilityElement(children: .combine)
                }
                Section("Membership") {
                    LabeledContent("Status") {
                        StatusLabel(OrganizationText.status(person.membershipStatus), tone: OrganizationText.statusTone(person.membershipStatus))
                    }
                    Text("Account \(Int(person.accountID)) · revision \(Int(person.securityRevision))")
                        .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    if person.isSuspended {
                        Button("Reactivate") { pendingReactivate = true }
                            .disabled(model.isPending)
                    } else if !isSelf {
                        Button("Suspend", role: .destructive) { pendingSuspend = true }
                            .disabled(model.isPending)
                    }
                }
                if model.support.offersPasswordReset && !isSelf {
                    OrganizationResetSection(model: model, person: person) { confirming = $0 }
                }
                Section("Profiles and access groups") {
                    if person.profiles.isEmpty {
                        Text("No profiles").foregroundStyle(.bloemMuted)
                    }
                    ForEach(person.profiles) { profile in
                        profileRow(person: person, profile: profile, isSelf: isSelf)
                    }
                    if model.support.profiles.add && !isSelf {
                        Button { profileEdit = .add } label: {
                            Label("Add profile", icon: .circlePlus).frame(minHeight: 44, alignment: .leading)
                        }
                        .disabled(model.isPending)
                        .accessibilityIdentifier("organization-add-profile")
                    }
                }
                if !isSelf {
                    if model.support.sessions {
                        OrganizationSignInsSection(model: model, session: session) { confirming = $0 }
                    }
                    if model.support.devices {
                        OrganizationDevicesSection(model: model) { confirming = $0 }
                    }
                }
                changesSection
                supportNote(isSelf: isSelf)
            }
        }
        .overlay {
            if model.isLoading && model.person == nil && !model.isGone { ProgressView("Loading…") }
        }
        .safeAreaInset(edge: .top, spacing: 0) { OrganizationSupportBanner(session: session) }
        .navigationTitle(model.person?.label ?? route.label)
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("organization-person-page")
        .task { await model.load(session: session, accountID: route.accountID) }
        .refreshable { await model.load(session: session, accountID: route.accountID) }
        .onDisappear { onChanged() }
        .confirmationDialog(
            String(localized: "Suspend \(model.person?.label ?? route.label)?"), isPresented: $pendingSuspend, titleVisibility: .visible
        ) {
            Button("Suspend", role: .destructive) { Task { await model.setSuspended(session: session, suspend: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They won't be able to use this organization until you reactivate them. Nothing is deleted.")
        }
        .confirmationDialog(
            String(localized: "Reactivate \(model.person?.label ?? route.label)?"), isPresented: $pendingReactivate, titleVisibility: .visible
        ) {
            Button("Reactivate") { Task { await model.setSuspended(session: session, suspend: false) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will be able to use this organization again")
        }
        .sheet(item: $profileEdit) { edit in
            OrganizationProfileNameSheet(edit: edit, groups: model.groups) { name, groupID in
                Task {
                    switch edit {
                    case .add: await model.addProfile(session: session, name: name, groupID: groupID)
                    case .rename(let profile): await model.renameProfile(session: session, profile: profile, to: name)
                    }
                }
            }
        }
        .sheet(item: Binding(get: { model.resetLink }, set: { if $0 == nil { model.dismissResetLink() } })) { link in
            OrganizationResetLinkSheet(link: link) { model.dismissResetLink() }
        }
        .confirmationDialog(
            confirming.map { $0.title(for: model.person ?? PersonSummary(accountID: route.accountID, membershipStatus: "", securityRevision: 0)) } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible,
            presenting: confirming
        ) { action in
            Button(action.actionTitle, role: action.isDestructive ? .destructive : nil) {
                Task { await action.perform(model: model, session: session) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            action.message
        }
    }

    @ViewBuilder
    private func profileRow(person: PersonSummary, profile: ProfileSummary, isSelf: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(profile.name).bloemText(.titleMedium)
            Text("Access group: \(profile.groupName.isEmpty ? String(profile.groupID) : profile.groupName)")
                .bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            if profile.isPrimary || profile.hasPIN {
                Text(profileFacts(profile)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if !profile.updatedAt.isEmpty {
                Text("Changed \(OrganizationText.when(profile.updatedAt))").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            Menu {
                ForEach(model.groups, id: \.id) { group in
                    Button(group.name) {
                        Task { await model.assignGroup(session: session, profile: profile, group: group) }
                    }
                    .disabled(group.numericID == profile.groupID)
                }
            } label: {
                Label("Move \(profile.name) to an access group", icon: .circleArrowRight)
                    .frame(minHeight: 44, alignment: .leading)
            }
            .disabled(model.isPending || model.groups.isEmpty)
            if !isSelf && profile.revision > 0 && hasProfileEdits(profile) {
                Menu {
                    if model.support.profiles.rename {
                        Button { profileEdit = .rename(profile) } label: { Label("Rename…", icon: .pencil) }
                    }
                    if model.support.profiles.clearPIN && profile.hasPIN {
                        Button { confirming = .clearPIN(profile) } label: { Label("Clear PIN", icon: .lockOpen) }
                    }
                    if model.support.profiles.remove && !profile.isPrimary {
                        Button(role: .destructive) { confirming = .removeProfile(profile) } label: { Label("Remove profile…", icon: .trash2) }
                    }
                } label: {
                    Label("Change \(profile.name)", icon: .slidersHorizontal)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .disabled(model.isPending)
                .accessibilityIdentifier("organization-profile-actions-\(profile.id)")
            }
        }
        .padding(.vertical, 4)
    }

    private func hasProfileEdits(_ profile: ProfileSummary) -> Bool {
        model.support.profiles.rename || (model.support.profiles.clearPIN && profile.hasPIN)
            || (model.support.profiles.remove && !profile.isPrimary)
    }

    private func profileFacts(_ profile: ProfileSummary) -> String {
        [
            profile.isPrimary ? String(localized: "Main profile") : nil,
            profile.hasPIN ? String(localized: "PIN set") : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    /// On a server with organization support: who may be helped, and that nobody helps themselves here. On an older
    /// server: what the page cannot do.
    @ViewBuilder
    private func supportNote(isSelf: Bool) -> some View {
        if model.support.offersPersonSupport {
            Section {
                if isSelf {
                    Text("This is your own account. Change your password and sign out in the app; nobody resets or signs themselves out here.")
                        .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                Text("Administrators help ordinary members. The organization's owner can also help its other administrators, and only the platform operator helps the owner. If the server refuses, it says why.")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            } header: {
                Text("Who you can help")
            }
        } else {
            Section {
                Text("Organization administrators can suspend or reactivate a membership and move a profile to an access group. Resetting a password, signing someone out and editing a profile aren't available to organization administrators; ask the server owner.")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            } header: {
                Text("What you can't do here")
            }
        }
    }

    @ViewBuilder
    private var changesSection: some View {
        Section {
            if model.changesUnavailable {
                Text("The organization's activity couldn't be loaded, so recent changes can't be shown.")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            } else if model.changes.isEmpty {
                Text("No changes to this membership among the latest \(model.changesLooked) on the organization.")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            } else {
                ForEach(model.changes) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(OrganizationVocabulary.auditActionText(event.action)).bloemText(.bodyMedium)
                        Text(OrganizationText.when(event.createdAt)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("Changes to this membership among the latest \(model.changesLooked) on the organization")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        } header: {
            Text("Recent changes")
        }
    }
}
