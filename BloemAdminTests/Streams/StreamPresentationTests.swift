import XCTest
@testable import BloemAdmin

/// The pure presentation rules for a live stream, ported from the web admin's
/// adminActivityPresentation.ts through the Android app's StreamPresentation.kt.
final class StreamPresentationTests: XCTestCase {
    private func session(
        method: String = "direct",
        paused: Bool = false,
        position: Double = 0,
        duration: Double? = nil,
        _ configure: (inout AdminSession) -> Void = { _ in }
    ) -> AdminSession {
        var value = AdminSession(
            sessionID: "s1", username: "alex", mediaTitle: "Film", mediaType: "movie", playMethod: method,
            positionSeconds: position, fileDuration: duration, isPaused: paused, clientName: nil
        )
        configure(&value)
        return value
    }

    // MARK: decisions and method

    func testDecisionsFollowTheWebsNormalisation() {
        XCTAssertEqual(StreamDecision(raw: "direct"), .direct)
        XCTAssertEqual(StreamDecision(raw: "copy"), .copy)
        XCTAssertEqual(StreamDecision(raw: "remux"), .copy)
        XCTAssertEqual(StreamDecision(raw: " transcode "), .transcode)
        XCTAssertEqual(StreamDecision(raw: "hls"), .unknown)
        XCTAssertEqual(StreamDecision(raw: nil), .unknown)
        XCTAssertEqual(StreamDecision(raw: "direct play"), .direct)
    }

    func testComponentDecisionsFallBackToThePlayMethodAndTheAudioFlag() {
        let bare = session(method: "transcode")
        XCTAssertEqual(bare.videoStreamDecision, .transcode)
        XCTAssertEqual(bare.audioStreamDecision, .transcode)
        let audioOnly = session(method: "direct") { $0.transcodeAudio = true }
        XCTAssertEqual(audioOnly.videoStreamDecision, .direct)
        XCTAssertEqual(audioOnly.audioStreamDecision, .transcode)
        let explicit = session(method: "transcode") { $0.videoDecision = "copy"; $0.audioDecision = "transcode" }
        XCTAssertEqual(explicit.videoStreamDecision, .copy)
        XCTAssertEqual(explicit.audioStreamDecision, .transcode)
        let blank = session(method: "transcode") { $0.videoDecision = "  " }
        XCTAssertEqual(blank.videoStreamDecision, .transcode)
    }

    func testTheServersEffectiveMethodWins() {
        func method(_ effective: String?) -> StreamMethod {
            session(method: "direct") { $0.effectivePlayMethod = effective }.streamMethod
        }
        XCTAssertEqual(method("direct"), .direct)
        XCTAssertEqual(method("remux"), .remux)
        XCTAssertEqual(method("direct_stream"), .directStream)
        XCTAssertEqual(method("audio"), .directStream)
        XCTAssertEqual(method("transcode"), .transcode)
        XCTAssertEqual(method("something-new"), .unknown)
    }

    func testWithoutAnEffectiveMethodItIsReducedFromTheComponents() {
        func method(_ video: String?, _ audio: String?, playMethod: String = "direct") -> StreamMethod {
            session(method: playMethod) { $0.videoDecision = video; $0.audioDecision = audio }.streamMethod
        }
        XCTAssertEqual(method("transcode", "direct"), .transcode)
        XCTAssertEqual(method("direct", "transcode"), .directStream)
        XCTAssertEqual(method("copy", "transcode"), .directStream)
        XCTAssertEqual(method("direct", "direct"), .direct)
        XCTAssertEqual(method("copy", "direct"), .remux)
        XCTAssertEqual(method("direct", "copy"), .remux)
        XCTAssertEqual(method(nil, nil, playMethod: ""), .unknown)
        // An unknown video decision must not turn a bare audio flag into a direct stream.
        XCTAssertEqual(session(method: "") { $0.transcodeAudio = true }.streamMethod, .unknown)
    }

    // MARK: titles, people, client

