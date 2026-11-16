import XCTest
@testable import BloemAdmin

/// Which sections the dashboard reads, when, and what a failed read leaves behind. The fixtures are
/// shaped like the server's responses (extra fields included, which the dashboard ignores).
@MainActor
final class DashboardViewModelTests: XCTestCase {
    nonisolated static let statsJSON = """
    {
      "total_items": 1200, "total_files": 1500, "total_users": 8,
      "total_movies": 400, "total_movie_files": 420, "total_shows": 60, "total_show_files": 1080,
      "advisory_titles": 12, "active_streams": 2, "total_storage_bytes": 987654321012,
      "watch_providers": [{"provider": "trakt", "display_name": "Trakt", "registered": true}]
    }
    """

    /// `net_rx_bps` / `net_tx_bps` are bits per second in the contract.
    nonisolated static let resourcesJSON = """
    {"available": true, "stale": false, "gpu": [], "sampled_at": "2026-01-01T00:00:00.250Z",
     "system": {"cpu_pct": 42.5, "load1": 0.5, "cores": 8, "mem_used_mb": 1024, "mem_total_mb": 4096,
                "disks": [], "net_rx_bps": 8000, "net_tx_bps": 16000}}
    """
    nonisolated static let resourcesStaleJSON = resourcesJSON.replacingOccurrences(of: "\"stale\": false", with: "\"stale\": true")
    nonisolated static let resourcesUnavailableJSON = #"{"available": false, "gpu": [], "stale": false}"#

    nonisolated static let statusJSON = """
    {"started_at": "2026-11-10T06:00:00Z", "restart_required": false, "restart_requested": false,
     "health": {"postgres": {"configured": true, "ok": true, "latency_ms": 1.5},
                "redis": {"configured": false}, "errors_24h": 1, "warnings_24h": 4}}
    """
    nonisolated static let buildJSON = #"{"available": true, "build_number": 12, "display": "v1.4", "revision": "abc"}"#
    nonisolated static let nodesJSON = #"{"items": [{"id": "n1", "name": "node-1", "enabled": true, "healthy": true}]}"#
    nonisolated static let activityJSON = """
    {"hours": 24, "bucket_seconds": 3600, "from": "2026-11-12T10:00:00Z", "to": "2026-11-13T10:30:00Z",
     "buckets": [{"hour": "2026-11-13T09:00:00Z", "direct": 3, "remux": 1, "transcode": 2}],
     "reliability": {"sessions_started": 6, "finalized_sessions": 4, "completion_rate": 0.75},
     "profiles_active_24h": 5}
    """
    nonisolated static let topJSON = """
    {"days": 7, "titles": [{"media_item_id": "m1", "title": "Dune", "media_type": "movie", "plays": 3, "total_seconds": 9000}],
     "profiles": [{"user_id": "1", "username": "alex", "profile_id": "p1", "profile_name": "Kids", "plays": 2, "total_seconds": 600}]}
    """
    nonisolated static let librariesJSON = #"{"items": [{"id": "l1", "name": "Movies", "type": "movie", "paths": ["/a", "/b"], "enabled": true}]}"#
    nonisolated static let usersJSON = """
    {"items": [{"id": "1", "username": "alex", "role": "admin", "enabled": true, "last_active_at": "2026-11-13T09:00:00Z"},
               {"id": "2", "username": "amy", "role": "user", "enabled": false}], "page": {"has_more": false}}
    """
    nonisolated static let historyJSON = """
    {"items": [{"session_id": "h1", "username": "amy", "media_title": "Heat", "media_type": "movie",
                "watched_seconds": 10, "completed": false, "started_at": "2026-11-13T09:30:00Z"}]}
    """

    /// One sample a minute ending 10:00 on the 13th; the same body answers every `hours` window.
    nonisolated static func timeseriesJSON(lastSample: String = "2026-11-13T10:00:00Z") -> String {
        """
        {"resolution_seconds": 60, "from": "2026-11-13T09:58:00Z", "to": "\(lastSample)", "egress_bytes": 1500000,
         "points": [{"t": "2026-11-13T09:59:00Z", "streams": 1, "egress_kbps": 2000, "download_egress_kbps": 500},
                    {"t": "\(lastSample)", "streams": 2, "egress_kbps": 12500, "download_egress_kbps": 500}]}
        """
    }

