import Foundation
import Observation

/// One server's dashboard. Every section publishes on its own: one failed or slow endpoint never
/// hides the others, and a failed refresh leaves the last good value beside its error.
///
/// What changes quickly (stats, host sample, sessions, status, nodes, the 24-hour playback read,
/// the egress-now hour, recent activity) is read on every load. What changes slowly (version, the
/// 24-hour egress series, the 7-day leaders, libraries, accounts) is read every few minutes
/// ("the slow tier"), on a forced refresh, and again on the next poll after it failed.
@Observable
@MainActor
final class DashboardViewModel {
    /// The slow tier is read at most this often.
    static let slowTierInterval: TimeInterval = 300

    private static let activityHours = 24
    private static let topDays = 7
    private static let topLimit = 5
    private static let recentLimit = 5

    private(set) var stats: AdminStats?
    /// The latest `stats` failure; drives the banner above the sections. The last good `stats`
    /// stays shown beside it.
    private(set) var errorMessage: String?
    /// `GET /api/v2/admin/system/resources`' result. `available:false` is not an error: the host
    /// line is hidden and `hostUnavailable` says so.
    private(set) var resources: SystemResources?
    private(set) var hostError: String?
    /// True once the server said it has no host sample to show.
    private(set) var hostUnavailable = false
    /// The live sessions behind Now playing and the Active streams tile.
    private(set) var sessions = SectionState<[AdminSession]>()
    /// Health, nodes, playback activity, egress, top lists, libraries, users and recent activity.
    private(set) var insights = DashboardInsights()
    /// The window each trend chart shows. Kept here, not in the view, so it survives a rebuild of
    /// the view and is per server.
    private(set) var ranges = ChartRanges()
    private(set) var sampledAt: Date?
    /// Set while the server answers 401, so a screen that shows several servers can offer Sign In
    /// for just this one. Cleared as soon as stats or sessions load again.
    private(set) var authFailure: ServerSectionFailure?
    /// The typed form of the latest `stats` failure, for a screen that shows several servers.
    private(set) var statsFailure: ServerSectionFailure?
    /// The events socket's state while this dashboard runs on it; nil when it polls the session list.
    private(set) var liveState: RealtimeState?
    /// Why the socket is not live, when it is not.
    private(set) var liveFailure: SessionFailure?
    /// True while a `LiveSessions` reads the session list for this dashboard, so a poll leaves it alone.
    @ObservationIgnored private var usesLiveSessions = false

    /// The clock the slow tier is paced against; tests replace it.
    @ObservationIgnored var clock: () -> Date = Date.init

    @ObservationIgnored private var slowLoadedAt: Date?
    @ObservationIgnored private var loadStarted = false
    /// The newest read started per section; a slower, older read of the same section is dropped.
    @ObservationIgnored private var latest: [SectionKey: Int] = [:]
    @ObservationIgnored private var counter = 0

    /// Names a section for the stale-result guard.
    private enum SectionKey: Hashable {
        case stats, resources, sessions, status, nodes, activity, egressNow, recent
        case build, egress24h, top, libraries, users
        case rangedActivity(ChartRange), rangedSeries(ChartRange)
    }

    // MARK: Derived

    /// The number tiles with data, in the web's order.
    func tiles(now: Date = Date(), locale: Locale = .current) -> [DashboardTile] {
        dashboardTiles(
            sessionCount: sessions.value?.count,
            stats: stats,
            activity: insights.activity.value,
            egressKbps: insights.egressNow.value?.freshEgressKbps(now: now),
            locale: locale
        )
    }

    /// The sections to draw, in the web's order.
    func visibleSections(now: Date = Date()) -> [DashboardSection] {
        visibleDashboardSections(
            hasTiles: !tiles(now: now).isEmpty,
            hasHealth: healthSectionVisible(insights: insights, resources: resources, hostError: hostError, hostUnavailable: hostUnavailable),
            insights: insights
        )
    }

    /// The failure a multi-server screen shows for this server: a sign-in problem first, otherwise
    /// the latest stats failure.
    var serverFailure: ServerSectionFailure? { authFailure ?? statsFailure }

