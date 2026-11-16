import Foundation

// The push notification kinds of docs/design.md (Admin). Compiled into the app and into
// the notification service extension, so nothing here may import UI frameworks.

/// A kind of notification. The ids are stable keys: payloads, switches and analytics use them, so they are
/// never renamed. `serverDown` and `serverUp` come from this app's own checks (a server that is down cannot
/// push); the others come from a server that advertises `admin_push_v1`.
enum PushKind: String, CaseIterable, Codable, Sendable {
    case serverDown = "admin.server_down"
    case serverUp = "admin.server_up"
    case requestWaiting = "admin.request_waiting"
    case scanFailed = "admin.scan_failed"
    case backupFailed = "admin.backup_failed"
    case nodeOffline = "admin.node_offline"
    case pluginFailed = "admin.plugin_failed"

    /// Made by this app's local checks; the server never sends it.
    var isLocal: Bool { self == .serverDown || self == .serverUp }

    /// The kinds a server sends, in the order the settings list them.
    static let remote: [PushKind] = allCases.filter { !$0.isLocal }

    /// Notifications of one family share a thread, so they group by server and kind. Down and up share one,
    /// because each replaces the other.
    var threadFamily: String {
        isLocal ? "admin.server_reachability" : rawValue
    }

    /// The thread a notification for this kind and server belongs to.
    func threadIdentifier(serverID: String) -> String {
        "\(serverID).\(threadFamily)"
    }

    /// All a locked screen shows unless the device allows details. The same words the server sends as
    /// `lock_screen`; used when the server's own text is missing.
    var lockScreenText: String {
        switch self {
        case .serverDown: String(localized: "A server can't be reached")
        case .serverUp: String(localized: "A server is back")
        case .requestWaiting: String(localized: "New request waiting")
        case .scanFailed: String(localized: "A library scan failed")
        case .backupFailed: String(localized: "A backup failed")
        case .nodeOffline: String(localized: "A node is offline")
        case .pluginFailed: String(localized: "A plugin needs attention")
        }
    }

    /// The row's name in Settings → Notifications.
    var settingsLabel: String {
        switch self {
        case .serverDown: String(localized: "Server can't be reached")
        case .serverUp: String(localized: "Server is back")
        case .requestWaiting: String(localized: "Request waiting")
        case .scanFailed: String(localized: "Library scan failed")
        case .backupFailed: String(localized: "Backup failed")
        case .nodeOffline: String(localized: "Node offline")
        case .pluginFailed: String(localized: "Plugin needs attention")
        }
    }
}

/// The pages a pushed notification can open. The server names them by these slugs.
enum PushLinkPage: String, CaseIterable, Sendable {
    case requests, libraries, backups, nodes, plugins
}

/// A button on a notification. Nothing destructive is ever offered.
enum PushAction: String, Sendable {
    case approve, decline
}
