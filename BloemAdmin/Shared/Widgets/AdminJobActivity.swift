import ActivityKit
import Foundation

/// The Live Activity for a library scan or a backup that was started from the app. The app starts and
/// updates it (`AdminJobActivityTracker`); the widget extension draws it on the Lock Screen and in the
/// Dynamic Island. It holds a server name, a phase and a progress figure, and (library scans only) the
/// library's name, which is drawn only where "Show details on the lock screen" allows it.
struct AdminJobActivityAttributes: ActivityAttributes {
    enum Kind: String, Codable, Hashable, Sendable {
        case libraryScan, backup
    }

    enum Phase: String, Codable, Hashable, Sendable {
        case running, finished, failed
    }

    struct ContentState: Codable, Hashable, Sendable {
        var phase: Phase
        /// 0 to 1, nil while the server reports none (a scan run reports none).
        var progress: Double?
        var libraryName: String?
    }

    var kind: Kind
    var serverID: String
    var serverName: String
    var startedAt: Date
}

extension AdminJobActivityAttributes {
    var link: URL {
        let page = kind == .backup ? "system.backups" : DeepLinkPage.libraries
        return DeepLinkRoute(target: .server(serverID), pageID: page).url
    }
}

extension AdminJobActivityAttributes.ContentState {
    func title(kind: AdminJobActivityAttributes.Kind) -> String {
        switch (kind, phase) {
        case (.libraryScan, .running): String(localized: "Scanning")
        case (.libraryScan, .finished): String(localized: "Scan finished")
        case (.libraryScan, .failed): String(localized: "Scan failed")
        case (.backup, .running): String(localized: "Backing up")
        case (.backup, .finished): String(localized: "Backup finished")
        case (.backup, .failed): String(localized: "Backup failed")
        }
    }

    var percentText: String? {
        progress.map { "\(Int(($0 * 100).rounded()))%" }
    }
}
