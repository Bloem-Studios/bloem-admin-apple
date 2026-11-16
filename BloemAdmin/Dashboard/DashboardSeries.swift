import Foundation

// The numbers behind the dashboard's trend charts, kept free of SwiftUI so series building,
// scaling and formatting can be unit tested. They follow the web's timeseriesSeries.ts,
// playbackActivitySeries.ts and charts/chartMath.ts, and the Android app's TrendSeries.kt.

/// The windows a chart offers, in the order the picker shows them (the web's WIDGET_RANGE_ORDER).
enum ChartRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, month

    var id: String { rawValue }

    var hours: Int {
        switch self {
        case .hour: 1
        case .day: 24
        case .week: 168
        case .month: 720
        }
    }

    /// The window every sampled chart starts on (the web's SAMPLED_RANGES default).
    static let `default`: ChartRange = .day

    /// The picker's button label: "1h", "24h", "7d", "30d".
    var label: String {
        switch self {
        case .hour: String(localized: "1h")
        case .day: String(localized: "24h")
        case .week: String(localized: "7d")
        case .month: String(localized: "30d")
        }
    }

    /// What the button does, for VoiceOver: "Show the last 7 days".
    var showLabel: String {
        switch self {
        case .hour: String(localized: "Show the last hour")
        case .day: String(localized: "Show the last 24 hours")
        case .week: String(localized: "Show the last 7 days")
        case .month: String(localized: "Show the last 30 days")
        }
    }

    /// The caption under a section title.
    var caption: String {
        switch self {
        case .hour: String(localized: "Last hour")
        case .day: String(localized: "Last 24 hours")
        case .week: String(localized: "Last 7 days")
        case .month: String(localized: "Last 30 days")
        }
    }

    /// The window inside a sentence: "over the last 24 hours".
    var phrase: String {
        switch self {
        case .hour: String(localized: "the last hour")
        case .day: String(localized: "the last 24 hours")
        case .week: String(localized: "the last 7 days")
        case .month: String(localized: "the last 30 days")
        }
    }

    /// The left end of the time axis.
    var startEdge: String {
        switch self {
        case .hour: String(localized: "1h ago")
        case .day: String(localized: "24h ago")
        case .week: String(localized: "7d ago")
        case .month: String(localized: "30d ago")
        }
    }
}

/// The three trend charts.
enum ChartKind: String, CaseIterable, Sendable {
    case playback, egress, streams
}

/// The window the trend charts of one server are showing. The three charts share one window, so a
/// peak can be followed from one to the next; the three values stay separate so each chart reads
/// the window it is drawn with.
struct ChartRanges: Equatable, Sendable {
    var playback: ChartRange = .default
    var egress: ChartRange = .default
    var streams: ChartRange = .default

    subscript(kind: ChartKind) -> ChartRange {
        switch kind {
        case .playback: playback
        case .egress: egress
        case .streams: streams
        }
    }

    /// Every chart on `range`.
    func with(_ range: ChartRange) -> ChartRanges {
        ChartRanges(playback: range, egress: range, streams: range)
    }

    /// The window all three charts show.
    var shared: ChartRange { streams }
}

/// One sample on a line chart. A nil `value` is a minute the sampler missed: the line breaks there.
struct LinePoint: Equatable, Sendable {
    /// Epoch milliseconds.
    let t: Int64
    let value: Double?

    var date: Date { Date(timeIntervalSince1970: Double(t) / 1000) }
    var isSampled: Bool { value?.isFinite == true }
}

/// Which number of a timeseries sample a line plots. Rates are in Mbps, the unit the web charts.
enum TimeseriesField: Sendable {
    case streams, egressMbps, downloadMbps
    /// Concurrent streams by how they were delivered. Direct stream is what is left after direct
    /// play and transcode, so the three always add up to `streams`.
    case directPlay, directStream, transcode

    func select(_ point: TimeseriesPoint) -> Double {
        switch self {
        case .directPlay: Double(point.direct ?? 0)
        case .transcode: Double(point.transcode ?? 0)
        case .directStream: Double(max(point.streams - (point.direct ?? 0) - (point.transcode ?? 0), 0))
        case .streams: Double(point.streams)
        case .egressMbps: point.egressKbps / kbpsPerMbps
        case .downloadMbps: point.downloadEgressKbps / kbpsPerMbps
        }
    }
}

private let kbpsPerMbps = 1_000.0
private let defaultResolutionSeconds: Int64 = 60
private let defaultPlaybackBucketSeconds: Int64 = 3600
private let hourMillis: Int64 = 3_600_000

/// The most columns or points a series is expanded to, so a malformed window cannot allocate
/// without bound.
let maxChartBuckets = 10_000

