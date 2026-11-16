import SwiftUI

/// Access groups: create, edit and delete. Writes quote the organization's policy revision and are sent once; the
/// default group and groups a plan manages are refused by the server, and its refusal is shown in the app's words.
struct OrganizationGroupsView: View {
    let session: OrganizationSession
    @State private var model = OrganizationGroupsViewModel()
    @State private var showsNewGroup = false
    @State private var newName = ""
    /// The group "New group" just made, opened so it can be filled in.
    @State private var createdGroupID: String?

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.groups.isEmpty,
            emptyTitle: String(localized: "Access groups"), emptyMessage: String(localized: "No access groups yet"),
            emptyIcon: .usersRound, errorMessage: model.errorMessage, noticeMessage: noticeText,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: { model.dismissMessages() }
        ) {
            Section {
                ForEach(model.groups) { group in
                    // A destination view, not a value: see `OrganizationAdminShell.menu`.
                    NavigationLink {
                        OrganizationGroupEditorView(session: session, model: model, groupID: group.id)
                    } label: {
                        OrganizationGroupRow(group: group)
                    }
                }
            } footer: {
                Text("Groups that decide what each profile can use. Create, edit and delete them here.")
            }
        }
        .accessibilityIdentifier("organization-page-groups")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { newName = ""; showsNewGroup = true } label: { Label("New group", icon: .plus) }
                    .disabled(model.isSaving)
            }
            .bloemFlat()
        }
        .task { await model.load(session: session) }
        .refreshable { await model.load(session: session) }
        .onChange(of: model.createdID) { _, id in
            // The group "New group" just made opens, ready to be filled in.
            if let id {
                createdGroupID = id
                model.consumeCreated()
            }
        }
        .navigationDestination(item: $createdGroupID) { id in
            OrganizationGroupEditorView(session: session, model: model, groupID: id)
        }
        .alert("New group", isPresented: $showsNewGroup) {
            TextField("Group name", text: $newName)
            Button("Create") { Task { await model.create(session: session, name: newName) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New group name")
        }
    }

    private var noticeText: String? {
        guard let notice = model.notice else { return nil }
        if let impact = model.lastDeletion, impact.profilesReassigned > 0 {
            let moved = impact.profilesReassigned == 1
                ? String(localized: "\(impact.profilesReassigned) profile moved to the default group")
                : String(localized: "\(impact.profilesReassigned) profiles moved to the default group")
            return "\(notice) \(moved)"
        }
        return notice
    }
}

private struct OrganizationGroupRow: View {
    let group: OrganizationAccessGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(group.name).bloemText(.titleMedium)
                if group.isDefault { StatusLabel("Default") }
            }
            Text(OrganizationText.members(Int(group.memberCount))).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            Text(summary).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        var parts: [String] = []
        parts.append(group.maxStreams > 0 ? String(localized: "Streams: \(Int(group.maxStreams))") : String(localized: "Streams: No limit"))
        parts.append(String(localized: "Quality: \(OrganizationVocabulary.qualityText(PlaybackQuality.canonical(group.maxPlaybackQuality)))"))
        if group.downloadAllowed { parts.append(String(localized: "Downloads")) }
        if group.transcodeAllowed { parts.append(String(localized: "Transcoding")) }
        if group.requestsAllowed { parts.append(String(localized: "Requests")) }
        return parts.joined(separator: " · ")
    }
}

/// The group as an editable form. Fields the form does not show are written back unchanged.
struct OrganizationGroupEditorView: View {
    let session: OrganizationSession
    let model: OrganizationGroupsViewModel
    let groupID: String
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AccessGroupDraft?
    @State private var original: OrganizationAccessGroup?
    @State private var showsDelete = false

    private var group: OrganizationAccessGroup? { model.groups.first { $0.id == groupID } }