    func testAnEpisodeReadsSeriesEpisodeNumberAndName() {
        let episode = session {
            $0.seriesName = "Severance"; $0.seasonNumber = 2; $0.episodeNumber = 3
            $0.episodeName = "Who Is Alive?"; $0.mediaTitle = "ignored"
        }
        XCTAssertEqual(episode.streamTitle, "Severance · S2E3 · Who Is Alive?")
    }

    func testAnEpisodeWithoutAnEpisodeNameFallsBackToTheMediaTitleOrLeavesItOut() {
        var withTitle = session {
            $0.seriesName = "Severance"; $0.seasonNumber = 1; $0.episodeNumber = 1; $0.mediaTitle = "Good News About Hell"
        }
        XCTAssertEqual(withTitle.streamTitle, "Severance · S1E1 · Good News About Hell")
        withTitle.mediaTitle = "Severance"
        XCTAssertEqual(withTitle.streamTitle, "Severance · S1E1")
    }

    func testAMovieOrIncompleteEpisodeUsesTheMediaTitle() {
        XCTAssertEqual(session().streamTitle, "Film")
        XCTAssertEqual(session { $0.seriesName = "Show"; $0.seasonNumber = 1 }.streamTitle, "Film")
        XCTAssertEqual(session { $0.episodeNumber = 4; $0.seasonNumber = 1 }.streamTitle, "Film")
    }

    func testUserAndProfileJoinAndSkipARepeatedOrMissingProfile() {
        XCTAssertEqual(session { $0.profileName = "Living room" }.streamUserLabel, "alex · Living room")
        XCTAssertEqual(session { $0.profileName = "ALEX" }.streamUserLabel, "alex")
        XCTAssertEqual(session { $0.profileName = "  " }.streamUserLabel, "alex")
        XCTAssertEqual(session().streamUserLabel, "alex")
    }

    func testTheClientLabelPrefersTheServersOwn() {
        XCTAssertEqual(session { $0.clientLabel = " Silo Android 1.4 "; $0.clientName = "x" }.streamClientLabel, "Silo Android 1.4")
        XCTAssertEqual(session { $0.clientName = "Silo Android"; $0.clientVersion = "1.4.2" }.streamClientLabel, "Silo Android 1.4.2")
        XCTAssertEqual(session { $0.clientName = "Silo Android" }.streamClientLabel, "Silo Android")
        XCTAssertNil(session().streamClientLabel)
        XCTAssertNil(session { $0.clientName = " "; $0.clientVersion = "2" }.streamClientLabel)
    }

    func testTheFullClientLabelFallsBackToTheCompactOne() {
        XCTAssertEqual(
            session { $0.clientLabel = "Silo Android 1.4"; $0.clientLabelFull = "Silo Android 1.4.2 (88) beta" }.streamClientLabelFull,
            "Silo Android 1.4.2 (88) beta"
        )
        XCTAssertEqual(session { $0.clientLabel = "Silo Android 1.4" }.streamClientLabelFull, "Silo Android 1.4")
    }

    func testDeviceNamesAreReadableAndUnknownPlatformsPassThrough() {
        XCTAssertEqual(session { $0.devicePlatform = "android" }.streamDeviceLabel, "Android")
        XCTAssertEqual(session { $0.devicePlatform = "IOS" }.streamDeviceLabel, "iOS")
        XCTAssertEqual(session { $0.devicePlatform = "tvos" }.streamDeviceLabel, "tvOS")
        XCTAssertEqual(session { $0.devicePlatform = "Fridge" }.streamDeviceLabel, "Fridge")
        XCTAssertNil(session().streamDeviceLabel)
    }

    func testTheClientLineJoinsAppAndDeviceOrIsNil() {
        XCTAssertEqual(
            session { $0.clientLabel = "Silo Android 1.4"; $0.devicePlatform = "android" }.streamClientLine,
            "Silo Android 1.4 · Android"
        )
        XCTAssertEqual(session { $0.devicePlatform = "android" }.streamClientLine, "Android")
        XCTAssertNil(session().streamClientLine)
    }

    // MARK: time

