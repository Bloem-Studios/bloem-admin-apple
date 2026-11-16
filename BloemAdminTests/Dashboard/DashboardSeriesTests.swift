import XCTest
@testable import BloemAdmin

/// Series building, scaling, ranges and formatting behind the trend charts; the cases follow the
/// Android app's TrendSeriesTest.
final class DashboardSeriesTests: XCTestCase {
    private let us = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func at(_ iso: String) -> Int64 {
        Int64(date(iso).timeIntervalSince1970 * 1000)
    }

    private func point(_ iso: String?, streams: Int = 0, kbps: Double = 0, download: Double = 0) -> TimeseriesPoint {
        TimeseriesPoint(t: iso.flatMap { ISO8601DateFormatter().date(from: $0) }, streams: streams, egressKbps: kbps, downloadEgressKbps: download)
    }

    private func series(
        resolution: Int = 60, from: String? = nil, to: String? = nil, points: [TimeseriesPoint] = []
    ) -> Timeseries {
        Timeseries(
            resolutionSeconds: resolution, from: from.flatMap { ISO8601DateFormatter().date(from: $0) },
            to: to.flatMap { ISO8601DateFormatter().date(from: $0) }, points: points
        )
    }

    private func streamsOf(_ series: Timeseries?) -> [LinePoint] {
        buildLinePoints(series) { Double($0.streams) }
    }

    // MARK: Ranges

    func testRangesAreTheWebsFourWindowsInItsHours() {
        XCTAssertEqual(ChartRange.allCases.map(\.hours), [1, 24, 168, 720])
        XCTAssertEqual(ChartRange.allCases.map(\.rawValue), ["hour", "day", "week", "month"])
        XCTAssertEqual(ChartRange.default, .day)
        XCTAssertEqual(ChartRange.allCases.map(\.label), ["1h", "24h", "7d", "30d"])
    }

    func testEveryChartStartsOnTheDayAndChoosingChangesAllThreeTogether() {
        var ranges = ChartRanges()
        XCTAssertEqual([ranges.playback, ranges.egress, ranges.streams], [.day, .day, .day])
        ranges = ranges.with(.week)
        XCTAssertEqual([ranges[.playback], ranges[.egress], ranges[.streams]], [.week, .week, .week])
        XCTAssertEqual(ranges.shared, .week)
        XCTAssertEqual(ranges.with(.month).playback, .month)
        XCTAssertEqual(ranges.with(.hour).streams, .hour)
    }

    func testRangeWordingIsSeparateFromTheButtonLabel() {
        XCTAssertEqual(ChartRange.week.showLabel, "Show the last 7 days")
        XCTAssertEqual(ChartRange.day.caption, "Last 24 hours")
        XCTAssertEqual(ChartRange.month.phrase, "the last 30 days")
        XCTAssertEqual(ChartRange.hour.startEdge, "1h ago")
    }

    // MARK: Timeseries to line points

    func testMissingMinutesBecomeGapsAndSampledZerosStayZeros() {
        let result = streamsOf(series(from: "2026-11-13T10:00:00Z", to: "2026-11-13T10:04:00Z", points: [
            point("2026-11-13T10:00:00Z", streams: 2), point("2026-11-13T10:03:00Z", streams: 0, kbps: 4000),
        ]))
        XCTAssertEqual(result.map(\.value), [2, nil, nil, 0, nil])
        XCTAssertEqual(result.first?.t, at("2026-11-13T10:00:00Z"))
        XCTAssertEqual(result.last?.t, at("2026-11-13T10:04:00Z"))
    }

    func testNoResponseIsNoPoints() {
        XCTAssertTrue(streamsOf(nil).isEmpty)
    }

    func testAMalformedWindowPlotsTheSamplesThatArrived() {
        let result = streamsOf(series(points: [
            point("2026-11-13T10:00:00Z", streams: 1), point(nil, streams: 9), point("2026-11-13T10:01:00Z", streams: 3),
        ]))
        XCTAssertEqual(result.map(\.value), [1, 3])
    }

    func testAReversedWindowPlotsTheSamplesThatArrived() {
        let result = streamsOf(series(from: "2026-11-13T11:00:00Z", to: "2026-11-13T10:00:00Z", points: [point("2026-11-13T10:30:00Z", streams: 4)]))
        XCTAssertEqual(result.map(\.value), [4])
    }