    var body: some View {
        Form {
            if let message = model.errorMessage {
                Section { OrganizationMessageBanner(text: message, isError: true, onDismiss: { model.dismissMessages() }) }
            }
            if let draftBinding = Binding($draft), let group = original ?? self.group {
                editor(draftBinding, group: group)
            } else {
                ProgressView()
            }
        }
        .navigationTitle(draft?.name ?? original?.name ?? String(localized: "Access groups"))
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("organization-group-editor")
        .onAppear { prepare() }
        .onChange(of: model.groups) { _, _ in prepare() }
        .confirmationDialog(
            String(localized: "Delete “\(deleteTitleName)”?"), isPresented: $showsDelete, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let target = original ?? group {
                    Task {
                        if await model.delete(session: session, group: target) { dismiss() }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(deleteMessage(original ?? group))
        }
    }

    private var deleteTitleName: String { original?.name ?? "" }

    /// Takes the group from the list the first time it is there. After a reload (each write reloads the list), a
    /// group the server now holds differently replaces the draft, so a later save never sends values another
    /// administrator has since changed, hidden fields included. An unchanged group keeps what is being typed.
    private func prepare() {
        guard let next = AccessGroupDraft.reconciled(draft: draft, original: original, reloaded: group) else { return }
        original = next.original
        draft = next.draft
    }

    @ViewBuilder
    private func editor(_ draft: Binding<AccessGroupDraft>, group: OrganizationAccessGroup) -> some View {
        Section {
            TextField("Name", text: draft.name)
            TextField("Description", text: draft.description, prompt: Text("Optional"))
            Toggle("Default for new users", isOn: draft.isDefault)
                .disabled(group.isDefault)
        } footer: {
            if group.isDefault {
                Text("Newly created accounts are placed in this group automatically. To change this, make another group the default.")
            } else {
                Text("Newly created accounts are placed in this group automatically. Existing users are never moved.")
            }
        }

        Section {
            Picker("Libraries", selection: allLibrariesBinding(draft)) {
                Text("Every library the organization can use").tag(true)
                Text("Only the libraries I choose").tag(false)
            }
            .pickerStyle(.inline)
            .labelsHidden()
            if draft.wrappedValue.libraryIDs != nil {
                ForEach(model.libraries) { library in
                    let id = String(library.folderID)
                    let usable = library.countsTowardCeiling
                    Toggle(isOn: libraryBinding(draft, id: id)) {
                        Text(usable ? library.name : String(localized: "\(library.name) (paused or withdrawn)"))
                    }
                    .disabled(!usable && !(draft.wrappedValue.libraryIDs?.contains(id) ?? false))
                }
            }
            Picker("Best picture quality", selection: qualityBinding(draft)) {
                ForEach(qualityChoices(draft.wrappedValue.maxPlaybackQuality), id: \.self) { value in
                    Text(OrganizationVocabulary.qualityText(value)).tag(value)
                }
            }
        } header: {
            Text("Libraries & playback")
        } footer: {
            Text("A group can use only libraries the organization can use. A paused or withdrawn shared library can't be given to a group.")
        }

        Section {
            Stepper(value: draft.maxStreams, in: 0...64) {
                LabeledContent("Concurrent streams") {
                    Text(draft.wrappedValue.maxStreams == 0 ? String(localized: "0 = unlimited") : String(draft.wrappedValue.maxStreams))
                }
            }
            Toggle("Video conversion", isOn: draft.transcodeAllowed)
            Toggle("Audio conversion", isOn: draft.audioTranscodeAllowed)
            Stepper(value: draft.maxTranscodes, in: 0...64) {
                LabeledContent("Conversions at once") {
                    Text(draft.wrappedValue.maxTranscodes == 0 ? String(localized: "0 = unlimited") : String(draft.wrappedValue.maxTranscodes))
                }
            }
        } footer: {
            Text("Convert a video when the device can't play the file as it is")
        }

        Section {
            Toggle("Download original files", isOn: draft.downloadAllowed)
            Toggle("Download converted copies", isOn: draft.downloadTranscodeAllowed)
                .disabled(!draft.wrappedValue.downloadAllowed)
            Toggle("Media requests", isOn: draft.requestsAllowed)
        } header: {
            Text("Downloads & requests")
        } footer: {
            Text("Ask for movies and shows the server doesn't have yet")
        }

        Section {
            Toggle("Allow every permission", isOn: allPermissionsBinding(draft))
            if draft.wrappedValue.allowedPermissions != nil {
                ForEach(GroupPermissions.all, id: \.self) { permission in
                    Toggle(OrganizationVocabulary.permissionText(permission), isOn: permissionBinding(draft, permission))
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("A member also needs the permission granted on their own account")
        }

        Section {
            Button {
                Task { await model.save(session: session, group: group, draft: draft.wrappedValue) }
            } label: {
                if model.isSaving { Text("Saving…") } else { Text("Save changes") }
            }
            .accessibilityIdentifier("organization-group-save")
            .disabled(model.isSaving || draft.wrappedValue.name.trimmingCharacters(in: .whitespaces).isEmpty)
            if let notice = model.notice {
                Text(notice).bloemText(.bodySmall).foregroundStyle(.bloemOK)
            }
        }

        Section {
            Button("Delete group", role: .destructive) { showsDelete = true }
                .disabled(group.isDefault || model.isSaving)
        } footer: {
            if group.isDefault {
                Text("The default group can't be deleted. Make another group the default first.")
            }
        }
    }

    private func deleteMessage(_ group: OrganizationAccessGroup?) -> String {
        guard let group else { return "" }
        let count = Int(group.memberCount)
        let organization = String(localized: "this organization")
        if count <= 0 { return String(localized: "This group has no profiles in \(organization). This can't be undone.") }
        let name = group.name
        let target = String(localized: "the default group")
        return count == 1
            ? String(localized: "\(count) profile in \(name) will be reassigned to \(target), this organization's default group. Their own restrictions are unchanged.")
            : String(localized: "\(count) profiles in \(name) will be reassigned to \(target), this organization's default group. Their own restrictions are unchanged.")
    }

    /// The server stores `""`, `1080p` and `2160p`; anything else it sent stays a choice until another is picked.
    private func qualityChoices(_ current: String) -> [String] {
        PlaybackQuality.choices.contains(current) ? PlaybackQuality.choices : [current] + PlaybackQuality.choices
    }

    private func qualityBinding(_ draft: Binding<AccessGroupDraft>) -> Binding<String> {
        Binding(
            get: { draft.wrappedValue.maxPlaybackQuality },
            set: { draft.wrappedValue.maxPlaybackQuality = $0 }
        )
    }

    private func allLibrariesBinding(_ draft: Binding<AccessGroupDraft>) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.libraryIDs == nil },
            set: { everyLibrary in
                if everyLibrary {
                    draft.wrappedValue.libraryIDs = nil
                } else if draft.wrappedValue.libraryIDs == nil {
                    draft.wrappedValue.libraryIDs = Set(model.libraries.filter(\.countsTowardCeiling).map { String($0.folderID) })
                }
            }
        )
    }

    private func libraryBinding(_ draft: Binding<AccessGroupDraft>, id: String) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.libraryIDs?.contains(id) ?? true },
            set: { isOn in
                var chosen = draft.wrappedValue.libraryIDs ?? []
                if isOn { chosen.insert(id) } else { chosen.remove(id) }
                draft.wrappedValue.libraryIDs = chosen
            }
        )
    }

    private func allPermissionsBinding(_ draft: Binding<AccessGroupDraft>) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.allowedPermissions == nil },
            set: { all in draft.wrappedValue.allowedPermissions = all ? nil : (draft.wrappedValue.allowedPermissions ?? []) }
        )
    }

    private func permissionBinding(_ draft: Binding<AccessGroupDraft>, _ permission: String) -> Binding<Bool> {
        Binding(
            get: { draft.wrappedValue.allowedPermissions?.contains(permission) ?? true },
            set: { isOn in
                var chosen = draft.wrappedValue.allowedPermissions ?? []
                if isOn { chosen.insert(permission) } else { chosen.remove(permission) }
                draft.wrappedValue.allowedPermissions = chosen
            }
        )
    }
}