    /// True once any section holds a value to show.
    var hasAnyValue: Bool {
        stats != nil || sessions.value != nil || resources != nil || insights.status.value != nil
            || insights.activity.value != nil || insights.egress24h.value != nil
    }

    /// True once anything has been heard from the server: a value or a failure of any section.
    var hasLoadedAnything: Bool {
        stats != nil || errorMessage != nil || sessions.hasContent || resources != nil || hostError != nil
            || hostUnavailable || insights.status.hasContent
    }

    /// Show `range` on all three trend charts, which share one control. The read for it is
    /// `loadCharts`; the screen starts it when the range changes.
    func selectRange(_ range: ChartRange) {
        ranges = ranges.with(range)
    }

    /// The session list now comes from a `LiveSessions` (socket cues, a read at most once a minute while
    /// the socket is down); `load` stops reading it.
    func beginLiveSessions() { usesLiveSessions = true }

    /// The live source stopped (the app left the foreground): `load` reads the list again.
    func endLiveSessions() {
        usesLiveSessions = false
        liveState = nil
        liveFailure = nil
    }

    /// Takes the live source's list, the failure of its latest read and the state of its socket. A
    /// failed read keeps the last good rows beside the error.
    func applyLive(sessions rows: [AdminSession]?, readFailure: ServerSectionFailure?, state: RealtimeState, failure: SessionFailure?) {
        liveState = state
        liveFailure = failure
        if let readFailure {
            sessions = SectionState(value: rows ?? sessions.value, error: readFailure.message)
        } else if let rows {
            sessions = SectionState(value: rows)
            authFailure = nil
        }
    }

    /// Marks a server whose sections could not be asked at all (no stored sign-in, no client).
    func reportUnavailable(_ failure: ServerSectionFailure) {
        authFailure = failure.kind == .signedOut ? failure : authFailure
        statsFailure = failure
        errorMessage = failure.message
    }

    // MARK: Loading

    /// Reads the session list alone, for a `sessions` signal on a screen that shows several servers.
    func refreshSessions(client: APIClient, sessionState: ServerScopedSession? = nil) async {
        await loadSection(.sessions, \.sessions, sessionState, String(localized: "Now playing couldn't be loaded. Try again.")) { try await client.listSessions() }
    }

    /// Reads every section. `forceRefresh` maps to `?refresh=true` on the stats and insight
    /// routes, which tells the server to invalidate its cache first; only pull to refresh sets it,
    /// never a poll tick.
    func load(client: APIClient, sessionState: ServerScopedSession? = nil, forceRefresh: Bool = false) async {
        loadStarted = true
        let slow = slowTierDue(forceRefresh: forceRefresh)
        if slow { slowLoadedAt = clock() }

        let hours = Self.activityHours
        let recent = Self.recentLimit
        let days = Self.topDays
        let limit = Self.topLimit
        let unavailable = Self.unavailable
        var jobs: [DashboardJob] = [
            { await self.loadStats(client, sessionState, forceRefresh) },
            { await self.loadResources(client, sessionState) },
            { await self.loadSection(.status, \.insights.status, sessionState, String(localized: "Server health unavailable")) { try await client.dashboardStatus() } },
            { await self.loadSection(.nodes, \.insights.nodes, sessionState, unavailable) { try await client.listNodes() } },
            { await self.loadSection(.activity, \.insights.activity, sessionState, unavailable) { try await client.playbackActivity(hours: hours, refresh: forceRefresh) } },
            { await self.loadSection(.egressNow, \.insights.egressNow, sessionState, unavailable) { try await client.timeseries(hours: 1, refresh: forceRefresh) } },
            { await self.loadSection(.recent, \.insights.recent, sessionState, unavailable) { try await client.recentPlayback(limit: recent) } },
        ]
        if !usesLiveSessions {
            jobs.append { await self.loadSection(.sessions, \.sessions, sessionState, String(localized: "Now playing couldn't be loaded. Try again.")) { try await client.listSessions() } }
        }
        jobs += rangedJobs(chartReads(all: slow), client, sessionState, forceRefresh)
        if slow {
            jobs += [
                { await self.loadSection(.build, \.insights.build, sessionState, unavailable) { try await client.buildInfo() } },
                { await self.loadSection(.egress24h, \.insights.egress24h, sessionState, unavailable) { try await client.timeseries(hours: hours, refresh: forceRefresh) } },
                { await self.loadSection(.top, \.insights.top, sessionState, unavailable) { try await client.topActivity(days: days, limit: limit, refresh: forceRefresh) } },
                { await self.loadSection(.libraries, \.insights.libraries, sessionState, unavailable) { try await client.listLibraries() } },
                { await self.loadSection(.users, \.insights.users, sessionState, unavailable) { try await client.usersForDashboard() } },
            ]
        }
        await runConcurrently(jobs)
    }