    func testANonFiniteValueIsAGapNotANumber() {
        let result = buildLinePoints(series(from: "2026-11-13T10:00:00Z", to: "2026-11-13T10:01:00Z", points: [
            point("2026-11-13T10:00:00Z", kbps: .nan), point("2026-11-13T10:01:00Z", kbps: .infinity),
        ])) { $0.egressKbps }
        XCTAssertEqual(result.map(\.value), [nil, nil])
    }

    func testTheGridFollowsTheServersBucketWidthNotAMinute() {
        let result = streamsOf(series(resolution: 1800, from: "2026-11-06T10:00:00Z", to: "2026-11-13T10:00:00Z", points: [
            point("2026-11-13T10:00:00Z", streams: 5),
        ]))
        XCTAssertEqual(result.count, 7 * 48 + 1)
        XCTAssertEqual(result.last?.value, 5)
        XCTAssertEqual(result[1].t - result[0].t, 1_800_000)
    }

    func testAZeroOrNegativeResolutionFallsBackToAMinute() {
        let result = streamsOf(series(resolution: 0, from: "2026-11-13T10:00:00Z", to: "2026-11-13T10:02:00Z", points: [
            point("2026-11-13T10:01:00Z", streams: 7),
        ]))
        XCTAssertEqual(result.map(\.value), [nil, 7, nil])
    }

    func testASampleOutsideTheWindowIsDropped() {
        let result = streamsOf(series(from: "2026-11-13T10:00:00Z", to: "2026-11-13T10:01:00Z", points: [
            point("2026-11-13T09:00:00Z", streams: 8), point("2026-11-13T12:00:00Z", streams: 8),
        ]))
        XCTAssertEqual(result.map(\.value), [nil, nil])
    }

    func testAHugeWindowIsCappedInsteadOfAllocatingWithoutBound() {
        let result = streamsOf(series(resolution: 1, from: "2000-01-01T00:00:00Z", to: "2026-01-01T00:00:00Z"))
        XCTAssertLessThanOrEqual(result.count, maxChartBuckets)
    }

    func testEgressIsPlottedInMbpsAndDownloadsAreAnOptionalSecondSeries() {
        let one = series(from: "2026-11-13T10:00:00Z", to: "2026-11-13T10:00:00Z", points: [
            point("2026-11-13T10:00:00Z", streams: 1, kbps: 12_500, download: 2_000),
        ])
        XCTAssertEqual(buildLinePoints(one, field: .egressMbps).first?.value, 12.5)
        XCTAssertEqual(buildLinePoints(one, field: .downloadMbps).first?.value, 2)
        XCTAssertTrue(one.hasDownloadTraffic)
        XCTAssertFalse(series(points: [point("2026-11-13T10:00:00Z", kbps: 1)]).hasDownloadTraffic)
    }

    // MARK: Egress freshness

    func testEgressIsCurrentOnlyWhileTheSampleIsFresh() {
        let s = series(points: [point("2026-11-13T10:00:00Z", kbps: 1000), point("2026-11-13T10:05:00Z", kbps: 12_500)])
        XCTAssertEqual(s.freshEgressKbps(now: date("2026-11-13T10:06:00Z")), 12_500)
        XCTAssertEqual(s.freshEgressKbps(now: date("2026-11-13T10:07:00Z")), 12_500, "exactly two minutes is still current")
        XCTAssertNil(s.freshEgressKbps(now: date("2026-11-13T10:07:01Z")))
        XCTAssertNil(series().freshEgressKbps(now: date("2026-11-13T10:06:00Z")))
        XCTAssertNil(series(points: [point(nil, kbps: 5)]).freshEgressKbps(now: date("2026-11-13T10:06:00Z")))
    }

    // MARK: Summary

    func testSummaryReportsLatestPeakAndMinimumOverTheSampledPointsOnly() throws {
        let points = [LinePoint(t: 0, value: 3), LinePoint(t: 1, value: nil), LinePoint(t: 2, value: 9), LinePoint(t: 3, value: 0.5), LinePoint(t: 4, value: nil)]
        let summary = try XCTUnwrap(summarize(points))
        XCTAssertEqual(summary.latest, 0.5)
        XCTAssertEqual(summary.latestAt, 3)
        XCTAssertEqual(summary.peak, 9)
        XCTAssertEqual(summary.peakAt, 2)
        XCTAssertEqual(summary.min, 0.5)
        XCTAssertEqual(summary.sampled, 3)
        XCTAssertEqual(summary.average, 12.5 / 3, accuracy: 1e-9)
    }

