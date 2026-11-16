import SwiftUI
import Observation

/// The organization pages, with the web's names and order (web bloemAdminNavigation.ts
/// ORGANIZATION_ADMIN_NAV_SECTIONS). Nothing platform-level is in this list, and nothing reachable from here can
/// show a platform page: the organization has its own destination list and its own pass client. Now playing is
/// the organization's own (the server's `streams` route); it follows Overview, and shows only when the server
/// offers it.
enum OrganizationPage: String, CaseIterable, Identifiable, Hashable {
    case overview, streams, people, cohorts, groups, libraries, invitations, decisions, activity

    var id: String { rawValue }

    /// The pages this server offers: every one of the web's, and Streams when the support capabilities list it.
    static func offered(_ support: SupportCapabilities) -> [OrganizationPage] {
        allCases.filter { $0 != .streams || support.streams.list }
    }

    var title: String {
        switch self {
        case .overview: String(localized: "Overview")
        case .people: String(localized: "People")
        case .streams: String(localized: "Now playing")
        case .cohorts: String(localized: "Cohorts")
        case .groups: String(localized: "Access groups")
        case .libraries: String(localized: "Libraries")
        case .invitations: String(localized: "Invitations")
        case .decisions: String(localized: "Access checks")
        case .activity: String(localized: "Activity")
        }
    }

    var icon: BloemIcon {
        switch self {
        case .overview: .layoutDashboard
        case .people: .users
        case .streams: .radio
        case .cohorts: .gitBranch
        case .groups: .usersRound
        case .libraries: .library
        case .invitations: .inbox
        case .decisions: .shieldCheck
        case .activity: .clipboardList
        }
    }
}

/// Opens the pass and says how it went. The pass is in memory only; nothing here is saved.
@Observable
@MainActor
final class OrganizationHostModel {
    enum Phase: Equatable {
        case opening
        case ready
        /// The server refused this account the organization.
        case denied(OrganizationDenial)
        case failed(String)
        /// The account's own sign-in was rejected: the gate shows its re-login form.
        case signedOut
    }

    private(set) var phase: Phase = .opening

    func open(session: OrganizationSession, accountSession: ServerScopedSession?) async {
        phase = .opening
        session.accountSession = accountSession
        do {
            // A session already opened (the Owner's support access, opened with its reason) keeps its pass.
            if !session.isOpen { try await session.open() }
            phase = .ready
            // Which support pages and actions to offer; until the server answers, none are.
            await session.loadSupportCapabilities()
        } catch let denied as OrganizationAccessDenied {
            phase = .denied(denied.reason)
        } catch let error as APIError where error.statusCode == 401 {
            // An expired sign-in lands on the same re-login form as everywhere else.
            _ = accountSession?.handleAuthenticationFailure(error)
            phase = .signedOut
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            phase = .failed(session.failureText(error, fallback: String(localized: "This organization couldn't be loaded. Try again.")))
        }
    }
}

/// The organization entry point: opens `session`, then shows the organization's pages. The integrator routes to
/// this view; `onChooseContext` returns to the context choice (the dropdown another thread builds).
struct OrganizationAdminRootView: View {
    let session: OrganizationSession
    let accountSession: ServerScopedSession?
    var title: String?
    /// Shown in the toolbar while the administrator has another organization to choose.
    var onChooseContext: (() -> Void)?
    /// Where "Choose another organization" goes once the server has turned this one away. Defaults to `onChooseContext`.
    var onDenied: (() -> Void)?
    /// True when this view is already inside a NavigationStack (the app pushes it from the server list): the pages
    /// then push onto that stack. SwiftUI does not support a NavigationStack or NavigationSplitView nested inside a
    /// NavigationStack; on an iPhone a nested one sent a tapped page back to the server list.
    var usesEnclosingNavigationStack = false
    @State private var host = OrganizationHostModel()

    var body: some View {
        let leave = onDenied ?? onChooseContext
        Group {
            if let denial = session.denial {
                OrganizationDeniedView(reason: denial, onChooseContext: leave)
            } else {
                switch host.phase {
                case .opening:
                    ProgressView("Opening organization…")
                case .signedOut:
                    // Normally the gate has already swapped in its re-login form; this shows only when it has not
                    // (the rejected request belonged to an older sign-in), so there is always a way on.
                    BloemEmptyState {
                        Label("Couldn't open this organization", icon: .userRoundX)
                    } description: {
                        Text("Your sign-in was not accepted. Try again, or sign in again from the server list.")
                    } actions: {
                        Button("Try again") {
                            Task { await host.open(session: session, accountSession: accountSession) }
                        }
                        .buttonStyle(.bloemProminent)
                    }
                case .ready:
                    OrganizationAdminShell(
                        session: session,
                        title: title ?? session.context?.name ?? String(localized: "Organization"),
                        onChooseContext: onChooseContext,
                        usesEnclosingNavigationStack: usesEnclosingNavigationStack
                    )
                case .denied(let reason):
                    OrganizationDeniedView(reason: reason, onChooseContext: leave)
                case .failed(let message):
                    BloemEmptyState {
                        Label("Couldn't open this organization", icon: .wifiOff)
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") {
                            Task { await host.open(session: session, accountSession: accountSession) }
                        }
                        .buttonStyle(.bloemProminent)
                    }
                }
            }
        }
        .task {
            // A task restarts whenever the view reappears; a pass that is already open is kept.
            if host.phase != .ready { await host.open(session: session, accountSession: accountSession) }
        }
    }
}