    /// One live session, shaped like `GET /api/v2/admin/sessions`.
    nonisolated static let sessionsJSON = """
    {"items": [{"session_id": "s1", "user_id": "86", "username": "mchan969", "profile_id": "1",
                "media_title": "The Real Housewives of Miami", "media_type": "series", "play_method": "direct",
                "file_duration": 2600, "position_seconds": 169.71, "is_paused": false, "client_name": "Silo Android",
                "started_at": "2026-11-13T10:00:00.000Z"}],
     "page": {"has_more": false}}
    """

    nonisolated static func healthyRoutes() -> [String: MockHTTPState.ResponseTuple] {
        [
            "/api/v2/admin/stats": (Data(statsJSON.utf8), 200),
            "/api/v2/admin/system/resources": (Data(resourcesJSON.utf8), 200),
            "/api/v2/admin/sessions": (Data(sessionsJSON.utf8), 200),
            "/api/v2/admin/server/status": (Data(statusJSON.utf8), 200),
            "/api/v2/admin/system/build": (Data(buildJSON.utf8), 200),
            "/api/v2/admin/nodes": (Data(nodesJSON.utf8), 200),
            "/api/v2/admin/stats/playback-activity": (Data(activityJSON.utf8), 200),
            "/api/v2/admin/stats/timeseries": (Data(timeseriesJSON().utf8), 200),
            "/api/v2/admin/stats/top-activity": (Data(topJSON.utf8), 200),
            "/api/v2/libraries": (Data(librariesJSON.utf8), 200),
            "/api/v2/admin/users": (Data(usersJSON.utf8), 200),
            "/api/v2/admin/playback-history": (Data(historyJSON.utf8), 200),
        ]
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// XCTest makes a fresh instance per test, so each test gets its own harness, answering every
    /// dashboard route with a healthy fixture until a test overrides one.
    nonisolated private let http: MockHTTPHarness = {
        let harness = MockHTTPHarness()
        harness.state.pathOverrides = DashboardViewModelTests.healthyRoutes()
        return harness
    }()
    /// `https://example.test`, through this test's harness.
    private var client: APIClient { http.client }

    override func tearDown() {
        http.invalidate()
        super.tearDown()
    }

    private func requests(_ path: String) -> [URLRequest] { http.state.requests(path: path) }

    private func queries(_ path: String) -> [String] {
        requests(path).map { $0.url?.query ?? "" }.sorted()
    }

    private func route(_ path: String, _ body: String, _ status: Int = 200) {
        var routes = http.state.pathOverrides
        routes[path] = (Data(body.utf8), status)
        http.state.pathOverrides = routes
    }

    // MARK: First load

    func testALoadFillsEverySectionAndTheSixTilesInTheWebOrder() async {
        let model = DashboardViewModel()
        await model.load(client: client)

        XCTAssertEqual(model.stats?.totalMovies, 400)
        XCTAssertEqual(model.stats?.totalStorageBytes, 987_654_321_012)
        XCTAssertEqual(model.sessions.value?.count, 1)
        XCTAssertEqual(model.insights.status.value?.health?.errors24h, 1)
        XCTAssertEqual(model.insights.build.value?.display, "v1.4")
        XCTAssertEqual(model.insights.nodes.value?.count, 1)
        XCTAssertEqual(model.insights.activity.value?.profilesActive24h, 5)
        XCTAssertEqual(model.insights.top.value?.titles.first?.title, "Dune")
        XCTAssertEqual(model.insights.libraries.value?.first?.paths.count, 2)
        XCTAssertEqual(model.insights.users.value?.count, 2)
        XCTAssertEqual(model.insights.recent.value?.first?.mediaTitle, "Heat")
        XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.sampledAt)

        let fresh = ISO8601DateFormatter().date(from: "2026-11-13T10:01:00Z")!
        XCTAssertEqual(model.tiles(now: fresh).map(\.id), [.activeStreams, .egressNow, .profilesActive, .movies, .shows, .storage])
        XCTAssertEqual(
            model.visibleSections(now: fresh),
            [.tiles, .health, .nowPlaying, .concurrentStreams, .playbackActivity, .egress, .topTitles, .topProfiles, .libraries, .users, .recentActivity]
        )
    }