    func testSummaryOfNothingSampledIsNil() {
        XCTAssertNil(summarize([]))
        XCTAssertNil(summarize([LinePoint(t: 0, value: nil), LinePoint(t: 1, value: nil)]))
    }

    func testSummaryOfASinglePointIsThatPointThreeWays() throws {
        let summary = try XCTUnwrap(summarize([LinePoint(t: 0, value: 4)]))
        XCTAssertEqual([summary.latest, summary.peak, summary.min], [4, 4, 4])
    }

    func testTheLaterOfTwoEqualPeaksWins() throws {
        let summary = try XCTUnwrap(summarize([LinePoint(t: 1, value: 5), LinePoint(t: 2, value: 5)]))
        XCTAssertEqual(summary.peakAt, 2)
    }

    // MARK: Playback activity columns

    private func bucket(_ iso: String, _ direct: Int, _ remux: Int, _ transcode: Int) -> PlaybackBucket {
        PlaybackBucket(hour: date(iso), direct: direct, remux: remux, transcode: transcode)
    }

    func testQuietHoursAreZeroFilledSoColumnsKeepTheirPlace() {
        let columns = buildPlaybackColumns(
            [bucket("2026-11-13T11:00:00Z", 2, 1, 0), bucket("2026-11-13T12:00:00Z", 0, 0, 4)],
            hours: 3, bucketSeconds: 3600, now: at("2026-11-13T12:30:00Z")
        )
        // 09:30 snaps to 09:00; the window covers 09:00 to 12:00 inclusive.
        let hours = columns.map { Calendar(identifier: .gregorian).dateComponents(in: utc, from: $0.date).hour }
        XCTAssertEqual(hours, [9, 10, 11, 12])
        XCTAssertEqual(columns.map(\.segments), [[0, 0, 0], [0, 0, 0], [2, 1, 0], [0, 0, 4]])
    }

    func testAnHourlyOneHourWindowCoversTheTwoBucketsTheServerCanReturn() {
        XCTAssertEqual(buildPlaybackColumns([], hours: 1, bucketSeconds: 3600, now: at("2026-11-13T12:30:00Z")).count, 2)
    }

    func testDailyBucketsZeroFillOnTheDayGrid() {
        let columns = buildPlaybackColumns([bucket("2026-11-10T00:00:00Z", 1, 0, 0)], hours: 24 * 7, bucketSeconds: 86_400, now: at("2026-11-13T12:00:00Z"))
        XCTAssertEqual(columns.count, 8)
        XCTAssertEqual(columns.filter { $0.total > 0 }.map(\.total), [1])
        XCTAssertTrue(columns.allSatisfy { $0.t % 86_400_000 == 0 })
    }

    func testABucketOffTheGridSnapsIntoTheColumnThatContainsIt() {
        let columns = buildPlaybackColumns([bucket("2026-11-13T12:20:00Z", 5, 0, 0)], hours: 2, bucketSeconds: 3600, now: at("2026-11-13T12:30:00Z"))
        XCTAssertEqual(columns.last?.total, 5)
    }

    func testAMalformedOrOutOfWindowBucketIsIgnored() {
        let columns = buildPlaybackColumns(
            [PlaybackBucket(hour: nil, direct: 1, remux: 1, transcode: 1), bucket("2020-01-01T00:00:00Z", 9, 9, 9)],
            hours: 2, bucketSeconds: 3600, now: at("2026-11-13T12:30:00Z")
        )
        XCTAssertTrue(columns.allSatisfy { $0.total == 0 })
    }

    func testAZeroBucketWidthFallsBackToHourly() {
        let columns = buildPlaybackColumns([], hours: 2, bucketSeconds: 0, now: at("2026-11-13T12:30:00Z"))
        XCTAssertEqual(columns.count, 3)
        XCTAssertEqual(columns[1].t - columns[0].t, 3_600_000)
    }

