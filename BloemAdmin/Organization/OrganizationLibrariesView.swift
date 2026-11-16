import SwiftUI

/// Libraries & Entitlements: the libraries this organization owns, and the ones the server shares with it. A shared
/// library can be paused, restored, or given back for good. Nothing about the server's own storage is shown here.
struct OrganizationLibrariesView: View {
    let session: OrganizationSession
    @State private var model = OrganizationLibrariesViewModel()
    @State private var pendingPause: OrganizationLibrary?
    @State private var pendingRestore: OrganizationLibrary?
    @State private var pendingGiveBack: OrganizationLibrary?

    private var owned: [OrganizationLibrary] { model.libraries.filter(\.isOwned) }
    private var shared: [OrganizationLibrary] { model.libraries.filter { !$0.isOwned } }

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.libraries.isEmpty,
            emptyTitle: String(localized: "Libraries"), emptyMessage: String(localized: "This organization has no libraries yet"),
            emptyIcon: .library, errorMessage: model.errorMessage, noticeMessage: model.notice,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: { model.dismissMessages() }
        ) {
            ceilingSection
            if !owned.isEmpty {
                Section {
                    ForEach(owned) { library in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(library.name).bloemText(.titleMedium)
                            if !library.type.isEmpty {
                                Text(OrganizationVocabulary.sentenceCase(library.type)).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                            }
                            Text("Always available to this organization's members")
                                .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Owned by this organization")
                }
            }
            if !shared.isEmpty {
                Section {
                    ForEach(shared) { library in
                        sharedRow(library)
                    }
                } header: {
                    Text("Shared by the server")
                } footer: {
                    Text("Libraries this organization owns, and libraries the server shares with it.")
                }
            }
        }
        .accessibilityIdentifier("organization-page-libraries")
        .task { await model.load(session: session) }
        .refreshable { await model.load(session: session) }
        .confirmationDialog(
            pendingPause.map { String(localized: "Pause \($0.name)?") } ?? "",
            isPresented: Binding(get: { pendingPause != nil }, set: { if !$0 { pendingPause = nil } }),
            titleVisibility: .visible, presenting: pendingPause
        ) { library in
            Button("Pause", role: .destructive) { Task { await model.setStatus(session: session, library: library, status: "suspended") } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Members can't use this library until you restore it. No files are deleted.")
        }
        .confirmationDialog(
            pendingRestore.map { String(localized: "Restore \($0.name)?") } ?? "",
            isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }),
            titleVisibility: .visible, presenting: pendingRestore
        ) { library in
            Button("Restore") { Task { await model.setStatus(session: session, library: library, status: "active") } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Members can use this library again, within their own plan and profile limits.")
        }
        .confirmationDialog(
            pendingGiveBack.map { String(localized: "Give back \($0.name)?") } ?? "",
            isPresented: Binding(get: { pendingGiveBack != nil }, set: { if !$0 { pendingGiveBack = nil } }),
            titleVisibility: .visible, presenting: pendingGiveBack
        ) { library in
            Button("Give back", role: .destructive) { Task { await model.giveBack(session: session, library: library) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Members lose this library for good. Only a platform administrator can share it again. No files are deleted.")
        }
    }

    /// What members can reach at most right now, so a paused library is not mistaken for a usable one.
    private var ceilingSection: some View {
        let usable = model.libraries.filter(\.countsTowardCeiling).count
        let paused = shared.filter { $0.entitlement?.status == "suspended" }.count
        let withdrawn = shared.filter { $0.entitlement?.status == "revoked" }.count
        let active = shared.filter { $0.entitlement?.status == "active" }.count
        var breakdown: [String] = [String(localized: "\(owned.count) owned"), String(localized: "\(active) shared and active")]
        if paused > 0 { breakdown.append(String(localized: "\(paused) paused")) }
        if withdrawn > 0 { breakdown.append(String(localized: "\(withdrawn) withdrawn")) }
        return Section {
            Text(usable == 1 ? String(localized: "\(usable) library members can use now") : String(localized: "\(usable) libraries members can use now"))
                .bloemText(.titleMedium)
            Text(breakdown.joined(separator: " · "))
                .bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
        } header: {
            Text("Most your members can reach")
        } footer: {
            Text("These are the most this organization's members can see. Each person's plan, access group and profile can narrow it further.")
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sharedRow(_ library: OrganizationLibrary) -> some View {
        let status = library.entitlement?.status ?? "revoked"
        let busy = model.pendingFolderIDs.contains(library.folderID)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(library.name).bloemText(.titleMedium)
                Spacer(minLength: 8)
                switch status {
                case "active": StatusLabel("Active", tone: .positive)
                case "suspended": StatusLabel("Paused", tone: .warning)
                default: StatusLabel("Withdrawn")
                }
            }
            Text(statusLine(status)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            if library.entitlement != nil && status != "revoked" {
                OrganizationFlowLayout(spacing: 8) {
                    if status == "active" {
                        Button("Pause") { pendingPause = library }
                            .accessibilityLabel(Text("Pause for \(library.name)"))
                    } else {
                        Button("Restore") { pendingRestore = library }
                            .accessibilityLabel(Text("Restore for \(library.name)"))
                    }
                    Button("Give back", role: .destructive) { pendingGiveBack = library }
                        .accessibilityLabel(Text("Give back for \(library.name)"))
                }
                .buttonStyle(.bloemSecondary)
                .disabled(busy)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusLine(_ status: String) -> String {
        switch status {
        case "active": String(localized: "Members can use it")
        case "suspended": String(localized: "Paused: members can't use it until it is restored")
        default: String(localized: "Withdrawn")
        }
    }
}