    func testTheEgressTileDropsOutOnceItsNewestSampleIsOverTwoMinutesOld() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        let formatter = ISO8601DateFormatter()
        XCTAssertTrue(model.tiles(now: formatter.date(from: "2026-11-13T10:02:00Z")!).contains { $0.id == .egressNow })
        let stale = model.tiles(now: formatter.date(from: "2026-11-13T10:02:01Z")!)
        XCTAssertFalse(stale.contains { $0.id == .egressNow })
        XCTAssertEqual(stale.count, 5)
    }

    func testAPollReadsEachRouteWithTheQueryTheContractDeclares() async {
        let model = DashboardViewModel()
        await model.load(client: client)

        XCTAssertEqual(queries("/api/v2/admin/stats"), [""], "a poll never forces the server's cache")
        XCTAssertEqual(queries("/api/v2/admin/system/resources"), [""])
        XCTAssertEqual(queries("/api/v2/admin/stats/timeseries"), ["hours=1", "hours=24"])
        XCTAssertEqual(queries("/api/v2/admin/stats/playback-activity"), ["hours=24"])
        XCTAssertEqual(queries("/api/v2/admin/stats/top-activity"), ["days=7&limit=5"])
        XCTAssertEqual(queries("/api/v2/admin/users"), ["limit=200"])
        XCTAssertEqual(queries("/api/v2/admin/playback-history"), ["limit=5"])
        XCTAssertEqual(queries("/api/v2/admin/sessions"), ["limit=200"])
        XCTAssertEqual(requests("/api/v2/admin/system/build").count, 1)
        XCTAssertEqual(requests("/api/v2/libraries").count, 1)
    }

    // MARK: Live sessions

    private func liveRow(_ id: String) -> AdminSession {
        AdminSession(
            sessionID: id, username: "amy", mediaTitle: "Heat", mediaType: "movie", playMethod: "directplay",
            positionSeconds: 0, fileDuration: 60, isPaused: false, clientName: nil
        )
    }

    func testADashboardOnTheSocketDoesNotReadTheSessionListOnAPoll() async {
        let model = DashboardViewModel()
        model.beginLiveSessions()

        await model.load(client: client)

        XCTAssertTrue(requests("/api/v2/admin/sessions").isEmpty, "the live source reads the list; a poll must not read it twice")
        XCTAssertNotNil(model.stats, "every other section is still read")
    }

    func testTheLiveSourcePublishesTheSessionsAndItsStateToNowPlaying() {
        let model = DashboardViewModel()
        model.beginLiveSessions()

        model.applyLive(sessions: [liveRow("a")], readFailure: nil, state: .live, failure: nil)

        XCTAssertEqual(model.sessions.value?.map(\.sessionID), ["a"])
        XCTAssertNil(model.sessions.error)
        XCTAssertEqual(model.liveState, .live)
        XCTAssertNil(model.liveFailure)

        model.applyLive(sessions: [liveRow("a")], readFailure: nil, state: .reconnecting, failure: .connection)
        XCTAssertEqual(model.liveState, .reconnecting)
        XCTAssertEqual(model.liveFailure, .connection)
    }

    func testAFailedLiveReadKeepsTheLastRowsBesideTheError() {
        let model = DashboardViewModel()
        model.applyLive(sessions: [liveRow("a")], readFailure: nil, state: .live, failure: nil)

        model.applyLive(
            sessions: [liveRow("a")],
            readFailure: .serverFailure(statusCode: 500, message: "Down"), state: .unavailable, failure: .unsupported
        )

        XCTAssertEqual(model.sessions.value?.map(\.sessionID), ["a"])
        XCTAssertEqual(model.sessions.error, "Down")
    }

    func testLeavingTheForegroundReturnsTheDashboardToPollingTheList() async {
        let model = DashboardViewModel()
        model.beginLiveSessions()
        model.applyLive(sessions: [], readFailure: nil, state: .live, failure: nil)

        model.endLiveSessions()
        await model.load(client: client)

        XCTAssertNil(model.liveState)
        XCTAssertEqual(requests("/api/v2/admin/sessions").count, 1)
    }

    func testPullToRefreshAsksTheInsightRoutesToRecomputeButNotTheLiveOnes() async {
        let model = DashboardViewModel()
        await model.load(client: client, forceRefresh: true)

        XCTAssertEqual(queries("/api/v2/admin/stats"), ["refresh=true"])
        XCTAssertEqual(queries("/api/v2/admin/stats/timeseries"), ["hours=1&refresh=true", "hours=24&refresh=true"])
        XCTAssertEqual(queries("/api/v2/admin/stats/playback-activity"), ["hours=24&refresh=true"])
        XCTAssertEqual(queries("/api/v2/admin/stats/top-activity"), ["days=7&limit=5&refresh=true"])
        XCTAssertEqual(queries("/api/v2/admin/system/resources"), [""], "a live sample has no refresh parameter")
        XCTAssertEqual(queries("/api/v2/admin/nodes"), ["limit=200"])
    }

    // MARK: Independent sections

    func testOneFailedSectionDoesNotHideTheOthers() async {
        route("/api/v2/libraries", #"{"error":"boom","message":"Libraries are down"}"#, 500)
        let model = DashboardViewModel()
        await model.load(client: client)

        XCTAssertNil(model.insights.libraries.value)
        XCTAssertEqual(model.insights.libraries.error, "Libraries are down")
        XCTAssertEqual(model.insights.users.value?.count, 2)
        XCTAssertEqual(model.stats?.totalMovies, 400)
        XCTAssertNil(model.errorMessage, "a section failure never raises the stats banner")
        XCTAssertTrue(model.visibleSections(now: t0).contains(.libraries), "a failed section keeps its place")
    }

    func testAFailedRefreshKeepsTheLastGoodValueBesideTheError() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        route("/api/v2/admin/stats/top-activity", #"{"error":"boom","message":"Top is down"}"#, 500)
        route("/api/v2/admin/stats", #"{"error":"boom","message":"Stats are down"}"#, 500)
        route("/api/v2/admin/sessions", #"{"error":"boom","message":"Sessions are down"}"#, 500)

        await model.load(client: client, forceRefresh: true)

        XCTAssertEqual(model.insights.top.value?.titles.first?.title, "Dune")
        XCTAssertEqual(model.insights.top.error, "Top is down")
        XCTAssertEqual(model.stats?.totalMovies, 400)
        XCTAssertEqual(model.errorMessage, "Stats are down")
        XCTAssertEqual(model.sessions.value?.count, 1)
        XCTAssertEqual(model.sessions.error, "Sessions are down")
        XCTAssertTrue(model.tiles(now: t0).contains { $0.id == .movies }, "the last good numbers stay on the tiles")
    }

    func testARecoveredSectionClearsItsError() async {
        route("/api/v2/admin/stats", #"{"error":"boom","message":"Stats are down"}"#, 500)
        let model = DashboardViewModel()
        await model.load(client: client)
        XCTAssertEqual(model.errorMessage, "Stats are down")
        XCTAssertNil(model.stats)

        route("/api/v2/admin/stats", Self.statsJSON)
        await model.load(client: client)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.stats?.totalMovies, 400)
    }

    func testAnUnreachableSectionUsesItsOwnFallbackText() async {
        route("/api/v2/admin/nodes", "not json", 200)
        let model = DashboardViewModel()
        await model.load(client: client)
        XCTAssertNil(model.insights.nodes.value)
        XCTAssertEqual(model.insights.nodes.error, "Unavailable")
    }

    // MARK: Host sample

    func testTheHostSampleConvertsBitsToBytesAndAcceptsAFractionalCPU() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        let system = model.resources?.visibleSystem
        XCTAssertEqual(system?.cpuPct, 42.5)
        XCTAssertEqual(system?.memUsedMB, 1024)
        XCTAssertEqual(system?.netRxBytesPerSec, 1000)
        XCTAssertEqual(system?.netTxBytesPerSec, 2000)
        XCTAssertNotNil(model.resources?.sampledAt, "sampled_at carries milliseconds")
        XCTAssertFalse(model.hostUnavailable)
    }

    func testAStaleHostSampleIsMarkedButStillShown() async {
        route("/api/v2/admin/system/resources", Self.resourcesStaleJSON)
        let model = DashboardViewModel()
        await model.load(client: client)
        XCTAssertEqual(model.resources?.stale, true)
        XCTAssertNotNil(model.resources?.visibleSystem)
    }

    func testAnUnavailableHostIsNotAnErrorAndHidesTheLine() async {
        route("/api/v2/admin/system/resources", Self.resourcesUnavailableJSON)
        let model = DashboardViewModel()
        await model.load(client: client)
        XCTAssertNil(model.resources)
        XCTAssertTrue(model.hostUnavailable)
        XCTAssertNil(model.hostError)
        XCTAssertNil(model.errorMessage)
    }

    func testAHostFailureNeverTouchesTheStatsBanner() async {
        route("/api/v2/admin/system/resources", #"{"error":"boom","message":"Host is down"}"#, 500)
        let model = DashboardViewModel()
        await model.load(client: client)
        XCTAssertEqual(model.hostError, "Host is down")
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.resources)
        XCTAssertEqual(model.stats?.totalMovies, 400)
    }

    // MARK: Slow tier

    private func slowReads() -> Int {
        requests("/api/v2/admin/system/build").count
    }

    func testTheSlowTierIsReadAtStartThenEveryFiveMinutesNotEveryPoll() async {
        var now = t0
        let model = DashboardViewModel()
        model.clock = { now }

        await model.load(client: client)
        XCTAssertEqual(slowReads(), 1)
        XCTAssertEqual(requests("/api/v2/admin/stats").count, 1)

        now = now.addingTimeInterval(30)
        await model.load(client: client)
        XCTAssertEqual(slowReads(), 1, "the next poll skips the slow tier")
        XCTAssertEqual(requests("/api/v2/admin/stats").count, 2, "but still reads the fast sections")
        XCTAssertEqual(requests("/api/v2/libraries").count, 1)
        XCTAssertEqual(requests("/api/v2/admin/users").count, 1)
        XCTAssertEqual(requests("/api/v2/admin/stats/top-activity").count, 1)

        now = now.addingTimeInterval(270)
        await model.load(client: client)
        XCTAssertEqual(slowReads(), 2, "five minutes after the first read")
    }

    func testAForcedRefreshAndAFailedSlowSectionBringTheSlowTierForward() async {
        var now = t0
        let model = DashboardViewModel()
        model.clock = { now }
        await model.load(client: client)
        XCTAssertEqual(slowReads(), 1)

        now = now.addingTimeInterval(30)
        await model.load(client: client, forceRefresh: true)
        XCTAssertEqual(slowReads(), 2, "pull to refresh re-reads the slow tier")

        route("/api/v2/libraries", #"{"error":"boom","message":"down"}"#, 500)
        now = now.addingTimeInterval(30)
        await model.load(client: client, forceRefresh: true)
        XCTAssertEqual(slowReads(), 3)
        XCTAssertNotNil(model.insights.libraries.error)

        now = now.addingTimeInterval(30)
        await model.load(client: client)
        XCTAssertEqual(slowReads(), 4, "a slow section that failed is retried on the next poll")

        route("/api/v2/libraries", Self.librariesJSON)
        now = now.addingTimeInterval(30)
        await model.load(client: client)
        XCTAssertEqual(slowReads(), 5)
        XCTAssertNil(model.insights.libraries.error)

        now = now.addingTimeInterval(30)
        await model.load(client: client)
        XCTAssertEqual(slowReads(), 5, "once everything is healthy the slow tier waits its five minutes again")
    }

    // MARK: Chart windows

    func testEveryChartStartsOnTheDayAndAPlainLoadReadsOnlyTheDayAndTheHour() async {
        let model = DashboardViewModel()
        XCTAssertEqual(model.ranges, ChartRanges())
        await model.load(client: client)
        XCTAssertEqual(queries("/api/v2/admin/stats/timeseries"), ["hours=1", "hours=24"])
        XCTAssertEqual(queries("/api/v2/admin/stats/playback-activity"), ["hours=24"])
        XCTAssertTrue(model.insights.rangedSeries.isEmpty)
        XCTAssertTrue(model.insights.rangedActivity.isEmpty)
    }

    func testChoosingAWeekReadsItOnceAndTheOtherChartsKeepTheirWindow() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        http.state.requestLog = []

        model.selectRange(.week)
        // The three trend charts share one window.
        XCTAssertEqual(model.ranges.egress, .week)
        XCTAssertEqual(model.ranges.streams, .week)
        XCTAssertEqual(model.ranges.playback, .week)
        await model.loadCharts(client: client)
        XCTAssertEqual(queries("/api/v2/admin/stats/timeseries"), ["hours=168"])
        XCTAssertEqual(model.insights.series(for: .week).value?.egressBytes, 1_500_000)
        XCTAssertNotNil(model.insights.series(for: .day).value, "the day is still the regular read")

        await model.loadCharts(client: client)
        XCTAssertEqual(requests("/api/v2/admin/stats/timeseries").count, 1, "a window already read is not read again")
    }

    func testTwoChartsOnTheSameWindowShareOneRead() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        http.state.requestLog = []
        model.selectRange(.month)
        model.selectRange(.month)
        await model.loadCharts(client: client)
        XCTAssertEqual(queries("/api/v2/admin/stats/timeseries"), ["hours=720"])
    }

    func testTheHourReusesTheEgressNowReadInsteadOfAskingAgain() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        http.state.requestLog = []
        model.selectRange(.hour)
        await model.loadCharts(client: client)
        XCTAssertTrue(requests("/api/v2/admin/stats/timeseries").isEmpty)
        XCTAssertNotNil(model.insights.series(for: .hour).value)
    }

    func testPlaybackActivityReadsTheWindowItShows() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        http.state.requestLog = []
        model.selectRange(.month)
        await model.loadCharts(client: client)
        XCTAssertEqual(queries("/api/v2/admin/stats/playback-activity"), ["hours=720"])
        XCTAssertNotNil(model.insights.activity(for: .month).value)
        XCTAssertEqual(model.insights.activity(for: .day).value?.hours, 24, "the profile tile keeps reading the 24 hours")
    }

    func testAWindowChosenBeforeTheFirstLoadWaitsForIt() async {
        let model = DashboardViewModel()
        model.selectRange(.week)
        await model.loadCharts(client: client)
        XCTAssertTrue(http.state.requestLog.isEmpty)

        await model.load(client: client)
        XCTAssertEqual(queries("/api/v2/admin/stats/timeseries"), ["hours=1", "hours=168", "hours=24"].sorted())
        XCTAssertNotNil(model.insights.series(for: .week).value)
    }

    func testAWeekFollowsTheSlowTierNotEveryPoll() async {
        var now = t0
        let model = DashboardViewModel()
        model.clock = { now }
        model.selectRange(.week)
        await model.load(client: client)
        now = now.addingTimeInterval(30)
        await model.load(client: client)
        XCTAssertEqual(requests("/api/v2/admin/stats/timeseries").filter { $0.url?.query == "hours=168" }.count, 1)
        now = now.addingTimeInterval(300)
        await model.load(client: client)
        XCTAssertEqual(requests("/api/v2/admin/stats/timeseries").filter { $0.url?.query == "hours=168" }.count, 2)
    }

    func testAnHourOfPlaybackIsReadEveryPoll() async {
        let model = DashboardViewModel()
        model.selectRange(.hour)
        await model.load(client: client)
        await model.load(client: client)
        XCTAssertEqual(requests("/api/v2/admin/stats/playback-activity").filter { $0.url?.query == "hours=1" }.count, 2)
    }

    func testAFailedWindowKeepsItsLastChartAndIsReadAgainByTheNextChartLoad() async {
        let model = DashboardViewModel()
        await model.load(client: client)
        model.selectRange(.week)
        await model.loadCharts(client: client)
        XCTAssertNotNil(model.insights.series(for: .week).value)

        // The week is re-read with the slow tier; this time it fails.
        route("/api/v2/admin/stats/timeseries", #"{"error":"boom","message":"Series down"}"#, 500)
        await model.load(client: client, forceRefresh: true)
        let week = model.insights.series(for: .week)
        XCTAssertNotNil(week.value, "the last good chart stays")
        XCTAssertEqual(week.error, "Series down")

        route("/api/v2/admin/stats/timeseries", Self.timeseriesJSON())
        await model.loadCharts(client: client)
        XCTAssertNil(model.insights.series(for: .week).error)
    }

    // MARK: Authentication

    func testAnExpiredTokenFlagsTheSessionAndOffersSignIn() async {
        http.state.pathOverrides = [:]
        http.state.responseData = Data(#"{"error":"invalid_token","message":"Token expired"}"#.utf8)
        http.state.responseStatus = 401
        let root = AdminSessionState()
        root.setAdministratorToken("admin-token", serverID: "srv-1")
        let secured = APIClient(
            baseURL: URL(string: "https://example.test")!, credentialProvider: root.credentialProvider(serverID: "srv-1"), session: http.session
        )
        let model = DashboardViewModel()

        await model.load(client: secured, sessionState: root.scoped(to: "srv-1"))

        XCTAssertTrue(root.isTokenExpired(for: "srv-1"))
        XCTAssertEqual(model.errorMessage, "Token expired")
        XCTAssertNil(model.stats)
        XCTAssertEqual(model.authFailure?.kind, .signedOut)
        XCTAssertEqual(model.serverFailure?.kind, .signedOut)
        XCTAssertFalse(model.hasAnyValue)
    }

    // MARK: Stale results

    func testAnOlderSlowerLoadResolvingSecondDoesNotClobberTheNewerStats() async throws {
        let older = APIClient(baseURL: URL(string: "https://dash-older.test")!, accessToken: nil, session: http.session)
        let newer = APIClient(baseURL: URL(string: "https://dash-newer.test")!, accessToken: nil, session: http.session)
        let oldStats = Self.statsJSON.replacingOccurrences(of: "\"total_movies\": 400", with: "\"total_movies\": 1")
        http.state.pathOverrides = [:]
        http.state.delayedHosts = ["dash-older.test": 0.3]
        http.state.hostPathOverrides = [
            "dash-older.test|/api/v2/admin/stats": (Data(oldStats.utf8), 200),
            "dash-newer.test|/api/v2/admin/stats": (Data(Self.statsJSON.utf8), 200),
        ]
        let model = DashboardViewModel()

        let olderTask = Task { await model.load(client: older) }
        try? await Task.sleep(nanoseconds: 20_000_000)
        await model.load(client: newer)
        XCTAssertEqual(model.stats?.totalMovies, 400)

        await olderTask.value
        XCTAssertEqual(model.stats?.totalMovies, 400, "the older call's late result is dropped")
    }

    // MARK: Decoding

    func testStatsKeepsOnlyWhatTheDashboardShows() throws {
        let stats = try JSONDecoder.iso8601.decode(AdminStats.self, from: Data(Self.statsJSON.utf8))
        XCTAssertEqual(stats.totalFiles, 1500)
        XCTAssertEqual(stats.totalMovieFiles, 420)
        XCTAssertEqual(stats.totalShows, 60)
        XCTAssertEqual(stats.totalShowFiles, 1080)
    }

    func testTimestampsThatAreMalformedLeaveAGapInsteadOfFailingTheSection() throws {
        let json = #"{"resolution_seconds":60,"points":[{"t":"yesterday","streams":1},{"t":"2026-11-13T10:00:00.500Z","streams":2}]}"#
        let series = try JSONDecoder.iso8601.decode(Timeseries.self, from: Data(json.utf8))
        XCTAssertEqual(series.points.count, 2)
        XCTAssertNil(series.points[0].t)
        XCTAssertNotNil(series.points[1].t, "milliseconds decode")
    }

    func testAMissingHealthBlockDecodesAsNoHealth() throws {
        let status = try JSONDecoder.iso8601.decode(DashboardServerStatus.self, from: Data(#"{"started_at":"2026-11-10T06:00:00Z","restart_required":true}"#.utf8))
        XCTAssertNil(status.health)
        XCTAssertTrue(status.restartRequired)
        XCTAssertNotNil(status.startedAt)
    }
}
