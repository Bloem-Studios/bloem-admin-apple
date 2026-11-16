import Foundation
import Observation

/// The API keys page of one server: a list with Load more, and Revoke. Creating keys and changing rate tiers
/// stay on the web, where the secret can be shown once. Revoking is one conditional DELETE: the key's current
/// version is read first and sent as `If-Match`, so a key that changed since the list was read is never
/// revoked blind.
@Observable
@MainActor
final class APIKeysViewModel {
    /// Nil until the first page has been read.
    private(set) var keys: [AdminAPIKey]?
    private(set) var nextCursor: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// Why the first read failed, by kind; drives the full-page failure view.
    private(set) var loadFailure: ServerSectionFailure?
    /// The server runs no API key administration: not a failure, so nothing to retry.
    private(set) var isUnavailable = false
    private(set) var moreFailed = false
    /// What the last revoke did, in words.
    private(set) var notice: String?
    /// Why the last revoke failed.
    private(set) var errorMessage: String?
    private var busyIDs: Set<String> = []

    private let client: APIClient
    private let serverName: String?
    /// Set by the page when it appears, from the environment; the model is built before that is known.
    var sessionState: ServerScopedSession?
    private var generation = 0

    init(client: APIClient, serverName: String? = nil, sessionState: ServerScopedSession? = nil) {
        self.client = client
        self.serverName = serverName
        self.sessionState = sessionState
    }

    var hasMore: Bool { nextCursor != nil }

    func isBusy(_ key: AdminAPIKey) -> Bool { busyIDs.contains(key.id) }

    func dismissMessages() {
        notice = nil
        errorMessage = nil
    }

    /// Reads the first page again and replaces the list.
    func load() async {
        generation += 1
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        do {
            let page = try await client.apiKeysPage(cursor: nil)
            guard token == generation else { return }
            keys = page.items
            nextCursor = Self.cursor(page)
            loadFailure = nil
            isUnavailable = false
            moreFailed = false
        } catch {
            guard token == generation else { return }
            if RequestAvailability.isUnavailable(error) {
                isUnavailable = true
                keys = []
                nextCursor = nil
                loadFailure = nil
            } else {
                loadFailure = ErrorMessage.failure(
                    for: error, sessionState: sessionState,
                    fallback: String(localized: "The API keys could not be loaded."), serverName: serverName
                )
            }
        }
        hasLoaded = true
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let token = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.apiKeysPage(cursor: cursor)
            guard token == generation else { return }
            let known = Set((keys ?? []).map(\.id))
            keys = (keys ?? []) + page.items.filter { !known.contains($0.id) }
            nextCursor = Self.cursor(page)
            moreFailed = false
        } catch {
            guard token == generation else { return }
            moreFailed = true
        }
    }

    /// Revokes `key`. True when it is gone afterwards, whether this call or someone else's removed it. A refusal
    /// is in `errorMessage`; nothing is sent twice.
    @discardableResult
    func revoke(_ key: AdminAPIKey) async -> Bool {
        guard !busyIDs.contains(key.id) else { return false }
        busyIDs.insert(key.id)
        defer { busyIDs.remove(key.id) }
        notice = nil
        errorMessage = nil
        do {
            guard let version = try await client.apiKeyVersion(id: key.id), !version.isEmpty else {
                errorMessage = ErrorMessage.named(
                    String(localized: "The server sent no version for this key, so it can't be revoked safely. Try again, or revoke it on the web."),
                    serverName: serverName
                )
                return false
            }
            try await client.deleteAPIKey(id: key.id, validator: version)
            await load()
            notice = String(localized: "Revoked \(key.displayLabel)")
            return true
        } catch let error as APIError where error.statusCode == 404 {
            await load()
            notice = String(localized: "\(key.displayLabel) was already revoked")
            return true
        } catch let error as APIError where error.statusCode == 412 || error.statusCode == 428 {
            await load()
            errorMessage = ErrorMessage.named(
                String(localized: "This key changed since the list was loaded. Check it and try again."), serverName: serverName
            )
            return false
        } catch {
            errorMessage = ErrorMessage.text(
                for: error, sessionState: sessionState,
                fallback: String(localized: "The key could not be revoked. Check the list and try again."), serverName: serverName
            )
            return false
        }
    }

    private static func cursor(_ page: APICollection<AdminAPIKey>) -> String? {
        let next = page.page.flatMap { $0.hasMore ? $0.nextCursor : nil }
        return next?.isEmpty == false ? next : nil
    }
}