/// "You don't have access to this organization" (or suspended, or lost authority) with a way back to context choice.
struct OrganizationDeniedView: View {
    let reason: OrganizationDenial
    var onChooseContext: (() -> Void)?

    var body: some View {
        BloemEmptyState {
            Label("No access", icon: .lock)
        } description: {
            Text(reason.message)
        } actions: {
            if let onChooseContext {
                Button("Choose another organization", action: onChooseContext)
                    .buttonStyle(.bloemProminent)
            }
        }
        .accessibilityIdentifier("organization-denied")
    }
}

/// The organization's pages. At the root of a window: a menu in its own NavigationStack on a phone, a sidebar on an
/// iPad. Inside a NavigationStack that already exists: the menu, with the pages pushed onto that stack.
struct OrganizationAdminShell: View {
    let session: OrganizationSession
    let title: String
    var onChooseContext: (() -> Void)?
    var usesEnclosingNavigationStack = false
    @State private var selected: OrganizationPage? = .overview
    @State private var isSearching = false
    /// The page search picked, opened once the search has closed.
    @State private var pickedPage: OrganizationPage?
    /// The page the menu pushes after a search.
    @State private var pushedPage: OrganizationPage?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var pages: [OrganizationPage] { OrganizationPage.offered(session.support) }

    var body: some View {
        if usesEnclosingNavigationStack {
            menu
        } else if horizontalSizeClass == .regular {
            NavigationSplitView {
                sidebar
                    .navigationTitle(title)
                    .toolbar { searchButton; chooseContextButton }
                    .safeAreaInset(edge: .top, spacing: 0) { OrganizationSupportBanner(session: session, allowsEnding: true) }
            } detail: {
                NavigationStack {
                    OrganizationPageView(page: selected ?? .overview, session: session)
                }
            }
        } else {
            NavigationStack { menu }
        }
    }

    /// The pages in one group, drawn like the platform menu: a group heading, then rows with an icon column.
    private var groupHeader: some View {
        MenuGroupHeader(title: String(localized: AdminGroup.organization.label))
            .accessibilityIdentifier(ShellID.groupPrefix + String(describing: AdminGroup.organization))
    }

    /// The menu as rows that push a page onto whichever NavigationStack contains it. The rows name their
    /// destination view rather than a value: the server list pushes the gate that way, and a NavigationStack keeps
    /// such views above anything pushed by value, so a value link here would slide its page in under the menu.
    private var menu: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                groupHeader
                ForEach(pages) { page in
                    NavigationLink {
                        OrganizationPageView(page: page, session: session)
                    } label: {
                        MenuRowLabel(title: page.title, icon: page.icon, selected: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("organization-menu-\(page.rawValue)")
                }
            }
            .padding(Theme.Space.s)
        }
        .background(Theme.background)
        .navigationTitle(title)
        .toolbar { searchButton; chooseContextButton }
        .safeAreaInset(edge: .top, spacing: 0) { OrganizationSupportBanner(session: session, allowsEnding: true) }
        .navigationDestination(item: $pushedPage) { page in
            OrganizationPageView(page: page, session: session)
        }
    }

    /// The web's page search over this organization's pages (the platform's pages are not here).
    @ToolbarContentBuilder
    private var searchButton: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                isSearching = true
            } label: {
                IconImage(.search, size: .bar)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(String(localized: "Search admin sections"))
            .accessibilityIdentifier(ShellID.searchButton)
            .fullScreenCover(isPresented: $isSearching, onDismiss: openPickedPage) {
                PageSearchSheet(
                    destinations: pages.map(AdminDestination.organization),
                    selectedID: selected.map { AdminDestination.organization($0).id },
                    onPick: { destination in
                        pickedPage = destination.organizationPage
                        isSearching = false
                    },
                    onDismiss: { isSearching = false }
                )
            }
        }
        .bloemFlat()
    }

    /// Once the search has closed: the iPad sidebar selects the page, the phone's menu pushes it.
    private func openPickedPage() {
        guard let page = pickedPage else { return }
        pickedPage = nil
        if usesEnclosingNavigationStack || horizontalSizeClass != .regular {
            pushedPage = page
        } else {
            selected = page
        }
    }

    /// The same rows as a sidebar on a wide screen, the chosen page marked.
    private var sidebar: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                groupHeader
                ForEach(pages) { page in
                    Button { selected = page } label: {
                        MenuRowLabel(title: page.title, icon: page.icon, selected: page == (selected ?? .overview))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(page == (selected ?? .overview) ? .isSelected : [])
                    .accessibilityIdentifier("organization-menu-\(page.rawValue)")
                }
            }
            .padding(Theme.Space.s)
        }
        .background(Theme.background)
    }

    @ToolbarContentBuilder
    private var chooseContextButton: some ToolbarContent {
        if let onChooseContext {
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onChooseContext) {
                    Label("Choose another organization", icon: .arrowLeftRight)
                }
            }
            .bloemFlat()
        }
    }
}

