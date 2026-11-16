import XCTest
@testable import BloemAdmin

/// Section order, tile omission and the other rules of the dashboard's layout; the cases follow
/// the Android app's DashboardInsightsTest and the web's registry.tsx DEFAULT_LAYOUT_ORDER.
final class DashboardInsightsTests: XCTestCase {
    private let us = Locale(identifier: "en_US")

    private struct FakeText: DashboardTileText {
        func label(_ id: DashboardTileID) -> String {
            switch id {
            case .activeStreams: "Active streams"
            case .egressNow: "Egress now"
            case .profilesActive: "Profiles · 24h"
            case .movies: "Movies"
            case .shows: "Shows"
            case .storage: "Storage"
            }
        }
        func sessions(_ count: Int) -> String { "\(count) sessions" }
        func files(_ count: Int) -> String { "\(count) files" }
        func profilesDetail() -> String { "watched on this server" }
        func egressDetail() -> String { "node + server egress" }
        func storage(_ bytes: Int64) -> String { "\(bytes) B" }
    }

    private let stats = AdminStats(totalFiles: 11, totalMovies: 13, totalMovieFiles: 14, totalShows: 15, totalShowFiles: 16, totalStorageBytes: 1000)
    private let activity = PlaybackActivity(profilesActive24h: 4)

    private func tiles(
        sessions: Int? = 2, stats: AdminStats? = nil, activity: PlaybackActivity? = nil, egress: Double? = 5000
    ) -> [DashboardTile] {
        dashboardTiles(
            sessionCount: sessions, stats: stats ?? self.stats, activity: activity ?? self.activity,
            egressKbps: egress, text: FakeText(), locale: us
        )
    }

    // MARK: Tiles

    func testTilesFollowTheWebOrder() {
        XCTAssertEqual(tiles().map(\.id), [.activeStreams, .egressNow, .profilesActive, .movies, .shows, .storage])
        XCTAssertEqual(tiles().map(\.label), ["Active streams", "Egress now", "Profiles · 24h", "Movies", "Shows", "Storage"])
    }

    func testTileValuesAndDetailsComeFromTheWebsSources() {
        let byID = Dictionary(uniqueKeysWithValues: tiles().map { ($0.id, $0) })
        XCTAssertEqual([byID[.activeStreams]?.value, byID[.activeStreams]?.detail], ["2", "2 sessions"])
        XCTAssertEqual(byID[.egressNow]?.value, "5.0 Mbps")
        XCTAssertEqual([byID[.profilesActive]?.value, byID[.profilesActive]?.detail], ["4", "watched on this server"])
        XCTAssertEqual([byID[.movies]?.value, byID[.movies]?.detail], ["13", "14 files"])
        XCTAssertEqual([byID[.shows]?.value, byID[.shows]?.detail], ["15", "16 files"])
        XCTAssertEqual([byID[.storage]?.value, byID[.storage]?.detail], ["1000 B", "11 files"])
    }

    func testATileWithoutDataIsLeftOut() {
        XCTAssertEqual(tiles(sessions: nil).map(\.id), [.egressNow, .profilesActive, .movies, .shows, .storage])
        XCTAssertEqual(tiles(egress: nil).map(\.id), [.activeStreams, .profilesActive, .movies, .shows, .storage])
        let noActivity = dashboardTiles(sessionCount: 2, stats: stats, activity: nil, egressKbps: 5000, text: FakeText(), locale: us)
        XCTAssertEqual(noActivity.map(\.id), [.activeStreams, .egressNow, .movies, .shows, .storage])
        let noStats = dashboardTiles(sessionCount: 2, stats: nil, activity: activity, egressKbps: 5000, text: FakeText(), locale: us)
        XCTAssertEqual(noStats.map(\.id), [.activeStreams, .egressNow, .profilesActive])
        XCTAssertTrue(dashboardTiles(sessionCount: nil, stats: nil, activity: nil, egressKbps: nil, text: FakeText(), locale: us).isEmpty)
    }

