import SwiftUI

/// Where a People row leads: one person's page.
struct OrganizationPersonRoute: Hashable {
    let accountID: Int64
    let label: String
}

/// People: search, status, access group, sort and recent-activity filters, suspend or reactivate, move a profile to
/// an access group, and the web's bulk actions. There is no password reset here: the server offers none to
/// organization administrators.
struct OrganizationPeopleView: View {
    let session: OrganizationSession
    @State private var model = OrganizationPeopleViewModel()
    @State private var draft = PeopleFilter()
    @State private var pendingSuspend: PersonSummary?
    @State private var pendingReactivate: PersonSummary?
    @State private var pendingBulk: BulkAction?
    @State private var openedPerson: OrganizationPersonRoute?

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.people.isEmpty && model.report == nil,
            emptyTitle: model.filter.isNarrowed ? String(localized: "Nobody matches these filters") : String(localized: "People"),
            emptyMessage: model.filter.isNarrowed ? String(localized: "Nobody matches these filters") : String(localized: "There is nobody in this organization yet"),
            emptyIcon: .users, errorMessage: model.errorMessage, noticeMessage: model.notice,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: { model.dismissMessages() }
        ) {
            filtersSection
            if let report = model.report {
                Section {
                    OrganizationBulkReportView(report: report) { model.dismissReport() }
                }
            }
            Section {
                ForEach(model.people) { person in
                    row(person)
                }
                if model.nextCursor != nil {
                    Button {
                        Task { await model.loadMore(session: session) }
                    } label: {
                        if model.isLoadingMore { ProgressView() } else { Text("Load more") }
                    }
                    .frame(minHeight: 44)
                    .disabled(model.isLoadingMore)
                }
            } header: {
                Text("About \(OrganizationText.people(Int(model.approximateTotal)))")
            } footer: {
                Text("Everyone in this organization. Change a profile's access group here, or select people to change several at once.")
            }
        }
        .accessibilityIdentifier("organization-page-people")
        .searchable(text: $draft.query, prompt: Text("Name, email or profile"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isSelecting {
                    Button("Done selecting") { model.stopSelecting() }
                        .disabled(model.isBulkRunning)
                } else {
                    Button("Select people") { model.startSelecting() }
                        .disabled(model.people.isEmpty)
                }
            }
            .bloemFlat()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isSelecting { bulkBar }
        }
        .task(id: draft) {
            // Typing waits for a pause; the other filters apply at once.
            if draft.query != model.filter.query {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            await model.load(session: session, filter: draft)
        }
        .task {
            // The task above reads on open and on a new filter. This one reads again when `org.people` says someone
            // changed; without the socket it does nothing, and the page is read on open and on pull as before.
            await OrganizationLive.follow(
                session: session, channel: .orgPeople, whenNotOffered: .readOnOpenOnly, readOnOpen: false,
                legacy: {}, refresh: { await model.load(session: session) }
            )
        }
        .refreshable { await model.load(session: session) }
        .navigationDestination(item: $openedPerson) { route in
            OrganizationPersonView(session: session, route: route, onChanged: { Task { await model.load(session: session) } })
        }
        .confirmationDialog(
            pendingSuspend.map { String(localized: "Suspend \($0.label)?") } ?? "",
            isPresented: Binding(get: { pendingSuspend != nil }, set: { if !$0 { pendingSuspend = nil } }),
            titleVisibility: .visible, presenting: pendingSuspend
        ) { person in
            Button("Suspend", role: .destructive) { Task { await model.setSuspended(session: session, person: person, suspend: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They won't be able to use this organization until you reactivate them. Nothing is deleted.")
        }
        .confirmationDialog(
            pendingReactivate.map { String(localized: "Reactivate \($0.label)?") } ?? "",
            isPresented: Binding(get: { pendingReactivate != nil }, set: { if !$0 { pendingReactivate = nil } }),
            titleVisibility: .visible, presenting: pendingReactivate
        ) { person in
            Button("Reactivate") { Task { await model.setSuspended(session: session, person: person, suspend: false) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("They will be able to use this organization again")
        }
        .confirmationDialog(
            bulkTitle(pendingBulk),
            isPresented: Binding(get: { pendingBulk != nil }, set: { if !$0 { pendingBulk = nil } }),
            titleVisibility: .visible, presenting: pendingBulk
        ) { action in
            Button("Apply", role: action == .suspend ? .destructive : nil) {
                Task { await model.apply(session: session, action: action) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(bulkMessage)
        }
    }

    // MARK: Filters

    private var statusLabel: String {
        draft.statuses.isEmpty
            ? String(localized: "Any status")
            : draft.statuses.sorted().map { OrganizationText.status($0) }.joined(separator: ", ")
    }

    private var groupLabel: String {
        guard let id = draft.groupID else { return String(localized: "Any access group") }
        return model.groups.first { $0.numericID == id }?.name ?? String(localized: "Group \(Int(id))")
    }

    private var sortLabel: String {
        switch draft.sort ?? PeopleSort.name {
        case PeopleSort.email: String(localized: "Email")
        case PeopleSort.recentActivity: String(localized: "Recent activity")
        default: String(localized: "Name")
        }
    }

    private var activeLabel: String {
        switch draft.activeWithinDays {
        case nil: String(localized: "Any time")
        case 1: String(localized: "Last 24 hours")
        case let days?: String(localized: "Last \(days) days")
        }
    }

    private var filtersSection: some View {
        Section {
            OrganizationFlowLayout(spacing: 8) {
                Menu {
                    ForEach([PersonSummary.membershipActive, PersonSummary.membershipSuspended, PersonSummary.membershipInvited], id: \.self) { status in
                        Toggle(OrganizationText.status(status), isOn: Binding(
                            get: { draft.statuses.contains(status) },
                            set: { isOn in if isOn { draft.statuses.insert(status) } else { draft.statuses.remove(status) } }
                        ))
                    }
                    Button("Any status") { draft.statuses = [] }
                } label: {
                    filterLabel("Membership status", statusLabel)
                }
                .accessibilityIdentifier("organization-filter-status")

                Menu {
                    Picker("Access group", selection: $draft.groupID) {
                        Text("Any access group").tag(Int64?.none)
                        ForEach(model.groups, id: \.id) { group in
                            Text(group.name).tag(group.numericID)
                        }
                    }
                } label: {
                    filterLabel("Access group", groupLabel)
                }
                .accessibilityIdentifier("organization-filter-group")
                .disabled(model.groups.isEmpty)

                Menu {
                    Picker("Sort people", selection: Binding(get: { draft.sort ?? PeopleSort.name }, set: { draft.sort = $0 })) {
                        Text("Name").tag(PeopleSort.name)
                        Text("Email").tag(PeopleSort.email)
                        Text("Recent activity").tag(PeopleSort.recentActivity)
                    }
                } label: {
                    filterLabel("Sort people", sortLabel)
                }
                .accessibilityIdentifier("organization-filter-sort")

                Menu {
                    Picker("Active since", selection: $draft.activeWithinDays) {
                        Text("Any time").tag(Int?.none)
                        Text("Last 24 hours").tag(Int?.some(1))
                        ForEach([7, 30, 90], id: \.self) { days in
                            Text("Last \(days) days").tag(Int?.some(days))
                        }
                    }
                } label: {
                    filterLabel("Active since", activeLabel)
                }
                .accessibilityIdentifier("organization-filter-active")
            }
            .buttonStyle(.bloemSecondary)
            .tint(Theme.text)
            .listRowSeparator(.hidden)
        }
    }

    private func filterLabel(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).bloemText(.labelSmall).foregroundStyle(.bloemMuted)
            Text(value).bloemText(.bodyMedium).lineLimit(1)
        }
        .frame(minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ person: PersonSummary) -> some View {
        let picked = model.pickedIDs.contains(person.accountID) || (model.matching != nil && model.isSelecting)
        let isSelf = person.isSelf(in: session.context)
        HStack(alignment: .top, spacing: 8) {
            Button {
                if model.isSelecting {
                    model.toggle(person.accountID)
                } else {
                    openedPerson = OrganizationPersonRoute(accountID: person.accountID, label: person.label)
                }
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    if model.isSelecting {
                        IconImage(picked ? .circleCheck : .circle, size: .bar)
                            .foregroundStyle(picked ? Theme.accent : Theme.muted)
                            .bloemText(.titleLarge)
                            .accessibilityHidden(true)
                    }
                    OrganizationPersonSummaryView(person: person, isSelf: isSelf)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .modifier(OrganizationRowSelectionAccessibility(isSelecting: model.isSelecting, isPicked: picked, label: person.label))

            if !model.isSelecting {
                actionsMenu(person, isSelf: isSelf)
            }
        }
        .accessibilityIdentifier("organization-person-\(person.accountID)")
    }

    private func actionsMenu(_ person: PersonSummary, isSelf: Bool) -> some View {
        Menu {
            Button("Details") { openedPerson = OrganizationPersonRoute(accountID: person.accountID, label: person.label) }
            if person.isSuspended {
                Button("Reactivate") { pendingReactivate = person }
            } else if !isSelf {
                Button("Suspend", role: .destructive) { pendingSuspend = person }
            }
            ForEach(person.profiles) { profile in
                Menu("Move \(profile.name) to an access group") {
                    ForEach(model.groups, id: \.id) { group in
                        Button(group.name) {
                            Task { await model.assignGroup(session: session, person: person, profile: profile, group: group) }
                        }
                        .disabled(group.numericID == profile.groupID)
                    }
                }
            }
        } label: {
            if model.pendingAccountIDs.contains(person.accountID) {
                ProgressView().frame(minWidth: 44, minHeight: 44)
            } else {
                RowActionsIcon()
            }
        }
        .disabled(model.pendingAccountIDs.contains(person.accountID) || model.isBulkRunning)
        .accessibilityLabel(Text("Actions for \(person.label)"))
        .accessibilityIdentifier("organization-person-actions-\(person.accountID)")
    }

    // MARK: Bulk

    /// The bulk actions wrap onto further lines on a narrow phone and sit in the safe area, so the list scrolls
    /// above them and a row is never covered.
    private var bulkBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.matching != nil
                 ? String(localized: "All \(OrganizationText.people(Int(model.selectedCount))) selected")
                 : (model.selectedCount == 1 ? String(localized: "\(Int(model.selectedCount)) person selected") : String(localized: "\(Int(model.selectedCount)) people selected")))
                .bloemText(.titleSmall)
                .accessibilityIdentifier("organization-bulk-count")
            OrganizationFlowLayout(spacing: 8) {
                if model.matching == nil {
                    Button {
                        Task { await model.selectAllMatching(session: session) }
                    } label: {
                        if model.isMakingSelection { Text("Selecting…") } else { Text("Select all \(Int(model.approximateTotal))") }
                    }
                    .disabled(model.isMakingSelection || model.isBulkRunning || model.approximateTotal == 0)
                    .accessibilityIdentifier("organization-bulk-select-all")
                }
                Menu("Move to access group") {
                    ForEach(model.groups, id: \.id) { group in
                        Button(group.name) { pendingBulk = .assignGroup(group) }
                    }
                }
                .disabled(!canApply || model.groups.isEmpty)
                .accessibilityIdentifier("organization-bulk-move")
                Button("Suspend") { pendingBulk = .suspend }
                    .disabled(!canApply)
                    .accessibilityIdentifier("organization-bulk-suspend")
                Button("Reactivate") { pendingBulk = .reactivate }
                    .disabled(!canApply)
                    .accessibilityIdentifier("organization-bulk-reactivate")
            }
            .buttonStyle(.bloemSecondary)
            .tint(Theme.text)
        }
        .padding(.horizontal)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Bulk people actions"))
        .accessibilityIdentifier("organization-bulk-bar")
    }

    private var canApply: Bool { model.hasSelection && !model.isBulkRunning && !model.isMakingSelection }

    private func bulkTitle(_ action: BulkAction?) -> String {
        switch action {
        case .suspend?: String(localized: "Suspend their memberships?")
        case .reactivate?: String(localized: "Reactivate their memberships?")
        case .assignGroup(let group)?: String(localized: "Move their profiles to \(group.name)?")
        case nil: ""
        }
    }

    private var filterDescription: String {
        var parts: [String] = []
        let query = model.filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { parts.append(String(localized: "matching “\(query)”")) }
        if let id = model.filter.groupID, let group = model.groups.first(where: { $0.numericID == id }) {
            parts.append(String(localized: "in \(group.name)"))
        }
        if let days = model.filter.activeWithinDays { parts.append(String(localized: "active in the last \(days) days")) }
        return parts.isEmpty ? String(localized: "everyone") : parts.joined(separator: ", ")
    }

    private var bulkMessage: String {
        let organization = session.context?.name ?? String(localized: "this organization")
        if let matching = model.matching {
            var text = String(localized: "This changes \(OrganizationText.people(Int(matching.matched))) in \(organization) (\(filterDescription)). People who match later are not included.")
            if matching.excluded > 0 { text += " " + String(localized: "\(Int(matching.excluded)) more match but are left out") }
            return text
        }
        return String(localized: "This changes the \(OrganizationText.people(model.pickedIDs.count)) you picked in \(organization), one after another")
    }
}

/// While people are being chosen, a row reads "Select <name>" with its state; otherwise it keeps the words of its content
/// (name, status, last activity, profiles), which the button combines for VoiceOver.
private struct OrganizationRowSelectionAccessibility: ViewModifier {
    let isSelecting: Bool
    let isPicked: Bool
    let label: String

    func body(content: Content) -> some View {
        if isSelecting {
            content
                .accessibilityLabel(Text("Select \(label)"))
                .accessibilityValue(isPicked ? Text("Selected") : Text("Not selected"))
                .accessibilityAddTraits(isPicked ? .isSelected : [])
        } else {
            content
        }
    }
}

/// One person as a list row and as the person page's header: name, email, status words, last activity, profiles.
struct OrganizationPersonSummaryView: View {
    let person: PersonSummary
    let isSelf: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Wraps: at the largest text sizes the status words drop under the name instead of pushing it aside.
            OrganizationFlowLayout(spacing: Theme.Space.s) {
                Text(person.label).bloemText(.titleMedium).lineLimit(2)
                if isSelf { StatusLabel("You") }
                if person.isAdministrator { StatusLabel("Administrator") }
                if !person.isActive {
                    StatusLabel(OrganizationText.status(person.membershipStatus), tone: OrganizationText.statusTone(person.membershipStatus))
                }
            }
            if !person.displayName.isEmpty, !person.email.isEmpty {
                Text(person.email).bloemText(.bodyMedium).foregroundStyle(.bloemMuted).lineLimit(1).truncationMode(.middle)
            }
            if let last = person.lastActivity, !last.isEmpty {
                Text("Last active \(OrganizationText.when(last))").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            ForEach(person.profiles) { profile in
                Text(profile.groupName.isEmpty ? profile.name : "\(profile.name) · \(profile.groupName)")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        }
    }
}

/// What a bulk change has done so far, then what it skipped or could not change, in the web's words.
struct OrganizationBulkReportView: View {
    let report: BulkReport
    let onDismiss: () -> Void

    private func name(_ accountID: Int64) -> String {
        report.names[accountID] ?? String(localized: "Account \(Int(accountID))")
    }

    var body: some View {
        let job = report.job
        VStack(alignment: .leading, spacing: 8) {
            Text(OrganizationVocabulary.bulkHeading(job)).bloemText(.titleMedium)
            if job.progressTotal > 0 {
                ProgressView(value: Double(min(job.progressCurrent, job.progressTotal)), total: Double(job.progressTotal))
                Text("\(Int(job.progressCurrent)) of \(Int(job.progressTotal)) done").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            Text(counts).bloemText(.bodyMedium)
            if let error = report.error {
                Text(error).bloemText(.bodyMedium).foregroundStyle(.bloemDanger)
            }
            if !job.skipped.isEmpty {
                Text("Skipped").bloemText(.titleSmall)
                ForEach(job.skipped) { record in
                    Text("\(name(record.accountID)): \(OrganizationVocabulary.resultReasonText(record.reason))").bloemText(.bodySmall)
                }
            }
            if !job.failed.isEmpty {
                Text("Failed").bloemText(.titleSmall)
                ForEach(job.failed) { record in
                    Text("\(name(record.accountID)): \(OrganizationVocabulary.resultReasonText(record.reason))").bloemText(.bodySmall)
                }
            }
            if !report.isRunning {
                Button("Dismiss", action: onDismiss).frame(minHeight: 44)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("organization-bulk-report")
    }

    private var counts: String {
        let job = report.job
        var parts = [String(localized: "\(Int(job.succeeded)) changed")]
        if !job.skipped.isEmpty { parts.append(String(localized: "\(job.skipped.count) skipped")) }
        if !job.failed.isEmpty { parts.append(String(localized: "\(job.failed.count) failed")) }
        return parts.joined(separator: " · ")
    }
}
