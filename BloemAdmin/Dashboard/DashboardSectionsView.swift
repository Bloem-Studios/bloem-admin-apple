import SwiftUI

/// One server's dashboard sections in the web's default order: number tiles, server health, now
/// playing, playback activity, egress, concurrent streams, top titles, most active profiles,
/// libraries, users, recent activity. Used by the single-server screen and, once per server, by
/// All servers.
struct DashboardSectionsView: View {
    let model: DashboardViewModel
    /// Opens Now playing. Nil hides "Manage streams".
    var onShowStreams: (() -> Void)?
    /// Opens Users. Nil hides "Manage users".
    var onShowUsers: (() -> Void)?
    /// Opens Nodes from the health strip's Nodes cell. Nil leaves the cell plain.
    var onShowNodes: (() -> Void)?

    var body: some View {
        let now = Date()
        VStack(alignment: .leading, spacing: 16) {
            ForEach(model.visibleSections(now: now), id: \.self) { section in
                switch section {
                case .tiles: TilesSection(tiles: model.tiles(now: now), sampledAt: model.sampledAt)
                case .health: HealthSection(model: model, now: now, onShowNodes: onShowNodes)
                case .nowPlaying: NowPlayingSection(model: model, onShowStreams: onShowStreams)
                case .playbackActivity: PlaybackActivitySection(model: model)
                case .egress: EgressSection(model: model)
                case .concurrentStreams: ConcurrentStreamsSection(model: model)
                case .topTitles: TopTitlesSection(state: model.insights.top)
                case .topProfiles: TopProfilesSection(state: model.insights.top)
                case .libraries: LibrariesSection(state: model.insights.libraries)
                case .users: UsersSection(state: model.insights.users, onShowUsers: onShowUsers)
                case .recentActivity: RecentActivitySection(state: model.insights.recent)
                }
            }
        }
    }
}

// MARK: - Number tiles

/// The top of the dashboard: at most four stat cards, two to a row on a phone and four on a wide screen, all the same
/// height, each a label, a figure and a line saying what it counts (maintainer, 2026-11-16, A7). The rest of the numbers are a
/// compact list under them, not more cards.
private struct TilesSection: View {
    let tiles: [DashboardTile]
    let sampledAt: Date?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass

    /// The four figures that matter now: what is playing, what it costs, who is watching, and what it fills.
    static let cardIDs: [DashboardTileID] = [.activeStreams, .egressNow, .profilesActive, .storage]

    private var cards: [DashboardTile] { tiles.filter { Self.cardIDs.contains($0.id) } }
    private var list: [DashboardTile] { tiles.filter { !Self.cardIDs.contains($0.id) } }

    private var columns: Int {
        if typeSize.isAccessibilitySize { return 1 }
        return sizeClass == .regular ? 4 : 2
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            EqualColumns(items: cards, columns: columns, spacing: Theme.Space.m) { tile in
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.s) {
                        // Live right now: the tally dot, only while something is streaming.
                        if tile.id == .activeStreams, tile.value != "0" { TallyDot() }
                        Text(tile.label).bloemText(.labelMedium).foregroundStyle(.bloemMuted)
                    }
                    Text(tile.value).bloemText(.headlineLarge)
                    if let detail = tile.detail {
                        Text(detail).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                }
                .wrapsAtAnySize()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(Theme.Space.l)
                .bloemCard()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(tile.accessibilityLabel)
                .accessibilityIdentifier("dashboard-tile-\(tile.id.rawValue)")
            }
            if !list.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, tile in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        DashboardValueRow(label: tile.label, value: tile.value, detail: tile.detail)
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(tile.accessibilityLabel)
                            .accessibilityIdentifier("dashboard-tile-\(tile.id.rawValue)")
                    }
                }
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bloemCard()
            }
            if let sampledAt {
                Text("Sampled \(formatRelativeTime(sampledAt))")
                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(DashboardSection.tiles.identifier)
    }
}

/// One line of a compact list: the label on the left, the figure on the right with its detail under it. At the
/// accessibility text sizes the figure goes under the label.
struct DashboardValueRow: View {
    let label: String
    let value: String
    var detail: String?
    var tone: HealthTone = .normal
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let figure = VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: Theme.Space.xs) {
            Text(value).bloemText(.titleSmall).foregroundStyle(color)
                .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            if let detail {
                Text(detail).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    .multilineTextAlignment(typeSize.isAccessibilitySize ? .leading : .trailing)
            }
        }
        .wrapsAtAnySize()
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    Text(label).bloemText(.bodyMedium).foregroundStyle(.bloemMuted)
                    figure
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.m) {
                    Text(label).bloemText(.bodyMedium).foregroundStyle(.bloemMuted).wrapsAtAnySize()
                    Spacer(minLength: Theme.Space.s)
                    figure
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.minimumTarget, alignment: .leading)
        .padding(.vertical, Theme.Space.s)
        .contentShape(Rectangle())
    }

    private var color: Color {
        switch tone {
        case .normal: Theme.text
        case .warn: Theme.warn
        case .error: Theme.danger
        }
    }
}

