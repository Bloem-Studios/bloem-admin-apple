import Foundation
import Observation

/// All servers › Organizations: one section per saved server, each with that server's own organizations (the first
/// page for the shared search and status filter). Every server has its own platform pass and its own failure: a server
/// that is not a Bloem server has no section (it is `.unavailable`), one that needs a new sign-in offers it, and neither stops the others.
@Observable
@MainActor
final class AggregatePlatformOrganizationsModel {
    enum SectionState: Equatable {
        case loading
        /// The server is not a Bloem server: it has no organizations to list.
        case unavailable
        case loaded([OrganizationSummary], hasMore: Bool)
        case failed(ServerSectionFailure)
    }

    private(set) var sections: [String: SectionState] = [:]
    var query = ""
    var statusFilter: PlatformOrganizationStatusFilter = .all

    @ObservationIgnored private var passes: [String: PlatformPass] = [:]
    @ObservationIgnored private var generations: [String: Int] = [:]

    func state(for server: AdminServer) -> SectionState {
        sections[server.id] ?? .loading
    }

    /// Reads every server's first page, all at once. Each section is filled in as its own server answers.
    func loadAll(
        servers: [AdminServer], store: ServerStore, sessionState: AdminSessionState,
        resolveClient: @escaping ServerClientResolver, session: URLSession? = nil
    ) async {
        let kept = Set(servers.map(\.id))
        sections = sections.filter { kept.contains($0.key) }
        // Plain main-actor tasks: they interleave while each waits on its own server.
        let loads = servers.map { server in
            Task {
                await self.load(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient, session: session)
            }
        }
        for load in loads { await load.value }
    }

    /// Reads one server again, leaving every other section as it is.
    func reload(
        server: AdminServer, store: ServerStore, sessionState: AdminSessionState,
        resolveClient: ServerClientResolver, session: URLSession? = nil
    ) async {
        await load(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient, session: session)
    }

    private func load(
        server: AdminServer, store: ServerStore, sessionState: AdminSessionState,
        resolveClient: ServerClientResolver, session: URLSession?
    ) async {
        let generation = (generations[server.id] ?? 0) + 1
        generations[server.id] = generation
        // A server with no saved sign-in is not asked anything: its section offers the sign-in.
        guard store.accessToken(for: server.id) != nil else {
            sections[server.id] = .failed(.signedOut(message: String(localized: "Not signed in."), requestIdentity: nil))
            return
        }
        if sections[server.id] == nil { sections[server.id] = .loading }
        let client = resolveClient(server)
        let scoped = sessionState.scoped(to: server.id)
        let query = query
        let status = statusFilter.serverValue
        let result: SectionState
        do {
            // The server's own answer to the capabilities route (remembered per server): a plain Silo server has no
            // organizations, and nothing else under /api/bloem/ is asked of it.
            guard try await client.bloemCapabilitiesIfBloem() != nil else {
                guard generations[server.id] == generation else { return }
                sections[server.id] = .unavailable
                return
            }
            let pass = passes[server.id] ?? PlatformPass(account: client, baseURL: server.baseURL, session: session)
            passes[server.id] = pass
            let page = try await pass.read {
                try await $0.listPlatformOrganizations(query: query, status: status, cursor: nil, limit: PlatformOrganizationsModel.pageLimit)
            }
            result = .loaded(page.organizations, hasMore: page.nextCursor != nil)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            result = .failed(ErrorMessage.failure(
                for: error, sessionState: scoped,
                fallback: String(localized: "The organizations couldn't be loaded. Check the connection and try again.")
            ))
        }
        guard generations[server.id] == generation else { return }
        sections[server.id] = result
    }
}
