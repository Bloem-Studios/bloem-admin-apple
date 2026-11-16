import SwiftUI

// MARK: - Overview

struct OrganizationOverviewView: View {
    let session: OrganizationSession
    @State private var model = OrganizationOverviewViewModel()

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.summary == nil,
            emptyTitle: String(localized: "Organization overview"),
            emptyMessage: String(localized: "Members, libraries and who owns this organization"),
            emptyIcon: .building2, errorMessage: model.errorMessage, noticeMessage: nil,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: {}
        ) {
            if let summary = model.summary {
                Section {
                    LabeledContent("Members") {
                        VStack(alignment: .trailing) {
                            Text(summary.membershipCount, format: .number)
                            Text("\(summary.activeMembershipCount) active").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    LabeledContent("Profiles") { Text(summary.profileCount, format: .number) }
                    LabeledContent("Owned libraries") { Text(summary.libraryCount, format: .number) }
                    LabeledContent("Libraries shared with it") { Text(summary.entitlementCount, format: .number) }
                } header: {
                    Text("Organization overview")
                } footer: {
                    Text("Members, libraries and who owns this organization")
                }
                Section("About") {
                    LabeledContent("Status") {
                        StatusLabel(OrganizationText.status(summary.status), tone: OrganizationText.statusTone(summary.status))
                    }
                    LabeledContent("Owner") {
                        Text(model.ownerText).accessibilityIdentifier("organization-owner")
                    }
                    if !summary.slug.isEmpty {
                        LabeledContent("Short name", value: summary.slug)
                    }
                    LabeledContent("Settings revision") { Text(summary.policyRevision, format: .number) }
                }
            }
        }
        .accessibilityIdentifier("organization-page-overview")
        .task { await model.load(session: session) }
        .refreshable { await model.load(session: session) }
    }
}

// MARK: - Activity & Audit

struct OrganizationActivityView: View {
    let session: OrganizationSession
    @State private var model = OrganizationActivityViewModel()

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.events.isEmpty,
            emptyTitle: String(localized: "Activity"), emptyMessage: String(localized: "Nothing has changed yet"),
            emptyIcon: .clipboardList, errorMessage: model.errorMessage, noticeMessage: nil,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: {}
        ) {
            Section {
                ForEach(model.events) { event in
                    OrganizationActivityRow(event: event)
                }
                if model.nextCursor != nil {
                    Button {
                        Task { await model.loadOlder(session: session) }
                    } label: {
                        if model.isLoadingOlder { ProgressView() } else { Text("Load more") }
                    }
                    .frame(minHeight: 44)
                    .disabled(model.isLoadingOlder)
                }
            } footer: {
                if session.support.offersPersonSupport {
                    Text("Changes to this organization: its name and status, its members and their plans, and the help administrators gave (reset links, sign-outs, profile edits, stopped streams). Platform support is the server operator. Members' own sign-ins and playback are not listed here.")
                } else {
                    Text("Changes to this organization: its name and status, its members, and their plans. Sign-ins, playback and other server events are not listed here.")
                }
            }
        }
        .accessibilityIdentifier("organization-page-activity")
        .task {
            // Read when it opens and when `org.activity` says there is a new entry; without the socket, on open and on pull.
            await OrganizationLive.follow(
                session: session, channel: .orgActivity, whenNotOffered: .readOnOpenOnly,
                legacy: { await model.load(session: session) }, refresh: { await model.load(session: session) }
            )
        }
        .refreshable { await model.load(session: session) }
    }
}

private struct OrganizationActivityRow: View {
    let event: OrganizationAuditEvent

    private var who: String {
        // The server operator under support access is "Platform support", never an account.
        if event.isPlatformSupport { return String(localized: "By Platform support") }
        if let actor = event.actorAccountID { return String(localized: "By account \(actor)") }
        return String(localized: "By Silo")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(OrganizationVocabulary.auditActionText(event.action)).bloemText(.titleMedium)
                Spacer(minLength: 8)
                if !event.isSuccess, let outcome = OrganizationVocabulary.auditOutcome(event.outcome) {
                    StatusLabel(outcome, tone: .warning)
                }
            }
            Text("\(OrganizationText.when(event.createdAt)) · \(who)")
                .bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            if let reason = event.reason {
                // The reason a support access was opened with, as the operator wrote it.
                Text("Reason: \(reason)").bloemText(.bodyMedium)
            }
            if !event.source.isEmpty || !event.targetID.isEmpty {
                Text([event.source, event.targetID].filter { !$0.isEmpty }.joined(separator: " · "))
                    .bloemText(.labelSmall).foregroundStyle(.bloemMuted)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Policy Cohorts

struct OrganizationCohortsView: View {
    let session: OrganizationSession
    @State private var model = OrganizationCohortsViewModel()

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.cohorts.isEmpty,
            emptyTitle: String(localized: "Cohorts"),
            emptyMessage: String(localized: "No cohorts yet. One appears when you first put people on a plan."),
            emptyIcon: .layers, errorMessage: model.errorMessage, noticeMessage: nil,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: {}
        ) {
            Section {
                ForEach(model.activeCohorts) { cohort in
                    OrganizationCohortRow(cohort: cohort, libraryNames: model.libraryNames(for: cohort.policy))
                }
            } header: {
                Text("Cohorts")
            } footer: {
                Text("A cohort is a group of accounts that share the same settings. A cohort never changes.")
            }
            if !model.archivedCohorts.isEmpty {
                Section {
                    ForEach(model.archivedCohorts) { cohort in
                        OrganizationCohortRow(cohort: cohort, libraryNames: model.libraryNames(for: cohort.policy))
                    }
                } header: {
                    Text("Archived cohorts (\(model.archivedCohorts.count))")
                } footer: {
                    Text("Kept for the record. Nobody can be moved to an archived cohort.")
                }
            }
        }
        .accessibilityIdentifier("organization-page-cohorts")
        .task { await model.load(session: session) }
        .refreshable { await model.load(session: session) }
    }
}

