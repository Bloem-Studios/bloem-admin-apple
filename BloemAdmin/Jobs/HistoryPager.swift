import Foundation
import Observation

/// A cursor-paged list read a page at a time: the first page on `load`, the next on `loadMore`.
/// Used for a task's run history and for the Job history. A failed first page is a typed failure with
/// no rows; a failed later page keeps the rows and leaves Load more available.
@Observable
@MainActor
final class HistoryPager<Item: Decodable & Identifiable & Sendable> where Item.ID == String {
    static var pageSize: Int { 20 }

    private(set) var items: [Item] = []
    private(set) var hasMore = false
    private(set) var hasLoaded = false
    private(set) var isLoadingMore = false
    /// Why the first page could not be read, by kind.
    private(set) var loadFailure: ServerSectionFailure?
    /// Why the next page could not be read; the rows already shown stay.
    private(set) var moreFailure: String?

    @ObservationIgnored private let fetch: @Sendable (APIClient, String?) async throws -> APICollection<Item>
    @ObservationIgnored private let loadFallback: String
    @ObservationIgnored private var cursor: String?
    @ObservationIgnored private var seenCursors: Set<String> = []
    @ObservationIgnored private var generation = 0

    init(
        loadFallback: String,
        fetch: @escaping @Sendable (APIClient, String?) async throws -> APICollection<Item>
    ) {
        self.loadFallback = loadFallback
        self.fetch = fetch
    }

    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        generation += 1
        let mine = generation
        do {
            let page = try await fetch(client, nil)
            guard mine == generation else { return }
            items = page.items
            seenCursors = []
            setCursor(from: page)
            loadFailure = nil
            moreFailure = nil
        } catch {
            guard mine == generation, !(error is CancellationError) else { return }
            loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: loadFallback)
        }
        hasLoaded = true
    }

    func loadMore(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard let cursor, hasMore, !isLoadingMore else { return }
        let mine = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await fetch(client, cursor)
            guard mine == generation else { return }
            let known = Set(items.map(\.id))
            items += page.items.filter { !known.contains($0.id) }
            setCursor(from: page)
            moreFailure = nil
        } catch {
            guard mine == generation, !(error is CancellationError) else { return }
            moreFailure = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "Could not load more. Check the connection and try again.")
            )
        }
    }

    /// The next cursor, unless the server says there is no more or repeats one it already gave.
    private func setCursor(from page: APICollection<Item>) {
        if let next = page.page.flatMap({ $0.hasMore ? $0.nextCursor : nil }), seenCursors.insert(next).inserted {
            cursor = next
            hasMore = true
        } else {
            cursor = nil
            hasMore = false
        }
    }
}

extension HistoryPager where Item == TaskExecution {
    /// `GET /api/v2/admin/tasks/{key}/history`.
    static func taskHistory(key: String) -> HistoryPager<TaskExecution> {
        HistoryPager<TaskExecution>(loadFallback: String(localized: "Could not load this task's history.")) { client, cursor in
            try await client.taskHistory(key: key, cursor: cursor, limit: HistoryPager<TaskExecution>.pageSize)
        }
    }
}

extension HistoryPager where Item == AdminJob {
    /// `GET /api/v2/admin/jobs`.
    static func jobHistory() -> HistoryPager<AdminJob> {
        HistoryPager<AdminJob>(loadFallback: String(localized: "Could not load job history.")) { client, cursor in
            try await client.adminJobs(cursor: cursor, limit: HistoryPager<AdminJob>.pageSize)
        }
    }
}
