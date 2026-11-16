import AppIntents
import Foundation

// Opening a page from outside the app: App Shortcuts (Siri, Spotlight, the Shortcuts app), the Action
// button and the Control Center control all run one of these. Each opens the app and hands a
// `DeepLinkRoute` to `DeepLinkCenter`, so the app lock and the admin gate still apply. With no server
// chosen they open the page across all servers. Compiled into the app and the widget extension.

enum OpenPageRouting {
    static func route(page: String, server: ServerEntity?) -> DeepLinkRoute {
        DeepLinkRoute(target: server.map { .server($0.id) } ?? .allServers, pageID: page)
    }
}

struct OpenNowPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Now playing"
    static let description = IntentDescription("Opens Bloem Admin on Now playing")
    static let openAppWhenRun = true

    @Parameter(title: "Server")
    var server: ServerEntity?

    init() {}

    init(server: ServerEntity?) {
        self.server = server
    }

    var route: DeepLinkRoute { OpenPageRouting.route(page: DeepLinkPage.nowPlaying, server: server) }

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkCenter.shared.submit(route)
        return .result()
    }
}

struct OpenRequestsIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Requests"
    static let description = IntentDescription("Opens Bloem Admin on Requests")
    static let openAppWhenRun = true

    @Parameter(title: "Server")
    var server: ServerEntity?

    init() {}

    init(server: ServerEntity?) {
        self.server = server
    }

    var route: DeepLinkRoute { OpenPageRouting.route(page: DeepLinkPage.requests, server: server) }

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkCenter.shared.submit(route)
        return .result()
    }
}

struct OpenDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Dashboard"
    static let description = IntentDescription("Opens Bloem Admin on the Dashboard")
    static let openAppWhenRun = true

    @Parameter(title: "Server")
    var server: ServerEntity?

    init() {}

    init(server: ServerEntity?) {
        self.server = server
    }

    var route: DeepLinkRoute { OpenPageRouting.route(page: DeepLinkPage.dashboard, server: server) }

    @MainActor
    func perform() async throws -> some IntentResult {
        DeepLinkCenter.shared.submit(route)
        return .result()
    }
}
