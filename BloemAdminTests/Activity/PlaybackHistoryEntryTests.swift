import XCTest
@testable import BloemAdmin

/// What a Playback history row shows, and the fields the route returns that it decodes
/// (`AdminPlaybackHistoryEntry` in the server's openapi.json).
final class PlaybackHistoryEntryTests: XCTestCase {
    /// A complete wire row; `overrides` replaces fields by key, a nil override writes JSON null.
    private func entry(_ overrides: [String: Any?] = [:]) throws -> PlaybackHistoryEntry {
        var fields: [String: Any?] = [
            "session_id": "ps_7f3a91c2d4", "user_id": "42", "username": "mchan", "profile_id": "p1", "profile_name": "Living room",
            "media_item_id": "m1", "media_file_id": "f1", "media_title": "Pilot", "media_type": "movie", "play_method": "direct",
            "started_at": "2026-11-14T21:00:00Z", "ended_at": "2026-11-14T21:42:10Z", "watched_seconds": 2530.0,
            "duration_seconds": 5400.0, "completed": false, "played_seconds": 2410.0, "series_title": "", "season_number": nil,
            "episode_number": nil, "measured": true, "start_position_seconds": 0.0, "paused_seconds": 120.0,
            "measured_since": nil, "measured_until": nil, "client_ip": "192.0.2.10", "device_id": "d1", "device_platform": "ios",
            "client_name": "Bloem for iPhone", "client_version": "1.4", "video_decision": "direct", "audio_decision": "direct",
            "end_reason": "stopped", "lifecycle_seq": 12,
        ]
        for (key, value) in overrides { fields[key] = value }
        let object = fields.mapValues { $0 ?? NSNull() }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder.iso8601.decode(PlaybackHistoryEntry.self, from: data)
    }

    // MARK: Decoding

    func testDecodesTheFieldsTheRowAndDetailsNeed() throws {
        let row = try entry(["series_title": "Night Shift", "season_number": 2, "episode_number": 4, "play_method": "transcode"])
        XCTAssertEqual(row.userID, "42")
        XCTAssertEqual(row.profileID, "p1")
        XCTAssertEqual(row.profileName, "Living room")
        XCTAssertEqual(row.playMethod, "transcode")
        XCTAssertEqual(row.seriesTitle, "Night Shift")
        XCTAssertEqual(row.seasonNumber, 2)
        XCTAssertEqual(row.episodeNumber, 4)
        XCTAssertEqual(row.playedSeconds, 2410)
        XCTAssertEqual(row.pausedSeconds, 120)
        XCTAssertEqual(row.durationSeconds, 5400)
        XCTAssertEqual(row.endReason, "stopped")
        XCTAssertEqual(row.clientName, "Bloem for iPhone")
        XCTAssertEqual(row.devicePlatform, "ios")
        XCTAssertEqual(row.clientIP, "192.0.2.10")
    }

    func testNullableFieldsDecodeAsNil() throws {
        let row = try entry(["duration_seconds": nil, "played_seconds": nil, "end_reason": nil, "client_ip": nil, "client_name": nil, "device_platform": nil])
        XCTAssertNil(row.durationSeconds)
        XCTAssertNil(row.playedSeconds)
        XCTAssertNil(row.endReason)
        XCTAssertNil(row.clientIP)
        XCTAssertNil(row.clientName)
        XCTAssertNil(row.devicePlatform)
    }

    // MARK: Title and episode code

    func testEpisodeCodePadsSeasonAndEpisodeToTwoDigits() throws {
        XCTAssertEqual(try entry(["series_title": "Night Shift", "season_number": 2, "episode_number": 4]).episodeCode, "S02E04")
        XCTAssertEqual(try entry(["series_title": "Night Shift", "season_number": 12, "episode_number": 104]).episodeCode, "S12E104")
    }

    func testNoEpisodeCodeWithoutBothNumbers() throws {
        XCTAssertNil(try entry().episodeCode)
        XCTAssertNil(try entry(["season_number": 2]).episodeCode)
        XCTAssertNil(try entry(["episode_number": 4]).episodeCode)
    }

    func testAnEpisodeLeadsWithItsSeriesAndDetailsTheCodeAndEpisodeTitle() throws {
        let row = try entry(["series_title": "Night Shift", "season_number": 2, "episode_number": 4, "media_title": "The Handover"])
        XCTAssertEqual(row.headline, "Night Shift")
        XCTAssertEqual(row.detailLine, "S02E04 · The Handover")
    }

    func testAPilotNamedAfterItsShowDoesNotRepeatTheTitle() throws {
        let row = try entry(["series_title": "Night Shift", "season_number": 1, "episode_number": 1, "media_title": "Night Shift"])
        XCTAssertEqual(row.detailLine, "S01E01")
    }

    func testAMovieKeepsItsOwnTitleAndHasNoDetailLine() throws {
        let row = try entry(["media_title": "Heat"])
        XCTAssertEqual(row.headline, "Heat")
        XCTAssertNil(row.detailLine)
    }

    // MARK: Watch time