    /// Read what a chart needs for the window just chosen, without re-reading the rest of the
    /// dashboard. Does nothing before the first `load`; that load reads the chosen windows itself.
    func loadCharts(client: APIClient, sessionState: ServerScopedSession? = nil, forceRefresh: Bool = false) async {
        guard loadStarted else { return }
        await runConcurrently(rangedJobs(chartReads(all: false), client, sessionState, forceRefresh))
    }

    private func rangedJobs(_ reads: [RangedRead], _ client: APIClient, _ sessionState: ServerScopedSession?, _ refresh: Bool) -> [DashboardJob] {
        reads.map { read in
            { await self.loadRanged(read, client, sessionState, refresh) }
        }
    }

    // MARK: Chart windows

    /// A trend read for a window the regular poll does not already make.
    private enum RangedRead: Hashable {
        case playback(ChartRange)
        case series(ChartRange)
    }

    /// The reads behind the trend charts for windows the regular poll does not already make. A day
    /// is the 24-hour reads every poll makes and an hour is the "egress now" read; a week or a
    /// month is read once when chosen, then with the slow tier. `all` re-reads every shown
    /// window; otherwise only those not yet loaded or that failed.
    private func chartReads(all: Bool) -> [RangedRead] {
        var reads: [RangedRead] = []
        // An hour of playback changes within a poll or two, so unlike the wider windows it is
        // read every time.
        let playback = ranges.playback
        if playback != .day, needsRead(all: all || playback == .hour, insights.rangedActivity[playback]) {
            reads.append(.playback(playback))
        }
        var seen = Set<ChartRange>()
        for range in [ranges.egress, ranges.streams] where range != .day && range != .hour && seen.insert(range).inserted {
            if needsRead(all: all, insights.rangedSeries[range]) { reads.append(.series(range)) }
        }
        return reads
    }

    /// A shown window is read when asked to re-read everything, when it has never been read, and
    /// again after it failed.
    private func needsRead<T>(all: Bool, _ state: SectionState<T>?) -> Bool {
        all || state == nil || state?.error != nil
    }

    private func loadRanged(_ read: RangedRead, _ client: APIClient, _ sessionState: ServerScopedSession?, _ refresh: Bool) async {
        switch read {
        case .playback(let range):
            let hours = range.hours
            await loadSection(
                .rangedActivity(range),
                get: { self.insights.rangedActivity[range] ?? SectionState() },
                set: { self.insights.rangedActivity[range] = $0 },
                sessionState, Self.unavailable
            ) {
                try await client.playbackActivity(hours: hours, refresh: refresh)
            }
        case .series(let range):
            let hours = range.hours
            await loadSection(
                .rangedSeries(range),
                get: { self.insights.rangedSeries[range] ?? SectionState() },
                set: { self.insights.rangedSeries[range] = $0 },
                sessionState, Self.unavailable
            ) {
                try await client.timeseries(hours: hours, refresh: refresh)
            }
        }
    }

    private func slowTierDue(forceRefresh: Bool) -> Bool {
        guard !forceRefresh, let last = slowLoadedAt else { return true }
        if clock().timeIntervalSince(last) >= Self.slowTierInterval { return true }
        return [
            insights.build.error, insights.egress24h.error, insights.top.error,
            insights.libraries.error, insights.users.error,
        ].contains { $0 != nil }
    }

    // MARK: Section plumbing

    private static var unavailable: String { String(localized: "Unavailable") }

    private func begin(_ key: SectionKey) -> Int {
        counter += 1
        latest[key] = counter
        return counter
    }