    func testZeroSessionsIsDataAndKeepsItsTile() {
        XCTAssertEqual(tiles(sessions: 0).first?.value, "0")
    }

    func testTheTileAnnouncesItsLabelValueAndDetailAsOnePhrase() {
        XCTAssertEqual(tiles().first { $0.id == .movies }?.accessibilityLabel, "Movies: 13, 14 files")
    }

    func testEgressNowIsHiddenWhenItsNewestSampleIsOverTwoMinutesOld() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func series(age: TimeInterval) -> Timeseries {
            Timeseries(points: [TimeseriesPoint(t: now.addingTimeInterval(-age), streams: 1, egressKbps: 8000)])
        }
        XCTAssertEqual(series(age: 119).freshEgressKbps(now: now), 8000)
        XCTAssertEqual(series(age: 120).freshEgressKbps(now: now), 8000)
        XCTAssertNil(series(age: 121).freshEgressKbps(now: now))
    }

    // MARK: Section order

    func testSectionsAppearInTheWebsOrderWithTheMainChartLeadingTheTrends() {
        let everything = DashboardInsights(
            activity: SectionState(value: activity), egress24h: SectionState(value: Timeseries()),
            top: SectionState(value: TopActivity()), libraries: SectionState(value: []),
            users: SectionState(value: []), recent: SectionState(value: [])
        )
        XCTAssertEqual(
            visibleDashboardSections(hasTiles: true, hasHealth: true, insights: everything),
            [.tiles, .health, .nowPlaying, .concurrentStreams, .playbackActivity, .egress, .topTitles, .topProfiles, .libraries, .users, .recentActivity]
        )
        XCTAssertEqual(DashboardSection.allCases.count, 11)
    }

    func testASectionWithoutDataOrFailureIsNotShownButNowPlayingAlwaysIs() {
        XCTAssertEqual(visibleDashboardSections(hasTiles: false, hasHealth: false, insights: DashboardInsights()), [.nowPlaying])
        XCTAssertEqual(
            visibleDashboardSections(hasTiles: true, hasHealth: false, insights: DashboardInsights(libraries: SectionState(value: []))),
            [.tiles, .nowPlaying, .libraries]
        )
    }

    func testAFailedSectionKeepsItsPlaceSoTheFailureIsVisible() {
        let failed = DashboardInsights(top: SectionState(error: "down"), recent: SectionState(error: "down"))
        XCTAssertEqual(
            visibleDashboardSections(hasTiles: false, hasHealth: false, insights: failed),
            [.nowPlaying, .topTitles, .topProfiles, .recentActivity]
        )
    }

    func testWatchProvidersAreNotADefaultSection() {
        XCTAssertFalse(DashboardSection.allCases.contains { $0.rawValue.lowercased().contains("provider") })
    }

    func testTheHealthSectionShowsWhileItHasSomethingToSayOrIsStillWaiting() {
        let empty = DashboardInsights()
        XCTAssertTrue(healthSectionVisible(insights: empty, resources: nil, hostError: nil, hostUnavailable: false), "still waiting to hear")
        XCTAssertFalse(healthSectionVisible(insights: empty, resources: nil, hostError: nil, hostUnavailable: true), "the server has nothing to report")
        XCTAssertTrue(healthSectionVisible(insights: empty, resources: nil, hostError: "down", hostUnavailable: true))
        XCTAssertTrue(healthSectionVisible(insights: DashboardInsights(status: SectionState(error: "x")), resources: nil, hostError: nil, hostUnavailable: true))
    }

    func testAnEmptySectionStateHasNoContentUntilItHoldsAValueOrAnError() {
        XCTAssertFalse(SectionState<Int>().hasContent)
        XCTAssertTrue(SectionState(value: 1).hasContent)
        XCTAssertTrue(SectionState<Int>(error: "x").hasContent)
    }

    func testTheRangedReadsAreWhatTheChartsShow() {
        var insights = DashboardInsights()
        insights.activity = SectionState(value: PlaybackActivity(hours: 24, profilesActive24h: 1))
        insights.rangedActivity[.week] = SectionState(value: PlaybackActivity(hours: 168, profilesActive24h: 1))
        insights.egressNow = SectionState(value: Timeseries(resolutionSeconds: 60))
        insights.egress24h = SectionState(value: Timeseries(resolutionSeconds: 300))
        insights.rangedSeries[.month] = SectionState(value: Timeseries(resolutionSeconds: 3600))
        XCTAssertEqual(insights.activity(for: .day).value?.hours, 24)
        XCTAssertEqual(insights.activity(for: .week).value?.hours, 168)
        XCTAssertNil(insights.activity(for: .month).value)
        XCTAssertEqual(insights.series(for: .hour).value?.resolutionSeconds, 60)
        XCTAssertEqual(insights.series(for: .day).value?.resolutionSeconds, 300)
        XCTAssertEqual(insights.series(for: .month).value?.resolutionSeconds, 3600)
        XCTAssertNil(insights.series(for: .week).value)
    }

    // MARK: Server health

    private func status(
        started: Date? = nil, restart: Bool = false, health: ServerHealthSummary? = nil
    ) -> DashboardServerStatus {
        DashboardServerStatus(startedAt: started, restartRequired: restart, health: health)
    }

    func testTheHealthStripHasTheSixCellsInOrder() {
        let health = ServerHealthSummary(
            postgres: HealthComponent(configured: true, ok: true, latencyMs: 1.25),
            redis: HealthComponent(configured: false),
            errors24h: 3, warnings24h: 2
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cells = healthCells(
            status: status(started: now.addingTimeInterval(-(3 * 86_400 + 4 * 3600 + 60)), health: health),
            build: BuildInfo(buildNumber: 12, dirty: true, display: "v1.4"),
            nodes: [DashboardNode(id: "1", enabled: true, healthy: true), DashboardNode(id: "2", enabled: true, healthy: false), DashboardNode(id: "3", enabled: false, healthy: false)],
            now: now, locale: us
        )
        XCTAssertEqual(cells.map(\.label), ["Version", "Uptime", "Postgres", "Redis", "Nodes", "Errors · 24h"])
        XCTAssertEqual([cells[0].value, cells[0].detail], ["12 · v1.4", "dirty build"])
        XCTAssertEqual(cells[1].value, "3d 4h")
        XCTAssertEqual([cells[2].value, cells[2].detail], ["OK", "1.25 ms"])
        XCTAssertEqual(cells[3].value, "Not configured")
        XCTAssertEqual(cells[3].tone, .normal)
        XCTAssertEqual(cells[4].value, "1/2")
        XCTAssertEqual(cells[4].tone, .warn)
        XCTAssertEqual(cells[5].value, "3")
        XCTAssertEqual(cells[5].detail, "2 warnings")
        XCTAssertEqual(cells[5].tone, .error)
    }

    func testAnUnreachableDependencyIsAnError() {
        let cell = dependencyCell(label: "Postgres", component: HealthComponent(configured: true, ok: false))
        XCTAssertEqual(cell.value, "Unreachable")
        XCTAssertEqual(cell.tone, .error)
        XCTAssertEqual(dependencyCell(label: "Redis", component: nil).value, "—")
    }

    func testMissingBuildNodesAndHealthReadAsADash() {
        let cells = healthCells(status: status(), build: nil, nodes: nil, now: Date(), locale: us)
        XCTAssertEqual(cells.map(\.value), ["—", "—", "—", "—", "—", "—"])
    }

    func testNoEnabledNodesReadsNoneAndARestartRequestWarns() {
        let cells = healthCells(status: status(started: Date(), restart: true), build: BuildInfo(display: "dev"), nodes: [], now: Date(), locale: us)
        XCTAssertEqual(cells[0].value, "dev")
        XCTAssertEqual(cells[1].detail, "Restart required")
        XCTAssertEqual(cells[1].tone, .warn)
        XCTAssertEqual(cells[4].value, "None")
        XCTAssertEqual(cells[4].tone, .normal)
    }

    // MARK: Formatting helpers

    func testWatchTimeStaysInMinutesBelowAnHour() {
        XCTAssertEqual(formatWatchTime(0, locale: us), "0m")
        XCTAssertEqual(formatWatchTime(.nan, locale: us), "0m")
        XCTAssertEqual(formatWatchTime(10, locale: us), "1m")
        XCTAssertEqual(formatWatchTime(1800, locale: us), "30m")
        XCTAssertEqual(formatWatchTime(5400, locale: us), "1.5h")
        XCTAssertEqual(formatWatchTime(36_000, locale: us), "10h")
    }

    func testUptimeUsesTheCoarsestUsefulUnit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func uptime(_ seconds: TimeInterval) -> String { formatUptime(startedAt: now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(uptime(45), "45s")
        XCTAssertEqual(uptime(120), "2m")
        XCTAssertEqual(uptime(125), "2m 5s")
        XCTAssertEqual(uptime(3 * 3600), "3h")
        XCTAssertEqual(uptime(3 * 3600 + 120), "3h 2m")
        XCTAssertEqual(uptime(2 * 86_400), "2d")
        XCTAssertEqual(uptime(2 * 86_400 + 5 * 3600), "2d 5h")
        XCTAssertEqual(formatUptime(startedAt: nil, now: now), "—")
        XCTAssertEqual(uptime(-30), "0s")
    }

    func testLatencyKeepsDecimalsOnlyBelowTenMilliseconds() {
        XCTAssertEqual(formatLatency(1.256, locale: us), "1.26 ms")
        XCTAssertEqual(formatLatency(42.7, locale: us), "43 ms")
        XCTAssertEqual(formatLatency(.infinity, locale: us), "—")
    }

    func testUsersAreMostRecentlyActiveFirstAndNeverActiveSinkToTheBottom() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let users = [
            DashboardUser(id: "1", username: "zed", lastActiveAt: nil),
            DashboardUser(id: "2", username: "bob", lastActiveAt: now.addingTimeInterval(-3600)),
            DashboardUser(id: "3", username: "amy", lastActiveAt: now),
            DashboardUser(id: "4", username: "Abe", lastActiveAt: nil),
        ]
        XCTAssertEqual(usersByLastActive(users).map(\.username), ["amy", "bob", "Abe", "zed"])
    }

    func testAProfileShowsItsNameBeforeItsAccountWhenTheyDiffer() {
        XCTAssertEqual(topProfileLabel(TopProfile(userID: "1", username: "alex", profileID: "p", profileName: "Kids")), "Kids · alex")
        XCTAssertEqual(topProfileLabel(TopProfile(userID: "1", username: "alex", profileID: "p", profileName: "alex")), "alex")
        XCTAssertEqual(topProfileLabel(TopProfile(userID: "1", username: "alex", profileID: "p", profileName: "")), "p · alex")
        XCTAssertEqual(topProfileLabel(TopProfile(userID: "1", username: "alex")), "alex")
    }

    func testRelativeTimeReadsInTheCoarsestUnit() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func ago(_ seconds: TimeInterval) -> String { formatRelativeTime(now.addingTimeInterval(-seconds), now: now) }
        XCTAssertEqual(ago(30), "just now")
        XCTAssertEqual(ago(5 * 60), "5 min ago")
        XCTAssertEqual(ago(3 * 3600), "3 h ago")
        XCTAssertEqual(ago(2 * 86_400), "2 d ago")
        XCTAssertEqual(ago(-10), "just now")
    }
}
