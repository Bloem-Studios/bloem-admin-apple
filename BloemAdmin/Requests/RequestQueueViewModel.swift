import Foundation
import Observation

/// One server's request queue, as the web admin's Requests page shows it: four views with their
/// counts, a title or TMDB ID search, a media-type filter, an optional "requested by" filter, one
/// page at a time, and the approve / decline / retry / cancel actions.
@Observable
@MainActor
final class RequestQueueViewModel {
    private(set) var view: RequestQueueView = .needsApproval
    /// True once a person picked a view; until then each load opens on `RequestQueue.defaultView`.
    private(set) var viewChosen = false
    var search = ""
    var mediaFilter: RequestMediaFilter = .all
    /// The account whose requests are shown alone; nil for every account.
    private(set) var userFilter: String?
    private(set) var counts: RequestCounts?
    private(set) var requests: [MediaRequest] = []
    private(set) var nextCursor: String?
    private(set) var hasLoaded = false
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// A failed first page: the queue shows "Requests didn't load".
    /// Why the first load failed, by kind; drives the full-screen failure page.
    private(set) var loadFailure: ServerSectionFailure?
    var errorMessage: String? { loadFailure?.message }
    /// A failed next page: the rows already shown stay.
    private(set) var moreFailed = false
    /// A refused action, shown above the queue.
    private(set) var actionErrorMessage: String?
    private(set) var busyRequestIDs: Set<String> = []
    /// Account ID to name, for the "requested by" line.
    private(set) var requesterNames: [String: String] = [:]

    /// The server runs no request administration (or the capabilities say so): the page says so and has
    /// nothing to retry. Pulling to refresh asks again.
    private(set) var isUnavailable = false
    /// A read failed while rows from an earlier read stay on screen.
    private(set) var isStale = false
    private(set) var lastLoadedAt: Date?

    private var generation = 0
    private var namesLoaded = false
    private var capabilitiesChecked = false
    private let now: () -> Date

    init(now: @escaping () -> Date = { Date() }) {
        self.now = now
    }

    /// False once the server said it has no request administration: the page stops polling.
    var shouldPoll: Bool { !isUnavailable }

    /// "Couldn't refresh · last updated 14:32", while a failed read leaves older rows on screen.
    var staleNotice: String? {
        guard isStale, let lastLoadedAt else { return nil }
        return String(localized: "Couldn't refresh · last updated \(lastLoadedAt.formatted(date: .omitted, time: .shortened))")
    }

    /// True while any filter narrows the view, so an empty page says "No matching requests".
    var isFiltered: Bool {
        !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || mediaFilter != .all || userFilter != nil
    }

    /// Rows past the first page were loaded, so a background refresh would drop them.
    var hasLoadedMore: Bool { requests.count > APIClient.requestPageLimit }

    func requester(for request: MediaRequest) -> String {
        RequestQueue.requesterLabel(request, names: requesterNames)
    }

    func isBusy(_ request: MediaRequest) -> Bool { busyRequestIDs.contains(request.id) }

    func select(view newView: RequestQueueView) {
        viewChosen = true
        view = newView
    }

    func filter(byUser id: String) { userFilter = id }
    func clearUserFilter() { userFilter = nil }
    func dismissActionError() { actionErrorMessage = nil }

    /// Counts and the first page of the current view. Opens on what needs approval, else what is
    /// under way, until a person picks a view.
    func load(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        generation += 1
        let token = generation
        isLoading = true
        defer { if token == generation { isLoading = false } }
        if !capabilitiesChecked || isUnavailable {
            switch await readCapabilities(client: client) {
            case .unavailable:
                guard token == generation else { return }
                markUnavailable()
                return
            case .available:
                guard token == generation else { return }
                isUnavailable = false
            case .unknown:
                guard token == generation else { return }
            }
        }
        // The counts are a convenience: the rows still load without them, as on the web. A lost sign-in or right is
        // not a convenience, though: nothing else will load either, so the page says so at once.
        var loadedCounts: RequestCounts?
        do {
            loadedCounts = try await client.requestCounts()
        } catch where RequestAvailability.isUnavailable(error) {
            guard token == generation else { return }
            markUnavailable()
            return
        } catch let error as APIError where error.statusCode == 401 || error.statusCode == 403 {
            guard token == generation else { return }
            presentFailure(error, sessionState: sessionState)
            return
        } catch {
            // Rows decide whether the page failed.
        }
        guard token == generation else { return }
        if let loadedCounts { counts = loadedCounts }
        if !viewChosen {
            // With no counts at all, open on Needs approval, as the web does.
            view = (loadedCounts ?? counts).map { RequestQueue.defaultView($0) } ?? .needsApproval
        }
        do {
            let page = try await client.requestQueuePage(
                view: view, search: search, mediaType: mediaFilter.queryValue, requestedBy: userFilter
            )
            guard token == generation else { return }
            requests = page.items
            nextCursor = page.nextCursor
            loadFailure = nil
            moreFailed = false
            hasLoaded = true
            isUnavailable = false
            isStale = false
            lastLoadedAt = now()
        } catch {
            guard token == generation else { return }
            if RequestAvailability.isUnavailable(error) {
                markUnavailable()
                return
            }
            presentFailure(error, sessionState: sessionState)
        }
        await loadNamesIfNeeded(client: client)
    }