private struct OrganizationCohortRow: View {
    let cohort: EntitlementCohort
    let libraryNames: [String]?
    @State private var showsDetails = false

    private var origin: String {
        if let key = cohort.sourceTemplateKey, !key.isEmpty {
            if let revision = cohort.sourceTemplateRevision { return String(localized: "From plan \(key), revision \(revision)") }
            return String(localized: "From plan \(key)")
        }
        return OrganizationVocabulary.derivationText(cohort.derivationKind)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            Text("Settings").bloemText(.titleSmall)
            OrganizationPolicyRows(policy: cohort.policy, libraryNames: libraryNames)
            Text("Details").bloemText(.titleSmall).padding(.top, 4)
            detail("How it was made", OrganizationVocabulary.derivationText(cohort.derivationKind))
            detail("Cohort revision", String(cohort.revision))
            if let parent = cohort.parentCohortID, !parent.isEmpty { detail("Started from cohort", parent) }
            if !cohort.createdAt.isEmpty { detail("Created", OrganizationText.when(cohort.createdAt)) }
            if let creator = cohort.createdByAccountID { detail("Created by", String(localized: "Account \(creator)")) }
            detail("Access group", String(cohort.accessGroupID))
            detail("Cohort ID", cohort.cohortID)
            if !cohort.policyDigest.isEmpty { detail("Settings fingerprint", cohort.policyDigest) }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(cohort.name).bloemText(.titleMedium)
                    if cohort.archived { StatusLabel("Archived") }
                }
                Text(origin).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                Text("Revision \(cohort.revision) · \(OrganizationText.accounts(Int(cohort.memberCount)))")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func detail(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(value).bloemText(.bodyLarge).textSelection(.enabled)
        } label: {
            Text(label).bloemText(.bodyLarge)
        }
    }
}

/// The settings a policy grants, in the web's words.
struct OrganizationPolicyRows: View {
    let policy: PolicyView
    let libraryNames: [String]?

    private func yesNo(_ value: Bool) -> String { value ? String(localized: "Yes") : String(localized: "No") }

    private func limit(_ value: Int64, _ text: (Int) -> String) -> String {
        value > 0 ? text(Int(value)) : String(localized: "No limit")
    }

    var body: some View {
        row("Plays video", yesNo(policy.playbackAllowed))
        row("Screens at once", limit(policy.maxStreams, OrganizationText.screens))
        row("Profiles", limit(policy.maxProfiles, OrganizationText.profiles))
        row("Video conversion", yesNo(policy.transcodeAllowed))
        if let audio = policy.audioTranscodeAllowed { row("Audio conversion", yesNo(audio)) }
        row("Conversions at once", limit(policy.maxTranscodes, OrganizationText.conversions))
        row("Download original files", yesNo(policy.downloadAllowed))
        row("Download converted copies", yesNo(policy.downloadTranscodeAllowed))
        row("Best picture quality", OrganizationVocabulary.qualityText(policy.maxPlaybackQuality))
        row("Media requests", yesNo(policy.requestsAllowed))
        row("Libraries", libraryNames.map { $0.isEmpty ? String(localized: "None") : $0.joined(separator: ", ") } ?? String(localized: "All libraries"))
        row(
            "Extra permissions",
            policy.allowedPermissions.map {
                $0.isEmpty ? String(localized: "None") : $0.map(OrganizationVocabulary.permissionText).joined(separator: ", ")
            } ?? String(localized: "All permissions")
        )
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        LabeledContent {
            Text(value).bloemText(.bodyLarge)
        } label: {
            Text(label).bloemText(.bodyLarge)
        }
    }
}

// MARK: - Policy Decisions

struct OrganizationDecisionsView: View {
    let session: OrganizationSession
    @State private var model = OrganizationDecisionsViewModel()

