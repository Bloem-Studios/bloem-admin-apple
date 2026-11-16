import AppIntents
import Foundation
import WidgetKit

// The buttons on a widget. Refresh is harmless. Approve and Decline change a server, so they need the phone
// to be unlocked (`authenticationPolicy = .requiresAuthentication`); the app's own lock does not come into it
// (maintainer, 2026-11-15). Nothing destructive is ever offered here: no delete, suspend, drain or sign out.

/// The one place the app, the widget extension and the background handlers ask for a widget reload. A reload
/// only asks WidgetKit for a new timeline; the widget then reads the servers itself. Callers:
///  - the app, whenever it saves new data a widget shows (`SnapshotSync`, `WidgetSettingsSync`);
///  - the live socket while the app is open, debounced to 10 seconds (`WidgetLiveReloader`);
///  - the silent push the server sends when something a widget shows changed, in the background handler,
///    with the channels the wake names (`reload(channels:)`);
///  - the Refresh button, and a request that was approved or declined.
enum WidgetReload {
    static let kinds = SiloWidgetKind.allCases.map(\.rawValue)

    /// The widgets that show `names`: the channels of the server's silent wake (`sessions`, `requests`,
    /// `libraries`, `nodes`) or of the app's live socket (`scans`, `jobs` and `tasks` change the libraries and
    /// their scans). Anything else names no widget.
    static func kinds(forChannels names: some Sequence<String>) -> Set<SiloWidgetKind> {
        let wanted = Set(names.map { name -> String in
            switch name {
            case "scans", "jobs", "tasks": "libraries"
            default: name
            }
        })
        return Set(SiloWidgetKind.allCases.filter { !$0.channels.isDisjoint(with: wanted) })
    }

    static func reload(_ kinds: Set<SiloWidgetKind>) {
        for kind in kinds { WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue) }
    }

    static func reload(channels names: some Sequence<String>) {
        reload(kinds(forChannels: names))
    }

    static func all() {
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// A request was decided: the list and the count on Server status change.
    static func requests() {
        reload([.requests, .serverStatus])
    }
}

struct RefreshWidgetsIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh widgets"
    static let description = IntentDescription("Reads every server again for the Bloem Admin widgets")
    static let isDiscoverable = false
    /// A tap on a locked phone asks for the unlock first, like Approve and Decline.
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    func perform() async throws -> some IntentResult {
        WidgetReload.all()
        return .result()
    }
}

/// What approving or declining does, apart from the intent shell, so it is tested without one.
enum RequestActionRunner {
    static func run(
        _ action: WidgetRequestAction, serverID: String, requestID: String,
        fetcher: WidgetFetcher?, snapshot: AdminSnapshot?
    ) async -> Bool {
        guard let fetcher else { return false }
        return await fetcher.actOnRequest(action, requestID: requestID, serverID: serverID, snapshot: snapshot)
    }
}

struct ApproveRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Approve request"
    static let description = IntentDescription("Approves one waiting request")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Server")
    var serverID: String

    @Parameter(title: "Request")
    var requestID: String

    init() {}

    init(serverID: String, requestID: String) {
        self.serverID = serverID
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        _ = await RequestActionRunner.run(
            .approve, serverID: serverID, requestID: requestID,
            fetcher: WidgetFetcher.live(), snapshot: FileSnapshotStore.appGroup()?.load()
        )
        WidgetReload.requests()
        return .result()
    }
}

struct DeclineRequestIntent: AppIntent {
    static let title: LocalizedStringResource = "Decline request"
    static let description = IntentDescription("Declines one waiting request")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Server")
    var serverID: String

    @Parameter(title: "Request")
    var requestID: String

    init() {}

    init(serverID: String, requestID: String) {
        self.serverID = serverID
        self.requestID = requestID
    }

    func perform() async throws -> some IntentResult {
        _ = await RequestActionRunner.run(
            .decline, serverID: serverID, requestID: requestID,
            fetcher: WidgetFetcher.live(), snapshot: FileSnapshotStore.appGroup()?.load()
        )
        WidgetReload.requests()
        return .result()
    }
}
