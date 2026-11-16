import XCTest
@testable import BloemAdmin

private final class FakeCredentials: SharedCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: SharedCredential] = [:]
    var locked = false
    private(set) var writes: [(String, SharedCredential)] = []

    init(_ items: [String: SharedCredential] = [:]) { self.items = items }

    func read(serverID: String) -> SharedCredentialRead {
        lock.withLock {
            if locked { return .locked }
            return items[serverID].map(SharedCredentialRead.found) ?? .missing
        }
    }

    func write(_ credential: SharedCredential, serverID: String) throws {
        lock.withLock {
            items[serverID] = credential
            writes.append((serverID, credential))
        }
    }

    func delete(serverID: String) { lock.withLock { items[serverID] = nil } }
}

private final class MemoryData: WidgetDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var cache = WidgetDataCache()
    func load() -> WidgetDataCache { lock.withLock { cache } }
    func save(_ cache: WidgetDataCache) throws { lock.withLock { self.cache = cache } }
}

/// A server that answers from a script.
private final class ScriptedAPI: WidgetServerAPI, @unchecked Sendable {
    var sessionsResult: Result<[WidgetSessionDTO], WidgetAPIError> = .success([])
    var capabilities: Result<Bool, WidgetAPIError> = .success(true)
    var counts: Result<Int, WidgetAPIError> = .success(0)
    var pending: [WidgetRequestDTO] = []
    var librariesResult: Result<[WidgetLibraryDTO], WidgetAPIError> = .success([])
    var nodesResult: Result<[WidgetNodeDTO], WidgetAPIError> = .success([])
    var users: [WidgetUserDTO] = []
    var actResult: Result<Void, WidgetAPIError> = .success(())
    private(set) var acted: [(String, WidgetRequestAction)] = []

    func sessions() async throws -> [WidgetSessionDTO] { try sessionsResult.get() }
    func requestCapabilities() async throws -> Bool { try capabilities.get() }
    func requestCounts() async throws -> WidgetRequestCountsDTO { WidgetRequestCountsDTO(needsApproval: try counts.get()) }
    func pendingRequests(limit: Int) async throws -> [WidgetRequestDTO] { pending }
    func users() async throws -> [WidgetUserDTO] { users }
    func libraries() async throws -> [WidgetLibraryDTO] { try librariesResult.get() }
    func activeScans() async throws -> [WidgetScanRunDTO] { [] }
    func libraryRefreshJobs() async throws -> [WidgetRefreshJobDTO] { [] }
    func nodes() async throws -> [WidgetNodeDTO] { try nodesResult.get() }
    func act(on requestID: String, _ action: WidgetRequestAction) async throws {
        acted.append((requestID, action))
        try actResult.get()
    }
}

private extension WidgetSessionDTO {
    static func make(_ id: String = "s1", user: String = "Maya", title: String = "Dune", position: Double = 30, duration: Double? = 120,
                     method: String? = "direct", kbps: Int? = 8000, series: String? = nil) -> WidgetSessionDTO {
        var object: [String: Any] = [
            "session_id": id, "username": user, "media_title": title, "media_type": "movie",
            "position_seconds": position, "is_paused": false, "season_number": 1, "episode_number": 3,
        ]
        if let method { object["play_method"] = method }
        if let duration { object["file_duration"] = duration }
        if let kbps { object["stream_bitrate_kbps"] = kbps }
        if let series { object["series_name"] = series }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(WidgetSessionDTO.self, from: data)
    }
}

final class WidgetFetcherTests: XCTestCase {
    private let now = WidgetSamples.now
    private let origin = URL(string: "https://home.example.test")!
    private let snapshot = AdminSnapshot(generatedAt: WidgetSamples.now, servers: [
        SnapshotServer(id: "a", name: "Home", origin: URL(string: "https://home.example.test")),
    ])

    private func credential(_ access: String = "access-1", refresh: String? = "refresh-1") -> SharedCredential {
        SharedCredential(accessToken: access, refreshToken: refresh, updatedAt: now, source: .app)
    }

