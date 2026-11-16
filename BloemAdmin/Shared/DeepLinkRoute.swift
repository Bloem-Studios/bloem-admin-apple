import Foundation

// One route format for every way into the app from outside it: a tapped notification, a widget, the
// Control Center control, an App Shortcut and a Home Screen quick action. It is compiled into the app and
// into the widget extension, which builds the links its widgets open.
//
//   bloemadmin://all[/{pageID}]                          every saved server
//   bloemadmin://server/{serverID}[/{pageID}[/{itemID}]] one saved server, and on a page one item
//
// `pageID` is a menu page's id (`live.streams`, `overview.dashboard`, `work.requests`), the same ids the
// Android app uses, and `itemID` is a request, library or plugin on that page (a pushed notification names
// one). A link only moves the app to a page, or to an item on it; it never acts on anything, and the app lock
// and the admin gate still apply once it arrives. The scheme is its own, so it cannot be mistaken for the
// OAuth redirect scheme (`OAuthRedirectSpec.scheme`).

/// The page ids a link can name. They equal the menu's ids (a test keeps them in step).
enum DeepLinkPage {
    static let nowPlaying = "live.streams"
    static let dashboard = "overview.dashboard"
    static let requests = "work.requests"
    static let libraries = "content.libraries"
    static let nodes = "playback.nodes"
    static let backups = "system.backups"
    static let plugins = "system.plugins"
}

struct DeepLinkRoute: Equatable, Hashable, Sendable {
    enum Target: Equatable, Hashable, Sendable {
        case allServers
        case server(String)
    }

    static let scheme = "bloemadmin"

    var target: Target
    /// nil opens the target's first page (Now playing).
    var pageID: String?
    /// The item on that page: a request, library or plugin. Only a link to one server on a page names one.
    var itemID: String?
}

extension DeepLinkRoute {
    private static let allHost = "all"
    private static let serverHost = "server"
    private static let serverIDLimit = 128
    private static let pageIDLimit = 64
    private static let itemIDLimit = 128

    /// A route, or nil for any URL that is not exactly one of the forms above: another scheme, an unknown
    /// target, extra path segments, sign-in details, a port, a query, a fragment or an id with anything
    /// beyond letters, digits, `.`, `_` and `-`.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == Self.scheme,
              components.user == nil, components.password == nil, components.port == nil,
              components.query == nil, components.fragment == nil,
              let host = components.host?.lowercased()
        else { return nil }

        var segments = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        if segments.first == "" { segments.removeFirst() }
        if segments.last == "" { segments.removeLast() }

        switch host {
        case Self.allHost:
            guard segments.count <= 1 else { return nil }
            if let page = segments.first, !Self.isPlainID(page, limit: Self.pageIDLimit) { return nil }
            self.init(target: .allServers, pageID: segments.first)
        case Self.serverHost:
            guard (1...3).contains(segments.count),
                  Self.isPlainID(segments[0], limit: Self.serverIDLimit) else { return nil }
            if segments.count >= 2, !Self.isPlainID(segments[1], limit: Self.pageIDLimit) { return nil }
            if segments.count == 3, !Self.isPlainID(segments[2], limit: Self.itemIDLimit) { return nil }
            self.init(
                target: .server(segments[0]),
                pageID: segments.count >= 2 ? segments[1] : nil,
                itemID: segments.count == 3 ? segments[2] : nil
            )
        default:
            return nil
        }
    }

    /// The link for this route, in the form `init?(url:)` reads.
    var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        let page = pageID.map { "/" + $0 } ?? ""
        switch target {
        case .allServers:
            components.host = Self.allHost
            components.path = page
        case .server(let id):
            components.host = Self.serverHost
            // An item belongs to a page, so a link with no page carries none.
            let item = pageID == nil ? "" : (itemID.map { "/" + $0 } ?? "")
            components.path = "/" + id + page + item
        }
        return components.url ?? URL(fileURLWithPath: "/")
    }

    private static func isPlainID(_ value: String, limit: Int) -> Bool {
        guard (1...limit).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "-"):
                true
            default:
                false
            }
        }
    }
}

// MARK: Home Screen quick actions

extension DeepLinkRoute {
    /// The quick action types declared in `project.yml` (`UIApplicationShortcutItems`).
    enum QuickAction {
        static let nowPlaying = "com.bloemstudios.admin.quick.now-playing"
        static let requests = "com.bloemstudios.admin.quick.requests"
        static let dashboard = "com.bloemstudios.admin.quick.dashboard"
    }

    /// The route a Home Screen quick action opens: the page across all servers. nil for a type this app
    /// does not declare.
    init?(quickActionType: String) {
        switch quickActionType {
        case QuickAction.nowPlaying: self.init(target: .allServers, pageID: DeepLinkPage.nowPlaying)
        case QuickAction.requests: self.init(target: .allServers, pageID: DeepLinkPage.requests)
        case QuickAction.dashboard: self.init(target: .allServers, pageID: DeepLinkPage.dashboard)
        default: return nil
        }
    }
}
