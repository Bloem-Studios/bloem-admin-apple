import XCTest
@testable import BloemAdmin

/// A Now playing card says what the app's own session card says (the same presentation rules), and a stream
/// moves on by itself between readings: its position, its expected end, and when it comes off the card.
final class WidgetStreamTests: XCTestCase {
    private let t0 = WidgetSamples.now
    private let server = WidgetServer(id: "home", name: "Silo Home", origin: URL(string: "https://home.example.test"))

    private func dto(_ patch: [String: Any] = [:]) -> WidgetSessionDTO {
        var object: [String: Any] = [
            "session_id": "s1", "username": "maria", "media_title": "Dune: Part Two", "media_type": "movie",
            "play_method": "direct", "effective_play_method": "direct", "position_seconds": 4330.0, "file_duration": 9960.0,
            "is_paused": false, "stream_bitrate_kbps": 38_400, "profile_name": "Living room", "device_platform": "tvos",
            "client_label": "Infuse 8.1", "source_video_codec": "hevc", "source_video_resolution": "2160p",
            "source_container": "mkv", "video_decision": "direct", "audio_decision": "direct",
        ]
        for (key, value) in patch { object[key] = value }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return try! JSONDecoder().decode(WidgetSessionDTO.self, from: data)
    }

    private func item(_ patch: [String: Any] = [:]) -> StreamItem {
        WidgetStreamMapper.item(dto(patch), server: server, readAt: t0)
    }

    // MARK: Mapping

    func testADirectPlayIsTheAppsCardInWords() {
        let stream = item()
        XCTAssertEqual(stream.title, "Dune: Part Two")
        XCTAssertEqual(stream.userLine, "maria · Living room")
        XCTAssertEqual(stream.clientLine, "Infuse 8.1 · tvOS")
        XCTAssertEqual(stream.source, "HEVC 4K · MKV")
        XCTAssertEqual(stream.methodKind, .direct)
        XCTAssertEqual(stream.methodKind.label, "Direct play")
        XCTAssertNil(stream.transcodeDetail)
        XCTAssertEqual(stream.bitrateKbps, 38_400)
        XCTAssertEqual(StreamFormat.bitrate(stream.bitrateKbps, locale: Locale(identifier: "en_US")), "38.4 Mbps")
        XCTAssertEqual(stream.positionSeconds, 4330)
        XCTAssertEqual(stream.durationSeconds, 9960)
        XCTAssertEqual(stream.readAt, t0)
        XCTAssertEqual(try XCTUnwrap(stream.progress), 4330.0 / 9960.0, accuracy: 0.0001)
        XCTAssertFalse(stream.isPaused)
    }

    func testAnEpisodeIsSeriesSeasonEpisodeAndName() {
        let stream = item([
            "series_name": "Severance", "season_number": 2, "episode_number": 3, "episode_name": "Who Is Alive?",
            "profile_name": "jonas", "username": "jonas",
        ])
        XCTAssertEqual(stream.title, "Severance · S2E3 · Who Is Alive?")
        XCTAssertEqual(stream.userLine, "jonas", "a profile that repeats the account is left out")
    }

    func testATranscodeNamesWhatItConvertsToAndWhatDoesTheWork() {
        let stream = item([
            "play_method": "transcode", "effective_play_method": "transcode", "video_decision": "transcode", "audio_decision": "transcode",
            "transcode_hw_accel": "qsv", "target_video_codec": "h264", "target_resolution": "1080p", "source_video_height": 2160,
        ])
        XCTAssertEqual(stream.methodKind, .transcode)
        XCTAssertTrue(stream.methodKind.isLit)
        XCTAssertEqual(stream.transcodeDetail, "H.264 1080p · HW QSV")
        XCTAssertEqual(stream.delivery, .transcode)
    }

    func testARemuxAndADirectStreamAreNotLit() {
        XCTAssertEqual(item(["effective_play_method": "remux"]).methodKind, .remux)
        XCTAssertEqual(item(["effective_play_method": "remux"]).methodKind.label, "Remux")
        XCTAssertEqual(item(["effective_play_method": "direct_stream"]).methodKind, .directStream)
        XCTAssertFalse(StreamMethodKind.remux.isLit)
        XCTAssertFalse(StreamMethodKind.directStream.isLit)
        XCTAssertFalse(StreamMethodKind.direct.isLit)
    }

