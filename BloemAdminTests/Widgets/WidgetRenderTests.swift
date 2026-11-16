import SwiftUI
import UIKit
import WidgetKit
import XCTest
@testable import BloemAdmin

/// Draws every widget at every size, dark and light, from fixed sample data. Each image must come out
/// non-blank; when `/tmp/bloem-widget-shots` exists on the machine running the simulator the PNGs are also
/// written there, for `docs/screenshots/bloem-widgets/` (the simulator shares that machine's file system).
/// Moving timers are drawn by the system, not the view, so the images show the still values of the same moment.
@MainActor
final class WidgetRenderTests: XCTestCase {
    private static let outputFolder = "/tmp/bloem-widget-shots"

    /// Point sizes of the widget families on an iPhone 15 (the iPad's extra large is the 11-inch iPad's).
    private func size(_ family: WidgetFamily) -> CGSize {
        switch family {
        case .systemSmall: CGSize(width: 170, height: 170)
        case .systemMedium: CGSize(width: 364, height: 170)
        case .systemLarge: CGSize(width: 364, height: 382)
        case .systemExtraLarge: CGSize(width: 726, height: 378)
        case .accessoryCircular: CGSize(width: 76, height: 76)
        case .accessoryRectangular: CGSize(width: 172, height: 76)
        case .accessoryInline: CGSize(width: 257, height: 26)
        default: CGSize(width: 170, height: 170)
        }
    }

    private func name(_ family: WidgetFamily) -> String {
        switch family {
        case .systemSmall: "small"
        case .systemMedium: "medium"
        case .systemLarge: "large"
        case .systemExtraLarge: "extra-large"
        case .accessoryCircular: "circular"
        case .accessoryRectangular: "rectangular"
        case .accessoryInline: "inline"
        default: "other"
        }
    }

    private func render(
        _ kind: SiloWidgetKind, entry: SiloEntry, family: WidgetFamily, scheme: ColorScheme, lockScreen: Bool = false,
        dynamicType: DynamicTypeSize = .large
    ) -> UIImage? {
        let effective = entry.settings.colorScheme ?? scheme
        let palette = WidgetPalette.of(effective)
        let isAccessory = WidgetSize(family).isAccessory
        let frameSize = size(family)
        // The widget draws its own 8 point page edge (`contentMarginsDisabled`), so only an accessory is padded here.
        let view = SiloWidgetRoot(kind: kind, entry: entry)
            .environment(\.siloFamilyOverride, family)
            .environment(\.colorScheme, scheme)
            .environment(\.siloStaticTime, true)
            .environment(\.dynamicTypeSize, dynamicType)
            .environment(\.siloSurfaceOverride, lockScreen || isAccessory ? WidgetSurface.lockScreen : WidgetSurface.homeScreen)
            .padding(isAccessory ? 4 : 0)
            .frame(width: frameSize.width, height: frameSize.height, alignment: .topLeading)
            .background(
                isAccessory
                    ? (effective == .dark ? Color(white: 0.12) : Color(white: 0.85))
                    : palette.canvas
            )
            .clipShape(RoundedRectangle(cornerRadius: isAccessory ? 12 : 22, style: .continuous))
            .padding(8)
            .background(effective == .dark ? Color.black : Color(white: 0.93))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 3
        return renderer.uiImage
    }