    private func fetcher(
        credentials: FakeCredentials, data: MemoryData = MemoryData(), api: @escaping @Sendable (String) -> any WidgetServerAPI,
        refresh: @escaping WidgetFetcher.Refresher = { _, _ in throw WidgetAPIError(status: 401) }
    ) -> WidgetFetcher {
        WidgetFetcher(
            credentials: credentials, lock: CredentialRefreshLock(fileURL: nil), dataStore: data,
            api: { _, token in api(token) }, refresh: refresh, now: { [now] in now }
        )
    }

    // MARK: Mapping

    func testNowPlayingMapsRowsAndTotals() async {
        let api = ScriptedAPI()
        api.sessionsResult = .success([
            .make("s1", user: "Maya", title: "Dune", position: 30, duration: 120, method: "direct", kbps: 8000),
            .make("s2", user: "Tomas", title: "Ep", position: 0, duration: nil, method: "transcode", kbps: 4000, series: "The Bear"),
        ])
        let board = await fetcher(credentials: FakeCredentials(["a": credential()]), api: { _ in api }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.total, 2)
        XCTAssertEqual(board.secondaryTotal, 12_000)
        XCTAssertEqual(board.items[0].progress, 0.25)
        XCTAssertEqual(board.items[0].delivery, .direct)
        XCTAssertNil(board.items[1].progress, "an unknown length has no progress")
        XCTAssertEqual(board.items[1].delivery, .transcode)
        XCTAssertEqual(board.items[1].title, "The Bear · S1E3 · Ep", "the app's own title: series, season and episode, then the name")
        XCTAssertEqual(board.state(now: now).phase, .content)
    }

