import Foundation

// What the dashboard shows beyond the stats, the host sample and the live sessions, and the rules
// for which sections and tiles appear. Free of SwiftUI so the order and omission rules can be unit
// tested. They follow the Android app's DashboardInsights.kt and the web's registry.tsx.

/// One independently loaded dashboard section: the last good value plus the error of the latest
/// failed refresh, if any.
struct SectionState<Value: Sendable>: Sendable {
    var value: Value?
    var error: String?

    init(value: Value? = nil, error: String? = nil) {
        self.value = value
        self.error = error
    }

    /// Loading is neither: a section with no value and no error has nothing to say yet.
    var hasContent: Bool { value != nil || error != nil }
}

extension SectionState: Equatable where Value: Equatable {}

/// Everything the dashboard shows beyond the stats, host sample and live sessions.
struct DashboardInsights: Sendable {
    var status = SectionState<DashboardServerStatus>()
    var build = SectionState<BuildInfo>()
    var nodes = SectionState<[DashboardNode]>()
    var activity = SectionState<PlaybackActivity>()
    var egressNow = SectionState<Timeseries>()
    var egress24h = SectionState<Timeseries>()
    var top = SectionState<TopActivity>()
    var libraries = SectionState<[DashboardLibrary]>()
    var users = SectionState<[DashboardUser]>()
    var recent = SectionState<[RecentPlayback]>()
    /// Playback activity for the windows other than the 24 hours in `activity`, read only while a
    /// chart shows one.
    var rangedActivity: [ChartRange: SectionState<PlaybackActivity>] = [:]
    /// The timeseries for the week and month windows; the hour is `egressNow` and the day is
    /// `egress24h`, read only while a chart shows one.
    var rangedSeries: [ChartRange: SectionState<Timeseries>] = [:]

    /// What the playback chart shows for `range`: the 24-hour read every poll already makes, or
    /// the one read for that window.
    func activity(for range: ChartRange) -> SectionState<PlaybackActivity> {
        range == .day ? activity : rangedActivity[range] ?? SectionState()
    }

    /// What the egress and concurrent-streams charts show for `range`; both plot the same endpoint.
    func series(for range: ChartRange) -> SectionState<Timeseries> {
        switch range {
        case .hour: egressNow
        case .day: egress24h
        case .week, .month: rangedSeries[range] ?? SectionState()
        }
    }
}

/// `/admin/server/status` as the dashboard reads it: uptime, the restart flag and the health summary.
struct DashboardServerStatus: Sendable, Equatable {
    var startedAt: Date?
    var restartRequired = false
    var health: ServerHealthSummary?
}

extension DashboardServerStatus: Decodable {
    private enum CodingKeys: String, CodingKey {
        case health
        case startedAt = "started_at"
        case restartRequired = "restart_required"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startedAt = (try? c.decodeIfPresent(Date.self, forKey: .startedAt)) ?? nil
        restartRequired = (try? c.decodeIfPresent(Bool.self, forKey: .restartRequired)) ?? false
        health = (try? c.decodeIfPresent(ServerHealthSummary.self, forKey: .health)) ?? nil
    }
}

/// The web's default arrangement (registry.tsx DEFAULT_LAYOUT_ORDER), in the order the dashboard
/// renders it.
enum DashboardSection: String, CaseIterable, Sendable {
    case tiles, health, nowPlaying
    /// The one main chart. The web keeps it one tap away in its Add-widget sheet; here it leads the
    /// trends, and the two smaller charts after it read the same window.
    case concurrentStreams
    case playbackActivity, egress
    case topTitles, topProfiles, libraries, users, recentActivity

    /// The accessibility identifier of the section's panel.
    var identifier: String {
        switch self {
        case .tiles: "dashboard-section-tiles"
        case .health: "dashboard-section-health"
        case .nowPlaying: "dashboard-section-now-playing"
        case .playbackActivity: "dashboard-section-playback-activity"
        case .egress: "dashboard-section-egress"
        case .concurrentStreams: "dashboard-section-concurrent-streams"
        case .topTitles: "dashboard-section-top-titles"
        case .topProfiles: "dashboard-section-top-profiles"
        case .libraries: "dashboard-section-libraries"
        case .users: "dashboard-section-users"
        case .recentActivity: "dashboard-section-recent-activity"
        }
    }
}

/// The sections that have something to say, in the web's order. Now playing is always present (it
/// carries the loading, stale and idle states); every other section appears once it has a value or
/// a failure.
func visibleDashboardSections(hasTiles: Bool, hasHealth: Bool, insights: DashboardInsights) -> [DashboardSection] {
    DashboardSection.allCases.filter { section in
        switch section {
        case .tiles: hasTiles
        case .health: hasHealth
        case .nowPlaying: true
        case .playbackActivity: insights.activity.hasContent
        case .egress, .concurrentStreams: insights.egress24h.hasContent
        case .topTitles, .topProfiles: insights.top.hasContent
        case .libraries: insights.libraries.hasContent
        case .users: insights.users.hasContent
        case .recentActivity: insights.recent.hasContent
        }
    }
}

