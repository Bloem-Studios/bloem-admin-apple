import SwiftUI
import WidgetKit

// The pieces every Bloem Admin widget shares: the palette, the settings the app mirrors for widgets, the
// privacy rule, and the families. Compiled into the app (so the unit tests and the screenshot tour can reach
// it) and into the widget extension.

// MARK: Palette

/// The Bloem staff look's tokens (docs/design.md) for one scheme. Widgets sit on the `card`
/// surface; the accent is used for the one figure that matters, the tally only for the dot that means live
/// or needs you.
struct WidgetPalette: Equatable, Sendable {
    /// The app's page: the widget is the page and the cards sit on it, as on the Now playing page.
    let canvas: Color
    let card: Color
    let raised: Color
    let hairline: Color
    let text: Color
    let muted: Color
    let accent: Color
    let tally: Color
    let ok: Color
    let warning: Color
    let danger: Color
    let onAccent: Color
    /// Chart order of the look: Direct play, then the rest.
    let chart: [Color]

    private static func hex(_ value: UInt32, alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255,
            opacity: alpha
        )
    }

    private static let charts: [Color] = [hex(0x5F74EE), hex(0x169E88), hex(0xBF7F22), hex(0xC2578F), hex(0x3F97CF)]

    static let dark = WidgetPalette(
        canvas: hex(0x141417), card: hex(0x1C1C20), raised: hex(0x28282E), hairline: hex(0xE8E8EC, alpha: 0.08),
        text: hex(0xE8E8EC), muted: hex(0xA4A4AE), accent: hex(0xFA6400), tally: hex(0xFA6400),
        ok: hex(0x57CB60), warning: hex(0xEAB532), danger: hex(0xF46666), onAccent: hex(0x141417), chart: charts
    )

    static let light = WidgetPalette(
        canvas: hex(0xF6F6F8), card: hex(0xFFFFFF), raised: hex(0xE9E9EE), hairline: hex(0x1A1A1F, alpha: 0.10),
        text: hex(0x1A1A1F), muted: hex(0x5A5A65), accent: hex(0xA04000), tally: hex(0xE85D00),
        ok: hex(0x1A6A2B), warning: hex(0x7F4E00), danger: hex(0xB42626), onAccent: hex(0xFFFFFF), chart: charts
    )

    static func of(_ scheme: ColorScheme) -> WidgetPalette { scheme == .dark ? .dark : .light }

    /// The colours as hex values, for the contrast test.
    struct Values: Equatable, Sendable {
        let canvas: UInt32, card: UInt32, text: UInt32, muted: UInt32, accent: UInt32, ok: UInt32, warning: UInt32, danger: UInt32
    }

    static let darkValues = Values(canvas: 0x141417, card: 0x1C1C20, text: 0xE8E8EC, muted: 0xA4A4AE, accent: 0xFA6400, ok: 0x57CB60, warning: 0xEAB532, danger: 0xF46666)
    static let lightValues = Values(canvas: 0xF6F6F8, card: 0xFFFFFF, text: 0x1A1A1F, muted: 0x5A5A65, accent: 0xA04000, ok: 0x1A6A2B, warning: 0x7F4E00, danger: 0xB42626)

    /// How a play method is drawn as a dot: the Now playing page's chart colours. Direct play is the first chart
    /// colour, direct stream and remux the second, transcode the third. Red is never a play method.
    func methodColor(_ method: StreamMethodKind) -> Color {
        switch method {
        case .direct: chart[0]
        case .remux, .directStream: chart[1]
        case .transcode: chart[2]
        case .unknown: muted
        }
    }
}

private struct WidgetPaletteKey: EnvironmentKey {
    static let defaultValue = WidgetPalette.dark
}

extension EnvironmentValues {
    var widgetPalette: WidgetPalette {
        get { self[WidgetPaletteKey.self] }
        set { self[WidgetPaletteKey.self] = newValue }
    }
}

// MARK: Settings the app mirrors

/// What the widgets need to know from the app's own settings, in a small file in the App Group
/// (`widget-settings.json`). Missing or unreadable means the most private choice: details off, system look.
struct WidgetSettings: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = WidgetSettings.currentVersion
    /// The existing per-device "Show details on the lock screen" setting (App settings, Server alerts).
    var showDetailsOnLockScreen = false
    /// `system`, `light` or `dark`: the app's Appearance setting.
    var appearance = "system"

    var colorScheme: ColorScheme? {
        switch appearance {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }
}

