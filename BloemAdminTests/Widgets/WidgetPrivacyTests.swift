import SwiftUI
import WidgetKit
import XCTest
@testable import BloemAdmin

/// The lock screen, StandBy and Always On show counts and statuses only, unless the per-device setting is on.
/// The app's own lock does not change what a home-screen widget shows (maintainer, 2026-11-15).
final class WidgetPrivacyTests: XCTestCase {
    private let now = WidgetSamples.now
    private var off: WidgetSettings { WidgetSettings(showDetailsOnLockScreen: false) }
    private var on: WidgetSettings { WidgetSettings(showDetailsOnLockScreen: true) }

    private func context(_ size: WidgetSize, _ surface: WidgetSurface, _ settings: WidgetSettings) -> WidgetContext {
        WidgetContext(size: size, surface: surface, settings: settings, now: now)
    }

    // MARK: Surfaces

    func testEveryAccessoryFamilyIsALockScreenSurface() {
        for family in [WidgetFamily.accessoryCircular, .accessoryRectangular, .accessoryInline] {
            XCTAssertEqual(WidgetSurface.of(family: family, isLuminanceReduced: false, showsContainerBackground: true), .lockScreen)
        }
    }

    func testAHomeScreenWidgetIsOnTheHomeScreenUnlessTheScreenIsDimmedOrTheBackgroundIsGone() {
        XCTAssertEqual(WidgetSurface.of(family: .systemMedium, isLuminanceReduced: false, showsContainerBackground: true), .homeScreen)
        XCTAssertEqual(WidgetSurface.of(family: .systemSmall, isLuminanceReduced: true, showsContainerBackground: true), .lockScreen, "Always On")
        XCTAssertEqual(WidgetSurface.of(family: .systemSmall, isLuminanceReduced: false, showsContainerBackground: false), .lockScreen, "StandBy")
    }

    func testDetailsDefaultToOffAndAMissingSettingsFileIsPrivate() throws {
        XCTAssertFalse(WidgetSettings().showDetailsOnLockScreen)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWidgetSettingsStore(directory: directory)
        XCTAssertEqual(store.load(), WidgetSettings())
        try Data("{".utf8).write(to: directory.appendingPathComponent(FileWidgetSettingsStore.fileName))
        XCTAssertFalse(store.load().showDetailsOnLockScreen, "an unreadable file is the private choice")
    }

    func testTheHomeScreenShowsDetailsAndTheLockScreenOnlyWhenTheSettingIsOn() {
        XCTAssertTrue(WidgetSurface.homeScreen.showsDetails(off))
        XCTAssertFalse(WidgetSurface.lockScreen.showsDetails(off))
        XCTAssertTrue(WidgetSurface.lockScreen.showsDetails(on))
    }

    func testTheSettingsFileRoundTripsAndTheAppearanceOverridesTheScheme() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileWidgetSettingsStore(directory: directory)
        let settings = WidgetSettings(showDetailsOnLockScreen: true, appearance: "dark")
        try store.save(settings)
        XCTAssertEqual(store.load(), settings)
        XCTAssertEqual(settings.colorScheme, .dark)
        XCTAssertEqual(WidgetSettings(appearance: "light").colorScheme, .light)
        XCTAssertNil(WidgetSettings(appearance: "system").colorScheme)
        XCTAssertNil(WidgetSettings(appearance: "nonsense").colorScheme)
    }

    // MARK: No names when details are off

    private func allText(_ rows: [StreamItem]) -> String {
        rows.flatMap { [$0.user, $0.title, $0.userLine, $0.clientLine ?? "", $0.source ?? ""] }.joined(separator: " ")
    }

    func testNowPlayingDrawsNoUserOrTitleOnTheLockScreenByDefault() {
        let board = WidgetSamples.entry().streams
        let figures = NowPlayingFigures(board: board)
        let locked = figures.visibleRows(context(.rectangular, .lockScreen, off))
        XCTAssertTrue(locked.isEmpty)
        XCTAssertEqual(figures.total, 4, "the count stays")
        XCTAssertEqual(figures.transcodes, 1)
        for name in ["maria", "jonas", "amira", "tomas", "Dune", "Severance", "Planet Earth", "The River"] {
            XCTAssertFalse(allText(locked).contains(name))
        }
    }

    func testNowPlayingDrawsRowsOnTheLockScreenWhenTheSettingIsOn() {
        let figures = NowPlayingFigures(board: WidgetSamples.entry().streams)
        XCTAssertEqual(figures.visibleRows(context(.rectangular, .lockScreen, on)).count, 4)
    }

    func testNowPlayingDrawsRowsOnTheHomeScreenWhateverTheSetting() {
        let figures = NowPlayingFigures(board: WidgetSamples.entry().streams)
        XCTAssertEqual(figures.visibleRows(context(.medium, .homeScreen, off)).count, 4)
    }

    func testStandByAndAlwaysOnHideTheRowsOfAHomeSizedWidget() {
        let figures = NowPlayingFigures(board: WidgetSamples.entry().streams)
        let standBy = WidgetSurface.of(family: .systemSmall, isLuminanceReduced: false, showsContainerBackground: false)
        XCTAssertTrue(figures.visibleRows(context(.small, standBy, off)).isEmpty)
    }

    func testRequestsDrawNoTitleOrRequesterOnTheLockScreenByDefault() {
        let figures = RequestsFigures(board: WidgetSamples.entry().requests)
        XCTAssertTrue(figures.visibleRows(context(.rectangular, .lockScreen, off)).isEmpty)
        XCTAssertEqual(figures.pending, 4, "the count stays")
        XCTAssertEqual(figures.visibleRows(context(.medium, .homeScreen, off)).count, 4)
        XCTAssertEqual(figures.visibleRows(context(.rectangular, .lockScreen, on)).count, 4)
    }

    func testRequestsListTheNewestFirst() {
        var board = WidgetSamples.entry().requests
        board.feeds[0].items.reverse()
        let figures = RequestsFigures(board: board)
        XCTAssertEqual(figures.rows.map(\.id), ["r1", "r2", "r3", "r4"])
    }

    // MARK: Look

    /// The one place a name can reach a lock screen is a row; each layout draws rows only through `visibleRows`.
    func testNoLayoutReadsRowsWithoutThePrivacyGate() throws {
        for file in ["NowPlayingWidgetView.swift", "RequestsWidgetView.swift"] {
            let source = try SourceTree.sources(in: "BloemAdmin/Shared/Widgets/Views").first { $0.path == file }
            let lines = try XCTUnwrap(source).lines
            for (index, line) in lines.enumerated() where line.contains("figures.rows") {
                XCTFail("\(file):\(index + 1) draws figures.rows without visibleRows: \(line)")
            }
        }
    }
}