    func testTheClockShowsMinutesAndHours() {
        XCTAssertEqual(StreamFormat.playbackClock(0), "0:00")
        XCTAssertEqual(StreamFormat.playbackClock(9.9), "0:09")
        XCTAssertEqual(StreamFormat.playbackClock(754), "12:34")
        XCTAssertEqual(StreamFormat.playbackClock(3599), "59:59")
        XCTAssertEqual(StreamFormat.playbackClock(3600), "1:00:00")
        XCTAssertEqual(StreamFormat.playbackClock(3723), "1:02:03")
        XCTAssertEqual(StreamFormat.playbackClock(43_200), "12:00:00")
    }

    func testTheClockTreatsBadValuesAsZero() {
        XCTAssertEqual(StreamFormat.playbackClock(-5), "0:00")
        XCTAssertEqual(StreamFormat.playbackClock(.nan), "0:00")
        XCTAssertEqual(StreamFormat.playbackClock(.infinity), "0:00")
    }

    func testRemainingTimeIsCompact() {
        XCTAssertEqual(StreamFormat.remainingTime(0), "0s")
        XCTAssertEqual(StreamFormat.remainingTime(0.2), "1s")
        XCTAssertEqual(StreamFormat.remainingTime(45), "45s")
        XCTAssertEqual(StreamFormat.remainingTime(60), "1m")
        XCTAssertEqual(StreamFormat.remainingTime(32 * 60 + 40), "32m")
        XCTAssertEqual(StreamFormat.remainingTime(3600), "1h")
        XCTAssertEqual(StreamFormat.remainingTime(3600 + 5 * 60 + 30), "1h 5m")
        XCTAssertEqual(StreamFormat.remainingTime(-3), "0s")
        XCTAssertEqual(StreamFormat.remainingTime(.nan), "0s")
    }

    func testRemainingNeedsAKnownLength() {
        XCTAssertEqual(StreamFormat.remainingSeconds(position: 40, duration: 100), 60)
        XCTAssertEqual(StreamFormat.remainingSeconds(position: 120, duration: 100), 0)
        XCTAssertNil(StreamFormat.remainingSeconds(position: 40, duration: nil))
        XCTAssertNil(StreamFormat.remainingSeconds(position: 40, duration: 0))
    }

    func testAPlayingStreamMovesForwardAndAPausedOneStaysPut() {
        XCTAssertEqual(StreamFormat.projectedPosition(position: 10, duration: 100, paused: false, elapsed: 5), 15, accuracy: 0.0001)
        XCTAssertEqual(StreamFormat.projectedPosition(position: 10, duration: 100, paused: true, elapsed: 5), 10)
        XCTAssertEqual(StreamFormat.projectedPosition(position: 10, duration: 100, paused: false, elapsed: -0.05), 10)
        XCTAssertEqual(StreamFormat.projectedPosition(position: 10, duration: 100, paused: false, elapsed: 0), 10)
    }

    func testAProjectedPositionStopsAtTheEndOfTheFile() {
        XCTAssertEqual(StreamFormat.projectedPosition(position: 98, duration: 100, paused: false, elapsed: 30), 100)
        XCTAssertEqual(StreamFormat.projectedPosition(position: 100, duration: nil, paused: false, elapsed: 400), 500)
        XCTAssertEqual(StreamFormat.projectedPosition(position: -4, duration: 100, paused: true, elapsed: 0), 0)
    }

    func testProgressIsAFractionOfAKnownLength() throws {
        XCTAssertEqual(try XCTUnwrap(StreamFormat.progressFraction(position: 25, duration: 100)), 0.25, accuracy: 0.0001)
        XCTAssertEqual(StreamFormat.progressFraction(position: 150, duration: 100), 1)
        XCTAssertEqual(StreamFormat.progressFraction(position: -1, duration: 100), 0)
        XCTAssertNil(StreamFormat.progressFraction(position: 25, duration: nil))
        XCTAssertNil(StreamFormat.progressFraction(position: 25, duration: 0))
    }

