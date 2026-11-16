import Foundation
import SwiftUI

// What the three trend sections say about their data: the summary line, the one VoiceOver label,
// the plain-number fallback ("Show values") and the axis. All of it is derived here from the
// fetched series so it can be unit tested; the views only draw it.

/// One label and value of the plain-number view.
struct ChartValueRow: Equatable, Identifiable, Sendable {
    let label: String
    let value: String
    /// A sub-heading above the rows that follow ("Readings") has no value.
    var isHeading = false

    var id: String { "\(isHeading ? "h" : "r")-\(label)-\(value)" }
}

/// The play methods the playback chart stacks, from the baseline up.
enum PlaybackSeries: Int, CaseIterable, Sendable {
    case directPlay, directStream, transcode

    var name: String {
        switch self {
        case .directPlay: String(localized: "Direct play")
        case .directStream: String(localized: "Direct stream")
        case .transcode: String(localized: "Transcode")
        }
    }

    /// The one play-method palette; the legend names each color, so color is never the only cue.
    var color: Color { method.color }

    var method: PlaybackMethod {
        switch self {
        case .directPlay: .directPlay
        case .directStream: .directStream
        case .transcode: .transcode
        }
    }
}

extension PlaybackColumn {
    /// The column's segments as stacked intervals, direct play at the baseline, empty ones left out.
    var stack: [(series: PlaybackSeries, from: Int, to: Int)] {
        var base = 0
        var result: [(series: PlaybackSeries, from: Int, to: Int)] = []
        for series in PlaybackSeries.allCases {
            let count = segments[series.rawValue]
            guard count > 0 else { continue }
            result.append((series, base, base + count))
            base += count
        }
        return result
    }
}

struct LegendItem: Equatable, Identifiable, Sendable {
    let name: String
    let text: String
    var id: String { name }
}

/// How long a chart takes to draw itself in: no time at all under Reduce Motion, so nothing
/// animates.
enum ChartMotion {
    static let revealSeconds = 0.25

    static func animation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : Theme.Motion.enter
    }
}

// MARK: - Playback activity

/// The Playback activity chart: sessions started per bucket, stacked by play method.
struct PlaybackChartModel: Equatable {
    let range: ChartRange
    let columns: [PlaybackColumn]
    let isDaily: Bool
    let ticks: [Double]
    let top: Double
    /// "12 sessions", the headline above the chart.
    let totalText: String
    /// "83% completed", when the server finalized any session in the window.
    let completionText: String?
    /// The one VoiceOver label for the chart.
    let description: String
    let legend: [LegendItem]
    let rows: [ChartValueRow]
    /// True when the window saw no session at all; the section says so instead of drawing columns.
    let isEmpty: Bool
    let emptyTitle: String
    let emptyDetail: String