// MARK: - Server health

private struct HealthSection: View {
    let model: DashboardViewModel
    let now: Date
    var onShowNodes: (() -> Void)?

    var body: some View {
        let status = model.insights.status
        SectionPanel(section: .health, title: "Server health") {
            if let value = status.value {
                let cells = healthCells(status: value, build: model.insights.build.value, nodes: model.insights.nodes.value, now: now)
                // A compact list, one line per fact, so a long value ("1.07 GB / 4.29 GB") never wraps inside a grid cell.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                        if index > 0 { Divider().overlay(Theme.hairline) }
                        if cell.linksToNodes, let onShowNodes {
                            Button(action: onShowNodes) {
                                HealthRowView(cell: cell, showsDisclosure: true)
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint(String(localized: "Opens Nodes"))
                            .accessibilityIdentifier("dashboard-nodes-cell")
                        } else {
                            HealthRowView(cell: cell)
                        }
                    }
                }
                SectionErrorText(message: status.error)
            } else if let error = status.error {
                SectionErrorText(message: error)
            } else if model.resources?.visibleSystem == nil && model.hostError == nil {
                EmptyLine(text: String(localized: "Loading server health…"))
            }
            HostResourcesLine(resources: model.resources, hostError: model.hostError)
        }
    }
}

private struct HealthRowView: View {
    let cell: HealthCell
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            DashboardValueRow(label: cell.label, value: cell.value, detail: cell.detail, tone: cell.tone)
            if showsDisclosure {
                IconImage(.chevronRight, size: .inline).foregroundStyle(.bloemMuted).accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

/// CPU, memory and network of the API host as three lines of the same list, with the age of the sample. A stale
/// sample says so.
private struct HostResourcesLine: View {
    let resources: SystemResources?
    let hostError: String?

    var body: some View {
        if let resources, let system = resources.visibleSystem {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(figures(system)) { figure in
                        Divider().overlay(Theme.hairline)
                        HealthRowView(cell: figure)
                    }
                }
                if let sampledAt = resources.sampledAt {
                    if resources.stale {
                        StatusLabel("Last sample \(formatRelativeTime(sampledAt))", tone: .warning)
                    } else {
                        Text("Sampled \(formatRelativeTime(sampledAt))").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                } else if resources.stale {
                    StatusLabel("This sample is out of date", tone: .warning)
                }
            }
            .accessibilityElement(children: .contain)
        } else if let hostError {
            Label(hostError, icon: .triangleAlert)
                .bloemText(.bodySmall).foregroundStyle(.bloemWarn).padding(.top, Theme.Space.xs)
        }
    }

    private func figures(_ system: SystemStats) -> [HealthCell] {
        let bytes = { (value: Double) in ByteCountFormatter.string(fromByteCount: Int64(value.rounded()), countStyle: .file) }
        let memory = "\(ByteCountFormatter.string(fromByteCount: system.memUsedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: system.memTotalBytes, countStyle: .file))"
        return [
            HealthCell(label: String(localized: "CPU"), value: "\(Int(system.cpuPct.rounded()))%"),
            HealthCell(label: String(localized: "Memory"), value: memory),
            HealthCell(label: String(localized: "Network"), value: "↓ \(bytes(system.netRxBytesPerSec))/s", detail: "↑ \(bytes(system.netTxBytesPerSec))/s"),
        ]
    }
}

// MARK: - Now playing

private struct NowPlayingSection: View {
    static let limit = 4
    let model: DashboardViewModel
    let onShowStreams: (() -> Void)?

    var body: some View {
        let state = model.sessions
        SectionPanel(
            section: .nowPlaying, title: "Now playing",
            actionTitle: onShowStreams == nil ? nil : "Manage streams", action: onShowStreams
        ) {
            if let liveState = model.liveState {
                LiveSessionsStatus(state: liveState, failure: model.liveFailure, hasSessions: state.value?.isEmpty == false)
            }
            if let sessions = state.value {
                if state.error != nil {
                    Label("Live sessions unavailable. Showing the last reported data", icon: .triangleAlert)
                        .bloemText(.bodySmall).foregroundStyle(.bloemWarn)
                }
                if sessions.isEmpty {
                    EmptyLine(text: String(localized: "Nothing playing right now"))
                }
                ForEach(sessions.prefix(Self.limit)) { session in
                    Divider()
                    SessionPreview(session: session, onShowStreams: onShowStreams)
                }
                let more = sessions.count - Self.limit
                if more > 0, let onShowStreams {
                    Button(action: onShowStreams) {
                        Text("+\(more) more active streams")
                            .bloemText(.titleSmall).foregroundStyle(.bloemMuted)
                            .frame(minHeight: Theme.minimumTarget, alignment: .leading)
                    }
                }
                if let message = state.error {
                    Text(message).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
            } else if let message = state.error {
                Label(message, icon: .triangleAlert).bloemText(.bodySmall).foregroundStyle(.bloemWarn)
            } else {
                EmptyLine(text: String(localized: "Loading live sessions…"))
            }
        }
    }
}

/// One stream on the dashboard: the same signal path, timecode and bitrate as the Now playing page, as a
/// summary that opens that page.
private struct SessionPreview: View {
    let session: AdminSession
    let onShowStreams: (() -> Void)?

