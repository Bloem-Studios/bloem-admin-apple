import SwiftUI

/// Access & limits: the access group, libraries, permissions and limits of one account, edited in
/// one ETag-guarded save. The form is the page's `UserAccessDraft`, so switching tabs keeps an
/// edit. Saving sends the ETag the page was read with; on a conflict (412, or 428) the page reads
/// the account again, which resets the form to the server's values, and the conflict message stays.
struct UserAccessTab: View {
    let model: UserDetailViewModel
    let user: AdminUser
    let actions: UserActions

    private var editable: Bool { actions.policyManageable }
    private var canEdit: Bool { editable && model.validator != nil && !model.isBusy }
    private var draft: UserAccessDraft { model.accessDraft }
    private var groupList: [AccessGroup] { model.groups.value ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !editable {
                Text(actions.manageable
                     ? "Only the server owner can change an admin's access and limits."
                     : "You can view this account's access and limits but not change them.")
                    .foregroundStyle(.bloemMuted)
            }
            summary
            groupSection
            librariesSection
            permissionsSection
            limitsSection
            footer
        }
        .task { await model.loadAccessChoices() }
    }

    // MARK: - Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let ids = user.effectivePolicy?.libraryIDs {
                Text("Effective libraries: Restricted to \(ids.count)")
            } else {
                Text("Effective libraries: Unrestricted")
            }
            if let permissions = user.effectivePolicy?.permissions {
                Text("Effective permissions: \(permissions.count) assigned")
            } else {
                Text("Effective permissions: None assigned")
            }
        }
    }

    // MARK: - Access group

    @ViewBuilder
    private var groupSection: some View {
        DetailCard(String(localized: "Access group")) {
            choicesStatus
            if user.role == "admin" {
                Text("Admins don't use access groups. Unset values follow the server default.")
                    .foregroundStyle(.bloemMuted)
            } else {
                let pickable = canEdit && model.groups.value != nil
                ChoiceRow(selected: draft.access.groupID == nil, label: String(localized: "No group"), isEnabled: pickable) {
                    model.editAccess { $0.access.groupID = nil }
                }
                ForEach(groupList) { group in
                    ChoiceRow(selected: draft.access.groupID == group.id, label: group.name, isEnabled: pickable) {
                        model.editAccess { $0.access.groupID = group.id }
                    }
                }
                // A group the list does not have (deleted since): still shown, so the form says what is saved.
                if let id = draft.access.groupID, !groupList.contains(where: { $0.id == id }) {
                    ChoiceRow(selected: true, label: String(localized: "Group \(id)"), isEnabled: false) {}
                }
                if let picked = groupList.first(where: { $0.id == draft.access.groupID }) {
                    Text(groupSummary(picked)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
        }
    }

    @ViewBuilder
    private var choicesStatus: some View {
        if let failure = model.groups.failure ?? model.libraries.failure {
            Text(failure).foregroundStyle(.bloemDanger)
            Button("Try again") { Task { await model.loadAccessChoices() } }
                .frame(minHeight: 44)
        } else if model.groups.value == nil || model.libraries.value == nil {
            Text("Loading groups and libraries…").foregroundStyle(.bloemMuted)
        }
    }

    private func groupSummary(_ group: AccessGroup) -> String {
        var parts: [String] = []
        if let libraries = model.libraries.value { parts.append(libraryListText(group.libraryIDs, libraries)) }
        if !group.maxPlaybackQuality.isEmpty { parts.append(group.maxPlaybackQuality) }
        parts.append(group.maxStreams == 0 ? String(localized: "unlimited streams") : String(localized: "\(group.maxStreams) streams"))
        return "\(group.name): \(parts.joined(separator: " · "))"
    }

    // MARK: - Libraries

    private func libraryListText(_ ids: [String]?, _ libraries: [LibraryChoice]) -> String {
        guard let ids else { return String(localized: "All libraries") }
        if ids.isEmpty { return String(localized: "No libraries") }
        return ids.map { id in libraries.first { $0.id == id }?.name ?? "#\(id)" }.joined(separator: ", ")
    }

    private var inheritedLibrariesText: String? {
        let inherited = AccessPolicy.inheritedLibraries(
            role: user.role, draftGroupID: draft.access.groupID, savedGroupID: user.accessGroupID,
            inheritsNow: user.libraryIDs == nil, effectiveLibraryIDs: user.effectivePolicy?.libraryIDs,
            groups: model.groups.value, defaults: model.policyDefaults.value
        )
        switch inherited {
        case .unknown: return nil
        case .all: return String(localized: "All libraries")
        case .some(let ids):
            if let libraries = model.libraries.value { return libraryListText(ids, libraries) }
            return ids.isEmpty ? String(localized: "No libraries") : nil
        }
    }

    @ViewBuilder
    private var librariesSection: some View {
        DetailCard(String(localized: "Libraries")) {
            let choosing = draft.access.libraryIDs != nil
            let fromGroup = AccessPolicy.inheritsFromGroup(role: user.role, draftGroupID: draft.access.groupID)
            ChoiceRow(
                selected: !choosing,
                label: fromGroup ? String(localized: "Use the group's libraries") : String(localized: "Use the server default"),
                detail: inheritedLibrariesText,
                isEnabled: canEdit
            ) {
                model.editAccess { $0.access.libraryIDs = nil }
            }
            ChoiceRow(
                selected: choosing,
                label: String(localized: "Choose for this account"),
                isEnabled: canEdit && model.libraries.value != nil
            ) {
                // Start from what the account can see now, so choosing changes nothing until a library is toggled.
                let seeing = user.effectivePolicy?.libraryIDs ?? model.libraries.value?.map(\.id) ?? []
                model.editAccess { $0.access.libraryIDs = seeing }
            }
            if let selected = draft.access.libraryIDs, let libraries = model.libraries.value {
                let all = libraries.map(\.id)
                ForEach(libraries) { library in
                    Toggle(library.name, isOn: Binding(
                        get: { selected.contains(library.id) },
                        set: { on in
                            model.editAccess { $0.access.libraryIDs = AccessPolicy.toggleLibrary(selected: selected, all: all, id: library.id, on: on) }
                        }
                    ))
                    .disabled(!canEdit)
                    .frame(minHeight: 44)
                    .padding(.leading, 24)
                }
                if selected.isEmpty {
                    Text("This account won't see any library").foregroundStyle(.bloemWarn)
                }
            }
        }
    }

    // MARK: - Permissions

    private func permissionTitle(_ permission: AssignablePermission) -> String {
        switch permission {
        case .markerEdit: String(localized: "Marker editing")
        case .metadataCuration: String(localized: "Metadata curation")
        case .watchLiveTV: String(localized: "Watch live TV")
        }
    }

    private func permissionHelp(_ permission: AssignablePermission) -> String {
        switch permission {
        case .markerEdit: String(localized: "Intro, recap, credits, and preview markers")
        case .metadataCuration: String(localized: "Edit, refresh, and rematch metadata")
        case .watchLiveTV: String(localized: "Watch channels and manage recordings. Independent of library access; group restrictions still apply.")
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        DetailCard(String(localized: "Permissions")) {
            ForEach(AssignablePermission.allCases) { permission in
                let lock = AccessPolicy.permissionLock(
                    role: user.role, groupID: draft.access.groupID, groups: groupList, permission: permission.rawValue
                )
                let assigned = draft.access.permissions.contains(permission.rawValue)
                let title = permissionTitle(permission)
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                        Text(permissionNote(permission, lock: lock, assigned: assigned))
                            .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        if lock.locked {
                            Text("\(lock.groupName ?? "") group doesn't allow this")
                                .bloemText(.bodySmall).foregroundStyle(.bloemWarn)
                        }
                    }
                    Spacer(minLength: 0)
                    if lock.locked && assigned {
                        Button("Remove from account") {
                            model.editAccess { $0.access.permissions = AccessPolicy.setAssignedPermission($0.access.permissions, permission.rawValue, on: false) }
                        }
                        .bloemText(.bodySmall)
                        .frame(minHeight: 44)
                        .disabled(!canEdit)
                        .accessibilityLabel("\(title): Remove from account")
                    }
                    // A locked switch shows what applies: off.
                    Toggle(title, isOn: Binding(
                        get: { assigned && !lock.locked },
                        set: { on in
                            model.editAccess { $0.access.permissions = AccessPolicy.setAssignedPermission($0.access.permissions, permission.rawValue, on: on) }
                        }
                    ))
                    .labelsHidden()
                    .disabled(!canEdit || lock.locked)
                }
                .frame(minHeight: 44)
            }
        }
    }

    private func permissionNote(_ permission: AssignablePermission, lock: PermissionLock, assigned: Bool) -> String {
        if lock.locked && assigned {
            return String(localized: "Set on this account; has no effect under \(lock.groupName ?? "")")
        }
        if !lock.locked, let name = lock.groupName {
            return String(localized: "The \(name) group allows this")
        }
        return permissionHelp(permission)
    }

    // MARK: - Limits

    @ViewBuilder
    private var limitsSection: some View {
        DetailCard(String(localized: "Limits")) {
            limitRow(String(localized: "Max streams"), text: \.limits.maxStreamsText, inherited: \.limits.maxStreamsInherited)
            limitRow(String(localized: "Max transcodes"), text: \.limits.maxTranscodesText, inherited: \.limits.maxTranscodesInherited)
            limitRow(String(localized: "Max profiles"), text: \.limits.maxProfilesText, inherited: \.limits.maxProfilesInherited)
            flagRow(String(localized: "Downloads allowed"), \.limits.downloadAllowed, effective: user.effectivePolicy?.downloadAllowed)
            flagRow(String(localized: "Requests allowed"), \.limits.requestsAllowed, effective: user.effectivePolicy?.requestsAllowed)
            flagRow(String(localized: "Transcode allowed"), \.limits.transcodeAllowed, effective: user.effectivePolicy?.transcodeAllowed)
            flagRow(String(localized: "Audio transcode allowed"), \.limits.audioTranscodeAllowed, effective: user.effectivePolicy?.audioTranscodeAllowed)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<UserAccessDraft, Value>) -> Binding<Value> {
        Binding(
            get: { model.accessDraft[keyPath: keyPath] },
            set: { newValue in model.editAccess { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func limitRow(
        _ title: String,
        text: WritableKeyPath<UserAccessDraft, String>,
        inherited: WritableKeyPath<UserAccessDraft, Bool>
    ) -> some View {
        let isInherited = model.accessDraft[keyPath: inherited]
        let value = model.accessDraft[keyPath: text]
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                TextField(title, text: Binding(
                    get: { model.accessDraft[keyPath: text] },
                    set: { newValue in model.editAccess { $0[keyPath: text] = newValue.filter(\.isNumber) } }
                ))
                .keyboardType(.numberPad)
                .disabled(!canEdit || isInherited)
                .foregroundStyle(!isInherited && Int(value) == nil ? Theme.danger : Color.primary)
                .frame(minHeight: 44)
                .accessibilityLabel(title)
            }
            Toggle("Inherit", isOn: binding(inherited))
                .toggleStyle(.switch)
                .fixedSize()
                .disabled(!canEdit)
                .accessibilityLabel("Inherit \(title)")
        }
    }

    private func flagRow(_ title: String, _ keyPath: WritableKeyPath<UserAccessDraft, PermissionState>, effective: Bool?) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            Picker(title, selection: binding(keyPath)) {
                // The inherit label says what inheriting means right now, so it is never a guess.
                Text(PermissionState.inherit.displayLabel(effectiveValue: effective)).tag(PermissionState.inherit)
                Text("Off").tag(PermissionState.off)
                Text("On").tag(PermissionState.on)
            }
            .pickerStyle(.menu)
            .disabled(!canEdit)
        }
        .frame(minHeight: 44)
    }

    // MARK: - Save

    @ViewBuilder
    private var footer: some View {
        if editable && model.validator == nil {
            Text("This server did not return a version for this user, so the change was not sent.")
                .foregroundStyle(.bloemDanger)
        }
        switch model.accessOutcome {
        case .saved: Text("Saved").foregroundStyle(.bloemOK)
        case .failed(let message): Text(message).foregroundStyle(.bloemDanger)
        case nil: EmptyView()
        }
        if editable {
            Button {
                Task { await model.saveAccess() }
            } label: {
                Text("Save changes").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bloemProminent)
            .frame(minHeight: 44)
            .disabled(!canEdit || !model.isAccessDirty)
        }
    }
}
