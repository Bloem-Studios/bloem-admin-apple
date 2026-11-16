import Foundation
import Observation

@Observable
@MainActor
final class ActivityViewModel {
    private(set) var entries: [PlaybackHistoryEntry] = []
    /// Reserved for the first-page `load()` failures only — drives
    /// ActivityListView's full-screen failure page.
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// Set by `loadMore` on failure, surfaced inline instead of the
    /// full-screen overlay so a failed "Load more" doesn't hide the
    /// already-loaded history — mirrors the errorMessage/actionErrorMessage
    /// split used by every mutating view model in the app.
    private(set) var loadMoreErrorMessage: String?
    private(set) var loadMoreFailure: ServerSectionFailure?
    private(set) var isLoadingMore = false
    /// Guards an explicit `load()` against a second explicit load for the same filter.
    private(set) var isLoading = false
    private var isPolling = false
    /// The cursor for the page after the last one loaded; nil means there is none.
    private var nextCursor: String?
    /// True once a continuation page has been appended. A poll then refreshes only the first
    /// page's rows and leaves the cursor alone.
    private var loadedMore = false
    /// The filter the rows and cursor belong to. nil before the first load. Captured here, not read
    /// from the view's pickers, so `loadMore` and polls always continue the same query the rows came from.
    private var activeFilter: HistoryFilter?
    /// Bumped whenever the filter changes. A `loadMore` that started under an older value
    /// discards its result.
    private var filterEpoch = 0
    private var requestID = 0

    private(set) var hasMore = false
    nonisolated static let pageSize = 50

    /// The filter the current rows were loaded with (empty when unfiltered).
    var appliedFilter: HistoryFilter { activeFilter ?? HistoryFilter() }

    /// True once the user has paged past the first screen via `loadMore`.
    var hasLoadedBeyondFirstPage: Bool { loadedMore }

    /// Mints a load token for `apply`. Call synchronously right before the fetch it guards.
    /// A changed filter clears the rows, cursor and `hasMore` here, before the request, so a
    /// failed load under the new filter shows neither the old rows nor a Load more.
    func beginLoad(filter: HistoryFilter = HistoryFilter()) -> Int {
        requestID += 1
        let filter = filter.normalized
        if filter != activeFilter {
            activeFilter = filter
            filterEpoch += 1
            entries = []
            nextCursor = nil
            hasMore = false
            loadedMore = false
            isLoadingMore = false
            loadMoreErrorMessage = nil
            loadMoreFailure = nil
            loadFailure = nil
        }
        return requestID
    }

    /// Applies a first-page outcome if `token` is still the newest and `userID` is still the
    /// current filter; anything else is discarded. With `merge` (polls) a section that has
    /// paged on, or has a Load more in flight, keeps its rows and cursor: first-page rows replace
    /// older copies by session id. An explicit (non-merge) apply no-ops while a Load more is in
    /// flight for the same filter.
    func apply(filter: HistoryFilter, _ result: Result<APICollection<PlaybackHistoryEntry>, Error>, token: Int, merge: Bool = false, sessionState: ServerScopedSession?) {
        guard token == requestID, filter.normalized == activeFilter else { return }
        if !merge && isLoadingMore { return }
        switch result {
        case .success(let collection):
            if merge && (loadedMore || isLoadingMore) {
                let fresh = Set(collection.items.map(\.sessionID))
                entries = collection.items + entries.filter { !fresh.contains($0.sessionID) }
            } else {
                entries = collection.items
                setCursor(collection.page)
                loadedMore = false
            }
            loadFailure = nil
            loadMoreErrorMessage = nil
            loadMoreFailure = nil
        case .failure(let error):
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "Playback history couldn't be loaded. Try again."))
        }
    }

    private func setCursor(_ page: PageInfo?) {
        nextCursor = page.flatMap { $0.hasMore ? $0.nextCursor : nil }
        hasMore = nextCursor != nil
    }

    /// Loads page one for `filter` (explicit: first load, a changed filter, pull to refresh).
    func load(filter: HistoryFilter = HistoryFilter(), client: APIClient, sessionState: ServerScopedSession? = nil) async {
        if filter.normalized == activeFilter { guard !isLoading, !isLoadingMore else { return } }
        isLoading = true
        let token = beginLoad(filter: filter)
        let result = await fetchFirstPage(client: client, filter: filter)
        if token == requestID { isLoading = false }
        apply(filter: filter, result, token: token, sessionState: sessionState)
    }

    /// The periodic refresh: reloads page one under the filter already applied. If later pages
    /// are loaded (or loading) they stay, with their cursor.
    func pollRefresh(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard activeFilter != nil, !isPolling, !isLoading else { return }
        isPolling = true
        defer { isPolling = false }
        let filter = appliedFilter
        let token = beginLoad(filter: filter)
        let result = await fetchFirstPage(client: client, filter: filter)
        apply(filter: filter, result, token: token, merge: true, sessionState: sessionState)
    }

    private func fetchFirstPage(client: APIClient, filter: HistoryFilter) async -> Result<APICollection<PlaybackHistoryEntry>, Error> {
        do {
            return .success(try await client.playbackHistory(filter: filter, cursor: nil))
        } catch {
            return .failure(error)
        }
    }

    func loadMore(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard hasMore, let cursor = nextCursor, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let epoch = filterEpoch
        let filter = appliedFilter
        defer { if epoch == filterEpoch { isLoadingMore = false } }
        do {
            let page = try await client.playbackHistory(filter: filter, cursor: cursor)
            guard epoch == filterEpoch else { return }
            let known = Set(entries.map(\.sessionID))
            entries.append(contentsOf: page.items.filter { !known.contains($0.sessionID) })
            setCursor(page.page)
            loadedMore = true
            loadMoreErrorMessage = nil
            loadMoreFailure = nil
        } catch let error as APIError {
            guard epoch == filterEpoch else { return }
            let failure = ServerSectionFailure.classify(error, fallback: String(localized: "More playback history couldn't be loaded. Try again."))
            guard failure.belongsToCurrentSession(sessionState) else { return }
            loadMoreFailure = failure
            if let sessionState, let message = sessionState.handleAuthenticationFailure(error) {
                loadMoreErrorMessage = message
            } else {
                loadMoreErrorMessage = error.message
            }
        } catch {
            guard epoch == filterEpoch else { return }
            let failure = ServerSectionFailure.classify(error, fallback: String(localized: "More playback history couldn't be loaded. Try again."))
            loadMoreFailure = failure
            loadMoreErrorMessage = failure.message
        }
    }
}
