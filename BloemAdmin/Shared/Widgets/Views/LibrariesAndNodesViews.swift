import SwiftUI
import WidgetKit

private func warningsText(_ count: Int) -> String {
    count == 1 ? String(localized: "1 warning") : String(localized: "\(count) warnings")
}

// MARK: Libraries and scans

struct LibrariesFigures: Equatable, Sendable {
    /// Libraries needing a look come first (a warning, then a scan running), then the rest by name.
    var items: [WidgetLibraryItem]
    var total: Int
    var warnings: Int
    var scanning: Int

    init(board: WidgetBoard<WidgetLibraryItem>) {
        let all = board.items
        func rank(_ item: WidgetLibraryItem) -> Int { item.warning != nil ? 0 : item.activity != nil ? 1 : 2 }
        items = all.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        total = board.total ?? all.count
        warnings = all.filter { $0.warning != nil }.count
        scanning = all.filter { $0.activity != nil }.count
    }

    /// The names are details: none on a surface that hides them.
    func visibleItems(_ context: WidgetContext) -> [WidgetLibraryItem] {
        context.showsDetails ? items : []
    }

    var hasItems: Bool { !items.isEmpty }

    /// The scan with the most to say: one that reports progress, else the first one running.
    var topScan: WidgetLibraryItem? {
        items.first { $0.activity?.progress != nil } ?? items.first { $0.activity != nil }
    }

    var stats: [WidgetStat] {
        [
            WidgetStat(id: "libraries", value: String(total), label: total == 1 ? String(localized: "library") : String(localized: "libraries")),
            WidgetStat(id: "scanning", value: String(scanning), label: String(localized: "scanning"), isLive: scanning > 0),
            WidgetStat(id: "warnings", value: String(warnings), label: warnings == 1 ? String(localized: "warning") : String(localized: "warnings")),
        ]
    }

    /// "Scanning 40%", "Scan queued", "Scanned 2h ago", "Not scanned yet".
    static func detail(_ library: WidgetLibraryItem, now: Date) -> String {
        if let activity = library.activity {
            switch activity.phase {
            case .queued: return String(localized: "Scan queued")
            case .running:
                if let progress = activity.progress { return String(localized: "Scanning \(Int((progress * 100).rounded()))%") }
                return String(localized: "Scanning")
            }
        }
        if let scanned = library.lastScannedAt {
            let age = WidgetTime.age(from: scanned, now: now) ?? ""
            return age == String(localized: "now") ? String(localized: "Scanned just now") : String(localized: "Scanned \(age) ago")
        }
        return String(localized: "Not scanned yet")
    }
}

enum LibrariesTier: Int, CaseIterable, Sendable {
    case roomy, compact

    static let tiers: [WidgetCardTier] = [
        WidgetCardTier(height: 64, minWidth: 200),
        WidgetCardTier(height: 46, minWidth: 0),
    ]
}

struct LibrariesWidgetView: View {
    let board: WidgetBoard<WidgetLibraryItem>
    let context: WidgetContext
    @Environment(\.widgetPalette) private var palette

    private var state: BoardState { board.state(now: context.now) }
    private var figures: LibrariesFigures { LibrariesFigures(board: board) }
    private var link: URL { WidgetLink.page(DeepLinkPage.libraries, serverID: board.serverID) }
    private var hasContent: Bool { state.phase == .content || state.phase == .empty }
    private var serverName: String { board.feeds.count == 1 ? board.feeds[0].serverName : board.title }

    var body: some View {
        Group {
            switch context.size {
            case .circular: circular
            case .rectangular: rectangular
            case .inline: inline
            default: home
            }
        }
        .widgetURL(link)
    }

