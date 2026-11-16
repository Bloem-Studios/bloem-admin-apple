import Foundation

struct PageInfo: Decodable, Sendable {
    let hasMore: Bool
    let nextCursor: String?

    private enum CodingKeys: String, CodingKey {
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
}

/// The v2 list envelope. A missing `page` means the whole collection came back in one response.
struct APICollection<T: Decodable & Sendable>: Decodable, Sendable {
    let items: [T]
    let page: PageInfo?
}

extension APIClient {
    func getCollection<T: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> APICollection<T> {
        try await get(path, query: query)
    }

    /// Follows `next_cursor` until the server reports no more pages. Stops early when a cursor
    /// repeats (a server that ignores the cursor would otherwise loop forever) or after `maxPages`.
    func readAllPages<T: Decodable & Sendable>(
        _ path: String,
        query: [String: String] = [:],
        pageSize: Int = 200,
        maxPages: Int = 50
    ) async throws -> [T] {
        var all: [T] = []
        var seen = Set<String>()
        var cursor: String?
        var pages = 0
        while pages < maxPages {
            var pageQuery = query
            pageQuery["limit"] = String(pageSize)
            if let cursor { pageQuery["cursor"] = cursor }
            let collection: APICollection<T> = try await getCollection(path, query: pageQuery)
            pages += 1
            all += collection.items
            guard let next = collection.page.flatMap({ $0.hasMore ? $0.nextCursor : nil }),
                  seen.insert(next).inserted else { break }
            cursor = next
        }
        return all
    }
}
