import SwiftUI

/// An organization opened for support, pushed onto this page's stack.
private struct OpenedSupportOrganization: Identifiable, Hashable {
    let session: OrganizationSession
    let name: String

    var id: String { session.organizationID }

    static func == (lhs: OpenedSupportOrganization, rhs: OpenedSupportOrganization) -> Bool { lhs.session === rhs.session }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(session)) }
}

/// Support Access (the server Owner only): open a customer's organization the Owner is not a member of, to help its
/// administrator. Each opening states a reason, which the organization's administrators see in Activity with every
/// change made under it, and lasts four hours at most. The organization's pages open on this page's stack with a
/// banner saying how long is left and a way to end the access early.
struct SupportAccessView: View {
    let server: AdminServer
    let client: APIClient
    let sessionState: AdminSessionState
    @State private var model: SupportAccessListModel
    @State private var asking: OrganizationSummary?
    @State private var opened: OpenedSupportOrganization?
    @State private var lastOpened: OpenedSupportOrganization?
    @State private var openingID: String?
    @State private var openError: String?

    init(server: AdminServer, client: APIClient, sessionState: AdminSessionState) {
        self.server = server
        self.client = client
        self.sessionState = sessionState
        _model = State(initialValue: SupportAccessListModel(account: client, baseURL: server.baseURL))
    }

    private var scoped: ServerScopedSession { sessionState.scoped(to: server.id) }

    var body: some View {
        List {
            Section {
                Text("Open an organization you don't belong to, to help its administrator. Say why each time: the reason, and every change you make, is shown to the organization's administrators in Activity as Platform support. Access ends after four hours at most.")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            if let openError {
                Section {
                    OrganizationMessageBanner(text: openError, isError: true, onDismiss: { self.openError = nil })
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.bloemMuted)
                    Button("Try again") { Task { await model.load(sessionState: scoped) } }
                }
            }
            Section {
                ForEach(model.organizations, id: \.id) { organization in
                    Button { choose(organization) } label: {
                        row(organization)
                    }
                    .disabled(openingID != nil)
                    .accessibilityIdentifier("support-access-organization-\(organization.id)")
                }
                if !model.isLoading && model.errorMessage == nil && model.organizations.isEmpty {
                    Text(model.query.isEmpty ? String(localized: "No other organizations on this server") : String(localized: "No organization matches"))
                        .foregroundStyle(.bloemMuted)
                }
            } header: {
                Text("Organizations")
            } footer: {
                Text("Organizations you belong to aren't listed: open them from the context menu.")
            }
        }
        .overlay { if model.isLoading { ProgressView("Loading…") } }
        .searchable(text: $model.query, prompt: Text("Search organizations"))
        .onSubmit(of: .search) { Task { await model.load(sessionState: scoped) } }
        .onChange(of: model.query) { _, query in
            if query.isEmpty { Task { await model.load(sessionState: scoped) } }
        }
        .task { await model.load(sessionState: scoped) }
        .refreshable { await model.load(sessionState: scoped) }
        .sheet(item: $asking) { organization in
            SupportReasonSheet(organization: organization) { reason in
                await open(organization, reason: reason)
            }
        }
        .navigationDestination(item: $opened) { opened in
            OrganizationAdminRootView(
                session: opened.session,
                accountSession: scoped,
                title: opened.name,
                onDenied: { self.opened = nil },
                // ShellLayout gives this page its own NavigationStack: the organization's pages push onto it.
                usesEnclosingNavigationStack: true
            )
        }
        .onChange(of: opened) { _, now in
            // Back on the list: remember the access if it is still open, forget it once it has ended.
            if now == nil, let lastOpened { model.record(lastOpened.session) }
        }
        .accessibilityIdentifier("support-access-page")
    }

    private func row(_ organization: OrganizationSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(organization.name).bloemText(.titleMedium).foregroundStyle(.primary)
                if openingID == organization.id { ProgressView() }
            }
            Text(OrganizationText.members(Int(organization.membershipCount))).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
            if let held = model.openAccess(for: organization.id) {
                Text(held.expiresAt.flatMap { OrganizationText.timeLeft(until: $0) }.map { String(localized: "Support access open, \($0) left") }
                     ?? String(localized: "Support access open"))
                    .bloemText(.bodySmall).foregroundStyle(.bloemWarn)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// An access this run still holds reopens without a reason; anything else asks for one.
    private func choose(_ organization: OrganizationSummary) {
        openError = nil
        guard model.openAccess(for: organization.id) != nil else {
            asking = organization
            return
        }
        Task {
            openingID = organization.id
            defer { openingID = nil }
            switch await model.open(organizationID: organization.id, reason: nil, makeSession: makeSession, sessionState: scoped) {
            case .success(let session): show(session, name: organization.name)
            case .failure(.reasonNeeded): asking = organization
            case .failure(.refused(let message)): openError = message
            }
        }
    }

    /// Returns the reason sheet's error text, or nil once the organization is open.
    private func open(_ organization: OrganizationSummary, reason: String) async -> String? {
        switch await model.open(organizationID: organization.id, reason: reason, makeSession: makeSession, sessionState: scoped) {
        case .success(let session):
            asking = nil
            show(session, name: organization.name)
            return nil
        case .failure(.reasonNeeded):
            return String(localized: "Say why you're opening this organization, in 10 to 500 characters")
        case .failure(.refused(let message)):
            return message
        }
    }

    private func show(_ session: OrganizationSession, name: String) {
        let organization = OpenedSupportOrganization(session: session, name: name)
        lastOpened = organization
        opened = organization
    }

    private func makeSession(_ organizationID: String) -> OrganizationSession {
        let session = OrganizationSession(account: client, baseURL: server.baseURL, organizationID: organizationID)
        session.accountSession = scoped
        return session
    }
}

/// Why the Owner is opening the organization. The reason is shown to the organization's administrators as written.
private struct SupportReasonSheet: View {
    let organization: OrganizationSummary
    /// Opens the organization; answers the text to show when it could not.
    let onOpen: @MainActor (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var isOpening = false
    @State private var error: String?

    private var length: Int { SupportAccessListModel.cleanedReason(reason).count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Reason", text: $reason, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("support-access-reason")
                } header: {
                    Text("Why are you opening \(organization.name)?")
                } footer: {
                    Text("\(length) of 10 to 500 characters. \(organization.name)'s administrators see this reason in Activity, with every change you make.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.bloemDanger) }
                }
                Section {
                    Text("Access ends after four hours at most. You can end it earlier from the banner at the top of the organization.")
                        .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            }
            .navigationTitle("Open for support")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isOpening)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task {
                            isOpening = true
                            error = await onOpen(reason)
                            isOpening = false
                        }
                    } label: {
                        if isOpening { ProgressView() } else { Text("Open") }
                    }
                    .disabled(isOpening || !SupportAccessListModel.isAcceptable(reason: reason))
                    .accessibilityIdentifier("support-access-open")
                }
            }
        }
        .interactiveDismissDisabled(isOpening)
    }
}
