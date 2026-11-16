import AppIntents
import Foundation
import WidgetKit

// WidgetKit cannot scroll, so the Now playing widget pages instead: when there are more streams than fit, the
// header gets Up and Down buttons (iOS 17 interactive widgets, `NowPlayingPageIntent`). The page a person is
// on is kept in a small file in the App Group (`widget-paging.json`), per server choice and size, because the
// widget extension is not running between taps. Written by the intent, read by the timeline provider, and drawn
// from the entry. A page that was left alone goes back to the first after `lifetime`, so a widget does not stay
// on page 3 for the rest of the day.

/// The page of each paged widget, by `WidgetPagingKey`. Plain values, so the rules are tested without WidgetKit.
struct WidgetPagingState: Codable, Equatable, Sendable {
    static let currentVersion = 1
    /// How long a page other than the first is kept.
    static let lifetime: TimeInterval = 5 * 60

    struct Mark: Codable, Equatable, Sendable {
        var page: Int
        var at: Date
    }

    var version = WidgetPagingState.currentVersion
    var marks: [String: Mark] = [:]

    /// The page to draw: 0 is the first. A page nobody touched for `lifetime` is gone, and so is a page in the
    /// future (a clock that was set back).
    func page(for key: String, now: Date) -> Int {
        guard let mark = marks[key], mark.page > 0, mark.at <= now.addingTimeInterval(1), now.timeIntervalSince(mark.at) < Self.lifetime else { return 0 }
        return mark.page
    }

    /// The state after the person moved `key` to `page`. Page 0 is the default, so it is not stored.
    func setting(page: Int, for key: String, at now: Date) -> WidgetPagingState {
        var copy = pruned(now: now)
        if page > 0 { copy.marks[key] = Mark(page: page, at: now) } else { copy.marks[key] = nil }
        return copy
    }

    /// Without the pages that have gone back to the first.
    func pruned(now: Date) -> WidgetPagingState {
        var copy = self
        copy.marks = marks.filter { page(for: $0.key, now: now) > 0 }
        return copy
    }

    /// The moments after `date` when a stored page goes back to the first: where a widget needs a timeline entry
    /// to draw the first page again.
    func expiries(after date: Date) -> [Date] {
        marks.values.map { $0.at.addingTimeInterval(Self.lifetime) }.filter { $0 > date }.sorted()
    }
}

enum WidgetPagingKey {
    /// A Now playing widget's page is kept per server choice (or all servers) and per size, because a larger
    /// widget fits more streams and so has other pages. Two widgets of the same choice and size turn together.
    static func nowPlaying(serverID: String?, size: WidgetSize) -> String {
        "now-playing/\(serverID ?? "all")/\(sizeName(size))"
    }

    private static func sizeName(_ size: WidgetSize) -> String {
        switch size {
        case .small: "small"
        case .medium: "medium"
        case .large: "large"
        case .extraLarge: "extra-large"
        case .circular: "circular"
        case .rectangular: "rectangular"
        case .inline: "inline"
        }
    }
}

protocol WidgetPagingStoring: Sendable {
    func load() -> WidgetPagingState
    func save(_ state: WidgetPagingState) throws
}

struct FileWidgetPagingStore: WidgetPagingStoring {
    static let fileName = "widget-paging.json"

    let directory: URL

    static func appGroup() -> FileWidgetPagingStore? {
        AppGroup.containerURL.map { FileWidgetPagingStore(directory: $0) }
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Missing or unreadable means every widget is on its first page.
    func load() -> WidgetPagingState {
        guard let data = try? Data(contentsOf: fileURL),
              let state = try? JSONDecoder().decode(WidgetPagingState.self, from: data),
              state.version == WidgetPagingState.currentVersion
        else { return WidgetPagingState() }
        return state
    }

    func save(_ state: WidgetPagingState) throws {
        let data = try JSONEncoder().encode(state)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// What a tap on Up or Down does, apart from the intent shell, so it is tested without one.
enum WidgetPageRunner {
    @discardableResult
    static func run(key: String, page: Int, store: (any WidgetPagingStoring)?, now: Date = Date()) -> WidgetPagingState? {
        guard let store else { return nil }
        let state = store.load().setting(page: max(0, page), for: key, at: now)
        do {
            try store.save(state)
        } catch {
            return nil
        }
        return state
    }
}

/// Up and Down on a Now playing widget: show another page of streams. It carries the page to show, worked out by
/// the view that knows how many streams there are, so the file never holds a page past the end. It changes
/// nothing on a server, so it needs no unlock.
struct NowPlayingPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Show other streams"
    static let description = IntentDescription("Moves the Now playing widget to another page of streams")
    static let isDiscoverable = false

    @Parameter(title: "Widget")
    var key: String

    @Parameter(title: "Page")
    var page: Int

    init() {}

    init(key: String, page: Int) {
        self.key = key
        self.page = page
    }

    func perform() async throws -> some IntentResult {
        WidgetPageRunner.run(key: key, page: page, store: FileWidgetPagingStore.appGroup())
        WidgetReload.reload([.nowPlaying])
        return .result()
    }
}
