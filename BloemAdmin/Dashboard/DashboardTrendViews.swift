import Charts
import SwiftUI

// The three trend sections. Concurrent streams, split by how each stream was delivered, is the one main
// chart; Playback activity and Egress are smaller and read the same window, chosen once by the range
// control above them. Each draws with Swift Charts and keeps its last good chart beside a failed
// refresh. The numbers and labels come from the models in DashboardTrends.swift.

// MARK: - Range control

/// The one window control for all three charts: a native segmented control, so the chosen window is
/// marked by more than color.
struct ChartRangePicker: View {
    let selected: ChartRange
    let onSelect: (ChartRange) -> Void

    var body: some View {
        Picker("Chart window", selection: Binding(get: { selected }, set: onSelect)) {
            ForEach(ChartRange.allCases) { range in
                Text(range.label)
                    .accessibilityLabel(range.showLabel)
                    .tag(range)
            }
        }
        .segmentedUnlessLargeText()
        .accessibilityIdentifier("dashboard-chart-range")
    }
}

// MARK: - Frame: summary, chart or plain numbers, switch

/// A chart with its summary line above and the switch to its plain numbers below. The summary and
/// the chart are one image to VoiceOver, described by `description` (window, latest, peak,
/// lowest); the numbers are the alternative to it.
struct TrendChartFrame<Plot: View>: View {
    let kind: ChartKind
    let title: String
    let description: String
    let summaryLine: String?
    let rows: [ChartValueRow]
    /// Drawn under the chart as ordinary text, outside the chart's single VoiceOver image, so it is
    /// read on its own and is never visible text without an element.
    var legend: [ChartLegendItem] = []
    @ViewBuilder var chart: () -> Plot
    @State private var showValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if showValues {
                ChartValuesList(rows: rows)
                    .accessibilityIdentifier("dashboard-chart-values-\(kind.rawValue)")
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    if let summaryLine {
                        Text(summaryLine)
                            .bloemText(.bodySmall)
                            .foregroundStyle(.bloemMuted)
                            .accessibilityIdentifier("dashboard-chart-summary-\(kind.rawValue)")
                    }
                    chart()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(description)
                .accessibilityAddTraits(.isImage)
                .accessibilityIdentifier("dashboard-chart-\(kind.rawValue)")
                if !legend.isEmpty {
                    ChartLegend(items: legend)
                        .accessibilityIdentifier("dashboard-chart-legend-\(kind.rawValue)")
                }
            }
            Button {
                showValues.toggle()
            } label: {
                Text(showValues ? String(localized: "Show chart") : String(localized: "Show values"))
                    .bloemText(.labelMedium)
                    .foregroundStyle(.bloemMuted)
                    .frame(minHeight: Theme.minimumTarget, alignment: .leading)
            }
            .accessibilityLabel(
                showValues
                    ? String(localized: "Show chart for \(title)")
                    : String(localized: "Show values for \(title)")
            )
            .accessibilityIdentifier("dashboard-chart-toggle-\(kind.rawValue)")
        }
    }
}