    func testTheCardUsesTheSameWordsAndStepsAsTheAppsSignalPath() {
        for patch: [String: Any] in [
            [:],
            ["effective_play_method": "remux", "video_decision": "copy", "audio_decision": "direct"],
            ["play_method": "transcode", "effective_play_method": "transcode", "video_decision": "transcode", "transcode_hw_accel": "vaapi",
             "target_video_codec": "h264", "target_resolution": "1080p", "source_video_height": 2160],
        ] {
            let source = dto(patch)
            let stream = WidgetStreamMapper.item(source, server: server, readAt: t0)
            let steps = SignalPath.steps(for: source.session)
            XCTAssertEqual(steps.count, 3)
            XCTAssertEqual(stream.methodKind.label, steps[1].value, "Playback")
            XCTAssertEqual(stream.transcodeDetail, steps[1].detail)
            XCTAssertEqual(stream.source, StreamFacts.dotted([steps[0].value, steps[0].detail]), "Source")
            XCTAssertEqual(stream.clientLine, StreamFacts.dotted([steps[2].value, steps[2].detail]), "Client")
            XCTAssertEqual(stream.title, source.session.streamTitle)
            XCTAssertEqual(stream.userLine, source.session.streamUserLabel)
        }
    }

    func testAMinimalSessionStillMakesACard() throws {
        let data = Data(#"{"session_id":"x","username":"u","media_title":"t"}"#.utf8)
        let minimal = try JSONDecoder().decode(WidgetSessionDTO.self, from: data)
        let stream = WidgetStreamMapper.item(minimal, server: server, readAt: t0)
        XCTAssertEqual(stream.title, "t")
        XCTAssertEqual(stream.userLine, "u")
        XCTAssertNil(stream.progress)
        XCTAssertNil(stream.length)
        XCTAssertEqual(stream.methodKind, .unknown)
        XCTAssertNil(stream.expectedEnd)
    }

    func testACacheWrittenBeforeTheCardsStillReads() throws {
        let old = Data(#"{"id":"s","serverID":"a","serverName":"A","user":"u","title":"t","isPaused":false,"delivery":"transcode","progress":0.5}"#.utf8)
        let stream = try JSONDecoder.widgetCache.decode(StreamItem.self, from: old)
        XCTAssertEqual(stream.userLine, "u")
        XCTAssertEqual(stream.methodKind, .transcode, "the old delivery still says how it plays")
        XCTAssertEqual(stream.fraction(at: t0), 0.5)
    }

    func testTheCardsRoundTripThroughTheCache() throws {
        let stream = item()
        let data = try JSONEncoder.widgetCache.encode(stream)
        XCTAssertEqual(try JSONDecoder.widgetCache.decode(StreamItem.self, from: data), stream)
    }

    // MARK: Moving on by itself

    private func stream(position: Double = 100, length: Double = 1000, paused: Bool = false) -> StreamItem {
        StreamItem(
            id: "s", serverID: "home", serverName: "Home", user: "u", title: "t", progress: position / length, isPaused: paused,
            delivery: .direct, bitrateKbps: nil, positionSeconds: position, durationSeconds: length, readAt: t0
        )
    }

    func testAPlayingStreamMovesOnWithTheClock() {
        let s = stream()
        XCTAssertEqual(s.position(at: t0), 100)
        XCTAssertEqual(s.position(at: t0.addingTimeInterval(60)), 160)
        XCTAssertEqual(try XCTUnwrap(s.fraction(at: t0.addingTimeInterval(400))), 0.5, accuracy: 0.0001)
        XCTAssertTrue(s.isMoving(at: t0.addingTimeInterval(60)))
    }

    func testAPausedStreamStaysWhereItWas() {
        let s = stream(paused: true)
        XCTAssertEqual(s.position(at: t0.addingTimeInterval(600)), 100)
        XCTAssertFalse(s.isMoving(at: t0.addingTimeInterval(60)))
        XCTAssertNil(s.expectedEnd, "a paused stream has no expected end")
    }

    func testAStreamNeverMovesPastTheEndOfTheFile() {
        let s = stream(position: 990)
        XCTAssertEqual(s.position(at: t0.addingTimeInterval(900)), 1000)
        XCTAssertEqual(s.fraction(at: t0.addingTimeInterval(900)), 1)
    }

    func testOldDataStopsMovingAtTheEndOfTheFreshnessWindow() {
        let s = stream(position: 100, length: 100_000)
        let window = WidgetBoard<StreamItem>.freshness
        XCTAssertTrue(s.isMoving(at: t0.addingTimeInterval(window - 1)))
        XCTAssertFalse(s.isMoving(at: t0.addingTimeInterval(window + 1)))
        XCTAssertEqual(s.position(at: t0.addingTimeInterval(window + 600)), 100 + window, "it stays where it was at the end of the window")
    }

    func testTheExpectedEndIsTheReadingPlusWhatIsLeft() {
        let s = stream()
        XCTAssertEqual(s.expectedEnd, t0.addingTimeInterval(900))
        XCTAssertEqual(s.playbackStart, t0.addingTimeInterval(-100), "the moment the bar was empty, for the system's own timer")
    }

    func testAStreamComesOffTheCardJustAfterItShouldHaveEnded() {
        let s = stream()
        XCTAssertFalse(s.isOver(at: t0.addingTimeInterval(900 + StreamItem.endSlack - 1)))
        XCTAssertTrue(s.isOver(at: t0.addingTimeInterval(900 + StreamItem.endSlack)))
        // A reading that was already old by the end cannot say the stream is over.
        XCTAssertFalse(stream(position: 100, length: 100_000).isOver(at: t0.addingTimeInterval(200_000)))
        XCTAssertFalse(stream(paused: true).isOver(at: t0.addingTimeInterval(5_000)))
    }

    // MARK: Figures

    func testEndedStreamsLeaveTheCountsAndTheBandwidth() {
        let board = WidgetSamples.entry().streams
        XCTAssertEqual(NowPlayingFigures(board: board).total, 4)
        let later = NowPlayingFigures(board: board, now: t0.addingTimeInterval(1_040))
        XCTAssertEqual(later.total, 3, "the transcode should have ended")
        XCTAssertEqual(later.transcodes, 0)
        XCTAssertEqual(later.bandwidthKbps, 65_500 - 8_200)
        XCTAssertEqual(later.rows.map(\.id), ["s1", "s2", "s4"])
        XCTAssertEqual(later.streamsText, "3 streams")
    }

    func testTheFiguresSayStreamForOne() {
        var board = WidgetSamples.entry().streams
        board.feeds[0].items = [WidgetSamples.streams[0]]
        board.feeds[0].total = 1
        XCTAssertEqual(NowPlayingFigures(board: board).streamsText, "1 stream")
        XCTAssertEqual(NowPlayingFigures(board: board).streamsNoun, "stream")
    }

    func testTheFooterFiguresAreStreamsTranscodingAndBandwidth() {
        let figures = NowPlayingFigures(board: WidgetSamples.entry().streams)
        XCTAssertEqual(figures.stats.map(\.id), ["streams", "transcoding", "bandwidth"])
        // The bandwidth is in the person's own number format.
        let mbps = (65.5).formatted(.number.precision(.fractionLength(0...1)))
        XCTAssertEqual(figures.stats.map(\.value), ["4", "1", mbps])
        XCTAssertTrue(figures.stats[0].isLive, "the live count carries the tally dot")
        XCTAssertEqual(figures.bandwidthText, "\(mbps) Mbps")
    }

    func testTheMethodDotsAreTheNowPlayingPagesChartColours() {
        let palette = WidgetPalette.dark
        XCTAssertEqual(palette.methodColor(.direct), palette.chart[0])
        XCTAssertEqual(palette.methodColor(.remux), palette.chart[1])
        XCTAssertEqual(palette.methodColor(.directStream), palette.chart[1])
        XCTAssertEqual(palette.methodColor(.transcode), palette.chart[2])
        XCTAssertEqual(WidgetPalette.light.methodColor(.transcode), WidgetPalette.light.chart[2], "the chart colours are the same in light")
    }
}

/// When a widget draws again and when it reads again.
final class WidgetTimelinePlanTests: XCTestCase {
    private let now = WidgetSamples.now

    func testNowPlayingHasEntriesWhereAStreamShouldEndAndWhereTheReadingTurnsOld() {
        let entry = WidgetSamples.entry()
        let dates = WidgetTimelinePlan.entryDates(.nowPlaying, entry)
        XCTAssertEqual(dates.first, now)
        // The transcode (1,020 s left, plus the slack) and the end of the freshness window (plus a second).
        XCTAssertTrue(dates.contains(now.addingTimeInterval(1_020 + StreamItem.endSlack)))
        XCTAssertTrue(dates.contains(now.addingTimeInterval(WidgetBoard<StreamItem>.freshness + 1)))
        XCTAssertEqual(dates, dates.sorted())
        XCTAssertLessThanOrEqual(dates.count, WidgetTimelinePlan.maxEntries)
        XCTAssertTrue(dates.allSatisfy { $0 <= now.addingTimeInterval(WidgetTimelinePlan.horizon) })
    }

    func testAStreamWhoseEndIsBeyondTheFreshnessWindowAddsNoEntry() {
        // Dune has 5,630 s left and Severance 1,898 s: both are past the window, so neither can be known to end.
        let dates = WidgetTimelinePlan.entryDates(.nowPlaying, WidgetSamples.entry())
        XCTAssertFalse(dates.contains(now.addingTimeInterval(5_630 + StreamItem.endSlack)))
        XCTAssertFalse(dates.contains(now.addingTimeInterval(1_898 + StreamItem.endSlack)))
    }

    func testEntriesCloseTogetherAreOne() {
        var board = WidgetSamples.entry().streams
        var near = WidgetSamples.streams[2]
        near.id = "near"
        near.positionSeconds = 1_970
        near.progress = 1_970.0 / 3_000
        board.feeds[0].items.append(near)
        let entry = SiloEntry(
            date: now, snapshot: nil, live: [:], serverID: nil, settings: WidgetSettings(), streams: board,
            requests: WidgetSamples.entry().requests, libraries: WidgetSamples.entry().libraries, nodes: WidgetSamples.entry().nodes, notice: nil
        )
        let dates = WidgetTimelinePlan.entryDates(.nowPlaying, entry)
        let ends = dates.filter { $0 > now.addingTimeInterval(900) && $0 < now.addingTimeInterval(1_100) }
        XCTAssertEqual(ends.count, 1, "two ends ten seconds apart draw once")
    }

    func testTheOtherWidgetsHaveOneEntry() {
        for kind in [SiloWidgetKind.serverStatus, .requests, .libraries, .nodes] {
            XCTAssertEqual(WidgetTimelinePlan.entryDates(kind, WidgetSamples.entry()), [now], "\(kind)")
        }
    }

    func testTheReloadIsAboutFiveMinutesWhileSomethingIsActiveAndFifteenOtherwise() {
        let busy = WidgetSamples.entry()
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(.nowPlaying, busy), now.addingTimeInterval(5 * 60), "streams play")
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(.serverStatus, busy), now.addingTimeInterval(5 * 60), "the live count is above zero")
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(.libraries, busy), now.addingTimeInterval(5 * 60), "a scan runs")
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(.requests, busy), now.addingTimeInterval(15 * 60))
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(.nodes, busy), now.addingTimeInterval(15 * 60))

        var board = busy.streams
        board.feeds[0].items = []
        board.feeds[0].total = 0
        let idle = SiloEntry(
            date: now, snapshot: WidgetSamples.snapshot, live: [:], serverID: nil, settings: WidgetSettings(), streams: board,
            requests: busy.requests, libraries: WidgetBoard(title: "All servers", serverID: nil, feeds: []), nodes: busy.nodes, notice: nil
        )
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(.nowPlaying, idle), now.addingTimeInterval(15 * 60), "nothing plays")
        XCTAssertEqual(WidgetTimelinePlan.reloadDate(.libraries, idle), now.addingTimeInterval(15 * 60), "no scan runs")
    }

    func testALaterEntryIsTheSameReadingsDrawnLater() {
        let entry = WidgetSamples.entry()
        let later = entry.at(now.addingTimeInterval(600))
        XCTAssertEqual(later.date, now.addingTimeInterval(600))
        XCTAssertEqual(later.streams, entry.streams)
        XCTAssertEqual(later.requests, entry.requests)
        XCTAssertEqual(later.settings, entry.settings)
    }
}