    // MARK: Lock screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                if !hasContent {
                    WidgetIconView(icon: .warning, size: 16)
                    Text(verbatim: "–").widgetText(.titleLarge)
                } else if figures.warnings > 0 {
                    WidgetIconView(icon: .warning, size: 16)
                    Text(verbatim: String(figures.warnings)).widgetText(.titleLarge)
                } else {
                    WidgetIconView(icon: .library, size: 16)
                    Text(verbatim: String(figures.scanning > 0 ? figures.scanning : figures.total)).widgetText(.titleLarge)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Libraries")
        .accessibilityValue(summaryLine)
    }

    /// "2 warnings · 1 scanning", or how many libraries there are.
    private var summaryLine: String {
        var parts: [String] = []
        if figures.warnings > 0 { parts.append(warningsText(figures.warnings)) }
        if figures.scanning > 0 { parts.append(String(localized: "\(figures.scanning) scanning")) }
        return parts.isEmpty
            ? (figures.total == 1 ? String(localized: "1 library") : String(localized: "\(figures.total) libraries"))
            : parts.joined(separator: " · ")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetRectangularTitle(title: "Libraries")
            switch state.phase {
            case .content, .empty:
                Text(verbatim: summaryLine).widgetText(.bodySmall).lineLimit(1)
                if let scan = figures.topScan, context.showsDetails {
                    Text(verbatim: "\(scan.name) · \(LibrariesFigures.detail(scan, now: context.now))")
                        .widgetText(.bodySmall).lineLimit(1).widgetDetail(context)
                    if let progress = scan.activity?.progress { ProgressBar(fraction: progress, height: 3).widgetDetail(context) }
                }
            case .signedOut: Text("Sign in to see libraries").widgetText(.bodySmall).lineLimit(2)
            case .unreachable(let name): Text("Can't reach \(name)").widgetText(.bodySmall).lineLimit(2)
            case .unavailable: Text("Not available on this server").widgetText(.bodySmall).lineLimit(2)
            case .noServers: Text("Add a Silo server").widgetText(.bodySmall)
            case .loading: Text("Loading").widgetText(.bodySmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inline: some View {
        switch state.phase {
        case .content, .empty: Text(verbatim: String(localized: "Libraries: \(summaryLine)"))
        case .signedOut: Text("Sign in to see libraries")
        case .unreachable(let name): Text("Can't reach \(name)")
        default: Text("Libraries")
        }
    }

    // MARK: Home screen

    @ViewBuilder
    private var home: some View {
        if state.phase == .content {
            if context.size == .small {
                small
            } else if context.showsDetails, figures.hasItems {
                list
            } else {
                countsOnly
            }
        } else {
            WidgetStateCard(
                icon: .library, title: "Libraries", trailing: state.phase == .empty ? serverName : nil, phase: state.phase,
                thing: String(localized: "libraries"), emptyText: String(localized: "No libraries yet"),
                unavailableText: String(localized: "Libraries aren't available on this server")
            )
        }
    }

    private var headerTally: String? { figures.scanning > 0 ? String(localized: "\(figures.scanning) scanning") : nil }
    private var headerTrailing: String { figures.warnings > 0 ? warningsText(figures.warnings) : serverName }

    private var small: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .library, title: "Libraries", compact: true)
            Spacer(minLength: 0)
            BigFigure(
                value: String(figures.total), caption: figures.total == 1 ? String(localized: "library") : String(localized: "libraries"),
                isLive: false
            )
            if let scan = figures.topScan, context.showsDetails {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        WidgetTallyDot()
                        Text(verbatim: "\(scan.name) · \(LibrariesFigures.detail(scan, now: context.now))")
                            .widgetText(.labelMedium).foregroundStyle(palette.text).lineLimit(1).widgetDetail(context)
                    }
                    if let progress = scan.activity?.progress { ProgressBar(fraction: progress).widgetDetail(context) }
                }
            } else if figures.warnings > 0 {
                Text(verbatim: warningsText(figures.warnings)).widgetText(.labelMedium).foregroundStyle(palette.warning).lineLimit(1)
            } else if figures.scanning > 0 {
                Text("\(figures.scanning) scanning").widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
            } else {
                Text("No warnings").widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(1)
            }
            FreshnessLine(state: state)
        }
    }

    private var list: some View {
        let values = figures
        return WidgetListLayout(
            rows: values.visibleItems(context), tiers: LibrariesTier.tiers,
            maxColumns: context.size == .extraLarge ? 2 : 1, reserved: widgetFreshnessHeight(state),
            header: { WidgetHeader(icon: .library, title: "Libraries", tally: headerTally, trailing: headerTrailing) },
            card: { library, slot in
                WidgetLibraryCard(
                    library: library, now: context.now, tier: LibrariesTier(rawValue: slot.tierIndex) ?? .compact,
                    showsServer: board.feeds.count > 1
                )
            },
            footer: { kind, _ in WidgetFooterView(kind: kind, stats: values.stats) },
            bottom: { FreshnessLine(state: state) }
        )
    }

    private var countsOnly: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .library, title: "Libraries", tally: headerTally, trailing: headerTrailing)
            WidgetFooterView(kind: .stats, stats: figures.stats)
            Spacer(minLength: 0)
            FreshnessLine(state: state)
        }
    }
}

