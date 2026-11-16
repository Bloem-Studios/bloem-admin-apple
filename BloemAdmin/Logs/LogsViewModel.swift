import Foundation
import Observation

/// The operational log (`GET /api/v2/admin/logs/app`) with its filters (`LogFilter`) and Load more.
/// Same rules as `AuditViewModel`: a changed filter clears rows, cursor and `hasMore` before its
/// request, a result for a superseded filter is discarded, and Load more continues the filters
/// its rows came from.
@Observable
@MainActor
final class LogsViewModel {
    private(set) var entries: [OperationalLogEntry] = []
    /// First-page failures only; drives the full-screen failure page.
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// A Load more failure, shown inline so the loaded entries stay visible.
    private(set) var loadMoreErrorMessage: String?
    private(set) var isLoadingMore = false
    private(set) var isLoading = false
    private(set) var hasMore = false
    private var nextCursor: String?
    private var activeFilter: LogFilter?
    private var filterEpoch = 0
    private var requestID = 0

    static let pageSize = 50

    func beginLoad(filter: LogFilter = LogFilter()) -> Int {
        requestID += 1
        let filter = filter.normalized
        if filter != activeFilter {
            activeFilter = filter
            filterEpoch += 1
            entries = []
            nextCursor = nil
            hasMore = false
            isLoadingMore = false
            loadMoreErrorMessage = nil
            loadFailure = nil
        }
        return requestID
    }

    func apply(filter: LogFilter, _ result: Result<APICollection<OperationalLogEntry>, Error>, token: Int, sessionState: ServerScopedSession?) {
        guard token == requestID, filter.normalized == activeFilter, !isLoadingMore else { return }
        switch result {
        case .success(let collection):
            entries = collection.items
            nextCursor = collection.page.flatMap { $0.hasMore ? $0.nextCursor : nil }
            hasMore = nextCursor != nil
            loadFailure = nil
            loadMoreErrorMessage = nil
        case .failure(let error):
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "Logs couldn't be loaded. Try again."))
        }
    }

    func load(filter: LogFilter = LogFilter(), client: APIClient, sessionState: ServerScopedSession? = nil) async {
        if filter.normalized == activeFilter { guard !isLoading, !isLoadingMore else { return } }
        isLoading = true
        let token = beginLoad(filter: filter)
        let result: Result<APICollection<OperationalLogEntry>, Error>
        do {
            result = .success(try await client.operationalLogs(filter: filter, cursor: nil, limit: Self.pageSize))
        } catch {
            result = .failure(error)
        }
        if token == requestID { isLoading = false }
        apply(filter: filter, result, token: token, sessionState: sessionState)
    }

    func loadMore(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard hasMore, let cursor = nextCursor, let filter = activeFilter, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let epoch = filterEpoch
        defer { if epoch == filterEpoch { isLoadingMore = false } }
        do {
            let page = try await client.operationalLogs(filter: filter, cursor: cursor, limit: Self.pageSize)
            guard epoch == filterEpoch else { return }
            let known = Set(entries.map(\.id))
            entries.append(contentsOf: page.items.filter { !known.contains($0.id) })
            nextCursor = page.page.flatMap { $0.hasMore ? $0.nextCursor : nil }
            hasMore = nextCursor != nil
            loadMoreErrorMessage = nil
        } catch {
            guard epoch == filterEpoch else { return }
            loadMoreErrorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "More log entries couldn't be loaded. Try again."))
        }
    }
}