/// Whole cards, as many as fit, richer as the widget gets bigger and no empty band.
final class WidgetListPlannerTests: XCTestCase {
    private let tiers = NowPlayingTier.tiers

    private func plan(_ width: CGFloat, _ height: CGFloat, rows: Int = 4, scale: CGFloat = 1, columns: Int = 1) -> WidgetListPlan {
        WidgetListPlanner.plan(size: CGSize(width: width, height: height), rows: rows, tiers: tiers, typeScale: scale, maxColumns: columns)
    }

    func testMediumShowsTwoCompactCardsUnderTheHeader() {
        let p = plan(348, 154)
        XCTAssertTrue(p.showsHeader)
        XCTAssertEqual(NowPlayingTier(rawValue: p.tierIndex), .compact)
        XCTAssertEqual(p.visible, 2)
        XCTAssertEqual(p.footer, .none)
        XCTAssertEqual(p.more, 2)
    }

    func testLargeShowsThreeRoomyCardsAndALineOfTotals() {
        let p = plan(348, 366)
        XCTAssertEqual(NowPlayingTier(rawValue: p.tierIndex), .roomy)
        XCTAssertEqual(p.visible, 3)
        XCTAssertEqual(p.footer, .line)
        XCTAssertEqual(p.more, 1)
        XCTAssertGreaterThan(p.cardHeight, tiers[p.tierIndex].height, "the height left over goes to the cards")
        XCTAssertLessThanOrEqual(p.cardHeight, tiers[p.tierIndex].height + WidgetLayout.maxStretch)
    }

