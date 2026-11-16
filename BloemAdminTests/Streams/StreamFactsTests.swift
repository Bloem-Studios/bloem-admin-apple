import XCTest
@testable import BloemAdmin

/// The wording a row and its expanded details show, built from the presentation rules. The test
/// host runs in the source language, so these assert the web admin's English wording.
final class StreamFactsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let us = Locale(identifier: "en_US")

    private var episode: AdminSession {
        var s = AdminSession(
            sessionID: "ep", username: "alex", mediaTitle: "Who Is Alive?", mediaType: "episode", playMethod: "transcode",
            positionSeconds: 754, fileDuration: 2652, isPaused: false, clientName: "Silo Android"
        )
        s.profileName = "Living room"; s.devicePlatform = "android"
        s.clientLabel = "Silo Android 1.4.2"; s.clientLabelFull = "Silo Android 1.4.2 (88) beta"; s.clientIP = "203.0.113.9"
        s.streamBitrateKbps = 8200; s.videoDecision = "transcode"; s.audioDecision = "transcode"
        s.effectivePlayMethod = "transcode"; s.transcodeHWAccel = "nvenc"; s.toneMapMode = "hardware"
        s.sourceVideoCodec = "hevc"; s.sourceVideoResolution = "2160p"; s.targetVideoCodec = "h264"; s.targetResolution = "1080p"
        s.sourceAudioCodec = "truehd"; s.sourceAudioChannels = 8; s.sourceAudioLanguage = "en"; s.targetAudioCodec = "aac"
        s.targetAudioChannels = 6; s.seriesName = "Severance"; s.episodeName = "Who Is Alive?"; s.seasonNumber = 2; s.episodeNumber = 3
        s.sourceContainer = "mkv"; s.sourceBitrateKbps = 24_500; s.outputContainer = "mpegts"; s.outputProtocol = "hls"
        s.streamLocation = "remote"; s.startedAt = "2026-11-13T14:02:30Z"; s.updatedAt = "2026-11-13T14:14:50Z"
        s.sourceAudioTitle = "Surround"
        s.routingWorkload = "video_transcode"; s.routingExecution = "transcode"; s.routingExecutionNodeName = "gpu-1"
        s.routingEgress = "api"; s.reportingNode = "main"
        return s
    }

    private var direct: AdminSession {
        var s = AdminSession(
            sessionID: "film", username: "amy", mediaTitle: "The River", mediaType: "movie", playMethod: "direct",
            positionSeconds: 1200, fileDuration: 5400, isPaused: true, clientName: "Web"
        )
        s.videoDecision = "direct"; s.audioDecision = "direct"; s.effectivePlayMethod = "direct"
        s.sourceVideoCodec = "h264"; s.sourceVideoResolution = "1920x1080"; s.sourceAudioCodec = "eac3"; s.sourceAudioChannels = 6
        return s
    }

    private var bare: AdminSession {
        AdminSession(
            sessionID: "bare", username: "kim", mediaTitle: "Live channel", mediaType: "movie", playMethod: "",
            positionSeconds: 61, fileDuration: nil, isPaused: false, clientName: nil
        )
    }

    // MARK: row lines

    func testATranscodeRowReadsLikeTheWeb() {
        // A fixed locale: the bitrate's decimal mark follows the device's region.
        let facts = StreamFacts(episode, locale: us)
        XCTAssertEqual(facts.methodLabel, "Transcode")
        XCTAssertEqual(facts.stateLabel, "Playing")
        XCTAssertEqual(facts.videoLine, "Video: Transcode · HEVC 4K → H.264 1080p")
        XCTAssertEqual(facts.audioLine, "Audio: Transcode · TrueHD 7.1 → AAC 5.1 · English")
        XCTAssertEqual(facts.extrasLine, "HW NVENC · HW tone map · 8.2 Mbps")
    }

    func testMethodNamesUseTheWebsWords() {
        func label(_ effective: String?) -> String { StreamFacts(AdminSession.methodProbe(effective)).methodLabel }
        XCTAssertEqual(label("direct"), "Direct play")
        XCTAssertEqual(label("remux"), "Remux")
        XCTAssertEqual(label("direct_stream"), "Direct stream")
        XCTAssertEqual(label("transcode"), "Transcode")
        XCTAssertEqual(label("new"), "Unknown")
    }

    func testAPausedDirectPlayShowsNoConversion() {
        let facts = StreamFacts(direct)
        XCTAssertEqual(facts.stateLabel, "Paused")
        XCTAssertEqual(facts.methodLabel, "Direct play")
        XCTAssertEqual(facts.videoLine, "Video: Direct · H.264 1080p")
        XCTAssertEqual(facts.audioLine, "Audio: Direct · EAC3 5.1")
        XCTAssertNil(facts.extrasLine)
    }

    func testACopiedStreamNamesTheDecisionCopy() {
        var s = direct
        s.videoDecision = "copy"; s.effectivePlayMethod = "remux"
        XCTAssertEqual(StreamFacts(s).videoLine, "Video: Copy · H.264 1080p")
    }

    func testARowWithNothingButTheRequiredFieldsLeavesEverythingElseOut() {
        let facts = StreamFacts(bare)
        XCTAssertEqual(facts.methodLabel, "Unknown")
        XCTAssertNil(facts.videoLine)
        XCTAssertNil(facts.audioLine)
        XCTAssertNil(facts.extrasLine)
        XCTAssertNil(bare.streamClientLine)
    }

    func testAnAudioOnlyTranscodeNamesTheWorkNotAnEncoderMode() {
        var s = direct
        s.audioDecision = "transcode"; s.effectivePlayMethod = "direct_stream"; s.streamBitrateKbps = 640
        XCTAssertEqual(StreamFacts(s).extrasLine, "Audio transcode · 640 kbps")
    }

    func testEncoderModesReadLikeTheWeb() {
        func extras(_ accel: String?) -> String? {
            var s = episode
            s.toneMapMode = nil; s.streamBitrateKbps = nil; s.transcodeHWAccel = accel
            return StreamFacts(s).extrasLine
        }
        XCTAssertEqual(extras("none"), "SW")
        XCTAssertEqual(extras("auto"), "HW/SW pending")
        XCTAssertEqual(extras(nil), "HW/SW unknown")
        XCTAssertEqual(extras("vaapi"), "HW VAAPI")
    }

    // MARK: accessibility

    func testTheDescriptionReadsTheKeyFactsAtTheReportedPosition() {
        let text = StreamFacts(episode).accessibilityDescription(for: episode)
        for fragment in [
            "Severance · S2E3 · Who Is Alive?", "alex · Living room", "Silo Android 1.4.2 · Android", "Playing", "Transcode",
            "12:34 of 44:12, 31m left", "HEVC 4K → H.264 1080p", "TrueHD 7.1 → AAC 5.1", "HW NVENC",
        ] {
            XCTAssertTrue(text.contains(fragment), "description lacks \"\(fragment)\": \(text)")
        }
    }

    func testTheDescriptionWithoutALengthGivesThePositionOnly() {
        let text = StreamFacts(bare).accessibilityDescription(for: bare)
        XCTAssertTrue(text.contains("at 1:01"), text)
        XCTAssertFalse(text.contains("left"), text)
    }

    // MARK: details

    private func rows(_ s: AdminSession, ip: Bool = false) -> [(String, String)] {
        streamDetailRows(s, showClientIP: ip, timeZone: utc, locale: us).map { ($0.label, $0.value) }
    }

    func testTheDetailsListWhatSupportNeedsInOrder() {
        let labels = rows(episode, ip: true).map(\.0)
        XCTAssertEqual(labels, [
            "Method", "Video", "Audio", "Audio track", "Transcoder", "Container", "Source bitrate", "Stream bitrate",
            "Client", "Playing node", "Network", "Client IP", "Started", "Last update",
        ])
    }

    func testTheDetailValues() {
        let d = Dictionary(uniqueKeysWithValues: rows(episode, ip: true))
        XCTAssertEqual(d["Method"], "Transcode")
        XCTAssertEqual(d["Video"], "HEVC 4K · Output → H.264 1080p")
        XCTAssertEqual(d["Audio"], "TrueHD 7.1 · Output → AAC 5.1")
        XCTAssertEqual(d["Audio track"], "Surround · English")
        XCTAssertEqual(d["Transcoder"], "HW NVENC · HW tone map")
        XCTAssertEqual(d["Container"], "MKV → HLS · MPEG-TS")
        XCTAssertEqual(d["Source bitrate"], "24.5 Mbps")
        XCTAssertEqual(d["Stream bitrate"], "8.2 Mbps")
        XCTAssertEqual(d["Client"], "Silo Android 1.4.2 (88) beta")
        XCTAssertEqual(d["Playing node"], "Transcode: gpu-1, Server: main")
        XCTAssertEqual(d["Network"], "Remote")
        XCTAssertEqual(d["Client IP"], "203.0.113.9")
        XCTAssertTrue(d["Started"]?.contains("Nov 13, 2026") == true)
        XCTAssertTrue(d["Last update"]?.contains("2:14") == true)
    }

    func testTheClientAddressIsOnlyThereWhenAsked() {
        XCTAssertFalse(rows(episode).map(\.0).contains("Client IP"))
        XCTAssertFalse(rows(episode).map(\.1).contains("203.0.113.9"))
        XCTAssertTrue(rows(episode, ip: true).map(\.0).contains("Client IP"))
        // Asked for, but the server sent none: no empty row.
        var none = episode
        none.clientIP = "  "
        XCTAssertFalse(rows(none, ip: true).map(\.0).contains("Client IP"))
    }

    func testDirectDetailsSayNoConversionAndLeaveOutWhatIsMissing() {
        let d = Dictionary(uniqueKeysWithValues: rows(direct))
        XCTAssertEqual(d["Video"], "H.264 1080p · No video conversion")
        XCTAssertEqual(d["Audio"], "EAC3 5.1 · No audio conversion")
        XCTAssertNil(d["Transcoder"])
        XCTAssertNil(d["Container"])
        XCTAssertNil(d["Network"])
        XCTAssertNil(d["Started"])
        XCTAssertEqual(d["Playing node"], "Node: Local server")
    }

    func testCopiedAndUnreportedComponentsAreWorded() {
        var s = direct
        s.videoDecision = "copy"; s.sourceVideoCodec = nil; s.sourceVideoResolution = nil
        let d = Dictionary(uniqueKeysWithValues: rows(s))
        XCTAssertEqual(d["Video"], "Unknown source · Copied without re-encoding")
    }

    func testATranscodeWithoutATargetSaysTranscoding() {
        var s = episode
        s.targetVideoCodec = nil; s.targetResolution = nil
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: rows(s))["Video"], "HEVC 4K · Transcoding")
    }

    func testABareRowHasNoDetailsButTheMethodAndNode() {
        XCTAssertEqual(rows(bare).map(\.0), ["Method", "Playing node"])
    }
}

extension AdminSession {
    /// A minimal session carrying only an effective play method, for naming it.
    fileprivate static func methodProbe(_ effective: String?) -> AdminSession {
        var s = AdminSession(
            sessionID: "p", username: "u", mediaTitle: "T", mediaType: "movie", playMethod: "direct",
            positionSeconds: 0, fileDuration: nil, isPaused: false, clientName: nil
        )
        s.effectivePlayMethod = effective
        return s
    }
}