    func testServerTimestampsShowInTheDevicesZone() throws {
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let us = Locale(identifier: "en_US")
        for iso in ["2026-11-13T14:02:30.123Z", "2026-11-13T14:02:30.123456789Z", "2026-11-13T14:02:30Z", "2026-11-13T15:02:30+01:00"] {
            let text = try XCTUnwrap(StreamFormat.instant(iso, timeZone: utc, locale: us), iso)
            XCTAssertTrue(text.contains("Nov 13, 2026"), text)
            XCTAssertTrue(text.contains("2:02"), text)
        }
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertTrue(try XCTUnwrap(StreamFormat.instant("2026-11-13T14:02:30Z", timeZone: berlin, locale: us)).contains("3:02"))
        XCTAssertNil(StreamFormat.instant(nil))
        XCTAssertNil(StreamFormat.instant(""))
        XCTAssertNil(StreamFormat.instant("yesterday"))
    }

    // MARK: media

    func testCodecsUseTheWebsLabels() {
        XCTAssertEqual(StreamFormat.codec("hevc"), "HEVC")
        XCTAssertEqual(StreamFormat.codec("h265"), "HEVC")
        XCTAssertEqual(StreamFormat.codec("h264"), "H.264")
        XCTAssertEqual(StreamFormat.codec(" H264 "), "H.264")
        XCTAssertEqual(StreamFormat.codec("truehd"), "TrueHD")
        XCTAssertEqual(StreamFormat.codec("dtshd"), "DTS-HD")
        XCTAssertEqual(StreamFormat.codec("vp9"), "VP9")
        XCTAssertNil(StreamFormat.codec(nil))
        XCTAssertNil(StreamFormat.codec("  "))
    }

    func testResolutionsNameTheSizeClass() {
        XCTAssertEqual(StreamFormat.resolution("2160p"), "4K")
        XCTAssertEqual(StreamFormat.resolution("3840x2160"), "4K")
        XCTAssertEqual(StreamFormat.resolution("3840x1600"), "4K")
        XCTAssertEqual(StreamFormat.resolution("4k"), "4K")
        XCTAssertEqual(StreamFormat.resolution("4320p"), "8K")
        XCTAssertEqual(StreamFormat.resolution("1080p"), "1080p")
        XCTAssertEqual(StreamFormat.resolution("1920x1080"), "1080p")
        XCTAssertEqual(StreamFormat.resolution("1280x720"), "720p")
        XCTAssertEqual(StreamFormat.resolution("576P"), "576p")
        XCTAssertEqual(StreamFormat.resolution("SD"), "SD")
        XCTAssertNil(StreamFormat.resolution(nil))
        XCTAssertNil(StreamFormat.resolution(""))
    }

    func testChannelLayoutsUseTheUsualNames() {
        XCTAssertEqual(StreamFormat.channelLayout(1), "1.0")
        XCTAssertEqual(StreamFormat.channelLayout(2), "2.0")
        XCTAssertEqual(StreamFormat.channelLayout(6), "5.1")
        XCTAssertEqual(StreamFormat.channelLayout(8), "7.1")
        XCTAssertEqual(StreamFormat.channelLayout(4), "4ch")
        XCTAssertEqual(StreamFormat.channelLayout(10), "10ch")
        XCTAssertNil(StreamFormat.channelLayout(0))
        XCTAssertNil(StreamFormat.channelLayout(-2))
        XCTAssertNil(StreamFormat.channelLayout(nil))
    }