    func testExtraLargeUsesTwoColumnsOfFullCards() {
        let p = plan(710, 362, columns: 2)
        XCTAssertEqual(p.columns, 2)
        XCTAssertEqual(NowPlayingTier(rawValue: p.tierIndex), .full)
        XCTAssertEqual(p.visible, 4)
        XCTAssertEqual(p.rowsPerColumn, 2)
        XCTAssertEqual(p.more, 0)
    }

    func testAColumnIsOnlyUsedWhenAskedForAndWideEnough() {
        XCTAssertEqual(plan(710, 362, columns: 1).columns, 1)
        XCTAssertEqual(plan(348, 366, columns: 2).columns, 1)
    }

    func testOneStreamOnALargeWidgetGetsTheFullCardAndTheTotals() {
        let p = plan(348, 366, rows: 1)
        XCTAssertEqual(NowPlayingTier(rawValue: p.tierIndex), .full)
        XCTAssertEqual(p.visible, 1)
        XCTAssertEqual(p.footer, .stats)
    }

    func testNoRowsDrawsNoCardsAndNoFooter() {
        let p = plan(348, 366, rows: 0)
        XCTAssertEqual(p.visible, 0)
        XCTAssertEqual(p.footer, .none)
    }

    func testALargerTextSizeShowsFewerCardsAndNeverACutOffOne() {
        let normal = plan(348, 154)
        let big = plan(348, 154, scale: 1.3)
        XCTAssertLessThanOrEqual(big.visible, normal.visible)
        XCTAssertGreaterThanOrEqual(big.cardHeight, WidgetLayout.scaled(tiers[big.tierIndex].height, by: 1.3), "a card is never drawn shorter than its tier")
    }