protocol WidgetSettingsStoring: Sendable {
    func load() -> WidgetSettings
    func save(_ settings: WidgetSettings) throws
}

struct FileWidgetSettingsStore: WidgetSettingsStoring {
    static let fileName = "widget-settings.json"

    let directory: URL

    static func appGroup() -> FileWidgetSettingsStore? {
        AppGroup.containerURL.map { FileWidgetSettingsStore(directory: $0) }
    }

    private var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    func load() -> WidgetSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? JSONDecoder().decode(WidgetSettings.self, from: data),
              settings.version == WidgetSettings.currentVersion
        else { return WidgetSettings() }
        return settings
    }

    func save(_ settings: WidgetSettings) throws {
        let data = try JSONEncoder().encode(settings)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

// MARK: Privacy

/// Where a widget is drawn. The app's own lock does not change what a home-screen widget shows (maintainer,
/// 2026-11-15): the phone's unlock is the gate. Lock screen, StandBy and Always On are seen by anyone near the
/// phone, so they show counts and statuses only unless the per-device setting is on.
enum WidgetSurface: Equatable, Sendable {
    case homeScreen, lockScreen

    static func of(family: WidgetFamily, isLuminanceReduced: Bool, showsContainerBackground: Bool) -> WidgetSurface {
        switch family {
        case .accessoryCircular, .accessoryRectangular, .accessoryInline:
            return .lockScreen
        default:
            return isLuminanceReduced || !showsContainerBackground ? .lockScreen : .homeScreen
        }
    }

    /// Whether names, titles and other details may be drawn on this surface.
    func showsDetails(_ settings: WidgetSettings) -> Bool {
        self == .homeScreen || settings.showDetailsOnLockScreen
    }
}

/// The widget's size, in the words the layouts use.
enum WidgetSize: Equatable, Sendable {
    case small, medium, large, extraLarge, circular, rectangular, inline

    init(_ family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        case .systemLarge: self = .large
        case .systemExtraLarge: self = .extraLarge
        case .accessoryCircular: self = .circular
        case .accessoryRectangular: self = .rectangular
        case .accessoryInline: self = .inline
        default: self = .small
        }
    }

    var isAccessory: Bool { self == .circular || self == .rectangular || self == .inline }
}

// MARK: Icons

/// The Lucide icons the widgets draw, from the extension's own catalog (`BloemAdminWidgets/Icons.xcassets`,
/// written by `scripts/lucide-icons.py`). Names follow `docs/design.md`.
enum WidgetIcon: String, CaseIterable, Sendable {
    case radio, inbox, library, cpu, server, archive
    case refresh = "rotate-cw"
    case warning = "triangle-alert"
    case check, x, lock
    case offline = "wifi-off"
    case arrowRight = "arrow-right"
    case chevronUp = "chevron-up"
    case chevronDown = "chevron-down"

    var assetName: String { "lucide." + rawValue }
}

struct WidgetIconView: View {
    let icon: WidgetIcon
    var size: CGFloat = 16

    var body: some View {
        Image(icon.assetName)
            .resizable()
            .renderingMode(.template)
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

// MARK: Links

enum WidgetLink {
    static func page(_ pageID: String, serverID: String?) -> URL {
        DeepLinkRoute(target: serverID.map { .server($0) } ?? .allServers, pageID: pageID).url
    }

    /// A page of one server and, on it, one item: a request or a library (the app scrolls to it and opens it).
    /// An item belongs to one server, so there is none for all servers; and an id the app's link parser would
    /// refuse leaves the link at the page, which always opens.
    static func item(_ itemID: String, on pageID: String, serverID: String) -> URL {
        let route = DeepLinkRoute(target: .server(serverID), pageID: pageID, itemID: itemID)
        return DeepLinkRoute(url: route.url) == route ? route.url : page(pageID, serverID: serverID)
    }
}

// MARK: Time

enum WidgetTime {
    /// "14:32" in the person's own format.
    static func clock(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// "Updated 14:32".
    static func updated(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        String(localized: "Updated \(clock(date, locale: locale, timeZone: timeZone))")
    }

    /// A short age: "now", "5m", "3h", "2d".
    static func age(from date: Date?, now: Date) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return String(localized: "now")
        case ..<3600: return String(localized: "\(Int(seconds / 60))m")
        case ..<86_400: return String(localized: "\(Int(seconds / 3600))h")
        default: return String(localized: "\(Int(seconds / 86_400))d")
        }
    }
}