    private func isCurrent(_ key: SectionKey, _ token: Int) -> Bool {
        latest[key] == token
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    /// Records an authentication failure for a screen that shows several servers.
    private func noteAuthFailure(_ error: Error, fallback: String) {
        let failure = ServerSectionFailure.classify(error, fallback: fallback)
        if failure.kind == .signedOut { authFailure = failure }
    }

    /// One independently published section read through a key path.
    private func loadSection<T: Sendable>(
        _ key: SectionKey,
        _ path: ReferenceWritableKeyPath<DashboardViewModel, SectionState<T>>,
        _ sessionState: ServerScopedSession?,
        _ fallback: String,
        fetch: @Sendable () async throws -> T
    ) async {
        await loadSection(key, get: { self[keyPath: path] }, set: { self[keyPath: path] = $0 }, sessionState, fallback, fetch: fetch)
    }

    /// One independently published section: the value on success, or the last good value beside
    /// the error. A result that arrives after a newer read of the same section started is dropped.
    private func loadSection<T: Sendable>(
        _ key: SectionKey,
        get: () -> SectionState<T>,
        set: (SectionState<T>) -> Void,
        _ sessionState: ServerScopedSession?,
        _ fallback: String,
        fetch: @Sendable () async throws -> T
    ) async {
        let token = begin(key)
        do {
            let value = try await fetch()
            guard isCurrent(key, token), !Task.isCancelled else { return }
            set(SectionState(value: value))
            if key == .sessions { authFailure = nil }
        } catch {
            guard isCurrent(key, token), !isCancellation(error), !Task.isCancelled else { return }
            let message = ErrorMessage.text(for: error, sessionState: sessionState, fallback: fallback)
            // The last good value stays beside the failure, so a flaky refresh does not blank a section.
            set(SectionState(value: get().value, error: message))
            noteAuthFailure(error, fallback: fallback)
        }
    }

    private func loadStats(_ client: APIClient, _ sessionState: ServerScopedSession?, _ forceRefresh: Bool) async {
        let token = begin(.stats)
        do {
            let loaded = try await client.adminStats(forceRefresh: forceRefresh)
            guard isCurrent(.stats, token), !Task.isCancelled else { return }
            stats = loaded
            sampledAt = clock()
            errorMessage = nil
            statsFailure = nil
            authFailure = nil
        } catch {
            guard isCurrent(.stats, token), !isCancellation(error), !Task.isCancelled else { return }
            errorMessage = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "Server statistics couldn't be loaded. Try again."))
            noteAuthFailure(error, fallback: String(localized: "Server statistics couldn't be loaded. Try again."))
            statsFailure = ServerSectionFailure.classify(error, fallback: String(localized: "Server statistics couldn't be loaded. Try again."))
        }
    }

    /// `system/resources` declares no query parameters (a live sample, not a cached one), so a
    /// forced refresh does not apply to it. Its failure never touches the stats banner.
    private func loadResources(_ client: APIClient, _ sessionState: ServerScopedSession?) async {
        let token = begin(.resources)
        do {
            let loaded = try await client.systemResources()
            guard isCurrent(.resources, token), !Task.isCancelled else { return }
            let usable = loaded.visibleSystem != nil
            resources = usable ? loaded : nil
            hostUnavailable = !usable
            hostError = nil
        } catch {
            guard isCurrent(.resources, token), !isCancellation(error), !Task.isCancelled else { return }
            resources = nil
            hostUnavailable = false
            hostError = ErrorMessage.text(for: error, sessionState: sessionState, fallback: String(localized: "Server health unavailable"))
            noteAuthFailure(error, fallback: String(localized: "Server health unavailable"))
        }
    }
}

#if DEBUG
extension DashboardViewModel {
    /// Fills the model with already-decoded data and no network, for the UI-test fixture screen
    /// and for tests that only need the layout rules.
    func seed(
        stats: AdminStats?,
        resources: SystemResources? = nil,
        sessions: [AdminSession]?,
        insights: DashboardInsights,
        now: Date = Date()
    ) {
        self.stats = stats
        self.resources = resources
        self.hostUnavailable = resources == nil
        self.sessions = SectionState(value: sessions)
        self.insights = insights
        self.sampledAt = now
        self.loadStarted = true
    }
}
#endif
