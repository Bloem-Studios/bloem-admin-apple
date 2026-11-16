import XCTest
@testable import BloemAdmin

/// What the three trend sections say about their data: the summary line, the one VoiceOver label,
/// the plain-number fallback behind "Show values", the empty states and Reduce Motion.
final class DashboardTrendsTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func egressSeries(downloads: Bool = false, bytes: Double? = 1_500_000_000) -> Timeseries {
        let start = date("2026-11-13T10:00:00Z")
        let points = (0..<5).map { i in
            TimeseriesPoint(
                t: start.addingTimeInterval(Double(i) * 60), streams: i,
                egressKbps: [2000, 12_000, 40_000, 8000, 12_400][i], downloadEgressKbps: downloads ? 500 : 0
            )
        }
        return Timeseries(
            resolutionSeconds: 60, from: start, to: start.addingTimeInterval(240), egressBytes: bytes, points: points
        )
    }

    // MARK: Egress

    func testEgressSummaryNamesLatestPeakAndLowest() throws {
        let model = SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(), locale: us, zone: utc)
        XCTAssertEqual(model.summaryLine, "Latest 12 Mbps · Peak 40 Mbps · Lowest 2.0 Mbps")
        XCTAssertFalse(model.isEmpty)
        XCTAssertTrue(model.isRate)
    }

    func testEgressChartIsOneVoiceOverLabelWithWindowAndSummary() {
        let model = SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(), locale: us, zone: utc)
        XCTAssertEqual(
            model.description,
            "Egress over the last 24 hours, in megabits per second. Latest 12 Mbps, peak 40 Mbps, lowest 2.0 Mbps."
        )
    }

    func testEgressShowsTheWindowTotalAndNothingWhenTheServerSendsNone() {
        XCTAssertEqual(SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(), locale: us, zone: utc).totalText, "Total 1.5 GB")
        XCTAssertNil(SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(bytes: nil), locale: us, zone: utc).totalText)
    }

    func testTheDownloadsLineAppearsOnlyWhenTheWindowHasDownloadTraffic() {
        XCTAssertNil(SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(), locale: us, zone: utc).downloads)
        let with = SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(downloads: true), locale: us, zone: utc)
        XCTAssertEqual(with.downloads?.compactMap(\.value), [0.5, 0.5, 0.5, 0.5, 0.5])
        // Concurrent streams never draws it, whatever the series carries.
        XCTAssertNil(SampledChartModel.make(kind: .streams, range: .day, series: egressSeries(downloads: true), locale: us, zone: utc).downloads)
    }

    func testShowValuesFallbackHasEveryNumberTheChartShows() throws {
        let model = SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(), locale: us, zone: utc)
        let byLabel = Dictionary(model.rows.filter { !$0.isHeading }.map { ($0.label, $0.value) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byLabel["Latest"], "12 Mbps")
        XCTAssertEqual(byLabel["Peak"]?.hasPrefix("40 Mbps · at "), true)
        XCTAssertEqual(byLabel["Lowest"], "2.0 Mbps")
        XCTAssertEqual(byLabel["Average"], "15 Mbps")
        XCTAssertEqual(byLabel["Total"], "1.5 GB")
        XCTAssertTrue(model.rows.contains { $0.isHeading && $0.label == "Readings" })
        let readings = model.rows.drop { !$0.isHeading }.dropFirst()
        XCTAssertEqual(readings.count, 5, "five samples are fewer than the six readings, so all of them")
        XCTAssertEqual(readings.last?.value, "12 Mbps")
    }

    func testAGapInTheWindowIsAReadingWithNoSampleNotZero() {
        var series = egressSeries()
        series.points.remove(at: 2)
        let model = SampledChartModel.make(kind: .egress, range: .day, series: series, locale: us, zone: utc)
        XCTAssertTrue(model.rows.contains { $0.value == "No sample" })
        XCTAssertEqual(model.summary?.peak, 12.4)
    }

    func testLongWindowsNameTheDayInTheirReadings() {
        let model = SampledChartModel.make(kind: .egress, range: .week, series: egressSeries(), locale: us, zone: utc)
        XCTAssertTrue(model.rows.contains { $0.label.hasPrefix("Nov 13, ") })
        XCTAssertTrue(model.description.hasPrefix("Egress over the last 7 days"))
    }

    func testAnEmptyEgressWindowSaysSoInsteadOfDrawing() {
        let model = SampledChartModel.make(kind: .egress, range: .day, series: Timeseries(), locale: us, zone: utc)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.emptyText, "No egress samples yet")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertNil(model.summaryLine)
    }

    // MARK: Concurrent streams

    func testConcurrentStreamsPlotsWholeStreamsOnACountAxis() {
        let model = SampledChartModel.make(kind: .streams, range: .hour, series: egressSeries(), locale: us, zone: utc)
        XCTAssertEqual(model.summaryLine, "Latest 4 · Peak 4 · Lowest 0")
        XCTAssertEqual(model.description, "Concurrent streams over the last hour. Latest 4, peak 4, lowest 0.")
        XCTAssertNil(model.totalText)
        XCTAssertFalse(model.isRate)
        XCTAssertTrue(model.ticks.allSatisfy { $0 == $0.rounded(.down) })
        XCTAssertEqual(model.tickLabel(2), "2")
        XCTAssertEqual(SampledChartModel.make(kind: .streams, range: .day, series: Timeseries(), locale: us, zone: utc).emptyText, "No stream samples yet")
    }

    func testTheAxisStartsAtZeroAndCoversTheLargestSample() {
        let model = SampledChartModel.make(kind: .egress, range: .day, series: egressSeries(), locale: us, zone: utc)
        XCTAssertEqual(model.ticks.first, 0)
        XCTAssertGreaterThanOrEqual(model.top, 40)
        XCTAssertEqual(model.tickLabel(40), "40")
        XCTAssertEqual(model.tickLabel(0.5), "0.5")
    }

    // MARK: Playback activity

    private func playback(hours: Int = 3, bucketSeconds: Int = 3600, buckets: [PlaybackBucket]) -> PlaybackActivity {
        PlaybackActivity(
            hours: hours, bucketSeconds: bucketSeconds, to: date("2026-11-13T12:30:00Z"), buckets: buckets,
            reliability: PlaybackReliability(finalizedSessions: 6, completionRate: 0.83), profilesActive24h: 2
        )
    }

    private func bucket(_ iso: String, _ direct: Int, _ remux: Int, _ transcode: Int) -> PlaybackBucket {
        PlaybackBucket(hour: date(iso), direct: direct, remux: remux, transcode: transcode)
    }

    func testPlaybackStacksDirectPlayDirectStreamAndTranscodeInThatOrder() {
        XCTAssertEqual(PlaybackSeries.allCases.map(\.name), ["Direct play", "Direct stream", "Transcode"])
        XCTAssertEqual(PlaybackSeries.allCases.map(\.rawValue), [0, 1, 2])
    }

    func testPlaybackChartCountsEveryMethodAndNamesTheBusiestHour() {
        let model = PlaybackChartModel.make(
            activity: playback(buckets: [bucket("2026-11-13T11:00:00Z", 2, 1, 0), bucket("2026-11-13T12:00:00Z", 0, 0, 4)]),
            range: .day, locale: us, zone: utc
        )
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(model.totalText, "7 sessions")
        XCTAssertEqual(model.completionText, "83% completed")
        XCTAssertEqual(model.legend.map(\.text), ["Direct play 2", "Direct stream 1", "Transcode 4"])
        XCTAssertEqual(model.columns.count, 4, "quiet hours stay in place")
        let description = model.description
        XCTAssertTrue(description.hasPrefix("Playback sessions per hour over the last 24 hours, by play method."), description)
        XCTAssertTrue(description.contains("7 sessions in total."), description)
        XCTAssertTrue(description.contains("Busiest hour starts at"), description)
        XCTAssertTrue(description.hasSuffix("Direct play 2, direct stream 1, transcode 4."), description)
    }

    func testPlaybackFallbackListsTheCountPerMethodTheTotalAndTheBusiestHour() {
        let model = PlaybackChartModel.make(
            activity: playback(buckets: [bucket("2026-11-13T11:00:00Z", 2, 1, 0), bucket("2026-11-13T12:00:00Z", 0, 0, 4)]),
            range: .day, locale: us, zone: utc
        )
        XCTAssertEqual(model.rows.prefix(4).map(\.label), ["Direct play", "Direct stream", "Transcode", "Total"])
        XCTAssertEqual(model.rows.prefix(4).map(\.value), ["2", "1", "4", "7"])
        XCTAssertEqual(model.rows.last?.label, "Busiest hour")
        XCTAssertEqual(model.rows.last?.value.replacingOccurrences(of: "\u{202F}", with: " "), "12:00 PM · 4 sessions")
    }

    func testDailyBucketsReadAsDaysInTheLabelAndTheFallback() {
        let model = PlaybackChartModel.make(
            activity: playback(hours: 168, bucketSeconds: 86_400, buckets: [bucket("2026-11-12T00:00:00Z", 3, 0, 0)]),
            range: .week, locale: us, zone: utc
        )
        XCTAssertTrue(model.isDaily)
        XCTAssertTrue(model.description.hasPrefix("Playback sessions per day over the last 7 days"), model.description)
        XCTAssertEqual(model.rows.last?.label, "Busiest day")
        XCTAssertTrue(model.rows.last?.value.hasPrefix("Nov 12") == true)
    }

    func testAPlaybackWindowWithNoSessionsSaysSoAndHasNoCompletionLine() {
        let model = PlaybackChartModel.make(activity: playback(buckets: []), range: .week, locale: us, zone: utc)
        XCTAssertTrue(model.isEmpty)
        XCTAssertEqual(model.emptyTitle, "No playback in the last 7 days")
        XCTAssertEqual(model.emptyDetail, "Sessions appear here as soon as someone starts watching")
        XCTAssertNil(model.completionText)
        XCTAssertTrue(model.rows.isEmpty)
    }

    func testNoCompletionLineWhenNoSessionFinished() {
        var activity = playback(buckets: [bucket("2026-11-13T12:00:00Z", 1, 0, 0)])
        activity.reliability = PlaybackReliability()
        XCTAssertNil(PlaybackChartModel.make(activity: activity, range: .day, locale: us, zone: utc).completionText)
    }

    // MARK: Reduce Motion

    func testChartsDoNotAnimateUnderReduceMotion() {
        XCTAssertNil(ChartMotion.animation(reduceMotion: true))
        XCTAssertNotNil(ChartMotion.animation(reduceMotion: false))
        XCTAssertGreaterThan(ChartMotion.revealSeconds, 0)
    }
}