    func testTheServersWindowEndAnchorsTheGrid() {
        let activity = PlaybackActivity(
            hours: 2, bucketSeconds: 3600, to: date("2026-11-13T12:59:59Z"),
            buckets: [bucket("2026-11-13T12:00:00Z", 1, 0, 0)], profilesActive24h: 0
        )
        // A phone clock a day behind must not misplace the newest column.
        let columns = activity.columns(clockNow: date("2026-11-12T12:00:00Z"))
        XCTAssertEqual(columns.last?.total, 1)
        XCTAssertEqual(columns.last?.t, at("2026-11-13T12:00:00Z"))
    }

    func testColumnTotalsSumALargeColumnWithoutOverflow() {
        let column = PlaybackColumn(t: 0, segments: [Int(Int32.max), Int(Int32.max), 1])
        XCTAssertEqual(column.total, Int64(Int32.max) * 2 + 1)
    }

    func testBucketsWiderThanADayReadAsDates() {
        XCTAssertTrue(PlaybackActivity(bucketSeconds: 86_400, profilesActive24h: 0).isDaily)
        XCTAssertFalse(PlaybackActivity(bucketSeconds: 3600, profilesActive24h: 0).isDaily)
    }

    // MARK: Axis scale

    func testTicksAreRoundNumbersCoveringTheDataFromZero() {
        XCTAssertEqual(niceTicks(min: 0, max: 9), [0, 5, 10])
        XCTAssertEqual(niceTicks(min: 0, max: 87), [0, 50, 100])
    }

    func testAFlatZeroSeriesStillGetsAReadableAxis() throws {
        let ticks = niceTicks(min: 0, max: 0)
        XCTAssertEqual(ticks.first, 0)
        XCTAssertGreaterThan(try XCTUnwrap(ticks.last), 0)
    }

    func testCountsNeverGetFractionalGridlinesWhenTheStepIsPinnedToOne() {
        XCTAssertEqual(niceTicks(min: 0, max: 1, count: 3, minStep: 1), [0, 1])
        XCTAssertTrue(niceTicks(min: 0, max: 2, count: 4, minStep: 1).allSatisfy { $0 == $0.rounded(.down) })
    }

    func testTicksAreAscendingAndCoverTheMaximumAcrossMagnitudes() {
        for max in [0.001, 0.37, 1, 7, 12.5, 999, 1000, 123_456, 9.9e9, 4.2e15] {
            let ticks = niceTicks(min: 0, max: max)
            XCTAssertGreaterThanOrEqual(ticks.count, 2, "ticks for \(max): \(ticks)")
            XCTAssertTrue(zip(ticks, ticks.dropFirst()).allSatisfy { $0 < $1 }, "ticks for \(max): \(ticks)")
            XCTAssertGreaterThanOrEqual(ticks.last ?? 0, max, "ticks for \(max): \(ticks)")
            XCTAssertLessThanOrEqual(ticks.count, 12)
        }
    }

    func testNonFiniteOrInvertedBoundsDegradeToAValidAxis() {
        XCTAssertGreaterThanOrEqual(niceTicks(min: .nan, max: .infinity).count, 2)
        let inverted = niceTicks(min: 10, max: 0)
        XCTAssertLessThanOrEqual(inverted.first ?? 1, 0)
        XCTAssertGreaterThanOrEqual(inverted.last ?? 0, 10)
    }

    func testNegativeValuesAreNotScaledBelowTheAxisFloor() {
        XCTAssertEqual(chartAxisTop([LinePoint(t: 0, value: -5), LinePoint(t: 1, value: nil)], minStep: 1).ticks.first, 0)
    }

    func testAxisTopCoversTheLargestValueAndIgnoresGaps() {
        let top = chartAxisTop([LinePoint(t: 0, value: 3), LinePoint(t: 1, value: nil), LinePoint(t: 2, value: 8.4)], minStep: 0).top
        XCTAssertGreaterThanOrEqual(top, 8.4)
        XCTAssertLessThanOrEqual(top, 20)
    }

    func testAHugeValueStillYieldsAFiniteAxis() {
        let axis = chartAxisTop([LinePoint(t: 0, value: 1.7e308)], minStep: 0)
        XCTAssertTrue(axis.top.isFinite)
        XCTAssertTrue(axis.ticks.allSatisfy(\.isFinite))
    }