    func testNothingPlayingIsEmpty() async {
        let board = await fetcher(credentials: FakeCredentials(["a": credential()]), api: { _ in ScriptedAPI() })
            .streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.state(now: now).phase, .empty)
    }

    func testRequestsMapTheNewestPendingWithWhoAndTheTotalFromTheCounts() async {
        let api = ScriptedAPI()
        api.counts = .success(7)
        api.pending = [WidgetRequestDTO(id: "r1", title: "Dune", year: 2024, requestedByUserID: "u1", createdAt: "2026-11-15T10:00:00.250Z")]
        api.users = [WidgetUserDTO(id: "u1", username: "maya")]
        let board = await fetcher(credentials: FakeCredentials(["a": credential()]), api: { _ in api }).requests(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.total, 7)
        XCTAssertEqual(board.items.first?.title, "Dune (2024)")
        XCTAssertEqual(board.items.first?.requester, "maya")
        XCTAssertNotNil(board.items.first?.createdAt)
    }

    func testRequestsOnAServerWithoutRequestAdministrationAreNotAvailable() async {
        let api = ScriptedAPI()
        api.capabilities = .success(false)
        let board = await fetcher(credentials: FakeCredentials(["a": credential()]), api: { _ in api }).requests(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.state(now: now).phase, .unavailable)
        let missing = ScriptedAPI()
        missing.capabilities = .failure(WidgetAPIError(status: 404))
        let board404 = await fetcher(credentials: FakeCredentials(["a": credential()]), api: { _ in missing }).requests(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board404.state(now: now).phase, .unavailable)
    }

    func testLibrariesMapTheLastScanAndTheWarning() {
        let server = WidgetServer(id: "a", name: "Home", origin: origin)
        let libraries = [
            WidgetLibraryDTO(id: "l1", name: "Films", enabled: true, lastScannedAt: "2026-11-15T09:00:00Z", scanWarningCode: nil),
            WidgetLibraryDTO(id: "l2", name: "Music", enabled: true, lastScannedAt: nil, scanWarningCode: "empty_root"),
            WidgetLibraryDTO(id: "l3", name: "Off", enabled: false, lastScannedAt: nil, scanWarningCode: nil),
        ]
        let runs = [WidgetScanRunDTO(id: "x", libraryID: "l1", status: "running")]
        let items = WidgetLibraryMapper.items(libraries: libraries, runs: runs, jobs: [], server: server)
        XCTAssertEqual(items.map(\.name), ["Films", "Music"], "a disabled library is left out, the rest sorted by name")
        XCTAssertEqual(items[0].activity?.phase, .running)
        XCTAssertNil(items[1].activity)
        XCTAssertEqual(items[1].warning, "The scan found no media files")
        XCTAssertNotNil(items[0].lastScannedAt)
    }

    func testARunningRefreshReportsItsProgress() {
        let server = WidgetServer(id: "a", name: "Home", origin: origin)
        let job = WidgetRefreshJobDTO(libraryID: "l1", state: "running", terminal: false, progress: .init(current: 40, total: 200))
        let items = WidgetLibraryMapper.items(
            libraries: [WidgetLibraryDTO(id: "l1", name: "Films", enabled: true, lastScannedAt: nil, scanWarningCode: nil)],
            runs: [], jobs: [job], server: server
        )
        XCTAssertEqual(items[0].activity?.progress ?? 0, 0.2, accuracy: 0.0001)
    }

    func testNodesMapStateAndTheFullestDisk() throws {
        let json = """
        {"id":"n1","name":"transcode-1","type":"transcode","enabled":true,"healthy":true,"drain_state":"none","drain_requested":false,
         "resources":{"system":{"cpu_pct":34,"mem_used_mb":2048,"mem_total_mb":4096,
         "disks":[{"used_gb":50,"total_gb":100},{"used_gb":90,"total_gb":100},{"used_gb":1,"total_gb":0,"unavailable":true}]}}}
        """
        let node = try JSONDecoder().decode(WidgetNodeDTO.self, from: Data(json.utf8))
        let item = WidgetNodeMapper.item(node, server: WidgetServer(id: "a", name: "Home", origin: origin))
        XCTAssertEqual(item.health, .healthy)
        XCTAssertEqual(item.cpuPercent, 34)
        XCTAssertEqual(item.memoryPercent, 50)
        XCTAssertEqual(item.diskPercent, 90)
        func health(enabled: Bool, healthy: Bool, drain: String, requested: Bool, type: String = "transcode") -> NodeHealth {
            let dto = WidgetNodeDTO(id: "n", name: "n", type: type, enabled: enabled, healthy: healthy, drainState: drain, drainRequested: requested, resources: nil)
            return WidgetNodeMapper.item(dto, server: WidgetServer(id: "a", name: "Home", origin: origin)).health
        }
        XCTAssertEqual(health(enabled: false, healthy: true, drain: "none", requested: false), .disabled)
        XCTAssertEqual(health(enabled: true, healthy: false, drain: "none", requested: false), .unhealthy)
        XCTAssertEqual(health(enabled: true, healthy: true, drain: "drained", requested: true), .drained)
        XCTAssertEqual(health(enabled: true, healthy: true, drain: "draining", requested: true), .draining)
        XCTAssertEqual(health(enabled: true, healthy: true, drain: "draining", requested: true, type: "proxy"), .healthy, "a proxy node does not drain")
        let missing = WidgetNodeMapper.item(
            WidgetNodeDTO(id: "n", name: "n", type: nil, enabled: true, healthy: true, drainState: nil, drainRequested: nil, resources: nil),
            server: WidgetServer(id: "a", name: "Home", origin: origin)
        )
        XCTAssertNil(missing.cpuPercent)
        XCTAssertNil(missing.diskPercent)
    }

    // MARK: Conditions

    func testNoSavedSignInIsSignedOut() async {
        let board = await fetcher(credentials: FakeCredentials(), api: { _ in ScriptedAPI() }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.state(now: now).phase, .signedOut)
    }

    func testALockedPhoneKeepsTheLastDataAndDoesNotAskTheServer() async {
        let data = MemoryData()
        let api = ScriptedAPI()
        api.sessionsResult = .success([.make()])
        let credentials = FakeCredentials(["a": credential()])
        _ = await fetcher(credentials: credentials, data: data, api: { _ in api }).streams(snapshot: snapshot, serverID: nil)
        credentials.locked = true
        let board = await fetcher(credentials: credentials, data: data, api: { _ in
            XCTFail("a locked phone must not reach the server"); return ScriptedAPI()
        }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.feeds[0].condition, .deviceLocked)
        XCTAssertEqual(board.total, 1)
    }

    func testAnUnreachableServerKeepsItsLastDataAndSaysSo() async {
        let data = MemoryData()
        let good = ScriptedAPI()
        good.sessionsResult = .success([.make()])
        let credentials = FakeCredentials(["a": credential()])
        _ = await fetcher(credentials: credentials, data: data, api: { _ in good }).streams(snapshot: snapshot, serverID: nil)
        let down = ScriptedAPI()
        down.sessionsResult = .failure(.transport)
        let board = await fetcher(credentials: credentials, data: data, api: { _ in down }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.feeds[0].condition, .unreachable)
        XCTAssertEqual(board.items.count, 1)
        let state = board.state(now: now)
        XCTAssertEqual(state.phase, .content)
        XCTAssertEqual(state.unreachableNames, ["Home"])
        XCTAssertEqual(state.updatedAt, now)
    }

    func testAServerErrorCountsAsUnreachableAndAMissingRouteAsNotAvailable() async {
        let failing = ScriptedAPI()
        failing.sessionsResult = .failure(WidgetAPIError(status: 503))
        let credentials = FakeCredentials(["a": credential()])
        let down = await fetcher(credentials: credentials, api: { _ in failing }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(down.state(now: now).phase, .unreachable(serverName: "Home"))
        let missing = ScriptedAPI()
        missing.sessionsResult = .failure(WidgetAPIError(status: 404))
        let none = await fetcher(credentials: credentials, api: { _ in missing }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(none.state(now: now).phase, .unavailable)
    }

    func testAnInsecureAddressIsNeverAsked() async {
        let insecure = AdminSnapshot(generatedAt: now, servers: [SnapshotServer(id: "a", name: "Home", origin: nil)])
        let board = await fetcher(credentials: FakeCredentials(["a": credential()]), api: { _ in
            XCTFail("no request without an HTTPS origin"); return ScriptedAPI()
        }).streams(snapshot: insecure, serverID: nil)
        XCTAssertEqual(board.state(now: now).phase, .unavailable)
    }

    // MARK: Token refresh

    func testARejectedTokenIsRefreshedOnceAndTheRotatedPairIsStored() async {
        let credentials = FakeCredentials(["a": credential("old", refresh: "refresh-old")])
        let api = ScriptedAPI()
        api.sessionsResult = .success([.make()])
        let seenTokens = TokenLog()
        let board = await fetcher(
            credentials: credentials,
            api: { token in
                seenTokens.add(token)
                if token == "old" { let rejected = ScriptedAPI(); rejected.sessionsResult = .failure(WidgetAPIError(status: 401)); return rejected }
                return api
            },
            refresh: { _, refreshToken in
                XCTAssertEqual(refreshToken, "refresh-old")
                return WidgetTokenPair(accessToken: "new", refreshToken: "refresh-new")
            }
        ).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.total, 1)
        XCTAssertEqual(seenTokens.all, ["old", "new"])
        let stored = credentials.writes.last?.1
        XCTAssertEqual(stored?.accessToken, "new")
        XCTAssertEqual(stored?.refreshToken, "refresh-new")
        XCTAssertEqual(stored?.source, .widget, "the app adopts what the widget rotated")
    }

    func testARefreshTheAppAlreadyDidIsNotSpentAgain() async {
        let credentials = FakeCredentials(["a": credential("old")])
        let api = ScriptedAPI()
        api.sessionsResult = .success([.make()])
        let time = now
        let board = await fetcher(
            credentials: credentials,
            api: { token in
                if token == "old" {
                    // While the widget was asking, the app refreshed and wrote its new tokens.
                    try? credentials.write(SharedCredential(accessToken: "app-new", refreshToken: "r", updatedAt: time, source: .app), serverID: "a")
                    let rejected = ScriptedAPI(); rejected.sessionsResult = .failure(WidgetAPIError(status: 401)); return rejected
                }
                return api
            },
            refresh: { _, _ in XCTFail("the refresh token was already spent by the app"); throw WidgetAPIError(status: 401) }
        ).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.total, 1)
    }

    func testARefreshThatFailsIsSignedOutAndLeavesTheStoredTokensAlone() async {
        let credentials = FakeCredentials(["a": credential("old")])
        let rejected = ScriptedAPI()
        rejected.sessionsResult = .failure(WidgetAPIError(status: 401))
        let board = await fetcher(credentials: credentials, api: { _ in rejected }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.state(now: now).phase, .signedOut)
        XCTAssertTrue(credentials.writes.isEmpty)
    }

    func testNoRefreshTokenMeansSignedOutAfterARejection() async {
        let credentials = FakeCredentials(["a": credential("old", refresh: nil)])
        let rejected = ScriptedAPI()
        rejected.sessionsResult = .failure(WidgetAPIError(status: 401))
        let board = await fetcher(credentials: credentials, api: { _ in rejected }).streams(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(board.state(now: now).phase, .signedOut)
    }

    // MARK: Counts for Server status

    func testServerStatusCountsComeFromTheServerAndAreMergedIntoTheSnapshot() async {
        let api = ScriptedAPI()
        api.sessionsResult = .success([.make("a"), .make("b")])
        api.counts = .success(5)
        let counts = await fetcher(credentials: FakeCredentials(["a": credential()]), api: { _ in api }).counts(snapshot: snapshot, serverID: nil)
        XCTAssertEqual(counts["a"]?.streams, 2)
        XCTAssertEqual(counts["a"]?.requests, 5)
        let merged = snapshot.applying(counts, at: now)
        XCTAssertEqual(merged.servers[0].activeStreams, 2)
        XCTAssertEqual(merged.servers[0].requestsWaiting, 5)
        XCTAssertEqual(merged.servers[0].countsAt, now)
    }

    func testServerStatusCountsFallBackToTheAppsLastCountsWithoutASignIn() async {
        var old = snapshot
        old.servers[0].activeStreams = 4
        old.servers[0].countsAt = now.addingTimeInterval(-600)
        let counts = await fetcher(credentials: FakeCredentials(), api: { _ in ScriptedAPI() }).counts(snapshot: old, serverID: nil)
        XCTAssertTrue(counts.isEmpty)
        let merged = old.applying(counts, at: now)
        XCTAssertEqual(merged.servers[0].activeStreams, 4, "the app's counts stay")
        XCTAssertEqual(merged.servers[0].countsAt, old.servers[0].countsAt, "and keep the time they were read")
    }

    // MARK: Saving

    func testReadingOneBoardDoesNotEraseAnother() async {
        let data = MemoryData()
        let api = ScriptedAPI()
        api.sessionsResult = .success([.make()])
        api.counts = .success(2)
        let f = fetcher(credentials: FakeCredentials(["a": credential()]), data: data, api: { _ in api })
        _ = await f.streams(snapshot: snapshot, serverID: nil)
        _ = await f.requests(snapshot: snapshot, serverID: nil)
        let cache = data.load()
        XCTAssertEqual(cache.streams["a"]?.total, 1)
        XCTAssertEqual(cache.requests["a"]?.total, 2)
    }

    func testRemovedServersLeaveTheCache() async {
        let data = MemoryData()
        var cache = WidgetDataCache()
        cache.streams["gone"] = ServerFeed(serverID: "gone", serverName: "Gone", condition: .current, items: [], total: 1, asOf: now)
        try? data.save(cache)
        _ = await fetcher(credentials: FakeCredentials(["a": credential()]), data: data, api: { _ in ScriptedAPI() })
            .streams(snapshot: snapshot, serverID: nil)
        XCTAssertNil(data.load().streams["gone"])
    }
}

private final class TokenLog: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String] = []
    func add(_ token: String) { lock.withLock { tokens.append(token) } }
    var all: [String] { lock.withLock { tokens } }
}
