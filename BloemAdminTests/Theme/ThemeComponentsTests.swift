import SwiftUI
import UIKit
import XCTest
@testable import BloemAdmin

final class StatusLabelTests: XCTestCase {
    func testOnlyAnExceptionOrLiveStateCarriesADot() {
        for tone in [StatusLabel.Tone.normal, .positive] {
            XCTAssertNotNil(StatusLabel.dotColor(for: tone), "every state, good ones included, carries a dot")
        }
        XCTAssertNotEqual(StatusLabel.dotColor(for: .normal), StatusLabel.dotColor(for: .positive))
        XCTAssertNotNil(StatusLabel.dotColor(for: .warning))
        XCTAssertNotNil(StatusLabel.dotColor(for: .failure))
        XCTAssertNotNil(StatusLabel.dotColor(for: .live))
        XCTAssertEqual(StatusLabel.dotSize, 8)
    }

    func testRedIsForFailuresAndTranscodeIsNeverRed() {
        XCTAssertEqual(StatusLabel.textColor(for: .failure), Theme.danger)
        XCTAssertNotEqual(StatusLabel.textColor(for: .warning), Theme.danger)
        XCTAssertNotEqual(PlaybackMethod.transcode.color, Theme.danger)
        XCTAssertNotEqual(StatusLabel.textColor(for: .warning), StatusLabel.textColor(for: .live))
    }

    func testPlayMethodsUseOnePaletteAndOnlyATranscodeIsLit() {
        XCTAssertEqual(PlaybackMethod(.direct), .directPlay)
        XCTAssertEqual(PlaybackMethod(.remux), .directStream)
        XCTAssertEqual(PlaybackMethod(.directStream), .directStream)
        XCTAssertEqual(PlaybackMethod(.transcode), .transcode)
        XCTAssertNil(PlaybackMethod(.unknown))
        XCTAssertEqual(PlaybackMethod.allCases.filter(\.isLit), [.transcode])
        XCTAssertEqual(PlaybackSeries.allCases.map(\.method), PlaybackMethod.allCases)
    }
}

final class FontTests: XCTestCase {
    func testPlusJakartaSansIsBundledAndRegistered() {
        XCTAssertFalse(UIFont.fontNames(forFamilyName: "Plus Jakarta Sans").isEmpty)
        XCTAssertNotNil(UIFont(name: BloemFont.familyName, size: 12))
    }
}

final class VocabularyTests: XCTestCase {
    func testServerCodesBecomeWordsAPersonWouldUse() {
        XCTAssertEqual(Vocabulary.role("admin"), "Administrator")
        XCTAssertEqual(Vocabulary.role("owner"), "Owner")
        XCTAssertEqual(Vocabulary.role("user"), "User")
        XCTAssertEqual(Vocabulary.taskState("running"), "Running")
        XCTAssertEqual(Vocabulary.invitationStatus("expired"), "Expired")
        XCTAssertEqual(Vocabulary.memberStatus("suspended"), "Suspended")
    }

    func testAnUnknownCodeIsShownAsSentenceCaseNotDropped() {
        XCTAssertEqual(Vocabulary.sentenceCase("device_name"), "Device name")
        XCTAssertEqual(Vocabulary.sentenceCase("SOME STATE"), "Some state")
        XCTAssertEqual(Vocabulary.role("auditor"), "Auditor")
        XCTAssertEqual(Vocabulary.numbered("User", 42), "User 42")
    }
}

final class SignalPathTests: XCTestCase {
    private func transcode() -> AdminSession {
        var s = AdminSession(
            sessionID: "t", username: "alex", mediaTitle: "Who Is Alive?", mediaType: "episode", playMethod: "transcode",
            positionSeconds: 754, fileDuration: 2652, isPaused: false, clientName: "Silo Android"
        )
        s.effectivePlayMethod = "transcode"; s.videoDecision = "transcode"; s.audioDecision = "transcode"
        s.sourceVideoCodec = "hevc"; s.sourceVideoResolution = "2160p"; s.targetVideoCodec = "h264"; s.targetResolution = "1080p"
        s.transcodeHWAccel = "nvenc"; s.sourceContainer = "mkv"; s.devicePlatform = "android"
        s.clientLabel = "Silo Android 1.4.2"
        return s
    }