    func testBitratesUseMbpsFromAThousandKbps() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(StreamFormat.bitrate(8200, locale: us), "8.2 Mbps")
        XCTAssertEqual(StreamFormat.bitrate(1000, locale: us), "1.0 Mbps")
        XCTAssertEqual(StreamFormat.bitrate(850, locale: us), "850 kbps")
        XCTAssertEqual(StreamFormat.bitrate(999, locale: us), "999 kbps")
        XCTAssertEqual(StreamFormat.bitrate(8200, locale: Locale(identifier: "de_DE")), "8,2 Mbps")
        XCTAssertNil(StreamFormat.bitrate(0, locale: us))
        XCTAssertNil(StreamFormat.bitrate(-5, locale: us))
        XCTAssertNil(StreamFormat.bitrate(nil, locale: us))
    }

    func testAudioLanguagesAreReadable() {
        let en = Locale(identifier: "en")
        XCTAssertEqual(StreamFormat.audioLanguage("en", locale: en), "English")
        XCTAssertEqual(StreamFormat.audioLanguage("ja", locale: en), "Japanese")
        XCTAssertEqual(StreamFormat.audioLanguage("en-GB", locale: en), "English")
        XCTAssertEqual(StreamFormat.audioLanguage("en_GB", locale: en), "English")
        XCTAssertEqual(StreamFormat.audioLanguage("zzzz-weird", locale: en), "zzzz-weird")
        XCTAssertNil(StreamFormat.audioLanguage(nil, locale: en))
        XCTAssertNil(StreamFormat.audioLanguage(" ", locale: en))
    }

    // MARK: flows

    func testATranscodeShowsSourceToTargetVideo() {
        let s = session(method: "transcode") {
            $0.videoDecision = "transcode"; $0.sourceVideoCodec = "hevc"; $0.sourceVideoResolution = "2160p"
            $0.targetVideoCodec = "h264"; $0.targetResolution = "1080p"
        }
        XCTAssertEqual(s.videoFlow, MediaFlow(source: "HEVC 4K", target: "H.264 1080p"))
        XCTAssertEqual(s.videoFlow.text, "HEVC 4K → H.264 1080p")
    }

    func testAFullHeightTranscodeKeepsTheSourcesSizeClass() {
        var s = session(method: "transcode") {
            $0.videoDecision = "transcode"; $0.sourceVideoCodec = "hevc"; $0.sourceVideoResolution = "2160p"
            $0.sourceVideoHeight = 1600; $0.targetVideoCodec = "h264"; $0.targetResolution = "1600p"
        }
        XCTAssertEqual(s.videoFlow.text, "HEVC 4K → H.264 4K")
        s.targetResolution = "1200p"
        XCTAssertEqual(s.videoFlow.text, "HEVC 4K → H.264 1200p")
    }

    func testADirectVideoShowsOnlyTheSource() {
        let s = session {
            $0.videoDecision = "direct"; $0.sourceVideoCodec = "h264"; $0.sourceVideoResolution = "1920x1080"
            $0.targetVideoCodec = "hevc"
        }
        XCTAssertEqual(s.videoFlow, MediaFlow(source: "H.264 1080p", target: nil))
        XCTAssertEqual(s.videoFlow.text, "H.264 1080p")
    }

    func testATranscodeWithoutATargetShowsTheSourceOnly() {
        let s = session(method: "transcode") { $0.videoDecision = "transcode"; $0.sourceVideoCodec = "hevc" }
        XCTAssertEqual(s.videoFlow, MediaFlow(source: "HEVC", target: nil))
        XCTAssertNil(session(method: "transcode").videoFlow.text)
    }

    func testAudioUsesTheTargetChannelsOnlyWhenReported() {
        var s = session(method: "direct") {
            $0.audioDecision = "transcode"; $0.sourceAudioCodec = "truehd"; $0.sourceAudioChannels = 8
            $0.targetAudioCodec = "aac"
        }
        XCTAssertEqual(s.audioFlow.text, "TrueHD 7.1 → AAC")
        s.targetAudioChannels = 6
        XCTAssertEqual(s.audioFlow.text, "TrueHD 7.1 → AAC 5.1")
    }

    func testATranscodedAudioWithoutATargetCodecAssumesAac() {
        let s = session { $0.audioDecision = "transcode"; $0.sourceAudioCodec = "dts"; $0.sourceAudioChannels = 6 }
        XCTAssertEqual(s.audioFlow.text, "DTS 5.1 → AAC")
    }

    func testADirectAudioShowsTheSourceFormat() {
        let s = session {
            $0.audioDecision = "direct"; $0.sourceAudioCodec = "eac3"; $0.sourceAudioChannels = 6; $0.targetAudioCodec = "aac"
        }
        XCTAssertEqual(s.audioFlow.text, "EAC3 5.1")
        XCTAssertNil(session().audioFlow.text)
    }

    // MARK: transcode details

    func testHardwareAccelerationIsNamedLikeTheWeb() {
        func mode(_ accel: String?) -> TranscodeMode? {
            session(method: "transcode") { $0.videoDecision = "transcode"; $0.transcodeHWAccel = accel }.transcodeMode
        }
        XCTAssertEqual(mode("nvenc"), .hardware("NVENC"))
        XCTAssertEqual(mode("vaapi"), .hardware("VAAPI"))
        XCTAssertEqual(mode("qsv"), .hardware("QSV"))
        XCTAssertEqual(mode("videotoolbox"), .hardware("VideoToolbox"))
        XCTAssertEqual(mode("none"), .software)
        XCTAssertEqual(mode("auto"), .pending)
        XCTAssertEqual(mode(nil), .unknown)
        XCTAssertEqual(mode(" "), .unknown)
    }

    func testAnAudioOnlyTranscodeHasNoEncoderMode() {
        let s = session { $0.videoDecision = "direct"; $0.audioDecision = "transcode"; $0.transcodeHWAccel = "nvenc" }
        XCTAssertEqual(s.transcodeMode, .audioOnly)
    }

    func testNothingTranscodedHasNoMode() {
        XCTAssertNil(session { $0.videoDecision = "direct"; $0.audioDecision = "direct"; $0.transcodeHWAccel = "nvenc" }.transcodeMode)
    }

    func testToneMappingNeedsATranscodedVideoAndAConfirmedExecutor() {
        func tone(_ mode: String?, video: String = "transcode") -> ToneMap? {
            session { $0.videoDecision = video; $0.toneMapMode = mode }.toneMap
        }
        XCTAssertEqual(tone("hardware"), .hardware)
        XCTAssertEqual(tone(" Software "), .software)
        XCTAssertNil(tone("other"))
        XCTAssertNil(tone(nil))
        XCTAssertNil(tone("hardware", video: "direct"))
    }

    // MARK: delivery and route

    func testADirectPlayDeliversTheSourceContainer() {
        let s = session(method: "direct") { $0.sourceContainer = "mkv"; $0.outputContainer = "fmp4" }
        XCTAssertEqual(s.sourceContainerLabel, "MKV")
        XCTAssertEqual(s.deliveredContainerLabel, "MKV")
    }

    func testATranscodeDeliversWhatTheNodeReported() {
        let base = session(method: "transcode") { $0.sourceContainer = "mkv" }
        func delivered(container: String? = nil, proto: String? = nil) -> String? {
            var s = base
            s.outputContainer = container
            s.outputProtocol = proto
            return s.deliveredContainerLabel
        }
        XCTAssertEqual(delivered(container: "fmp4"), "fMP4")
        XCTAssertEqual(delivered(container: "mpegts", proto: "hls"), "HLS · MPEG-TS")
        XCTAssertEqual(delivered(container: "webm", proto: "hls"), "HLS · WEBM")
        XCTAssertEqual(delivered(proto: "hls"), "HLS")
        XCTAssertNil(delivered())
    }

    func testWithoutRoutingFieldsTheLegacyNodeIsShown() {
        XCTAssertEqual(session { $0.nodeDisplayName = "edge-1"; $0.reportingNode = "n1" }.routeNodes, [RouteNode(role: .node, name: "edge-1")])
        XCTAssertEqual(session { $0.reportingNode = "n1" }.routeNodes, [RouteNode(role: .node, name: "n1")])
        XCTAssertEqual(session { $0.reportingNode = "local" }.routeNodes, [RouteNode(role: .node, name: nil)])
        XCTAssertEqual(session().routeNodes, [RouteNode(role: .node, name: nil)])
    }

    func testATranscodeNodeAndAProxyEgressAreListedWorkFirst() {
        let s = session {
            $0.routingWorkload = "video_transcode"; $0.routingExecution = "transcode"; $0.routingExecutionNodeName = "gpu-1"
            $0.routingEgress = "proxy"; $0.routingEgressNodeName = "edge-eu"
        }
        XCTAssertEqual(s.routeNodes, [RouteNode(role: .transcode, name: "gpu-1"), RouteNode(role: .proxy, name: "edge-eu")])
    }

    func testAPIEgressNamesTheReportingServer() {
        var s = session { $0.routingExecution = "api"; $0.routingEgress = "api"; $0.reportingNode = "main" }
        XCTAssertEqual(s.routeNodes, [RouteNode(role: .server, name: "main")])
        s.reportingNode = "Local"
        XCTAssertEqual(s.routeNodes, [RouteNode(role: .server, name: nil)])
    }

    func testAProxyThatBothRunsAndServesIsListedOnce() {
        let s = session {
            $0.routingExecution = "proxy"; $0.routingExecutionNodeName = "edge-eu"
            $0.routingEgress = "proxy"; $0.routingEgressNodeName = "edge-eu"
        }
        XCTAssertEqual(s.routeNodes, [RouteNode(role: .proxy, name: "edge-eu")])
    }

    // MARK: the model

    func testTheV2SessionRowDecodesEveryFieldTheRowShows() throws {
        let json = """
        {"session_id":"s1","user_id":"7","username":"alex","profile_id":"p","profile_name":"Living room",
         "media_title":"Who Is Alive?","media_type":"episode","series_name":"Severance","episode_name":"Who Is Alive?",
         "season_number":2,"episode_number":3,"play_method":"transcode","reporting_node":"main",
         "node_display_name":"Main","file_duration":2652,"started_at":"2026-11-13T14:02:30.123456Z",
         "updated_at":"2026-11-13T14:14:50Z","position_seconds":754.5,"is_paused":false,"client_ip":"203.0.113.9",
         "stream_location":"remote","client_name":"Silo","client_version":"1.4.2","client_label":"Silo 1.4.2",
         "client_label_full":"Silo 1.4.2 (88)","device_platform":"ios","transcode_audio":true,
         "stream_bitrate_kbps":8200,"source_bitrate_kbps":24500,"target_bitrate_kbps":8000,
         "source_audio_channels":8,"source_audio_language":"en","source_audio_title":"Surround",
         "target_audio_channels":6,"source_video_height":1600,"source_container":"mkv","output_container":"mpegts",
         "output_protocol":"hls","tone_map_mode":"hardware","routing_workload":"video_transcode",
         "routing_execution":"transcode","routing_execution_node_name":"gpu-1","routing_egress":"api",
         "routing_egress_node_name":"x"}
        """
        let s = try JSONDecoder().decode(AdminSession.self, from: Data(json.utf8))
        XCTAssertEqual(s.profileName, "Living room")
        XCTAssertEqual(s.devicePlatform, "ios")
        XCTAssertEqual(s.transcodeAudio, true)
        XCTAssertEqual(s.clientIP, "203.0.113.9")
        XCTAssertEqual(s.streamLocation, "remote")
        XCTAssertEqual(s.sourceBitrateKbps, 24500)
        XCTAssertEqual(s.sourceAudioChannels, 8)
        XCTAssertEqual(s.targetAudioChannels, 6)
        XCTAssertEqual(s.sourceVideoHeight, 1600)
        XCTAssertEqual(s.outputProtocol, "hls")
        XCTAssertEqual(s.routingExecutionNodeName, "gpu-1")
        XCTAssertEqual(s.startedAt, "2026-11-13T14:02:30.123456Z")
        XCTAssertNil(s.videoDecision)
        XCTAssertEqual(s.streamTitle, "Severance · S2E3 · Who Is Alive?")
    }

    func testARowWithOnlyTheRequiredFieldsDecodes() throws {
        let json = #"{"session_id":"s","username":"u","media_title":"T","media_type":"movie","play_method":"direct","position_seconds":1,"file_duration":null,"is_paused":true}"#
        let s = try JSONDecoder().decode(AdminSession.self, from: Data(json.utf8))
        XCTAssertNil(s.fileDuration)
        XCTAssertNil(s.profileName)
        XCTAssertEqual(s.streamMethod, .direct)
    }
}
