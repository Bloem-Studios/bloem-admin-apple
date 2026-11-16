import SwiftUI

/// One organization on the platform: status, owner by name, counts, its members with role and status, its plan, and
/// Suspend or Reactivate with a confirmation that says what it does to the organization's people. "Open as
/// administrator" is there only when the signed-in account administers this organization on this server.
struct PlatformOrganizationDetailView: View {
    let server: AdminServer
    let sessionState: AdminSessionState
    let organization: OrganizationSummary
    let client: APIClient
    var urlSession: URLSession?
    @State private var model: PlatformOrganizationDetailModel
    @State private var plan: PlatformPlanModel
    @State private var pendingSuspend: Bool?
    @Environment(ShellRouter.self) private var router

    init(server: AdminServer, client: APIClient, sessionState: AdminSessionState, organization: OrganizationSummary, urlSession: URLSession? = nil) {
        self.server = server
        self.client = client
        self.sessionState = sessionState
        self.organization = organization
        self.urlSession = urlSession
        _model = State(initialValue: PlatformOrganizationDetailModel(
            organizationID: organization.id, account: client,
            pass: PlatformPass(account: client, baseURL: server.baseURL, session: urlSession)
        ))
        _plan = State(initialValue: PlatformPlanModel(
            organizationID: organization.id, organizationName: organization.name,
            pass: PlatformPass(account: client, baseURL: server.baseURL, session: urlSession)
        ))
    }

    private var scoped: ServerScopedSession { sessionState.scoped(to: server.id) }

    /// The organization as last loaded, else as the list showed it.
    private var shown: OrganizationSummary { model.organization ?? organization }

    private var administered: ScopeOrganization? {
        PlatformOrganizationAccess.scopeOrganization(organizationID: organization.id, serverID: server.id, in: router.organizations)
    }

    var body: some View {
        Group {
            if let failure = model.failure {
                LoadFailureView(failure: failure) { Task { await reload() } }
            } else {
                content
            }
        }
        .navigationTitle(shown.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .accessibilityIdentifier("platform-organization-detail")
    }

    private func reload() async {
        await model.load(sessionState: scoped)
        await plan.load(sessionState: scoped)
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let notice = model.notice {
                    Label(notice, icon: .circleCheck)
                        .bloemText(.bodyMedium)
                        .accessibilityIdentifier("platform-organization-notice")
                }
                if let problem = model.actionError {
                    Label(problem, icon: .triangleAlert)
                        .bloemText(.titleSmall)
                        .accessibilityIdentifier("platform-organization-error")
                }
                overview
                actions
                members
                PlatformPlanSection(model: plan, sessionState: scoped)
                Text("Every change to this organization and its members is recorded in the activity log. Organizations can't be deleted here.")
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
            .padding()
        }
        .refreshable { await reload() }
        .overlay { if model.isLoading { ProgressView("Loading…") } }
        .alert(
            pendingSuspend == true ? Text("Suspend \(shown.name)?") : Text("Reactivate \(shown.name)?"),
            isPresented: Binding(get: { pendingSuspend != nil }, set: { if !$0 { pendingSuspend = nil } }),
            presenting: pendingSuspend
        ) { suspend in
            Button(suspend ? "Suspend" : "Reactivate", role: suspend ? .destructive : nil) {
                Task { await model.setSuspended(suspend, sessionState: scoped) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { suspend in
            Text(suspend
                 ? PlatformOrganizationText.suspendConsequence(name: shown.name, activeMembers: Int(shown.activeMembershipCount))
                 : PlatformOrganizationText.reactivateConsequence(name: shown.name))
        }
    }

    // MARK: Parts

    private var overview: some View {
        DetailCard(String(localized: "Organization")) {
            LabeledContent("Status") {
                Text(PlatformOrganizationText.status(shown.status))
                    .bloemText(.titleMedium)
                    .accessibilityIdentifier("platform-organization-status")
            }
            LabeledContent("Owner") {
                Text(model.ownerText)
                    .accessibilityIdentifier("platform-organization-owner")
            }
            if !shown.slug.isEmpty {
                LabeledContent("Short name") { Text(shown.slug) }
            }
            LabeledContent("Members") {
                VStack(alignment: .trailing) {
                    Text(shown.membershipCount, format: .number)
                    Text("\(shown.activeMembershipCount) active").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
            .accessibilityElement(children: .combine)
            LabeledContent("Profiles") { Text(shown.profileCount, format: .number) }
            LabeledContent("Own libraries") { Text(shown.libraryCount, format: .number) }
            LabeledContent("Libraries shared with it") { Text(shown.entitlementCount, format: .number) }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let administered {
                Button {
                    router.onSelectOrganization(administered)
                } label: {
                    Label("Open as administrator", icon: .building2)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bloemSecondary)
                .accessibilityIdentifier("platform-organization-open")
            }
            if shown.status == "suspended" {
                Button {
                    pendingSuspend = false
                } label: {
                    Text("Reactivate organization").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bloemSecondary)
                .disabled(model.isChangingStatus)
                .accessibilityIdentifier("platform-organization-reactivate")
            } else {
                Button(role: .destructive) {
                    pendingSuspend = true
                } label: {
                    Text("Suspend organization").frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bloemSecondary)
                .disabled(model.isChangingStatus)
                .accessibilityIdentifier("platform-organization-suspend")
            }
            if shown.status != "suspended" {
                Text("Suspending blocks its members until you reactivate it. Nothing is deleted.")
                    .bloemText(.bodySmall)
                    .foregroundStyle(.bloemMuted)
            }
        }
    }

    private var members: some View {
        DetailCard(String(localized: "Members")) {
            if model.members.isEmpty {
                Text("No members yet").foregroundStyle(.bloemMuted)
            }
            ForEach(model.members) { member in
                VStack(alignment: .leading, spacing: 4) {
                    Text(member.label).bloemText(.titleMedium)
                    if !member.email.isEmpty, member.email != member.label {
                        Text(member.email).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                    Text("\(PlatformOrganizationText.role(of: member, ownerAccountID: shown.ownerAccountID)) · \(PlatformOrganizationText.membershipStatus(member.status))")
                        .bloemText(.bodyMedium)
                        .foregroundStyle(.bloemMuted)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("platform-organization-member-\(member.id)")
            }
            if model.hasMoreMembers {
                Button {
                    Task { await model.loadMoreMembers(sessionState: scoped) }
                } label: {
                    HStack {
                        Text("Show more")
                        if model.isLoadingMoreMembers { ProgressView() }
                    }
                    .frame(minHeight: 44)
                }
                .disabled(model.isLoadingMoreMembers)
                .accessibilityIdentifier("platform-organization-members-more")
            }
        }
    }
}