private func millis(_ date: Date?) -> Int64? {
    guard let date else { return nil }
    let value = date.timeIntervalSince1970 * 1000
    guard value.isFinite, abs(value) < 9e15 else { return nil }
    return Int64(value.rounded())
}

private func floorDiv(_ a: Int64, _ b: Int64) -> Int64 {
    let q = a / b
    return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
}

extension Timeseries {
    /// True once any sample in the window carries measured download traffic; only then is the
    /// second line drawn.
    var hasDownloadTraffic: Bool { points.contains { $0.downloadEgressKbps > 0 } }

    /// True when the server reported how many streams were direct play and transcode.
    var hasPlayMethodSplit: Bool { points.contains { $0.direct != nil || $0.transcode != nil || $0.remux != nil } }

    /// The newest sample's egress, or nil when it is older than `maxAge`: a stale rate must not
    /// pass as the current one. The sampler writes one row a minute, so older than two minutes
    /// means it is behind or stopped.
    func freshEgressKbps(now: Date, maxAge: TimeInterval = 120) -> Double? {
        guard let latest = points.last, let sampledAt = latest.t else { return nil }
        return now.timeIntervalSince(sampledAt) <= maxAge ? latest.egressKbps : nil
    }
}

func buildLinePoints(_ series: Timeseries?, field: TimeseriesField) -> [LinePoint] {
    buildLinePoints(series, select: field.select)
}

/// The dense series for the response window. The endpoint omits minutes the sampler never wrote,
/// so the window is re-expanded here and missing buckets become gaps: "the server was down" and
/// "nobody was watching" are different facts, and only the second is a real zero.
func buildLinePoints(_ series: Timeseries?, select: (TimeseriesPoint) -> Double) -> [LinePoint] {
    guard let series else { return [] }
    let step = (series.resolutionSeconds > 0 ? Int64(series.resolutionSeconds) : defaultResolutionSeconds) * 1000
    let samples: [LinePoint] = series.points.compactMap { point in
        guard let t = millis(point.t) else { return nil }
        let value = select(point)
        return LinePoint(t: t, value: value.isFinite ? value : nil)
    }
    // A missing or malformed window: plot whatever samples arrived rather than nothing.
    guard let from = millis(series.from), let to = millis(series.to), to >= from else { return samples }
    let start = floorDiv(from, step) * step
    let end = floorDiv(to, step) * step
    let count = Int(min((end - start) / step + 1, Int64(maxChartBuckets)))
    var filled = [Double?](repeating: nil, count: count)
    for sample in samples where sample.t >= start {
        let index = (sample.t - start) / step
        if index < Int64(count) { filled[Int(index)] = sample.value }
    }
    return (0..<count).map { LinePoint(t: start + Int64($0) * step, value: filled[$0]) }
}

/// Latest, highest and lowest sampled values of a window; gaps do not count.
struct LineSummary: Equatable, Sendable {
    let latest: Double
    let latestAt: Int64
    let peak: Double
    let peakAt: Int64
    let min: Double
    let average: Double
    let sampled: Int
}

func summarize(_ points: [LinePoint]) -> LineSummary? {
    let sampled = points.filter(\.isSampled)
    guard let latest = sampled.last else { return nil }
    var peak = sampled[0]
    for next in sampled where next.value! >= peak.value! { peak = next }
    let values = sampled.map { $0.value! }
    return LineSummary(
        latest: latest.value!, latestAt: latest.t, peak: peak.value!, peakAt: peak.t,
        min: values.min()!, average: values.reduce(0, +) / Double(values.count), sampled: values.count
    )
}

/// Playback starts of one bucket, split direct play, direct stream (the server's remux), transcode.
struct PlaybackColumn: Equatable, Sendable {
    /// Epoch milliseconds of the bucket start.
    let t: Int64
    let segments: [Int]

    var total: Int64 { segments.reduce(Int64(0)) { $0 + Int64($1) } }
    var date: Date { Date(timeIntervalSince1970: Double(t) / 1000) }
}

