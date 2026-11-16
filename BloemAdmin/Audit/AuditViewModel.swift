import Foundation
import Observation

/// Cursor-paged audit trail (`GET /api/v2/admin/logs/audit`) with a `user_id` filter. It does not
/// poll, so only filter changes and explicit loads can race; those follow Activity's rules: a
/// changed filter clears rows, cursor and `hasMore` before its request, a result for a
/// superseded filter is discarded, and Load more continues the filter its rows came from.
@Observable
@MainActor
final class AuditViewModel {
    private(set) var entries: [AuditLogEntry] = []
    /// First-page failures only; drives the full-screen failure page.
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// A Load more failure, shown inline so the loaded entries stay visible.
    private(set) var loadMoreErrorMessage: String?
    private(set) var loadMoreFailure: ServerSectionFailure?
    private(set) var isLoadingMore = false
    private(set) var isLoading = false
    private(set) var hasMore = false
    private var nextCursor: String?
    /// The filter the rows and cursor belong to; nil before the first load.
    private var activeFilter: AuditFilter?
    /// Bumped whenever the filter changes; a Load more started under an older value discards its result.
    private var filterEpoch = 0
    private var requestID = 0

    static let pageSize = 50

    var appliedFilter: AuditFilter { activeFilter ?? AuditFilter() }

    /// Mints a load token for `apply`. Call synchronously right before the fetch it guards.
    func beginLoad(filter: AuditFilter = AuditFilter()) -> Int {
        requestID += 1
        if filter != activeFilter {
            activeFilter = filter
            filterEpoch += 1
            entries = []
            nextCursor = nil
            hasMore = false
            isLoadingMore = false
            loadMoreErrorMessage = nil
            loadMoreFailure = nil
            loadFailure = nil
        }
        return requestID
    }

    /// Applies a first-page outcome if `token` is the newest and `userID` is still the current
    /// filter. No-ops while a Load more is in flight for that filter, so a reload cannot swap the
    /// cursor under it.
    func apply(filter: AuditFilter, _ result: Result<APICollection<AuditLogEntry>, Error>, token: Int, sessionState: ServerScopedSession?) {
        guard token == requestID, filter == activeFilter, !isLoadingMore else { return }
        switch result {
        case .success(let collection):
            entries = collection.items
            setCursor(collection.page)
            loadFailure = nil
            loadMoreErrorMessage = nil
            loadMoreFailure = nil
        case .failure(let error):
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "The audit log couldn't be loaded. Try again."))
        }
    }

    private func setCursor(_ page: PageInfo?) {
        nextCursor = page.flatMap { $0.hasMore ? $0.nextCursor : nil }
        hasMore = nextCursor != nil
    }

    /// Loads page one for `filter` (first load, a changed filter, pull to refresh).
    func load(filter: AuditFilter = AuditFilter(), client: APIClient, sessionState: ServerScopedSession? = nil) async {
        if filter == activeFilter { guard !isLoading, !isLoadingMore else { return } }
        isLoading = true
        let token = beginLoad(filter: filter)
        let result: Result<APICollection<AuditLogEntry>, Error>
        do {
            result = .success(try await client.auditLogs(filter: filter, cursor: nil, limit: Self.pageSize))
        } catch {
            result = .failure(error)
        }
        if token == requestID { isLoading = false }
        apply(filter: filter, result, token: token, sessionState: sessionState)
    }

    /// Fetches the next page with the cursor from the previous response and the filter the rows
    /// were loaded with, never a filter typed since.
    func loadMore(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard hasMore, let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let epoch = filterEpoch
        let filter = appliedFilter
        defer { if epoch == filterEpoch { isLoadingMore = false } }
        let fallback = String(localized: "More audit entries couldn't be loaded. Try again.")
        do {
            let page = try await client.auditLogs(filter: filter, cursor: cursor, limit: Self.pageSize)
            guard epoch == filterEpoch else { return }
            let known = Set(entries.map(\.id))
            entries.append(contentsOf: page.items.filter { !known.contains($0.id) })
            setCursor(page.page)
            loadMoreErrorMessage = nil
            loadMoreFailure = nil
        } catch let error as APIError {
            guard epoch == filterEpoch else { return }
            let failure = ServerSectionFailure.classify(error, fallback: fallback)
            guard failure.belongsToCurrentSession(sessionState) else { return }
            loadMoreFailure = failure
            loadMoreErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback)
        } catch {
            guard epoch == filterEpoch else { return }
            let failure = ServerSectionFailure.classify(error, fallback: fallback)
            loadMoreFailure = failure
            loadMoreErrorMessage = failure.message
        }
    }
}