    static func make(
        activity: PlaybackActivity,
        range: ChartRange,
        locale: Locale = .current,
        zone: TimeZone = .current,
        clockNow: Date = Date()
    ) -> PlaybackChartModel {
        let columns = activity.columns(clockNow: clockNow)
        let (ticks, top) = columnAxisTop(columns)
        let daily = activity.isDaily
        let empty = columns.reduce(Int64(0)) { $0 + $1.total } == 0
        let perSeries = PlaybackSeries.allCases.map { series in columns.reduce(Int64(0)) { $0 + Int64($1.segments[series.rawValue]) } }
        let total = perSeries.reduce(0, +)
        let completion: String? = activity.reliability.finalizedSessions > 0
            ? String(localized: "\(Int((activity.reliability.completionRate * 100).rounded()))% completed")
            : nil

        func sessions(_ count: Int64) -> String { String(localized: "\(Int(min(count, Int64(Int32.max)))) sessions") }
        func count(_ value: Int64) -> String { formatChartCount(Double(value), locale: locale) }

        guard !empty, let busiest = columns.reduce(nil as PlaybackColumn?, { best, next in
            guard let best else { return next }
            return next.total >= best.total ? next : best
        }) else {
            return PlaybackChartModel(
                range: range, columns: columns, isDaily: daily, ticks: ticks, top: top,
                totalText: sessions(0), completionText: nil, description: "", legend: [], rows: [], isEmpty: true,
                emptyTitle: String(localized: "No playback in \(range.phrase)"),
                emptyDetail: String(localized: "Sessions appear here as soon as someone starts watching")
            )
        }

        let busiestAt = formatColumnTimestamp(daily: daily, epochMillis: busiest.t, zone: zone, locale: locale)
        let busiestSessions = sessions(busiest.total)
        let busiestText = daily
            ? String(localized: "Busiest day is \(busiestAt) with \(busiestSessions)")
            : String(localized: "Busiest hour starts at \(busiestAt) with \(busiestSessions)")
        let methods = String(
            localized: "Direct play \(count(perSeries[0])), direct stream \(count(perSeries[1])), transcode \(count(perSeries[2]))"
        )
        let window = range.phrase
        let label = daily
            ? String(localized: "Playback sessions per day over \(window), by play method")
            : String(localized: "Playback sessions per hour over \(window), by play method")
        let description = String(localized: "\(label). \(sessions(total)) in total. \(busiestText). \(methods).")

        let legend = PlaybackSeries.allCases.map {
            LegendItem(name: $0.name, text: "\($0.name) \(count(perSeries[$0.rawValue]))")
        }
        var rows = PlaybackSeries.allCases.map { ChartValueRow(label: $0.name, value: count(perSeries[$0.rawValue])) }
        rows.append(ChartValueRow(label: String(localized: "Total"), value: count(total)))
        rows.append(ChartValueRow(
            label: daily ? String(localized: "Busiest day") : String(localized: "Busiest hour"),
            value: "\(busiestAt) · \(busiestSessions)"
        ))
        return PlaybackChartModel(
            range: range, columns: columns, isDaily: daily, ticks: ticks, top: top,
            totalText: sessions(total), completionText: completion, description: description,
            legend: legend, rows: rows, isEmpty: false, emptyTitle: "", emptyDetail: ""
        )
    }
}

// MARK: - Egress and concurrent streams

/// A sampled line chart: Egress (Mbps, with a Downloads line when the window has download
/// traffic) or Concurrent streams.
struct SampledChartModel: Equatable {
    let kind: ChartKind
    let range: ChartRange
    let points: [LinePoint]
    /// The Downloads line; nil unless the window carries measured download traffic.
    let downloads: [LinePoint]?
    let summary: LineSummary?
    /// "Latest 12 Mbps · Peak 40 Mbps · Lowest 2.0 Mbps", shown above the chart.
    let summaryLine: String?
    /// The one VoiceOver label for the chart.
    let description: String
    /// "Total 1.5 GB", the data the whole window moved (egress only).
    let totalText: String?
    let rows: [ChartValueRow]
    let ticks: [Double]
    let top: Double
    let isRate: Bool
    let emptyText: String
    let locale: Locale
    /// Concurrent streams only: the stack of play methods, direct play at the baseline. Empty when
    /// the server did not say how its streams were delivered; the chart then draws the total.
    var layers: [MethodLayer] = []

    /// Readings in the plain-number view.
    static let readingCount = 6

    var isEmpty: Bool { summary == nil }

    /// An axis label: Mbps without a unit, or a whole count.
    func tickLabel(_ value: Double) -> String {
        isRate ? formatMbpsValue(value, locale: locale) : formatChartCount(value, locale: locale)
    }