struct OrganizationPageView: View {
    let page: OrganizationPage
    let session: OrganizationSession

    var body: some View {
        Group {
            switch page {
            case .overview: OrganizationOverviewView(session: session)
            case .people: OrganizationPeopleView(session: session)
            case .streams: OrganizationStreamsView(session: session)
            case .cohorts: OrganizationCohortsView(session: session)
            case .groups: OrganizationGroupsView(session: session)
            case .libraries: OrganizationLibrariesView(session: session)
            case .invitations: OrganizationInvitationsView(session: session)
            case .decisions: OrganizationDecisionsView(session: session)
            case .activity: OrganizationActivityView(session: session)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { OrganizationSupportBanner(session: session) }
        .navigationTitle(page.title)
        .navigationBarTitleDisplayMode(.inline)
        .id(page)
    }
}

/// Where the gate sends an administrator who is not a platform administrator: straight in for one organization,
/// a choice for several. An organization the server turns away is dropped from the choice.
struct OrganizationAdmissionView: View {
    let server: AdminServer
    let store: ServerStore
    let sessionState: AdminSessionState
    let contexts: [AdminContext]
    @State private var chosenID: String?
    @State private var unavailableIDs: Set<String> = []
    @State private var session: OrganizationSession?

    private var available: [AdminContext] {
        contexts.filter { $0.organizationID.map { !unavailableIDs.contains($0) } ?? false }
    }

    var body: some View {
        Group {
            if let session, let chosenID, let context = contexts.first(where: { $0.organizationID == chosenID }) {
                OrganizationAdminRootView(
                    session: session,
                    accountSession: sessionState.scoped(to: server.id),
                    title: context.name,
                    onChooseContext: available.count > 1 ? { leave() } : nil,
                    onDenied: { leave() },
                    // The gate is a page of the server list's NavigationStack.
                    usesEnclosingNavigationStack: true
                )
                .id(chosenID)
            } else if available.count == 1, let only = available.first {
                Color.clear.task { open(only) }
            } else if available.isEmpty {
                BloemEmptyState(
                    "No admin access",
                    icon: .lock,
                    description: Text("This account doesn't have admin access on \(server.displayName).")
                )
            } else {
                List(available) { context in
                    Button {
                        open(context)
                    } label: {
                        Label(context.name, icon: .building2)
                    }
                    .accessibilityIdentifier("organization-choice-\(context.organizationID ?? "")")
                }
                .navigationTitle("Choose an organization")
                .safeAreaInset(edge: .top) {
                    Text("You administer more than one organization on \(server.displayName)")
                        .bloemText(.bodyMedium)
                        .foregroundStyle(.bloemMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                }
            }
        }
    }

    private func open(_ context: AdminContext) {
        guard let organizationID = context.organizationID else { return }
        session = OrganizationSession.make(server: server, store: store, sessionState: sessionState, organizationID: organizationID)
        chosenID = organizationID
    }

    /// Back to the choice. The organization the server refused is left out of it.
    private func leave() {
        if let id = chosenID, session?.accessDenied == true { unavailableIDs.insert(id) }
        session?.close()
        session = nil
        chosenID = nil
    }
}

extension OrganizationSession {
    /// A session for one organization of `server`. The account client carries the sign-in the app already holds (and
    /// its re-login handling); the pass client is made from each pass the server issues. The integrator calls this
    /// when a context in the dropdown is chosen.
    static func make(
        server: AdminServer,
        store: ServerStore,
        sessionState: AdminSessionState,
        organizationID: String,
        session: URLSession? = nil
    ) -> OrganizationSession {
        let account = store.client(for: server, sessionState: sessionState, session: session)
        let created = OrganizationSession(
            account: account, baseURL: server.baseURL, organizationID: organizationID, session: session
        )
        created.accountSession = sessionState.scoped(to: server.id)
        return created
    }
}