    func testColumnAxisCountsWholeSessions() {
        let columns = [PlaybackColumn(t: 0, segments: [1, 1, 1]), PlaybackColumn(t: 1, segments: [0, 0, 0]), PlaybackColumn(t: 2, segments: [4, 0, 2])]
        let axis = columnAxisTop(columns)
        XCTAssertGreaterThanOrEqual(axis.top, 6)
        XCTAssertTrue(axis.ticks.allSatisfy { $0 == $0.rounded(.down) })
    }

    // MARK: Paths and readings

    func testAGapBreaksTheLineIntoSeparateRunsAndALoneSampleIsItsOwnRun() {
        let runs = plottedRuns([
            LinePoint(t: 0, value: 1), LinePoint(t: 1, value: 2), LinePoint(t: 2, value: nil), LinePoint(t: 3, value: 5), LinePoint(t: 4, value: nil),
        ])
        XCTAssertEqual(runs.map(\.count), [2, 1])
        XCTAssertEqual(runs[1].first?.index, 3)
    }

    func testReadingsAreSpreadEvenlyAndKeepBothEnds() {
        let points = (0..<100).map { LinePoint(t: Int64($0), value: Double($0)) }
        let picked = pickReadings(points, count: 6)
        XCTAssertEqual(picked.count, 6)
        XCTAssertEqual(picked.first?.t, 0)
        XCTAssertEqual(picked.last?.t, 99)
        XCTAssertEqual(pickReadings(points, count: 200), points)
        XCTAssertEqual(pickReadings(points, count: 1), [points.last!])
        XCTAssertTrue(pickReadings(points, count: 0).isEmpty)
        XCTAssertTrue(pickReadings([], count: 6).isEmpty)
    }

    // MARK: Formatting

    func testMbpsAxisLabelsKeepOneDecimalForATrickle() {
        XCTAssertEqual(formatMbpsValue(0.5, locale: us), "0.5")
        XCTAssertEqual(formatMbpsValue(12.4, locale: us), "12")
        XCTAssertEqual(formatMbpsValue(0, locale: us), "0")
        XCTAssertEqual(formatMbpsValue(.nan, locale: us), "—")
        XCTAssertEqual(formatMbpsValue(1200, locale: us), "1,200")
    }

    func testDataTotalsUseDecimalUnitsAndNeverRead1000KB() {
        XCTAssertEqual(formatDataTotal(0, locale: us), "0 B")
        XCTAssertEqual(formatDataTotal(999, locale: us), "999 B")
        XCTAssertEqual(formatDataTotal(1000, locale: us), "1.0 KB")
        XCTAssertEqual(formatDataTotal(999_999, locale: us), "1.0 MB")
        XCTAssertEqual(formatDataTotal(99_999_000_000, locale: us), "100 GB")
        XCTAssertEqual(formatDataTotal(12.34e12, locale: us), "12.3 TB")
        XCTAssertEqual(formatDataTotal(-1, locale: us), "—")
        XCTAssertEqual(formatDataTotal(.nan, locale: us), "—")
        XCTAssertFalse(formatDataTotal(1e30, locale: us).isEmpty)
    }

    func testChartTimestampsReadAsClockTimesForShortWindowsAndDatesForLongOnes() {
        let t = at("2026-11-13T14:05:00Z")
        func clean(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
        XCTAssertEqual(clean(formatChartTimestamp(range: .day, epochMillis: t, zone: utc, locale: us, withTime: true)), "2:05 PM")
        XCTAssertEqual(clean(formatChartTimestamp(range: .hour, epochMillis: t, zone: utc, locale: us, withTime: false)), "2:05 PM")
        XCTAssertEqual(formatChartTimestamp(range: .week, epochMillis: t, zone: utc, locale: us, withTime: false), "Nov 13")
        XCTAssertEqual(clean(formatChartTimestamp(range: .month, epochMillis: t, zone: utc, locale: us, withTime: true)), "Nov 13, 2:05 PM")
        XCTAssertEqual(formatColumnTimestamp(daily: true, epochMillis: t, zone: utc, locale: us), "Nov 13")
    }

    func testCountsAreGroupedForTheLocale() {
        XCTAssertEqual(formatChartCount(1234, locale: us), "1,234")
        XCTAssertEqual(formatChartCount(0, locale: us), "0")
    }
}