/// The columns of the window, oldest first. The endpoint returns only buckets that saw a session,
/// so the quiet ones are filled in: skipping them would compress the window and misplace every
/// other column. Both edges snap to the bucket grid the server truncates on, so the leading
/// bucket is the one that contains `now - hours`, partial or not.
func buildPlaybackColumns(_ buckets: [PlaybackBucket], hours: Int, bucketSeconds: Int, now: Int64) -> [PlaybackColumn] {
    let step = (bucketSeconds > 0 ? Int64(bucketSeconds) : defaultPlaybackBucketSeconds) * 1000
    let to = floorDiv(now, step) * step
    let from = Swift.min(to, floorDiv(now - Int64(Swift.max(0, hours)) * hourMillis, step) * step)
    let count = Int(Swift.min((to - from) / step + 1, Int64(maxChartBuckets)))
    var segments = [[Int]](repeating: [0, 0, 0], count: count)
    for bucket in buckets {
        guard let t = millis(bucket.hour) else { continue }
        let index = (floorDiv(t, step) * step - from) / step
        if index < 0 || index >= Int64(count) { continue }
        segments[Int(index)] = [bucket.direct, bucket.remux, bucket.transcode]
    }
    return (0..<count).map { PlaybackColumn(t: from + Int64($0) * step, segments: segments[$0]) }
}

extension PlaybackActivity {
    /// The columns anchored on the server's window end when the response carries it: a phone
    /// clock a minute off must not drop the newest bucket.
    func columns(clockNow: Date = Date()) -> [PlaybackColumn] {
        buildPlaybackColumns(buckets, hours: hours, bucketSeconds: bucketSeconds, now: millis(to) ?? millis(clockNow) ?? 0)
    }

    /// Buckets wider than a day are read as dates; hourly ones as clock times.
    var isDaily: Bool { bucketSeconds >= 86_400 }
}

// MARK: - Axis scale

private let maxAxisValue = 1e300
private let maxTicks = 1000

private func niceNumber(_ range: Double, roundToNearest: Bool) -> Double {
    let exponent = floor(log10(range))
    let fraction = range / pow(10, exponent)
    let nice: Double
    if roundToNearest {
        nice = fraction < 1.5 ? 1 : fraction < 3 ? 2 : fraction < 7 ? 5 : 10
    } else {
        nice = fraction <= 1 ? 1 : fraction <= 2 ? 2 : fraction <= 5 ? 5 : 10
    }
    return nice * pow(10, exponent)
}

private func roundTo(_ value: Double, decimals: Int) -> Double {
    let scale = pow(10, Double(decimals))
    return (value * scale).rounded(.toNearestOrAwayFromZero) / scale
}

/// Axis ticks rounded to human numbers, ascending, evenly spaced and always covering `[min, max]`.
/// `count` is the wanted tick count, not a guarantee. A `minStep` above zero keeps counts from
/// getting fractional gridlines.
func niceTicks(min lowerBound: Double, max upperBound: Double, count: Int = 3, minStep: Double = 0) -> [Double] {
    var lo = lowerBound.isFinite ? lowerBound : 0
    var hi = upperBound.isFinite ? upperBound : 0
    if lo > hi { swap(&lo, &hi) }
    lo = Swift.min(Swift.max(lo, -maxAxisValue), maxAxisValue)
    hi = Swift.min(Swift.max(hi, -maxAxisValue), maxAxisValue)
    // A flat series still needs a readable axis: grow the top instead of collapsing everything
    // onto one gridline.
    if lo == hi { hi = lo + (lo == 0 ? 1 : abs(lo)) }
    let target = Swift.max(2, count)
    let rawStep = niceNumber(niceNumber(hi - lo, roundToNearest: false) / Double(target - 1), roundToNearest: true)
    let step = (minStep.isFinite && minStep > 0) ? Swift.max(rawStep, minStep) : rawStep
    let decimals = Swift.min(Swift.max(-Int(floor(log10(step))), 0), 10)
    let start = floor(lo / step) * step
    let end = ceil(hi / step) * step
    var ticks: [Double] = []
    for i in 0...maxTicks {
        let value = roundTo(start + Double(i) * step, decimals: decimals)
        ticks.append(value)
        if value >= end { break }
    }
    return ticks
}

/// The value axis of a line chart: ticks from zero up past the largest sample, and the top the
/// plot is scaled to.
func chartAxisTop(_ points: [LinePoint], minStep: Double) -> (ticks: [Double], top: Double) {
    let highest = points.compactMap(\.value).filter(\.isFinite).max() ?? 0
    let ticks = niceTicks(min: 0, max: Swift.max(0, highest), count: 3, minStep: minStep)
    let last = ticks.last ?? 0
    return (ticks, last > 0 ? last : 1)
}

/// The value axis of the stacked columns: whole sessions only.
func columnAxisTop(_ columns: [PlaybackColumn]) -> (ticks: [Double], top: Double) {
    let ticks = niceTicks(min: 0, max: Double(columns.map(\.total).max() ?? 0), count: 3, minStep: 1)
    let last = ticks.last ?? 0
    return (ticks, last > 0 ? last : 1)
}