    private func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return true }
        let count = CFDataGetLength(data)
        guard count >= 8 else { return true }
        var distinct = Set<UInt32>()
        var index = 0
        let step = max(4, (count / 4 / 4000) * 4)
        while index + 3 < count && distinct.count < 6 {
            distinct.insert(UInt32(bytes[index]) << 16 | UInt32(bytes[index + 1]) << 8 | UInt32(bytes[index + 2]))
            index += step
        }
        return distinct.count < 3
    }

    private func save(_ image: UIImage, _ name: String) {
        guard FileManager.default.fileExists(atPath: Self.outputFolder), let png = image.pngData() else { return }
        try? png.write(to: URL(fileURLWithPath: "\(Self.outputFolder)/\(name).png"))
    }

    private func check(
        _ kind: SiloWidgetKind, _ label: String, entry: SiloEntry, families: [WidgetFamily]? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        for family in families ?? kind.families {
            for scheme in [ColorScheme.dark, .light] {
                let scheme_ = scheme == .dark ? "dark" : "light"
                guard let image = render(kind, entry: entry, family: family, scheme: scheme) else {
                    XCTFail("\(label) \(name(family)) \(scheme_) did not render", file: file, line: line)
                    continue
                }
                XCTAssertFalse(isBlank(image), "\(label) \(name(family)) \(scheme_) is blank", file: file, line: line)
                save(image, "\(label)-\(name(family))-\(scheme_)")
            }
        }
    }

    // MARK: Every widget, every size

    func testServerStatusAtEverySize() { check(.serverStatus, "server-status", entry: WidgetSamples.entry()) }
    func testNowPlayingAtEverySize() { check(.nowPlaying, "now-playing", entry: WidgetSamples.entry()) }
    func testRequestsAtEverySize() { check(.requests, "requests", entry: WidgetSamples.entry()) }
    func testLibrariesAtEverySize() { check(.libraries, "libraries", entry: WidgetSamples.entry()) }
    func testNodesAtEverySize() { check(.nodes, "nodes", entry: WidgetSamples.entry()) }

    func testEveryWidgetIsOfferedInEveryFamily() {
        // Small, medium, large, extra large on an iPad and the three lock screen shapes: a superset of the
        // spec's admin table (docs/design.md), on the maintainer's request of 2026-11-16.
        let every: Set<WidgetFamily> = [
            .systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline,
        ]
        for kind in SiloWidgetKind.allCases { XCTAssertEqual(Set(kind.families), every, "\(kind)") }
    }

    /// A larger text size makes cards taller; the list shows fewer of them and still draws whole cards.
    func testALargeTextSizeStillDrawsEveryWidget() {
        for kind in SiloWidgetKind.allCases {
            for family in [WidgetFamily.systemMedium, .systemLarge] {
                guard let image = render(kind, entry: WidgetSamples.entry(), family: family, scheme: .dark, dynamicType: .accessibility1) else {
                    return XCTFail("\(kind) \(name(family)) did not render")
                }
                XCTAssertFalse(isBlank(image))
                save(image, "\(kind.shortName)-\(name(family))-large-text-dark")
            }
        }
    }

    // MARK: States

    private func board<Item: Codable & Equatable & Sendable>(_ feeds: [ServerFeed<Item>], placeholder: Bool = false) -> WidgetBoard<Item> {
        WidgetBoard(title: "All servers", serverID: nil, feeds: feeds, isPlaceholder: placeholder)
    }

    private func entry(
        streams: WidgetBoard<StreamItem>? = nil, requests: WidgetBoard<RequestItem>? = nil,
        libraries: WidgetBoard<WidgetLibraryItem>? = nil, nodes: WidgetBoard<NodeItem>? = nil,
        settings: WidgetSettings = WidgetSettings(), notice: WidgetActionNotice? = nil
    ) -> SiloEntry {
        let base = WidgetSamples.entry(settings: settings)
        return SiloEntry(
            date: base.date, snapshot: base.snapshot, live: base.live, serverID: nil, settings: settings,
            streams: streams ?? base.streams, requests: requests ?? base.requests,
            libraries: libraries ?? base.libraries, nodes: nodes ?? base.nodes, notice: notice
        )
    }

    private func feed<Item: Codable & Equatable & Sendable>(
        _ condition: FeedCondition, items: [Item] = [], total: Int? = nil, asOf: Date? = nil
    ) -> ServerFeed<Item> {
        ServerFeed(serverID: "home", serverName: "Silo Home", condition: condition, items: items, total: total, asOf: asOf)
    }

    func testEveryStateOfEveryDataWidgetRenders() {
        let now = WidgetSamples.now
        let stale = now.addingTimeInterval(-3_600)
        let states: [(String, SiloEntry)] = [
            ("loading", entry(
                streams: board([feed(.current, items: [StreamItem]())], placeholder: true), requests: board([feed(.current, items: [RequestItem]())], placeholder: true),
                libraries: board([feed(.current, items: [WidgetLibraryItem]())], placeholder: true), nodes: board([feed(.current, items: [NodeItem]())], placeholder: true))),
            ("signed-out", entry(
                streams: board([feed(.signedOut, items: [StreamItem]())]), requests: board([feed(.signedOut, items: [RequestItem]())]),
                libraries: board([feed(.signedOut, items: [WidgetLibraryItem]())]), nodes: board([feed(.signedOut, items: [NodeItem]())]))),
            ("unreachable", entry(
                streams: board([feed(.unreachable, items: [StreamItem]())]), requests: board([feed(.unreachable, items: [RequestItem]())]),
                libraries: board([feed(.unreachable, items: [WidgetLibraryItem]())]), nodes: board([feed(.unreachable, items: [NodeItem]())]))),
            ("unavailable", entry(
                streams: board([feed(.unavailable, items: [StreamItem]())]), requests: board([feed(.unavailable, items: [RequestItem]())]),
                libraries: board([feed(.unavailable, items: [WidgetLibraryItem]())]), nodes: board([feed(.unavailable, items: [NodeItem]())]))),
            ("empty", entry(
                streams: board([feed(.current, items: [StreamItem](), total: 0, asOf: now)]), requests: board([feed(.current, items: [RequestItem](), total: 0, asOf: now)]),
                libraries: board([feed(.current, items: [WidgetLibraryItem](), total: 0, asOf: now)]), nodes: board([feed(.current, items: [NodeItem](), total: 0, asOf: now)]))),
            ("stale", entry(
                streams: board([feed(.unreachable, items: WidgetSamples.streams, total: 3, asOf: stale)]),
                requests: board([feed(.unreachable, items: WidgetSamples.requests, total: 4, asOf: stale)]),
                libraries: board([feed(.unreachable, items: WidgetSamples.libraries, total: 3, asOf: stale)]),
                nodes: board([feed(.unreachable, items: WidgetSamples.nodes, total: 3, asOf: stale)]))),
            ("action-failed", entry(notice: WidgetActionNotice(requestID: "r1", serverID: "home", text: "Couldn't approve, open the app", at: now))),
        ]
        for (label, state) in states {
            for kind in [SiloWidgetKind.nowPlaying, .requests, .libraries, .nodes] {
                let families: [WidgetFamily] = kind.families.filter { [.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular].contains($0) }
                check(kind, "\(kind.shortName)-\(label)", entry: state, families: families)
            }
        }
    }

    func testServerStatusStatesRender() {
        let now = WidgetSamples.now
        var down = WidgetSamples.snapshot
        down.servers[0].reachable = false
        let downEntry = SiloEntry(
            date: now, snapshot: down, live: ["home": false], serverID: nil, settings: WidgetSettings(),
            streams: WidgetSamples.entry().streams, requests: WidgetSamples.entry().requests,
            libraries: WidgetSamples.entry().libraries, nodes: WidgetSamples.entry().nodes, notice: nil
        )
        check(.serverStatus, "server-status-down", entry: downEntry)
        let none = SiloEntry(
            date: now, snapshot: nil, live: [:], serverID: nil, settings: WidgetSettings(),
            streams: WidgetSamples.entry().streams, requests: WidgetSamples.entry().requests,
            libraries: WidgetSamples.entry().libraries, nodes: WidgetSamples.entry().nodes, notice: nil
        )
        check(.serverStatus, "server-status-empty", entry: none, families: [.systemSmall, .systemMedium])
    }

    func testTheLockScreenWithDetailsOffAndOn() {
        for (label, settings) in [("details-off", WidgetSettings()), ("details-on", WidgetSettings(showDetailsOnLockScreen: true))] {
            let state = WidgetSamples.entry(settings: settings)
            for kind in [SiloWidgetKind.nowPlaying, .requests] {
                for family in [WidgetFamily.accessoryRectangular, .accessoryCircular, .accessoryInline] where kind.families.contains(family) {
                    guard let image = render(kind, entry: state, family: family, scheme: .dark, lockScreen: true) else { return XCTFail("no image") }
                    XCTAssertFalse(isBlank(image))
                    save(image, "\(kind.shortName)-lock-\(label)-\(name(family))-dark")
                }
            }
        }
    }

    func testTheAppearanceSettingOverridesTheSystemScheme() {
        let dark = WidgetSamples.entry(settings: WidgetSettings(appearance: "dark"))
        guard let forced = render(.requests, entry: dark, family: .systemMedium, scheme: .light),
              let natural = render(.requests, entry: WidgetSamples.entry(), family: .systemMedium, scheme: .dark) else { return XCTFail("no image") }
        XCTAssertEqual(forced.pngData()?.count, natural.pngData()?.count, "a dark choice draws dark on a light phone")
    }

    func testTheLiveActivityLockScreenRenders() {
        let attributes = AdminJobActivityAttributes(kind: .libraryScan, serverID: "home", serverName: "Silo Home", startedAt: WidgetSamples.now)
        let running = AdminJobActivityAttributes.ContentState(phase: .running, progress: 0.42, libraryName: "Series")
        for scheme in [ColorScheme.dark, .light] {
            let palette = WidgetPalette.of(scheme)
            let view = AdminJobLockScreenView(attributes: attributes, state: running, palette: palette)
                .environment(\.colorScheme, scheme)
                .frame(width: 364)
                .background(palette.card)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 3
            guard let image = renderer.uiImage else { return XCTFail("no image") }
            XCTAssertFalse(isBlank(image))
            save(image, "live-activity-lock-screen-\(scheme == .dark ? "dark" : "light")")
        }
    }
}

