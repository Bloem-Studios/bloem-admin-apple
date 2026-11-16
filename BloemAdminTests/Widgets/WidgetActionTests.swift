import AppIntents
import XCTest
@testable import BloemAdmin

private final class ActionStore: WidgetDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: WidgetDataCache
    init(_ cache: WidgetDataCache) { self.cache = cache }
    func load() -> WidgetDataCache { lock.withLock { cache } }
    func save(_ cache: WidgetDataCache) throws { lock.withLock { self.cache = cache } }
}

private final class ActionCredentials: SharedCredentialStoring, @unchecked Sendable {
    let credential: SharedCredentialRead
    init(_ credential: SharedCredentialRead) { self.credential = credential }
    func read(serverID: String) -> SharedCredentialRead { credential }
    func write(_ credential: SharedCredential, serverID: String) throws {}
    func delete(serverID: String) {}
}

private final class ActionAPI: WidgetServerAPI, @unchecked Sendable {
    let result: Result<Void, WidgetAPIError>
    private let lock = NSLock()
    private(set) var calls: [(String, WidgetRequestAction)] = []
    init(_ result: Result<Void, WidgetAPIError>) { self.result = result }
    func sessions() async throws -> [WidgetSessionDTO] { [] }
    func requestCapabilities() async throws -> Bool { true }
    func requestCounts() async throws -> WidgetRequestCountsDTO { WidgetRequestCountsDTO(needsApproval: 0) }
    func pendingRequests(limit: Int) async throws -> [WidgetRequestDTO] { [] }
    func users() async throws -> [WidgetUserDTO] { [] }
    func libraries() async throws -> [WidgetLibraryDTO] { [] }
    func activeScans() async throws -> [WidgetScanRunDTO] { [] }
    func libraryRefreshJobs() async throws -> [WidgetRefreshJobDTO] { [] }
    func nodes() async throws -> [WidgetNodeDTO] { [] }
    func act(on requestID: String, _ action: WidgetRequestAction) async throws {
        lock.withLock { calls.append((requestID, action)) }
        try result.get()
    }
}

/// Approve and Decline from a widget: the intents' policy, what they send, and what the widget shows after.
final class WidgetActionTests: XCTestCase {
    private let now = WidgetSamples.now
    private let snapshot = WidgetSamples.snapshot

    private func cache() -> WidgetDataCache {
        var cache = WidgetDataCache()
        cache.requests["home"] = ServerFeed(
            serverID: "home", serverName: "Silo Home", condition: .current,
            items: WidgetSamples.requests, total: 4, asOf: now
        )
        return cache
    }

    private func fetcher(api: any WidgetServerAPI, store: ActionStore, credential: SharedCredentialRead? = nil) -> WidgetFetcher {
        let found = credential ?? .found(SharedCredential(accessToken: "t", refreshToken: nil, updatedAt: now, source: .app))
        return WidgetFetcher(
            credentials: ActionCredentials(found), lock: CredentialRefreshLock(fileURL: nil), dataStore: store,
            api: { _, _ in api }, refresh: { _, _ in throw WidgetAPIError(status: 401) }, now: { [now] in now }
        )
    }

    // MARK: Intents

    func testApproveAndDeclineNeedTheDeviceToBeUnlocked() {
        let required = String(describing: IntentAuthenticationPolicy.requiresAuthentication)
        XCTAssertEqual(String(describing: ApproveRequestIntent.authenticationPolicy), required)
        XCTAssertEqual(String(describing: DeclineRequestIntent.authenticationPolicy), required)
        XCTAssertNotEqual(String(describing: IntentAuthenticationPolicy.alwaysAllowed), required)
    }

    func testTheIntentsCarryTheServerAndTheRequest() {
        let approve = ApproveRequestIntent(serverID: "home", requestID: "r1")
        XCTAssertEqual(approve.serverID, "home")
        XCTAssertEqual(approve.requestID, "r1")
        let decline = DeclineRequestIntent(serverID: "office", requestID: "r9")
        XCTAssertEqual(decline.serverID, "office")
        XCTAssertEqual(decline.requestID, "r9")
    }

    func testNoWidgetIntentIsOfferedToSiri() {
        XCTAssertFalse(RefreshWidgetsIntent.isDiscoverable)
        XCTAssertFalse(ApproveRequestIntent.isDiscoverable)
        XCTAssertFalse(DeclineRequestIntent.isDiscoverable)
    }

    func testTheOnlyRequestActionsAreApproveAndDecline() {
        // Nothing destructive is reachable from a widget: no delete, suspend, drain or sign out.
        XCTAssertEqual(Set(["approve", "decline"]), Set([WidgetRequestAction.approve, .decline].map(\.rawValue)))
        let forbidden = ["delete", "suspend", "drain", "signOut", "sign-out", "remove", "terminate"]
        let intents = (try? SourceTree.sources(in: "BloemAdmin/Shared/Widgets").first { $0.path == "WidgetIntents.swift" }?.lines) ?? []
        for line in intents.filter({ $0.contains("struct ") && $0.contains("Intent") }) {
            for word in forbidden { XCTAssertFalse(line.lowercased().contains(word), line) }
        }
    }

    // MARK: Approve and decline

