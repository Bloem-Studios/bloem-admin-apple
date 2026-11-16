import Foundation

/// Body of every `POST /api/v2/admin/requests/{id}/<action>`; the contract requires an object
/// even when there is nothing to say. `reason` is only used when declining or cancelling.
struct RequestActionBody: Encodable, Sendable {
    var reason: String?
}

enum RequestAction: String, Sendable {
    case approve, decline, retry, cancel
}

/// One page of a queue view, newest request first.
struct RequestQueuePage: Sendable {
    let items: [MediaRequest]
    /// Where the next page starts; nil on the last page.
    let nextCursor: String?
}

/// `GET /api/v2/admin/requests/capabilities`: whether the server runs request administration at all. The
/// document also lists routing and Discover features; only `available` is read here.
struct RequestCapabilities: Decodable, Equatable, Sendable {
    let available: Bool
}

extension APIClient {
    /// The route allows at most 50 per page.
    static let requestPageLimit = 50

    func requestCapabilities() async throws -> RequestCapabilities {
        try await get("/api/v2/admin/requests/capabilities")
    }

    func mediaRequests() async throws -> [MediaRequest] {
        try await readAllPages("/api/v2/admin/requests", pageSize: Self.requestPageLimit)
    }

    /// One page of a queue view, filtered like the web admin's queue: `search` is a title substring
    /// or an exact TMDB ID, `mediaType` is `movie` or `series`, `requestedBy` an account ID.
    func requestQueuePage(
        view: RequestQueueView,
        search: String? = nil,
        mediaType: String? = nil,
        requestedBy: String? = nil,
        cursor: String? = nil,
        limit: Int = APIClient.requestPageLimit
    ) async throws -> RequestQueuePage {
        var query = ["view": view.rawValue, "limit": String(min(max(limit, 1), Self.requestPageLimit))]
        if let search = search?.trimmingCharacters(in: .whitespacesAndNewlines), !search.isEmpty { query["q"] = search }
        if let mediaType { query["media_type"] = mediaType }
        if let requestedBy { query["requested_by_user_id"] = requestedBy }
        if let cursor { query["cursor"] = cursor }
        let page: APICollection<MediaRequest> = try await getCollection("/api/v2/admin/requests", query: query)
        let next = page.page.flatMap { $0.hasMore ? $0.nextCursor : nil }
        return RequestQueuePage(items: page.items, nextCursor: next?.isEmpty == false ? next : nil)
    }

    func requestCounts() async throws -> RequestCounts {
        try await get("/api/v2/admin/requests/counts")
    }

    /// A request's history, newest first.
    func requestEvents(id: String) async throws -> [RequestEvent] {
        let collection: APICollection<RequestEvent> = try await getCollection(
            "/api/v2/admin/requests/\(APIPath.segment(id))/events"
        )
        return collection.items
    }

    func actOnRequest(id: String, action: RequestAction, reason: String? = nil) async throws {
        try await post(
            "/api/v2/admin/requests/\(APIPath.segment(id))/\(action.rawValue)",
            body: RequestActionBody(reason: reason)
        )
    }
}