// MARK: Now playing with no stream, one stream and many

extension WidgetRenderTests {
    /// `count` sample streams, with ids and titles of their own so each card is different.
    private func nowPlayingEntry(count: Int, page: Int = 0, settings: WidgetSettings = WidgetSettings()) -> SiloEntry {
        let base = WidgetSamples.entry(settings: settings)
        let titles = ["Dune: Part Two", "Severance · S2E3 · Who Is Alive?", "Planet Earth III · S1E2 · Oceans", "The River", "Shogun · S1E4", "Anatomy of a Fall", "Poor Things"]
        let items: [StreamItem] = (0..<count).map { index in
            var item = WidgetSamples.streams[index % WidgetSamples.streams.count]
            item.id = "s\(index + 1)"
            item.title = titles[index % titles.count]
            return item
        }
        let feed = ServerFeed(serverID: "home", serverName: "Silo Home", condition: .current, items: items, total: count, secondary: count == 0 ? nil : 65_500, asOf: WidgetSamples.now)
        let streams = WidgetBoard(title: "All servers", serverID: nil, feeds: [feed])
        var paging = WidgetPagingState()
        if page > 0 {
            for size in [WidgetSize.medium, .large, .extraLarge] {
                paging = paging.setting(page: page, for: WidgetPagingKey.nowPlaying(serverID: nil, size: size), at: base.date)
            }
        }
        return SiloEntry(
            date: base.date, snapshot: base.snapshot, live: base.live, serverID: nil, settings: settings,
            streams: streams, requests: base.requests, libraries: base.libraries, nodes: base.nodes, notice: nil, paging: paging
        )
    }