    static func make(
        kind: ChartKind,
        range: ChartRange,
        series: Timeseries,
        locale: Locale = .current,
        zone: TimeZone = .current
    ) -> SampledChartModel {
        precondition(kind != .playback, "Playback activity has its own model")
        let isRate = kind == .egress
        let points = buildLinePoints(series, field: isRate ? .egressMbps : .streams)
        let downloads = isRate && series.hasDownloadTraffic ? buildLinePoints(series, field: .downloadMbps) : nil
        let summary = summarize(points)
        let (ticks, top) = chartAxisTop(points + (downloads ?? []), minStep: isRate ? 0 : 1)
        let emptyText = isRate ? String(localized: "No egress samples yet") : String(localized: "No stream samples yet")

        func value(_ v: Double) -> String { isRate ? formatMbps(v, locale: locale) : formatChartCount(v, locale: locale) }

        guard let summary else {
            return SampledChartModel(
                kind: kind, range: range, points: points, downloads: downloads, summary: nil, summaryLine: nil,
                description: "", totalText: nil, rows: [], ticks: ticks, top: top, isRate: isRate,
                emptyText: emptyText, locale: locale
            )
        }
        let latest = value(summary.latest)
        let peak = value(summary.peak)
        let lowest = value(summary.min)
        let phrase = range.phrase
        let label = isRate
            ? String(localized: "Egress over \(phrase), in megabits per second")
            : String(localized: "Concurrent streams over \(phrase)")
        let description = String(localized: "\(label). Latest \(latest), peak \(peak), lowest \(lowest).")
        let total = isRate ? series.egressBytes.map { formatDataTotal($0, locale: locale) } : nil

        var rows = [
            ChartValueRow(label: String(localized: "Latest"), value: latest),
            ChartValueRow(
                label: String(localized: "Peak"),
                value: "\(peak) · " + String(localized: "at \(formatChartTimestamp(range: range, epochMillis: summary.peakAt, zone: zone, locale: locale, withTime: true))")
            ),
            ChartValueRow(label: String(localized: "Lowest"), value: lowest),
            ChartValueRow(label: String(localized: "Average"), value: value(summary.average)),
        ]
        if let total { rows.append(ChartValueRow(label: String(localized: "Total"), value: total)) }
        rows.append(ChartValueRow(label: String(localized: "Readings"), value: "", isHeading: true))
        for reading in pickReadings(points, count: readingCount) {
            rows.append(ChartValueRow(
                label: formatChartTimestamp(range: range, epochMillis: reading.t, zone: zone, locale: locale, withTime: true),
                value: reading.value.map(value) ?? String(localized: "No sample")
            ))
        }
        var model = SampledChartModel(
            kind: kind, range: range, points: points, downloads: downloads, summary: summary,
            summaryLine: String(localized: "Latest \(latest) · Peak \(peak) · Lowest \(lowest)"),
            description: description, totalText: total.map { String(localized: "Total \($0)") },
            rows: rows, ticks: ticks, top: top, isRate: isRate, emptyText: emptyText, locale: locale
        )
        if kind == .streams { model.layers = MethodLayer.stack(series) }
        return model
    }
}

/// One play method's band in the concurrent streams chart: `upper` is the running total up to and
/// including this method, `lower` the running total below it (same length, same times).
struct MethodLayer: Equatable, Sendable {
    let method: PlaybackMethod
    let lower: [Double?]
    let upper: [LinePoint]

    /// The stack of a window, direct play first, or nothing when the series has no split.
    static func stack(_ series: Timeseries) -> [MethodLayer] {
        guard series.hasPlayMethodSplit else { return [] }
        let bands = [PlaybackMethod.directPlay, .directStream, .transcode].map { method -> (PlaybackMethod, [LinePoint]) in
            let field: TimeseriesField = switch method {
            case .directPlay: .directPlay
            case .directStream: .directStream
            case .transcode: .transcode
            }
            return (method, buildLinePoints(series, field: field))
        }
        var layers: [MethodLayer] = []
        var running = [Double?](repeating: 0, count: bands.first?.1.count ?? 0)
        for (method, points) in bands {
            let lower = running
            var upper: [LinePoint] = []
            for (index, point) in points.enumerated() {
                let below = running[index]
                let value: Double? = (below != nil && point.value != nil) ? below! + point.value! : nil
                running[index] = value
                upper.append(LinePoint(t: point.t, value: value))
            }
            layers.append(MethodLayer(method: method, lower: lower, upper: upper))
        }
        return layers
    }
}

extension LinePoint {
    /// Rendering needs a value to plot; callers skip gaps through `plottedRuns`.
    var plotted: Double { value ?? 0 }
}
