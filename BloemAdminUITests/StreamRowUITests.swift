import XCTest

/// The Now playing row and the details it opens to, on the app's fixture page
/// (`--ui-testing-stream-rows`), which shows fixed sessions with no server behind them.
final class StreamRowUITests: XCTestCase {
    @MainActor
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        // The wording and the bitrate's decimal mark follow the device's language and region.
        app.launchArguments = ["--ui-testing-stream-rows", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        return app
    }

    @MainActor
    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor
    func testATranscodeRowShowsWhoWhatAndHowWithinTheScreen() throws {
        let app = launch()
        let row = element("stream-row.ep", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        let description = row.label
        for fragment in [
            "Severance · S2E3 · Who Is Alive?", "alex · Living room", "Silo Android 1.4.2 · Android", "Playing", "Transcode",
            "12:34 of 44:12, 31m left", "Video: Transcode · HEVC 4K → H.264 1080p",
            "Audio: Transcode · TrueHD 7.1 → AAC 5.1 · English", "HW NVENC · HW tone map · 8.2 Mbps",
        ] {
            XCTAssertTrue(description.contains(fragment), "row description lacks \"\(fragment)\": \(description)")
        }
        XCTAssertLessThanOrEqual(row.frame.maxX, app.windows.firstMatch.frame.width, "the row runs off the screen")
        XCTAssertEqual(row.value as? String, "Details hidden")
    }

    @MainActor
    func testAPausedDirectPlayAndARowWithoutLengthLeaveOutWhatIsMissing() throws {
        let app = launch()
        let film = element("stream-row.film", in: app)
        XCTAssertTrue(film.waitForExistence(timeout: 10))
        XCTAssertTrue(film.label.contains("Paused"), film.label)
        XCTAssertTrue(film.label.contains("Direct play"), film.label)
        XCTAssertTrue(film.label.contains("Video: Direct · H.264 1080p"), film.label)
        XCTAssertTrue(film.label.contains("20:00 of 1:30:00, 1h 10m left"), film.label)

        let bare = element("stream-row.bare", in: app)
        XCTAssertTrue(bare.label.contains("Live channel"), bare.label)
        XCTAssertTrue(bare.label.contains("at 1:01"), bare.label)
        XCTAssertFalse(bare.label.contains("left"), bare.label)
        XCTAssertFalse(bare.label.contains("Video:"), bare.label)
    }

    @MainActor
    func testTappingARowOpensItsDetailsAndTappingAgainClosesThem() throws {
        let app = launch()
        let row = element("stream-row.ep", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertFalse(element("stream-detail.container", in: app).exists)

        row.tap()

        XCTAssertEqual(row.value as? String, "Details shown")
        let expected: [(String, String, String)] = [
            ("container", "Container", "MKV → HLS · MPEG-TS"),
            ("sourceBitrate", "Source bitrate", "24.5 Mbps"),
            ("streamBitrate", "Stream bitrate", "8.2 Mbps"),
            ("audioTrack", "Audio track", "English"),
            ("client", "Client", "Silo Android 1.4.2 (88) beta"),
            ("node", "Playing node", "Transcode: gpu-1, Server: main"),
            ("network", "Network", "Remote"),
        ]
        for (kind, label, value) in expected {
            let detail = element("stream-detail.\(kind)", in: app)
            XCTAssertTrue(detail.waitForExistence(timeout: 5), "no \(label) line")
            XCTAssertEqual(detail.label, label)
            XCTAssertEqual(detail.value as? String, value)
        }
        XCTAssertTrue(element("stream-detail.started", in: app).exists)
        XCTAssertTrue(element("stream-detail.updated", in: app).exists)

        row.tap()
        XCTAssertEqual(row.value as? String, "Details hidden")
        XCTAssertFalse(element("stream-detail.container", in: app).exists)
    }

    @MainActor
    func testTheClientAddressShowsOnlyWhenThePageIsForThePlatformAdministrator() throws {
        let app = launch()
        let row = element("stream-row.ep", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.tap()
        XCTAssertTrue(element("stream-detail.container", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("stream-detail.clientIP", in: app).exists)

        app.switches["Platform administrator"].tap()

        let address = element("stream-detail.clientIP", in: app)
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        XCTAssertEqual(address.value as? String, "203.0.113.9")
    }

    @MainActor
    func testTheCornerControlStaysReachableAndDoesNotOpenTheRow() throws {
        let app = launch()
        let row = element("stream-row.ep", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 10))

        element("stream-actions.ep", in: app).tap()

        XCTAssertTrue(app.staticTexts["Corner taps: 1"].waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "Details hidden")
    }

    @MainActor
    func testAPreviewRowIsASummaryWithNoDetails() throws {
        let app = launch()
        let preview = element("stream-row.preview", in: app)
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(preview.label.contains("The River"), preview.label)
        XCTAssertEqual(preview.value as? String ?? "", "", "a preview must not announce details")
        XCTAssertFalse(preview.label.isEmpty)
        preview.tap()
        XCTAssertFalse(element("stream-detail.method", in: app).exists)
    }
}