/// The health section shows while it has something to say, or is still waiting to hear; it hides
/// only when the server has nothing to report.
func healthSectionVisible(
    insights: DashboardInsights,
    resources: SystemResources?,
    hostError: String?,
    hostUnavailable: Bool
) -> Bool {
    insights.status.hasContent || resources?.visibleSystem != nil || hostError != nil || !hostUnavailable
}

// MARK: - Number tiles

enum DashboardTileID: String, CaseIterable, Sendable {
    case activeStreams, egressNow, profilesActive, movies, shows, storage
}

struct DashboardTile: Equatable, Identifiable, Sendable {
    let id: DashboardTileID
    let label: String
    let value: String
    let detail: String?

    /// One VoiceOver phrase for the whole tile: "Movies: 400, 420 files".
    var accessibilityLabel: String {
        "\(label): " + [value, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The words and units the tiles need, so the tile logic stays free of the string catalog.
protocol DashboardTileText {
    func label(_ id: DashboardTileID) -> String
    func sessions(_ count: Int) -> String
    func files(_ count: Int) -> String
    func profilesDetail() -> String
    func egressDetail() -> String
    func storage(_ bytes: Int64) -> String
}

struct LocalizedTileText: DashboardTileText {
    func label(_ id: DashboardTileID) -> String {
        switch id {
        case .activeStreams: String(localized: "Active streams")
        case .egressNow: String(localized: "Egress now")
        case .profilesActive: String(localized: "Profiles · 24h")
        case .movies: String(localized: "Movies")
        case .shows: String(localized: "Shows")
        case .storage: String(localized: "Storage")
        }
    }

    func sessions(_ count: Int) -> String { String(localized: "\(count) sessions") }
    func files(_ count: Int) -> String { String(localized: "\(count) files") }
    func profilesDetail() -> String { String(localized: "watched on this server") }
    func egressDetail() -> String { String(localized: "node + server egress") }

    func storage(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// The web's number tiles in its order. A tile whose data has not arrived (or, for egress, whose
/// sample is stale) is left out rather than shown as a dash.
func dashboardTiles(
    sessionCount: Int?,
    stats: AdminStats?,
    activity: PlaybackActivity?,
    egressKbps: Double?,
    text: DashboardTileText = LocalizedTileText(),
    locale: Locale = .current
) -> [DashboardTile] {
    func number(_ value: Int) -> String { formatChartCount(Double(value), locale: locale) }
    var tiles: [DashboardTile] = []
    if let sessionCount {
        tiles.append(DashboardTile(id: .activeStreams, label: text.label(.activeStreams), value: number(sessionCount), detail: text.sessions(sessionCount)))
    }
    if let egressKbps {
        tiles.append(DashboardTile(id: .egressNow, label: text.label(.egressNow), value: formatMbps(egressKbps / 1000, locale: locale), detail: text.egressDetail()))
    }
    if let activity {
        tiles.append(DashboardTile(id: .profilesActive, label: text.label(.profilesActive), value: number(activity.profilesActive24h), detail: text.profilesDetail()))
    }
    if let stats {
        tiles.append(DashboardTile(id: .movies, label: text.label(.movies), value: number(stats.totalMovies), detail: text.files(stats.totalMovieFiles)))
        tiles.append(DashboardTile(id: .shows, label: text.label(.shows), value: number(stats.totalShows), detail: text.files(stats.totalShowFiles)))
        tiles.append(DashboardTile(id: .storage, label: text.label(.storage), value: text.storage(stats.totalStorageBytes), detail: text.files(stats.totalFiles)))
    }
    return tiles
}

// MARK: - Server health strip

enum HealthTone: Sendable { case normal, warn, error }

struct HealthCell: Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    var detail: String?
    var tone: HealthTone = .normal
    /// The cell opens the Nodes page.
    var linksToNodes = false

    var id: String { label }

    var accessibilityLabel: String {
        "\(label): " + [value, detail].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The six cells of the health strip: Version, Uptime, Postgres, Redis, Nodes, Errors · 24h.
func healthCells(
    status: DashboardServerStatus,
    build: BuildInfo?,
    nodes: [DashboardNode]?,
    now: Date,
    locale: Locale = .current
) -> [HealthCell] {
    let noValue = "—"
    let enabledNodes = nodes?.filter(\.enabled) ?? []
    let healthyNodes = enabledNodes.filter(\.healthy).count
    let health = status.health

    let version: String
    if let build {
        if build.buildNumber > 0 {
            version = String(localized: "\(build.buildNumber) · \(build.display)")
        } else {
            version = build.display.isEmpty ? noValue : build.display
        }
    } else {
        version = noValue
    }

    let nodesValue: String
    if nodes != nil {
        nodesValue = enabledNodes.isEmpty
            ? String(localized: "None")
            : String(localized: "\(healthyNodes)/\(enabledNodes.count)")
    } else {
        nodesValue = noValue
    }

    return [
        HealthCell(
            label: String(localized: "Version"), value: version,
            detail: build?.dirty == true ? String(localized: "dirty build") : nil
        ),
        HealthCell(
            label: String(localized: "Uptime"), value: formatUptime(startedAt: status.startedAt, now: now),
            detail: status.restartRequired ? String(localized: "Restart required") : nil,
            tone: status.restartRequired ? .warn : .normal
        ),
        dependencyCell(label: String(localized: "Postgres"), component: health?.postgres, locale: locale),
        dependencyCell(label: String(localized: "Redis"), component: health?.redis, locale: locale),
        HealthCell(
            label: String(localized: "Nodes"), value: nodesValue,
            tone: (nodes != nil && healthyNodes < enabledNodes.count) ? .warn : .normal,
            linksToNodes: true
        ),
        HealthCell(
            label: String(localized: "Errors · 24h"),
            value: health.map { String($0.errors24h) } ?? noValue,
            detail: health.map { String(localized: "\($0.warnings24h) warnings") },
            tone: (health?.errors24h ?? 0) > 0 ? .error : .normal
        ),
    ]
}

/// A dependency reports whether it is configured before whether it is up: a single-node server
/// with no Redis is healthy.
func dependencyCell(label: String, component: HealthComponent?, locale: Locale = .current) -> HealthCell {
    guard let component else { return HealthCell(label: label, value: "—") }
    if !component.configured { return HealthCell(label: label, value: String(localized: "Not configured")) }
    if component.ok != true { return HealthCell(label: label, value: String(localized: "Unreachable"), tone: .error) }
    return HealthCell(label: label, value: String(localized: "OK"), detail: component.latencyMs.map { formatLatency($0, locale: locale) })
}

// MARK: - Formatting

/// Watch time for the top lists: sub-hour totals stay in minutes so a short session does not
/// collapse to "0.0h".
func formatWatchTime(_ totalSeconds: Double, locale: Locale = .current) -> String {
    guard totalSeconds.isFinite, totalSeconds > 0 else { return "0m" }
    if totalSeconds < 3600 { return "\(max(1, Int((totalSeconds / 60).rounded())))m" }
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 1
    return (formatter.string(from: NSNumber(value: totalSeconds / 3600)) ?? "—") + "h"
}

/// Uptime at the coarsest unit that still says something useful: "3d 4h", not a seconds counter.
func formatUptime(startedAt: Date?, now: Date) -> String {
    guard let startedAt else { return "—" }
    let seconds = max(0, Int(now.timeIntervalSince(startedAt)))
    if seconds < 86_400 { return formatDuration(seconds) }
    let days = seconds / 86_400
    let hours = seconds % 86_400 / 3600
    return hours == 0 ? "\(days)d" : "\(days)d \(hours)h"
}

private func formatDuration(_ total: Int) -> String {
    if total < 60 { return "\(total)s" }
    if total < 3600 {
        let minutes = total / 60
        let seconds = total % 60
        return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
    }
    let hours = total / 3600
    let minutes = total % 3600 / 60
    return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
}

/// Sub-10ms round trips keep their decimals; anything slower does not need them.
func formatLatency(_ latencyMs: Double, locale: Locale = .current) -> String {
    guard latencyMs.isFinite else { return "—" }
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = latencyMs < 10 ? 2 : 0
    return (formatter.string(from: NSNumber(value: latencyMs)) ?? "—") + " ms"
}

/// Most recently active first; accounts with no recorded activity sink to the bottom.
func usersByLastActive(_ users: [DashboardUser]) -> [DashboardUser] {
    users.sorted { a, b in
        let left = a.lastActiveAt ?? .distantPast
        let right = b.lastActiveAt ?? .distantPast
        if left != right { return left > right }
        return a.username.lowercased() < b.username.lowercased()
    }
}

/// "Profile · account" when the account name adds anything; per profile, since several profiles
/// share one login.
func topProfileLabel(_ profile: TopProfile) -> String {
    let account = profile.username.isEmpty ? String(localized: "User \(profile.userID)") : profile.username
    let name = !profile.profileName.isEmpty ? profile.profileName : (!profile.profileID.isEmpty ? profile.profileID : account)
    return name == account ? account : "\(name) · \(account)"
}

/// "just now", "5 min ago", "3 h ago", "2 d ago".
func formatRelativeTime(_ date: Date, now: Date = Date()) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    let minutes = Int(seconds / 60)
    let hours = Int(seconds / 3600)
    if minutes < 1 { return String(localized: "just now") }
    if minutes < 60 { return String(localized: "\(minutes) min ago") }
    if hours < 24 { return String(localized: "\(hours) h ago") }
    return String(localized: "\(Int(seconds / 86_400)) d ago")
}