/// The plain-number alternative to a chart.
struct ChartValuesList: View {
    let rows: [ChartValueRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            ForEach(rows) { row in
                if row.isHeading {
                    Text(row.label)
                        .bloemText(.labelMedium)
                        .foregroundStyle(.bloemMuted)
                        .padding(.top, Theme.Space.s)
                        .accessibilityAddTraits(.isHeader)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
                        Text(row.label).foregroundStyle(.bloemMuted)
                        Spacer(minLength: Theme.Space.s)
                        Text(row.value).multilineTextAlignment(.trailing)
                    }
                    .bloemText(.bodyMedium)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Charts

private let mainPlotHeight: CGFloat = 200
private let smallPlotHeight: CGFloat = 96

/// The time axis: day marks for a week or a month, hour marks for a day, quarter-hours for an hour.
/// It replaces the old "24h ago … now" edge labels, so a peak can be placed on the clock or calendar.
private struct TimeAxisSpec {
    let component: Calendar.Component
    let count: Int
    let format: Date.FormatStyle

    init(_ range: ChartRange) {
        switch range {
        case .hour: self.init(.minute, 15, .dateTime.hour().minute())
        case .day: self.init(.hour, 6, .dateTime.hour())
        case .week: self.init(.day, 1, .dateTime.weekday(.abbreviated))
        case .month: self.init(.day, 7, .dateTime.month(.abbreviated).day())
        }
    }

    private init(_ component: Calendar.Component, _ count: Int, _ format: Date.FormatStyle) {
        self.component = component
        self.count = count
        self.format = format
    }
}

private extension View {
    /// Muted gridlines and time labels, and a value axis that shows its ticks.
    func trendAxes(range: ChartRange, ticks: [Double], label: @escaping (Double) -> String) -> some View {
        let spec = TimeAxisSpec(range)
        return chartXAxis {
            AxisMarks(values: .stride(by: spec.component, count: spec.count)) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: spec.format).bloemText(.labelSmall).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: ticks) { value in
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel {
                    if let tick = value.as(Double.self) {
                        Text(label(tick)).bloemText(.labelSmall).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

/// The main chart: concurrent streams over the window, stacked by how each was delivered, direct play at
/// the baseline. A server that does not report the split gets a single line for the total. Missing samples
/// break the stack instead of dropping to zero, and the value axis starts at zero.
struct StackedStreamsChart: View {
    let model: SampledChartModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let first = model.points.first?.date ?? Date()
        let last = model.points.last?.date ?? first
        let domain = first < last ? first...last : first.addingTimeInterval(-30)...first.addingTimeInterval(30)
        Chart {
            if model.layers.isEmpty {
                ForEach(Array(plottedRuns(model.points).enumerated()), id: \.offset) { runIndex, run in
                    ForEach(run, id: \.index) { item in
                        AreaMark(
                            x: .value("Time", item.point.date), y: .value("Streams", item.point.plotted),
                            series: .value("Area", "area-\(runIndex)")
                        )
                        .interpolationMethod(.stepEnd)
                        .foregroundStyle(PlaybackMethod.directPlay.color.opacity(0.85))
                    }
                }
            } else {
                ForEach(model.layers, id: \.method) { layer in
                    ForEach(Array(plottedRuns(layer.upper).enumerated()), id: \.offset) { runIndex, run in
                        ForEach(run, id: \.index) { item in
                            AreaMark(
                                x: .value("Time", item.point.date),
                                yStart: .value("From", layer.lower[item.index] ?? 0),
                                yEnd: .value("To", item.point.plotted),
                                series: .value("Band", "\(layer.method.name)-\(runIndex)")
                            )
                            .interpolationMethod(.stepEnd)
                            .foregroundStyle(layer.method.color.opacity(0.9))
                        }
                    }
                }
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...model.top)
        .trendAxes(range: model.range, ticks: model.ticks, label: model.tickLabel)
        .frame(height: mainPlotHeight)
        .animation(ChartMotion.animation(reduceMotion: reduceMotion), value: model.points)
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// A smaller time line for egress, in ink rather than a hue: the line is the signal. Missing samples
/// break the line instead of dropping to zero, an isolated sample is a dot, and the newest sample is
/// marked. A dashed line in the direct-stream color shows download traffic.
struct LineTrendChart: View {
    let model: SampledChartModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let runs = plottedRuns(model.points)
        let downloadRuns = model.downloads.map(plottedRuns) ?? []
        let first = model.points.first?.date ?? Date()
        let last = model.points.last?.date ?? first
        let domain = first < last ? first...last : first.addingTimeInterval(-30)...first.addingTimeInterval(30)
        Chart {
            ForEach(Array(runs.enumerated()), id: \.offset) { runIndex, run in
                ForEach(run, id: \.index) { item in
                    AreaMark(
                        x: .value("Time", item.point.date),
                        y: .value("Value", item.point.plotted),
                        series: .value("Area", "area-\(runIndex)")
                    )
                    .foregroundStyle(Theme.text.opacity(0.08))
                    LineMark(
                        x: .value("Time", item.point.date),
                        y: .value("Value", item.point.plotted),
                        series: .value("Line", "line-\(runIndex)")
                    )
                    .foregroundStyle(Theme.text)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                if run.count == 1, let only = run.first {
                    PointMark(x: .value("Time", only.point.date), y: .value("Value", only.point.plotted))
                        .foregroundStyle(Theme.text)
                        .symbolSize(24)
                }
            }
            ForEach(Array(downloadRuns.enumerated()), id: \.offset) { runIndex, run in
                ForEach(run, id: \.index) { item in
                    LineMark(
                        x: .value("Time", item.point.date),
                        y: .value("Downloads", item.point.plotted),
                        series: .value("Downloads", "downloads-\(runIndex)")
                    )
                    .foregroundStyle(PlaybackMethod.directStream.color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                }
            }
            if let latest = runs.last?.last {
                PointMark(x: .value("Time", latest.point.date), y: .value("Value", latest.point.plotted))
                    .foregroundStyle(Theme.text)
                    .symbolSize(40)
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...model.top)
        .trendAxes(range: model.range, ticks: model.ticks, label: model.tickLabel)
        .frame(height: smallPlotHeight)
        .animation(ChartMotion.animation(reduceMotion: reduceMotion), value: model.points)
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// Columns of sessions per bucket, stacked direct play, direct stream, transcode from the baseline up.
struct PlaybackColumnsChart: View {
    let model: PlaybackChartModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let unit: Calendar.Component = model.isDaily ? .day : .hour
        let step = model.isDaily ? 86_400.0 : 3600.0
        let start = model.columns.first?.date ?? Date()
        let end = (model.columns.last?.date ?? start).addingTimeInterval(step)
        Chart {
            ForEach(model.columns, id: \.t) { column in
                ForEach(column.stack, id: \.series) { segment in
                    BarMark(
                        x: .value("Time", column.date, unit: unit),
                        yStart: .value("From", Double(segment.from)),
                        yEnd: .value("To", Double(segment.to))
                    )
                    .foregroundStyle(by: .value("Method", segment.series.name))
                }
            }
        }
        .chartForegroundStyleScale(
            domain: PlaybackSeries.allCases.map(\.name),
            range: PlaybackSeries.allCases.map(\.color)
        )
        .chartLegend(.hidden)
        .chartXScale(domain: start...end)
        .chartYScale(domain: 0...model.top)
        .trendAxes(range: model.range, ticks: model.ticks) { formatChartCount($0) }
        .frame(height: smallPlotHeight)
        .animation(ChartMotion.animation(reduceMotion: reduceMotion), value: model.columns)
        .transaction { if reduceMotion { $0.animation = nil } }
    }
}

/// One series in a chart's legend: its color, its name (and count), and whether its line is dashed.
struct ChartLegendItem: Identifiable {
    let color: Color
    let text: String
    var dashed = false

    var id: String { text }
}

/// Swatch and name of each series, so the colors are never the only way to tell them apart. The
/// entries wrap onto further lines when they do not fit, at any text size.
struct ChartLegend: View {
    let items: [ChartLegendItem]

    var body: some View {
        WrappingRow(spacing: Theme.Space.m, lineSpacing: Theme.Space.xs) {
            ForEach(items) { item in
                HStack(spacing: Theme.Space.xs) {
                    if item.dashed {
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: 4))
                            path.addLine(to: CGPoint(x: 16, y: 4))
                        }
                        .stroke(item.color, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                        .frame(width: 16, height: 8)
                    } else {
                        RoundedRectangle(cornerRadius: Theme.Radius.inner).fill(item.color).frame(width: 8, height: 8)
                    }
                    Text(item.text).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, Theme.Space.xs)
        .accessibilityElement(children: .contain)
    }
}

/// Lays its views out left to right and starts a new line when the next one does not fit. Unlike
/// switching between a row and a column, a view keeps its identity whatever the text size.
struct WrappingRow: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (view, frame) in zip(subviews, arrange(subviews, width: bounds.width)) {
            view.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return frames
    }
}

// MARK: - Sections

/// Concurrent streams, the main chart, with the window control the other two trend charts follow.
struct ConcurrentStreamsSection: View {
    let model: DashboardViewModel

    var body: some View {
        let range = model.ranges.streams
        let state = model.insights.series(for: range)
        SectionPanel(section: .concurrentStreams, title: "Concurrent streams") {
            ChartRangePicker(selected: range) { model.selectRange($0) }
            if let series = state.value {
                SampledBody(kind: .streams, range: range, series: series).equatable()
            } else if state.error == nil {
                EmptyLine(text: String(localized: "Loading…"))
            }
            SectionErrorText(message: state.error)
        }
    }
}

struct PlaybackActivitySection: View {
    let model: DashboardViewModel

    var body: some View {
        let range = model.ranges.playback
        let state = model.insights.activity(for: range)
        SectionPanel(section: .playbackActivity, title: "Playback activity") {
            if let activity = state.value {
                PlaybackBody(activity: activity, range: range).equatable()
            } else if state.error == nil {
                EmptyLine(text: String(localized: "Loading…"))
            }
            SectionErrorText(message: state.error)
        }
    }
}

private struct PlaybackBody: View, Equatable {
    let activity: PlaybackActivity
    let range: ChartRange

    var body: some View {
        let chart = PlaybackChartModel.make(activity: activity, range: range)
        if chart.isEmpty {
            EmptyLine(text: chart.emptyTitle)
            Text(chart.emptyDetail).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(chart.totalText).bloemText(.titleLarge)
                if let completion = chart.completionText {
                    Text(completion).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                TrendChartFrame(
                    kind: .playback, title: String(localized: "Playback activity"),
                    description: chart.description, summaryLine: nil, rows: chart.rows,
                    legend: PlaybackSeries.allCases.map { ChartLegendItem(color: $0.color, text: chart.legend[$0.rawValue].text) }
                ) {
                    PlaybackColumnsChart(model: chart)
                }
            }
        }
    }
}

struct EgressSection: View {
    let model: DashboardViewModel

    var body: some View {
        let range = model.ranges.egress
        let state = model.insights.series(for: range)
        SectionPanel(section: .egress, title: "Egress") {
            if let series = state.value {
                SampledBody(kind: .egress, range: range, series: series).equatable()
            } else if state.error == nil {
                EmptyLine(text: String(localized: "Loading…"))
            }
            SectionErrorText(message: state.error)
        }
    }
}

/// The body both sampled charts share: the window's latest, peak and lowest value over the chart.
private struct SampledBody: View, Equatable {
    let kind: ChartKind
    let range: ChartRange
    let series: Timeseries

    var body: some View {
        let chart = SampledChartModel.make(kind: kind, range: range, series: series)
        if chart.isEmpty {
            EmptyLine(text: chart.emptyText)
            Text("The metrics sampler collects one sample a minute while the server runs.")
                .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if let total = chart.totalText {
                    Text(total).bloemText(.titleLarge)
                }
                TrendChartFrame(
                    kind: kind,
                    title: kind == .egress ? String(localized: "Egress") : String(localized: "Concurrent streams"),
                    description: chart.description, summaryLine: chart.summaryLine, rows: chart.rows,
                    legend: legend(chart)
                ) {
                    if kind == .streams {
                        StackedStreamsChart(model: chart)
                    } else {
                        LineTrendChart(model: chart)
                    }
                }
            }
        }
    }

    private func legend(_ chart: SampledChartModel) -> [ChartLegendItem] {
        if kind == .streams {
            return chart.layers.map { ChartLegendItem(color: $0.method.color, text: $0.method.name) }
        }
        guard chart.downloads != nil else { return [] }
        return [
            ChartLegendItem(color: Theme.text, text: String(localized: "Egress")),
            ChartLegendItem(color: PlaybackMethod.directStream.color, text: String(localized: "Downloads"), dashed: true),
        ]
    }
}