    func testNarrowWidthsDropToTheLeanestCard() {
        XCTAssertEqual(NowPlayingTier(rawValue: plan(200, 366).tierIndex), .compact)
    }

    func testEverySizeFitsItsHeightAndNeverDrawsMoreRowsThanItHas() {
        for width: CGFloat in [154, 200, 348, 710] {
            for height: CGFloat in [154, 224, 366, 362] {
                for rows in 0...8 {
                    for scale: CGFloat in [1, 1.3] {
                        let p = WidgetListPlanner.plan(
                            size: CGSize(width: width, height: height), rows: rows, tiers: tiers, typeScale: scale,
                            maxColumns: width >= 600 ? 2 : 1
                        )
                        let label = "\(width)x\(height) rows \(rows) scale \(scale)"
                        XCTAssertLessThanOrEqual(p.visible, rows, label)
                        XCTAssertEqual(p.more, rows - p.visible, label)
                        guard p.visible > 0 else { continue }
                        XCTAssertGreaterThanOrEqual(p.cardHeight, WidgetLayout.scaled(tiers[p.tierIndex].height, by: scale) - 0.001, label)
                        let header = p.showsHeader ? WidgetLayout.scaled(WidgetLayout.headerHeight, by: scale) + WidgetLayout.gap : 0
                        let cards = CGFloat(p.rowsPerColumn) * p.cardHeight + CGFloat(p.rowsPerColumn - 1) * WidgetLayout.gap
                        let footer: CGFloat = p.footer == .stats ? WidgetLayout.scaled(WidgetLayout.statsFooterHeight, by: scale) + WidgetLayout.gap
                            : p.footer == .line ? WidgetLayout.scaled(WidgetLayout.lineFooterHeight, by: scale) + WidgetLayout.gap : 0
                        // Whenever at least one whole card of the leanest design fits, the plan fits too.
                        let leanest = WidgetLayout.scaled(tiers[tiers.count - 1].height, by: scale)
                        if height - header >= leanest {
                            XCTAssertLessThanOrEqual(header + cards + footer, height + 0.5, label)
                        }
                    }
                }
            }
        }
    }
}