    private func direct() -> AdminSession {
        var s = AdminSession(
            sessionID: "d", username: "amy", mediaTitle: "The River", mediaType: "movie", playMethod: "direct",
            positionSeconds: 1200, fileDuration: 5400, isPaused: true, clientName: "Web"
        )
        s.effectivePlayMethod = "direct"; s.videoDecision = "direct"; s.audioDecision = "direct"
        s.sourceVideoCodec = "h264"; s.sourceVideoResolution = "1920x1080"
        return s
    }

    func testAStreamIsDrawnAsSourcePlaybackClient() {
        let steps = SignalPath.steps(for: transcode(), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(steps.map(\.kind), [.source, .decision, .client])
        XCTAssertEqual(steps.map(\.label), ["Source", "Playback", "Client"])
        XCTAssertEqual(steps[0].value, "HEVC 4K")
        XCTAssertEqual(steps[0].detail, "MKV")
        XCTAssertEqual(steps[2].value, "Silo Android 1.4.2")
        XCTAssertEqual(steps[2].detail, "Android")
    }

    func testOnlyATranscodeStepIsLitAndItNamesWhatItConvertsTo() {
        let converted = SignalPath.steps(for: transcode(), locale: Locale(identifier: "en_US"))
        XCTAssertEqual(converted.filter(\.lit).map(\.kind), [.decision])
        XCTAssertEqual(converted[1].value, "Transcode")
        XCTAssertEqual(converted[1].detail, "H.264 1080p · HW NVENC")
        XCTAssertEqual(converted[1].method, .transcode)

        let plain = SignalPath.steps(for: direct(), locale: Locale(identifier: "en_US"))
        XCTAssertTrue(plain.filter(\.lit).isEmpty, "a direct play lights nothing")
        XCTAssertEqual(plain[1].value, "Direct play")
        XCTAssertEqual(plain[1].method, .directPlay)
        XCTAssertNil(plain[1].detail)
    }
}

final class ConcurrentStreamsStackTests: XCTestCase {
    private func series(_ json: String) throws -> Timeseries {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Timeseries.self, from: Data(json.utf8))
    }

    func testTheStackIsSplitByPlayMethodAndAddsUpToTheTotal() throws {
        let data = try series("""
        {"resolution_seconds":60,"from":"2026-11-14T10:00:00Z","to":"2026-11-14T10:02:00Z","points":[
          {"t":"2026-11-14T10:00:00Z","streams":5,"direct":2,"remux":1,"transcode":1,"egress_kbps":0},
          {"t":"2026-11-14T10:01:00Z","streams":3,"direct":3,"remux":0,"transcode":0,"egress_kbps":0},
          {"t":"2026-11-14T10:02:00Z","streams":4,"direct":1,"remux":0,"transcode":2,"egress_kbps":0}]}
        """)
        XCTAssertTrue(data.hasPlayMethodSplit)
        let layers = MethodLayer.stack(data)
        XCTAssertEqual(layers.map(\.method), [.directPlay, .directStream, .transcode])
        // Direct stream is what is left after direct play and transcode.
        XCTAssertEqual(layers[0].upper.map(\.value), [2, 3, 1])
        XCTAssertEqual(layers[1].upper.map(\.value), [4, 3, 2])
        XCTAssertEqual(layers[2].upper.map(\.value), [5, 3, 4], "the top of the stack is the total")
        XCTAssertEqual(layers[1].lower, [2, 3, 1], "each band starts where the one below ends")
    }

    func testAServerThatDoesNotReportTheSplitGetsNoLayers() throws {
        let data = try series("""
        {"resolution_seconds":60,"points":[{"t":"2026-11-14T10:00:00Z","streams":5,"egress_kbps":0}]}
        """)
        XCTAssertFalse(data.hasPlayMethodSplit)
        XCTAssertTrue(MethodLayer.stack(data).isEmpty)
    }
}

final class ScheduleWordingTests: XCTestCase {
    func testIntervalsAreWordsNotMinutesOfMinutes() {
        XCTAssertEqual(TaskTrigger.everyText(minutes: 1), "Every minute")
        XCTAssertEqual(TaskTrigger.everyText(minutes: 60), "Every hour")
        XCTAssertEqual(TaskTrigger.everyText(minutes: 1440), "Every day")
        XCTAssertTrue(TaskTrigger.everyText(minutes: 15).hasPrefix("Every 15"))
        XCTAssertTrue(TaskTrigger.everyText(minutes: 360).contains("6"))
    }
}