    func testApproveSendsTheRequestAndRemovesItFromTheWidget() async {
        let api = ActionAPI(.success(()))
        let store = ActionStore(cache())
        let done = await RequestActionRunner.run(
            .approve, serverID: "home", requestID: "r1", fetcher: fetcher(api: api, store: store), snapshot: snapshot
        )
        XCTAssertTrue(done)
        XCTAssertEqual(api.calls.map(\.0), ["r1"])
        XCTAssertEqual(api.calls.map(\.1), [.approve])
        let feed = store.load().requests["home"]
        XCTAssertEqual(feed?.items.map(\.id), ["r2", "r3", "r4"])
        XCTAssertEqual(feed?.total, 3)
        XCTAssertNil(store.load().notice)
    }

    func testDeclineSendsDecline() async {
        let api = ActionAPI(.success(()))
        let store = ActionStore(cache())
        let done = await RequestActionRunner.run(
            .decline, serverID: "home", requestID: "r2", fetcher: fetcher(api: api, store: store), snapshot: snapshot
        )
        XCTAssertTrue(done)
        XCTAssertEqual(api.calls.map(\.1), [.decline])
        XCTAssertEqual(store.load().requests["home"]?.total, 3)
    }

    func testAFailedApproveLeavesTheRequestAndSaysCouldntApprove() async {
        let store = ActionStore(cache())
        let done = await RequestActionRunner.run(
            .approve, serverID: "home", requestID: "r1",
            fetcher: fetcher(api: ActionAPI(.failure(WidgetAPIError(status: 409))), store: store), snapshot: snapshot
        )
        XCTAssertFalse(done)
        XCTAssertEqual(store.load().requests["home"]?.items.count, 4, "the request stays")
        XCTAssertEqual(store.load().notice?.text, "Couldn't approve, open the app")
        XCTAssertEqual(store.load().notice?.requestID, "r1")
    }

    func testAFailedDeclineSaysCouldntDecline() async {
        let store = ActionStore(cache())
        _ = await RequestActionRunner.run(
            .decline, serverID: "home", requestID: "r1",
            fetcher: fetcher(api: ActionAPI(.failure(.transport)), store: store), snapshot: snapshot
        )
        XCTAssertEqual(store.load().notice?.text, "Couldn't decline, open the app")
    }

    func testNoSignInOrALockedPhoneFailsTheActionWithoutAskingTheServer() async {
        for credential in [SharedCredentialRead.missing, .locked] {
            let api = ActionAPI(.success(()))
            let store = ActionStore(cache())
            let done = await RequestActionRunner.run(
                .approve, serverID: "home", requestID: "r1", fetcher: fetcher(api: api, store: store, credential: credential), snapshot: snapshot
            )
            XCTAssertFalse(done)
            XCTAssertTrue(api.calls.isEmpty)
            XCTAssertEqual(store.load().notice?.text, "Couldn't approve, open the app")
        }
    }

    func testAnUnknownServerOrNoFetcherDoesNothing() async {
        let api = ActionAPI(.success(()))
        let store = ActionStore(cache())
        let unknown = await RequestActionRunner.run(
            .approve, serverID: "nope", requestID: "r1", fetcher: fetcher(api: api, store: store), snapshot: snapshot
        )
        XCTAssertFalse(unknown)
        let none = await RequestActionRunner.run(.approve, serverID: "home", requestID: "r1", fetcher: nil, snapshot: snapshot)
        XCTAssertFalse(none)
        XCTAssertTrue(api.calls.isEmpty)
    }

    func testTheNoteGoesWhenTheRequestIsGoneFromAFreshListAndStaysWhileItIsThere() async {
        var seeded = cache()
        seeded.notice = WidgetActionNotice(requestID: "r1", serverID: "home", text: "Couldn't approve, open the app", at: now)
        // The server still lists r1: the note stays.
        let stillThere = ActionStore(seeded)
        let listing = ListingAPI(pending: [WidgetRequestDTO(id: "r1", title: "Dune", year: nil, requestedByUserID: nil, createdAt: nil)])
        _ = await fetcher(api: listing, store: stillThere).requests(snapshot: snapshot, serverID: nil)
        XCTAssertNotNil(stillThere.load().notice)
        // The server no longer lists it: the note goes.
        let gone = ActionStore(seeded)
        _ = await fetcher(api: ListingAPI(pending: []), store: gone).requests(snapshot: snapshot, serverID: nil)
        XCTAssertNil(gone.load().notice)
    }
}

private final class ListingAPI: WidgetServerAPI, @unchecked Sendable {
    let pending: [WidgetRequestDTO]
    init(pending: [WidgetRequestDTO]) { self.pending = pending }
    func sessions() async throws -> [WidgetSessionDTO] { [] }
    func requestCapabilities() async throws -> Bool { true }
    func requestCounts() async throws -> WidgetRequestCountsDTO { WidgetRequestCountsDTO(needsApproval: pending.count) }
    func pendingRequests(limit: Int) async throws -> [WidgetRequestDTO] { pending }
    func users() async throws -> [WidgetUserDTO] { [] }
    func libraries() async throws -> [WidgetLibraryDTO] { [] }
    func activeScans() async throws -> [WidgetScanRunDTO] { [] }
    func libraryRefreshJobs() async throws -> [WidgetRefreshJobDTO] { [] }
    func nodes() async throws -> [WidgetNodeDTO] { [] }
    func act(on requestID: String, _ action: WidgetRequestAction) async throws {}
}