    /// A background refresh: the whole first page while nothing more was loaded, else only the counts,
    /// so a person reading further down keeps their place. Does nothing once the server has no request
    /// administration.
    func refresh(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard shouldPoll else { return }
        if hasLoadedMore {
            do {
                counts = try await client.requestCounts()
                isStale = false
                lastLoadedAt = now()
            } catch {
                if RequestAvailability.isUnavailable(error) { markUnavailable() } else { isStale = true }
            }
        } else {
            await load(client: client, sessionState: sessionState)
        }
    }

    /// A read failed: the page says why, by kind. Rows already on screen stay, and are marked out of date.
    private func presentFailure(_ error: Error, sessionState: ServerScopedSession?) {
        loadFailure = ErrorMessage.failure(for: error, sessionState: sessionState, fallback: String(localized: "The queue couldn't be loaded. Try again."))
        hasLoaded = true
        isStale = !requests.isEmpty
    }

    private enum CapabilitiesAnswer { case available, unavailable, unknown }

    /// Asked once per page, and again after the server said unavailable. A server too old to have the route, or
    /// any answer that is not a clear "unavailable", leaves the queue to say for itself.
    private func readCapabilities(client: APIClient) async -> CapabilitiesAnswer {
        do {
            let capabilities = try await client.requestCapabilities()
            capabilitiesChecked = true
            return capabilities.available ? .available : .unavailable
        } catch {
            if error is APIError { capabilitiesChecked = true }
            return RequestAvailability.isUnavailable(error) ? .unavailable : .unknown
        }
    }

    private func markUnavailable() {
        isUnavailable = true
        capabilitiesChecked = true
        hasLoaded = true
        loadFailure = nil
        isStale = false
        requests = []
        nextCursor = nil
        counts = nil
    }

    func loadMore(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        guard let cursor = nextCursor, !isLoadingMore else { return }
        let token = generation
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await client.requestQueuePage(
                view: view, search: search, mediaType: mediaFilter.queryValue, requestedBy: userFilter, cursor: cursor
            )
            guard token == generation else { return }
            let known = Set(requests.map(\.id))
            requests += page.items.filter { !known.contains($0.id) }
            nextCursor = page.nextCursor
            moreFailed = false
        } catch {
            guard token == generation else { return }
            moreFailed = true
        }
    }

    /// Runs one action, then reloads the counts and the view so the request moves to where it now
    /// belongs. Returns false when the server refused it; the reason is in `actionErrorMessage`.
    @discardableResult
    func perform(
        _ action: RequestQueueAction, on request: MediaRequest, reason: String? = nil,
        client: APIClient, sessionState: ServerScopedSession? = nil
    ) async -> Bool {
        busyRequestIDs.insert(request.id)
        defer { busyRequestIDs.remove(request.id) }
        let note = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await client.actOnRequest(
                id: request.id, action: action.requestAction,
                reason: action.asksForReason && note?.isEmpty == false ? note : nil
            )
            actionErrorMessage = nil
        } catch {
            actionErrorMessage = Self.message(for: error, sessionState: sessionState, fallback: String(localized: "The action didn't go through. Try again."))
            return false
        }
        await load(client: client, sessionState: sessionState)
        return true
    }

    private func loadNamesIfNeeded(client: APIClient) async {
        guard !namesLoaded else { return }
        // Best effort: without the account list the line says "User 12".
        guard let users = try? await client.users() else { return }
        namesLoaded = true
        requesterNames = Dictionary(users.map { ($0.id, $0.username) }, uniquingKeysWith: { first, _ in first })
    }

    static func message(for error: Error, sessionState: ServerScopedSession?, fallback: String) -> String {
        if let apiError = error as? APIError {
            return sessionState?.handleAuthenticationFailure(apiError) ?? apiError.message
        }
        if let notSignedIn = error as? NotSignedInError, let description = notSignedIn.errorDescription {
            return description
        }
        return fallback
    }
}