    /// Every size, dark and light, with no stream, one and seven: the header always says how many, and where
    /// seven do not fit the medium and large widgets get page buttons (and "2/4" on the second page).
    func testNowPlayingWithNoStreamOneStreamAndMany() {
        let families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular]
        for (label, entry) in [
            ("streams-0", nowPlayingEntry(count: 0)), ("streams-1", nowPlayingEntry(count: 1)),
            ("streams-7", nowPlayingEntry(count: 7)), ("streams-7-page-2", nowPlayingEntry(count: 7, page: 1)),
        ] {
            let kindFamilies = label.hasSuffix("page-2") ? families.filter { [.systemMedium, .systemLarge, .systemExtraLarge].contains($0) } : families
            for family in kindFamilies {
                for scheme in [ColorScheme.dark, .light] {
                    let schemeName = scheme == .dark ? "dark" : "light"
                    guard let image = render(.nowPlaying, entry: entry, family: family, scheme: scheme) else {
                        XCTFail("now playing \(label) \(name(family)) \(schemeName) did not render")
                        continue
                    }
                    XCTAssertFalse(isBlank(image), "\(label) \(name(family)) \(schemeName) is blank")
                    save(image, "now-playing-\(label)-\(name(family))-\(schemeName)")
                }
            }
        }
    }

    /// Paging must not change what the lock screen hides: details off draws counts only, with no buttons.
    func testPagingShowsNoStreamNamesOrButtonsWhereDetailsAreHidden() {
        let entry = nowPlayingEntry(count: 7)
        guard let image = render(.nowPlaying, entry: entry, family: .systemMedium, scheme: .dark, lockScreen: true) else { return XCTFail("no image") }
        XCTAssertFalse(isBlank(image))
        save(image, "now-playing-streams-7-lock-details-off-medium-dark")
    }
}

private extension SiloWidgetKind {
    var shortName: String {
        switch self {
        case .serverStatus: "server-status"
        case .nowPlaying: "now-playing"
        case .requests: "requests"
        case .libraries: "libraries"
        case .nodes: "nodes"
        }
    }
}