    var body: some View {
        let row = StreamRowView(session: session, expandable: false)
            .frame(maxWidth: .infinity, minHeight: Theme.minimumTarget, alignment: .leading)
            .contentShape(Rectangle())
        if let onShowStreams {
            Button(action: onShowStreams) { row }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
        } else {
            row
        }
    }
}

// MARK: - Top lists

private struct TopTitlesSection: View {
    static let limit = 5
    let state: SectionState<TopActivity>

    var body: some View {
        SectionPanel(section: .topTitles, title: "Top titles", caption: String(localized: "Last 7 days")) {
            if let titles = state.value?.titles {
                if titles.isEmpty { EmptyLine(text: String(localized: "Nothing played in the last 7 days")) }
                ForEach(Array(titles.prefix(Self.limit).enumerated()), id: \.offset) { _, title in
                    DashboardListRow(
                        primary: title.title.isEmpty ? title.mediaItemID : title.title,
                        trailing: playsText(title.plays, seconds: title.totalSeconds)
                    )
                }
            }
            SectionErrorText(message: state.error)
        }
    }
}

private struct TopProfilesSection: View {
    static let limit = 5
    let state: SectionState<TopActivity>

    var body: some View {
        SectionPanel(section: .topProfiles, title: "Most active profiles", caption: String(localized: "Last 7 days")) {
            if let profiles = state.value?.profiles {
                if profiles.isEmpty { EmptyLine(text: String(localized: "Nothing played in the last 7 days")) }
                ForEach(Array(profiles.prefix(Self.limit).enumerated()), id: \.offset) { _, profile in
                    DashboardListRow(
                        primary: topProfileLabel(profile),
                        trailing: playsText(profile.plays, seconds: profile.totalSeconds)
                    )
                }
            } else {
                // The titles section above reads the same request and already shows its failure.
                EmptyLine(text: String(localized: "Unavailable"))
            }
        }
    }
}

private func playsText(_ plays: Int, seconds: Double) -> String {
    String(localized: "\(plays) plays · \(formatWatchTime(seconds))")
}

// MARK: - Libraries, users, recent activity

private struct LibrariesSection: View {
    static let limit = 8
    let state: SectionState<[DashboardLibrary]>

    var body: some View {
        SectionPanel(section: .libraries, title: "Libraries") {
            if let libraries = state.value {
                if libraries.isEmpty { EmptyLine(text: String(localized: "No libraries configured")) }
                ForEach(libraries.prefix(Self.limit)) { library in
                    DashboardListRow(
                        primary: library.name,
                        secondary: String(localized: "\(library.type) · \(library.paths.count) paths"),
                        trailing: library.enabled ? nil : String(localized: "Disabled"),
                        warn: !library.enabled
                    )
                }
            }
            SectionErrorText(message: state.error)
        }
    }
}

private struct UsersSection: View {
    static let limit = 5
    let state: SectionState<[DashboardUser]>
    let onShowUsers: (() -> Void)?

    var body: some View {
        SectionPanel(
            section: .users, title: "Users",
            actionTitle: onShowUsers == nil ? nil : "Manage users", action: onShowUsers
        ) {
            if let users = state.value {
                if users.isEmpty { EmptyLine(text: String(localized: "No users")) }
                ForEach(usersByLastActive(users).prefix(Self.limit)) { user in
                    DashboardListRow(
                        primary: user.username,
                        secondary: user.enabled ? user.role : String(localized: "\(user.role) · Disabled"),
                        trailing: user.lastActiveAt.map { formatRelativeTime($0) } ?? String(localized: "No activity yet"),
                        warn: !user.enabled
                    )
                }
            }
            SectionErrorText(message: state.error)
        }
    }
}

private struct RecentActivitySection: View {
    static let limit = 5
    let state: SectionState<[RecentPlayback]>

    var body: some View {
        SectionPanel(section: .recentActivity, title: "Recent activity") {
            if let entries = state.value {
                if entries.isEmpty { EmptyLine(text: String(localized: "No recent activity")) }
                ForEach(entries.prefix(Self.limit)) { entry in
                    DashboardListRow(
                        primary: entry.mediaTitle,
                        secondary: entry.username,
                        trailing: entry.startedAt.map { formatRelativeTime($0) }
                    )
                }
            }
            SectionErrorText(message: state.error)
        }
    }
}