    var body: some View {
        OrganizationListFrame(
            isLoading: model.isLoading, isEmpty: model.decisions.isEmpty,
            emptyTitle: String(localized: "Access checks"), emptyMessage: String(localized: "Nothing has been checked yet"),
            emptyIcon: .shieldCheck, errorMessage: model.errorMessage, noticeMessage: nil,
            onRetry: { Task { await model.load(session: session) } }, onDismissMessages: {}
        ) {
            Section {
                ForEach(model.decisions) { decision in
                    NavigationLink {
                        OrganizationDecisionDetailView(session: session, model: model, id: decision.id)
                    } label: {
                        OrganizationDecisionRow(decision: decision)
                    }
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
            } footer: {
                Text("When Silo checks whether someone here may do something, it records the answer. Pick one to see why.")
            }
        }
        .accessibilityIdentifier("organization-page-decisions")
        .task { await model.load(session: session) }
        .refreshable { await model.load(session: session) }
    }
}

private struct OrganizationDecisionRow: View {
    let decision: PolicyDecision

    var body: some View {
        let action = OrganizationVocabulary.accessActionText(decision.action)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(decision.allowed ? String(localized: "\(action): allowed") : String(localized: "\(action): refused"))
                    .bloemText(.titleMedium)
                    .foregroundStyle(decision.allowed ? Color.primary : Theme.warn)
            }
            Text(OrganizationVocabulary.accessReasonText(decision.reasonCode)).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            Text(summary).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("See why"))
    }

    private var summary: String {
        var parts: [String] = [OrganizationText.when(decision.timestamp)]
        parts.append(decision.subject.accountID > 0 ? String(localized: "Account \(decision.subject.accountID)") : String(localized: "Account not recorded"))
        if !decision.group.name.isEmpty { parts.append(String(localized: "Group \(decision.group.name)")) }
        if !decision.subject.profileID.isEmpty { parts.append(String(localized: "Profile \(decision.subject.profileID)")) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct OrganizationDecisionDetailView: View {
    let session: OrganizationSession
    let model: OrganizationDecisionsViewModel
    let id: Int64

    var body: some View {
        List {
            if let message = model.detailErrorMessage {
                Section { OrganizationMessageBanner(text: message, isError: true, onDismiss: { model.close() }) }
            }
            if let detail = model.detail {
                Section("Check") {
                    LabeledContent("Check", value: OrganizationVocabulary.accessActionText(detail.action))
                    LabeledContent("Allowed") {
                        StatusLabel(detail.allowed ? String(localized: "Allowed") : String(localized: "Refused"), tone: detail.allowed ? .normal : .warning)
                    }
                    LabeledContent("Why", value: OrganizationVocabulary.accessReasonText(detail.reasonCode))
                    if !detail.reasonCode.isEmpty { LabeledContent("Reason code", value: detail.reasonCode) }
                    LabeledContent("When", value: OrganizationText.when(detail.timestamp))
                }
                Section("Who") {
                    LabeledContent("Account", value: detail.subject.accountID > 0 ? String(localized: "Account \(detail.subject.accountID)") : String(localized: "Account not recorded"))
                    if !detail.subject.profileID.isEmpty { LabeledContent("Profile", value: detail.subject.profileID) }
                    if !detail.group.name.isEmpty { LabeledContent("Access group", value: detail.group.name) }
                }
                Section("Libraries they could use") {
                    if let ceiling = detail.libraryCeiling, !ceiling.isEmpty {
                        ForEach(ceiling, id: \.self) { Text(model.libraryName($0)) }
                    } else {
                        Text("None recorded").foregroundStyle(.bloemMuted)
                    }
                }
                Section("What they asked for") {
                    if detail.resource.isEmpty {
                        Text("None recorded").foregroundStyle(.bloemMuted)
                    } else {
                        ForEach(detail.resource.keys.sorted(), id: \.self) { key in
                            let value = detail.resource[key]?.displayText ?? ""
                            LabeledContent(OrganizationVocabulary.sentenceCase(key)) {
                                if value == "[redacted]" {
                                    Text("Sensitive value hidden").foregroundStyle(.bloemMuted)
                                } else {
                                    Text(value)
                                }
                            }
                        }
                    }
                }
                Section("Rules checked") {
                    if let versions = detail.policyVersions, !versions.isEmpty {
                        ForEach(Array(versions.enumerated()), id: \.offset) { _, version in
                            if let name = version.name, !name.isEmpty {
                                Text("\(version.kind) \(name) version \(version.version)")
                            } else {
                                Text("\(version.kind) version \(version.version)")
                            }
                        }
                    } else {
                        Text("None recorded").foregroundStyle(.bloemMuted)
                    }
                }
                Section {
                    LabeledContent("Organization ID", value: detail.organization.id).textSelection(.enabled)
                    if let membership = detail.organization.membershipID { LabeledContent("Membership ID", value: membership).textSelection(.enabled) }
                    if detail.group.id > 0 { LabeledContent("Access group ID", value: String(detail.group.id)) }
                }
                .bloemText(.bodyLarge)
            }
        }
        .overlay {
            if model.isDetailLoading { ProgressView("Loading…") }
        }
        .navigationTitle("Access check")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("organization-decision-detail")
        .task(id: id) { await model.open(session: session, id: id) }
        .onDisappear { model.close() }
    }
}
