import SwiftUI

/// Platform › Organizations: every organization on the server, for any platform administrator. Search by name or short
/// name, filter by status, and open one to see its members, change its plan or suspend it. Support access (the server
/// Owner only) is a separate page of the same group.
struct PlatformOrganizationsView: View {
    let server: AdminServer
    let client: APIClient
    let sessionState: AdminSessionState
    /// Tests give the pages their own URL session; the app leaves it nil.
    var urlSession: URLSession?
    @State private var model: PlatformOrganizationsModel
    @State private var hasLoaded = false

    init(server: AdminServer, client: APIClient, sessionState: AdminSessionState, urlSession: URLSession? = nil) {
        self.server = server
        self.client = client
        self.sessionState = sessionState
        self.urlSession = urlSession
        _model = State(initialValue: PlatformOrganizationsModel(pass: PlatformPass(account: client, baseURL: server.baseURL, session: urlSession)))
    }

    private var scoped: ServerScopedSession { sessionState.scoped(to: server.id) }

    /// A change of search or status starts a new load; typing waits a moment so each letter is not a request.
    private struct Search: Equatable {
        let query: String
        let status: PlatformOrganizationStatusFilter
    }

    var body: some View {
        Group {
            if let failure = model.failure {
                LoadFailureView(failure: failure) { Task { await model.load(sessionState: scoped) } }
            } else {
                list
            }
        }
        .searchable(text: $model.query, prompt: Text("Search name or slug"))
        .task(id: Search(query: model.query, status: model.statusFilter)) {
            if hasLoaded {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            hasLoaded = true
            await model.load(sessionState: scoped)
        }
        .accessibilityIdentifier("platform-organizations-page")
    }

    private var list: some View {
        List {
            Section {
                Picker("Status", selection: $model.statusFilter) {
                    ForEach(PlatformOrganizationStatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("platform-organizations-status")
            } footer: {
                Text("Every organization on this server. Open one to manage its members, plan and libraries.")
            }
            Section {
                ForEach(model.organizations, id: \.id) { organization in
                    NavigationLink {
                        PlatformOrganizationDetailView(server: server, client: client, sessionState: sessionState, organization: organization, urlSession: urlSession)
                    } label: {
                        PlatformOrganizationRow(organization: organization)
                    }
                    .accessibilityIdentifier("platform-organization-\(organization.id)")
                }
                if model.hasMore {
                    Button {
                        Task { await model.loadMore(sessionState: scoped) }
                    } label: {
                        HStack {
                            Text("Show more")
                            if model.isLoadingMore { ProgressView() }
                        }
                        .frame(minHeight: 44)
                    }
                    .disabled(model.isLoadingMore)
                    .accessibilityIdentifier("platform-organizations-more")
                }
                if let problem = model.moreFailure {
                    Text(problem).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                if !model.isLoading && model.organizations.isEmpty {
                    Text(isFiltering ? "No organizations match these filters" : "No organizations on this server yet")
                        .foregroundStyle(.bloemMuted)
                        .accessibilityIdentifier("platform-organizations-empty")
                }
            } header: {
                Text("Organizations")
            }
        }
        .overlay { if model.isLoading { ProgressView("Loading…") } }
        .refreshable { await model.load(sessionState: scoped) }
    }

    private var isFiltering: Bool {
        !model.query.trimmingCharacters(in: .whitespaces).isEmpty || model.statusFilter != .all
    }
}

/// One organization in the list: its name, its short name, its status in words, and how many people, profiles and
/// libraries it has.
struct PlatformOrganizationRow: View {
    let organization: OrganizationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(organization.name).bloemText(.titleMedium)
            if !organization.slug.isEmpty {
                Text(organization.slug).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
            Text("\(PlatformOrganizationText.status(organization.status)) · \(PlatformOrganizationText.counts(organization))")
                .bloemText(.bodyMedium)
                .foregroundStyle(.bloemMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