    func testMeasuredWatchTimeIsPlayedSecondsAndIsNotEstimated() throws {
        let watch = try entry().watchTime
        XCTAssertEqual(watch.seconds, 2410)
        XCTAssertFalse(watch.estimated)
    }

    func testUnmeasuredWatchTimeIsTheEndPositionCappedAtElapsedTimeAndEstimated() throws {
        // Ended at position 2530 s, but only 2530 s (42m10s) passed between start and end: not capped.
        var watch = try entry(["played_seconds": nil, "watched_seconds": 2530.0]).watchTime
        XCTAssertEqual(watch.seconds, 2530)
        XCTAssertTrue(watch.estimated)
        // A play resumed at 1 h: the end position 4000 s is capped to the 2530 s that passed.
        watch = try entry(["played_seconds": nil, "watched_seconds": 4000.0]).watchTime
        XCTAssertEqual(watch.seconds, 2530)
        XCTAssertTrue(watch.estimated)
    }

    func testDurationText() {
        XCTAssertEqual(PlaybackHistoryEntry.durationText(45), "45s")
        XCTAssertEqual(PlaybackHistoryEntry.durationText(724), "12m 04s")
        XCTAssertEqual(PlaybackHistoryEntry.durationText(5400), "1h 30m")
        XCTAssertEqual(PlaybackHistoryEntry.durationText(0), "0s")
    }

    func testWatchLineIsWatchTimeOutOfDuration() throws {
        XCTAssertEqual(try entry().watchLine, "40m 10s of 1h 30m")
    }

    func testEstimatedWatchLineSaysAbout() throws {
        XCTAssertEqual(try entry(["played_seconds": nil]).watchLine, "About 42m 10s of 1h 30m")
    }

    func testWatchLineWithoutADurationShowsOnlyTheWatchTime() throws {
        XCTAssertEqual(try entry(["duration_seconds": nil]).watchLine, "40m 10s")
    }

    // MARK: Play method, profile, end reason

    func testPlayMethodNamesFollowTheNowPlayingWords() throws {
        XCTAssertEqual(try entry(["play_method": "direct"]).playMethodLabel, "Direct play")
        XCTAssertEqual(try entry(["play_method": "remux"]).playMethodLabel, "Remux")
        XCTAssertEqual(try entry(["play_method": "direct_stream"]).playMethodLabel, "Direct stream")
        XCTAssertEqual(try entry(["play_method": "transcode"]).playMethodLabel, "Transcode")
        XCTAssertEqual(try entry(["play_method": ""]).playMethodLabel, "Unknown")
    }

    func testProfileLabelFallsBackToTheProfileID() throws {
        XCTAssertEqual(try entry().profileLabel, "Living room")
        XCTAssertEqual(try entry(["profile_name": ""]).profileLabel, "p1")
    }

    func testEndReasonIsSaidInWords() throws {
        XCTAssertEqual(try entry(["end_reason": "stopped"]).endReasonLabel, "Stopped by the viewer")
        XCTAssertEqual(try entry(["end_reason": "terminated"]).endReasonLabel, "Ended by an administrator")
        XCTAssertEqual(try entry(["end_reason": "expired"]).endReasonLabel, "Client stopped responding")
        XCTAssertEqual(try entry(["end_reason": "aborted"]).endReasonLabel, "Stopped by the server")
        XCTAssertEqual(try entry(["end_reason": "replaced"]).endReasonLabel, "Replaced by a new session")
        XCTAssertNil(try entry(["end_reason": nil]).endReasonLabel)
    }

    // MARK: When

    func testWhenIsLocalDateAndTimeOfTheEnd() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Amsterdam"))
        let text = try entry().whenText(timeZone: zone, locale: Locale(identifier: "en_GB"))
        // 21:42:10Z is 22:42 in Amsterdam in November.
        XCTAssertTrue(text.contains("22:42"), text)
        XCTAssertTrue(text.contains("14"), text)
    }

    func testAnEntryWithoutAnEndFallsBackToItsStart() throws {
        let row = try entry(["ended_at": nil])
        let zone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        XCTAssertTrue(row.whenText(timeZone: zone, locale: Locale(identifier: "en_GB")).contains("21:00"))
    }
}

/// A short row (as older fixtures and servers send) still decodes.
final class PlaybackHistoryEntryShortRowTests: XCTestCase {
    func testARowWithoutTheNewFieldsDecodesToEmptyText() throws {
        let json = #"{"session_id":"s1","username":"bob","media_title":"The Long Film","media_type":"movie","watched_seconds":3600.0,"duration_seconds":7200.0,"completed":true,"started_at":"2026-02-03T04:05:06.000Z","ended_at":null}"#
        let row = try JSONDecoder.iso8601.decode(PlaybackHistoryEntry.self, from: Data(json.utf8))
        XCTAssertEqual(row.profileLabel, "")
        XCTAssertEqual(row.playMethodLabel, "Unknown")
        XCTAssertNil(row.episodeCode)
        XCTAssertEqual(row.headline, "The Long Film")
    }
}