/// One library, as the app's library card: its name, when it was last scanned or how far a scan is, and a
/// warning where the last scan found one. A running scan's progress is the card's lower edge.
struct WidgetLibraryCard: View {
    let library: WidgetLibraryItem
    let now: Date
    var tier: LibrariesTier = .compact
    var showsServer = false
    @Environment(\.widgetPalette) private var palette

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: WidgetLayout.cardRadius, style: .continuous) }
    private var detail: String { LibrariesFigures.detail(library, now: now) }

    /// "Last scan Nov 15, 2:32 PM", in the person's own format.
    private var lastScan: String {
        library.lastScannedAt.map { String(localized: "Last scan \($0.formatted(.dateTime.month(.abbreviated).day().hour().minute()))") }
            ?? String(localized: "Never scanned")
    }

    var body: some View {
        Link(destination: WidgetLink.item(library.id, on: DeepLinkPage.libraries, serverID: library.serverID)) {
            WidgetCard {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if library.warning != nil { WidgetIconView(icon: .warning, size: 14).foregroundStyle(palette.warning) }
                        Text(verbatim: showsServer ? "\(library.name) · \(library.serverName)" : library.name)
                            .widgetText(tier == .roomy ? .titleSmall : .labelMedium).foregroundStyle(palette.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if library.activity != nil {
                            WidgetDotLabel(color: palette.tally, text: detail)
                        } else if tier == .roomy || library.warning == nil {
                            Text(verbatim: detail).widgetText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
                        }
                    }
                    if let warning = library.warning {
                        Text(verbatim: warning).widgetText(.bodySmall).foregroundStyle(palette.warning).lineLimit(1)
                    } else if tier == .roomy {
                        Text(verbatim: lastScan)
                            .widgetText(.bodySmall).foregroundStyle(palette.muted).lineLimit(1)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if let progress = library.activity?.progress { ProgressBar(fraction: progress, height: 3) }
            }
            .clipShape(shape)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: Nodes and resources

struct NodesFigures: Equatable, Sendable {
    /// Nodes needing a look come first: unhealthy, draining, then healthy, then disabled.
    var items: [NodeItem]
    var total: Int
    var healthy: Int
    var unhealthy: Int
    var averageCPU: Int?
    var averageMemory: Int?
    var fullestDisk: Int?

    init(board: WidgetBoard<NodeItem>) {
        let all = board.items
        func rank(_ item: NodeItem) -> Int {
            switch item.health {
            case .unhealthy: 0
            case .draining, .drained: 1
            case .healthy: 2
            case .disabled: 3
            }
        }
        items = all.sorted { a, b in
            rank(a) != rank(b) ? rank(a) < rank(b) : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        total = board.total ?? all.count
        healthy = all.filter { $0.health == .healthy }.count
        unhealthy = all.filter { $0.health == .unhealthy }.count
        func average(_ values: [Int]) -> Int? {
            values.isEmpty ? nil : Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
        }
        averageCPU = average(all.compactMap(\.cpuPercent))
        averageMemory = average(all.compactMap(\.memoryPercent))
        fullestDisk = all.compactMap(\.diskPercent).max()
    }

    /// The names are details: none on a surface that hides them.
    func visibleItems(_ context: WidgetContext) -> [NodeItem] {
        context.showsDetails ? items : []
    }

    var hasItems: Bool { !items.isEmpty }

    var stats: [WidgetStat] {
        var result = [
            WidgetStat(id: "nodes", value: String(total), label: total == 1 ? String(localized: "node") : String(localized: "nodes")),
            WidgetStat(id: "healthy", value: String(healthy), label: String(localized: "healthy")),
        ]
        if let averageCPU { result.append(WidgetStat(id: "cpu", value: "\(averageCPU)%", label: String(localized: "CPU"))) }
        return result
    }

    /// "CPU 34% · Memory 52%": all a lock screen rectangle has room for.
    var shortResourceLine: String? {
        let parts = [
            averageCPU.map { String(localized: "CPU \($0)%") },
            averageMemory.map { String(localized: "Memory \($0)%") },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "CPU 34% · Memory 52% · Disk 61%", of what the nodes report.
    var resourceLine: String? {
        let parts = [
            averageCPU.map { String(localized: "CPU \($0)%") },
            averageMemory.map { String(localized: "Memory \($0)%") },
            fullestDisk.map { String(localized: "Disk \($0)%") },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum NodesTier: Int, CaseIterable, Sendable {
    /// Name and state, then CPU, memory and disk as three small bars.
    case roomy
    /// Name and state, then the three figures on one line.
    case compact

    static let tiers: [WidgetCardTier] = [
        WidgetCardTier(height: 66, minWidth: 260),
        WidgetCardTier(height: 46, minWidth: 0),
    ]
}

struct NodesWidgetView: View {
    let board: WidgetBoard<NodeItem>
    let context: WidgetContext
    @Environment(\.widgetPalette) private var palette

    private var state: BoardState { board.state(now: context.now) }
    private var figures: NodesFigures { NodesFigures(board: board) }
    private var link: URL { WidgetLink.page(DeepLinkPage.nodes, serverID: board.serverID) }
    private var hasContent: Bool { state.phase == .content || state.phase == .empty }
    private var serverName: String { board.feeds.count == 1 ? board.feeds[0].serverName : board.title }

    var body: some View {
        Group {
            switch context.size {
            case .circular: circular
            case .rectangular: rectangular
            case .inline: inline
            default: home
            }
        }
        .widgetURL(link)
    }

    // MARK: Lock screen

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if hasContent, figures.unhealthy == 0, let cpu = figures.averageCPU {
                Gauge(value: Double(min(max(cpu, 0), 100)) / 100) {
                    WidgetIconView(icon: .cpu, size: 12)
                } currentValueLabel: {
                    Text(verbatim: String(cpu)).widgetText(.labelMedium)
                }
                .gaugeStyle(.accessoryCircularCapacity)
            } else {
                VStack(spacing: 0) {
                    WidgetIconView(icon: !hasContent || figures.unhealthy > 0 ? .warning : .cpu, size: 16)
                    Text(verbatim: !hasContent ? "–" : String(figures.unhealthy > 0 ? figures.unhealthy : figures.total)).widgetText(.titleLarge)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nodes")
        .accessibilityValue(summaryLine)
    }

    private var summaryLine: String {
        figures.unhealthy > 0
            ? String(localized: "\(figures.total) nodes · \(figures.unhealthy) unhealthy")
            : String(localized: "\(figures.healthy) of \(figures.total) healthy")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            WidgetRectangularTitle(title: "Nodes")
            switch state.phase {
            case .content, .empty:
                Text(verbatim: summaryLine).widgetText(.bodySmall).lineLimit(1)
                if let line = figures.shortResourceLine { Text(verbatim: line).widgetText(.bodySmall).lineLimit(1) }
            case .signedOut: Text("Sign in to see nodes").widgetText(.bodySmall).lineLimit(2)
            case .unreachable(let name): Text("Can't reach \(name)").widgetText(.bodySmall).lineLimit(2)
            case .unavailable: Text("Not available on this server").widgetText(.bodySmall).lineLimit(2)
            case .noServers: Text("Add a Silo server").widgetText(.bodySmall)
            case .loading: Text("Loading").widgetText(.bodySmall)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var inline: some View {
        switch state.phase {
        case .content, .empty: Text(verbatim: String(localized: "Nodes: \(summaryLine)"))
        case .signedOut: Text("Sign in to see nodes")
        case .unreachable(let name): Text("Can't reach \(name)")
        default: Text("Nodes")
        }
    }

    // MARK: Home screen

    @ViewBuilder
    private var home: some View {
        if state.phase == .content {
            if context.size == .small {
                small
            } else if context.showsDetails, figures.hasItems {
                list
            } else {
                countsOnly
            }
        } else {
            WidgetStateCard(
                icon: .cpu, title: "Nodes", trailing: state.phase == .empty ? serverName : nil, phase: state.phase,
                thing: String(localized: "nodes"), emptyText: String(localized: "No nodes yet"),
                unavailableText: String(localized: "Nodes aren't available on this server")
            )
        }
    }

    private var headerTally: String? { figures.unhealthy > 0 ? String(localized: "\(figures.unhealthy) unhealthy") : nil }

    private var small: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .cpu, title: "Nodes", tally: headerTally, compact: true)
            Spacer(minLength: 0)
            BigFigure(value: "\(figures.healthy)/\(figures.total)", caption: String(localized: "healthy"))
            if figures.unhealthy > 0 {
                Text("\(figures.unhealthy) unhealthy").widgetText(.labelMedium).foregroundStyle(palette.danger).lineLimit(1)
            } else if let line = figures.resourceLine {
                Text(verbatim: line).widgetText(.labelMedium).foregroundStyle(palette.muted).lineLimit(2)
            }
            FreshnessLine(state: state)
        }
    }

    private var list: some View {
        let values = figures
        return WidgetListLayout(
            rows: values.visibleItems(context), tiers: NodesTier.tiers,
            maxColumns: context.size == .extraLarge ? 2 : 1, reserved: widgetFreshnessHeight(state),
            header: { WidgetHeader(icon: .cpu, title: "Nodes", tally: headerTally, trailing: serverName) },
            card: { node, slot in
                WidgetNodeCard(node: node, tier: NodesTier(rawValue: slot.tierIndex) ?? .compact, showsServer: board.feeds.count > 1)
            },
            footer: { kind, _ in WidgetFooterView(kind: kind, stats: values.stats) },
            bottom: { FreshnessLine(state: state) }
        )
    }

    private var countsOnly: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.gap) {
            WidgetHeader(icon: .cpu, title: "Nodes", tally: headerTally, trailing: serverName)
            WidgetFooterView(kind: .stats, stats: figures.stats)
            Spacer(minLength: 0)
            FreshnessLine(state: state)
        }
    }
}

/// One node, as the app's node card: its name and state (a dot and a word), then CPU, memory and disk.
struct WidgetNodeCard: View {
    let node: NodeItem
    var tier: NodesTier = .compact
    var showsServer = false
    @Environment(\.widgetPalette) private var palette

    private var tone: Color {
        switch node.health {
        case .healthy: palette.ok
        case .draining, .drained: palette.warning
        case .unhealthy: palette.danger
        case .disabled: palette.muted
        }
    }

    var body: some View {
        Link(destination: WidgetLink.page(DeepLinkPage.nodes, serverID: node.serverID)) {
            WidgetCard {
                VStack(alignment: .leading, spacing: tier == .roomy ? 6 : 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(verbatim: showsServer ? "\(node.name) · \(node.serverName)" : node.name)
                            .widgetText(tier == .roomy ? .titleSmall : .labelMedium).foregroundStyle(palette.text).lineLimit(1)
                        Spacer(minLength: 4)
                        WidgetDotLabel(color: tone, text: node.health.label, textColor: node.health == .unhealthy ? palette.danger : palette.muted)
                    }
                    if tier == .roomy {
                        HStack(alignment: .top, spacing: 12) {
                            WidgetMeter(label: String(localized: "CPU"), value: node.cpuPercent, warnAt: 90, showsBar: true)
                            WidgetMeter(label: String(localized: "Memory"), value: node.memoryPercent, warnAt: 90, showsBar: true)
                            WidgetMeter(label: String(localized: "Disk"), value: node.diskPercent, warnAt: 85, showsBar: true)
                        }
                    } else {
                        HStack(spacing: 12) {
                            WidgetMeter(label: String(localized: "CPU"), value: node.cpuPercent, warnAt: 90, showsBar: false)
                            WidgetMeter(label: String(localized: "Memory"), value: node.memoryPercent, warnAt: 90, showsBar: false)
                            WidgetMeter(label: String(localized: "Disk"), value: node.diskPercent, warnAt: 85, showsBar: false)
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A label and its percentage, with a thin bar where there is room. A figure at or over its limit is amber.
struct WidgetMeter: View {
    let label: String
    let value: Int?
    let warnAt: Int
    let showsBar: Bool
    @Environment(\.widgetPalette) private var palette

    private var isHigh: Bool { (value ?? 0) >= warnAt }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: label).widgetText(.labelSmall).foregroundStyle(palette.muted).lineLimit(1)
                if !showsBar { Spacer(minLength: 0) }
                Text(verbatim: value.map { "\($0)%" } ?? "–").widgetText(.labelMedium)
                    .foregroundStyle(isHigh ? palette.warning : palette.text).lineLimit(1)
            }
            if showsBar {
                ProgressBar(fraction: Double(value ?? 0) / 100, height: 3, paused: isHigh)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