/// The stretches of consecutive sampled points, each point with its index in `points`. A gap ends
/// a run; an isolated sample is a run of one.
func plottedRuns(_ points: [LinePoint]) -> [[(index: Int, point: LinePoint)]] {
    var runs: [[(index: Int, point: LinePoint)]] = []
    var current: [(index: Int, point: LinePoint)] = []
    for (index, point) in points.enumerated() {
        if point.isSampled {
            current.append((index, point))
        } else if !current.isEmpty {
            runs.append(current)
            current = []
        }
    }
    if !current.isEmpty { runs.append(current) }
    return runs
}

/// Up to `count` points spread evenly over the window, first and last included: the plain-number
/// view of a long series.
func pickReadings(_ points: [LinePoint], count: Int) -> [LinePoint] {
    if points.count <= count || count < 2 {
        return count < 2 ? Array(points.suffix(Swift.max(count, 0))) : points
    }
    var picked: [LinePoint] = []
    for i in 0..<count {
        let point = points[i * (points.count - 1) / (count - 1)]
        if picked.last != point { picked.append(point) }
    }
    return picked
}

// MARK: - Formatting

private func decimalFormatter(locale: Locale, fractionDigits: ClosedRange<Int>) -> NumberFormatter {
    let formatter = NumberFormatter()
    formatter.locale = locale
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = fractionDigits.lowerBound
    formatter.maximumFractionDigits = fractionDigits.upperBound
    return formatter
}

/// An egress rate without its unit; small rates keep one decimal so a trickle does not round to a
/// flat "0".
func formatMbpsValue(_ mbps: Double, locale: Locale = .current) -> String {
    guard mbps.isFinite else { return "—" }
    let decimals = (mbps > 0 && mbps < 10) ? 1 : 0
    return decimalFormatter(locale: locale, fractionDigits: decimals...decimals).string(from: NSNumber(value: mbps)) ?? "—"
}

/// Egress rate with its unit; small rates keep one decimal so a trickle does not read as idle.
func formatMbps(_ mbps: Double, locale: Locale = .current) -> String {
    mbps.isFinite ? String(localized: "\(formatMbpsValue(mbps, locale: locale)) Mbps") : "—"
}

/// A whole count, grouped for the locale.
func formatChartCount(_ value: Double, locale: Locale = .current) -> String {
    decimalFormatter(locale: locale, fractionDigits: 0...0).string(from: NSNumber(value: value.rounded())) ?? "—"
}

private let dataTotalUnits = ["B", "KB", "MB", "GB", "TB", "PB"]

/// Data transferred over a window, in decimal units to match the Mbps beside it, with one decimal
/// below 100. The unit and precision are chosen on the value as displayed, so it never reads
/// "1,000 KB" (it reads "1.0 MB").
func formatDataTotal(_ bytes: Double, locale: Locale = .current) -> String {
    guard bytes.isFinite, bytes >= 0 else { return "—" }
    var value = bytes
    var unit = 0
    while true {
        let decimals = (unit > 0 && value < 100) ? 1 : 0
        let rounded = roundTo(value, decimals: decimals)
        if rounded >= 1000 && unit < dataTotalUnits.count - 1 {
            value /= 1000
            unit += 1
            continue
        }
        let shown = (unit > 0 && rounded < 100) ? 1 : 0
        let text = decimalFormatter(locale: locale, fractionDigits: shown...shown).string(from: NSNumber(value: rounded)) ?? "—"
        return "\(text) \(dataTotalUnits[unit])"
    }
}

private func timeText(_ date: Date, zone: TimeZone, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = zone
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func dayText(_ date: Date, zone: TimeZone, locale: Locale) -> String {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = zone
    formatter.setLocalizedDateFormatFromTemplate("MMM d")
    return formatter.string(from: date)
}

/// A moment on a chart. Hours and days read as clock times; from a week up the day is what tells
/// moments apart, so it is shown, with the time too where there is room (`withTime`).
func formatChartTimestamp(range: ChartRange, epochMillis: Int64, zone: TimeZone = .current, locale: Locale = .current, withTime: Bool) -> String {
    let moment = Date(timeIntervalSince1970: Double(epochMillis) / 1000)
    let time = timeText(moment, zone: zone, locale: locale)
    if range == .hour || range == .day { return time }
    let day = dayText(moment, zone: zone, locale: locale)
    return withTime ? "\(day), \(time)" : day
}

/// A column of a playback chart: a clock time for hourly buckets, a date for daily ones.
func formatColumnTimestamp(daily: Bool, epochMillis: Int64, zone: TimeZone = .current, locale: Locale = .current) -> String {
    let moment = Date(timeIntervalSince1970: Double(epochMillis) / 1000)
    return daily ? dayText(moment, zone: zone, locale: locale) : timeText(moment, zone: zone, locale: locale)
}
