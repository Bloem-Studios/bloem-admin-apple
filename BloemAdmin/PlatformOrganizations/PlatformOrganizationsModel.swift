import Foundation
import Observation

/// Whether a server's platform menu offers Organizations: the server is a Bloem server, which it proves by answering
/// the public capabilities route. A plain Silo server, or one that cannot be asked, leaves the page out; the account
/// itself is already a platform administrator, or the gate would not have shown the platform pages.
enum PlatformOrganizationsEligibility {
    static func check(client: APIClient) async -> Bool {
        await client.isBloemServer()
    }
}

/// The platform's list of organizations: search, a status filter, and cursor paging. It holds a platform pass in
/// memory for as long as the page is open.
@Observable
@MainActor
final class PlatformOrganizationsModel {
    static let pageLimit = 50

    private(set) var organizations: [OrganizationSummary] = []
    private(set) var isLoading = true
    private(set) var isLoadingMore = false
    /// Why the first page could not be shown: the page shows this in place of the list.
    private(set) var failure: ServerSectionFailure?
    /// Why a further page could not be added: the list stays as it was.
    private(set) var moreFailure: String?
    private(set) var nextCursor: String?
    var query = ""
    var statusFilter: PlatformOrganizationStatusFilter = .all

    var hasMore: Bool { nextCursor != nil }

    @ObservationIgnored private let pass: PlatformPass
    @ObservationIgnored private var gate = LatestRequestGate()

    init(pass: PlatformPass) {
        self.pass = pass
    }

    /// The first page for the current search and filter. A newer call wins: an answer to an earlier search that
    /// arrives late is dropped.
    func load(sessionState: ServerScopedSession?) async {
        let request = gate.begin()
        isLoading = organizations.isEmpty
        failure = nil
        moreFailure = nil
        let query = query
        let status = statusFilter.serverValue
        do {
            let page = try await pass.read {
                try await $0.listPlatformOrganizations(query: query, status: status, cursor: nil, limit: Self.pageLimit)
            }
            guard gate.isCurrent(request) else { return }
            organizations = page.organizations
            nextCursor = page.nextCursor
            isLoading = false
        } catch is CancellationError {
            return
        } catch {
            guard gate.isCurrent(request), !Task.isCancelled else { return }
            isLoading = false
            organizations = []
            nextCursor = nil
            failure = ErrorMessage.failure(
                for: error, sessionState: sessionState,
                fallback: String(localized: "The organizations couldn't be loaded. Check the connection and try again.")
            )
        }
    }

    /// The page after the last one shown, added to the list.
    func loadMore(sessionState: ServerScopedSession?) async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let request = gate.current()
        isLoadingMore = true
        moreFailure = nil
        defer { isLoadingMore = false }
        let query = query
        let status = statusFilter.serverValue
        do {
            let page = try await pass.read {
                try await $0.listPlatformOrganizations(query: query, status: status, cursor: cursor, limit: Self.pageLimit)
            }
            guard gate.isCurrent(request) else { return }
            let known = Set(organizations.map(\.id))
            organizations += page.organizations.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
        } catch is CancellationError {
            return
        } catch {
            guard gate.isCurrent(request), !Task.isCancelled else { return }
            moreFailure = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "More organizations couldn't be loaded. Check the connection and try again.")
            )
        }
    }
}
