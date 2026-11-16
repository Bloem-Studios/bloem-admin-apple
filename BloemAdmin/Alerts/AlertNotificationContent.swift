import Foundation

/// What one local notification says and where it leads. Built from a server's name, a time and a failure
/// kind only, so it cannot carry a title, an account, an email address or an address. The default text is
/// generic; "Show details on the lock screen" (per device, off by default) adds when it stopped and why.
struct AlertNotificationContent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case serverDown
        case serverBack
    }

    let kind: Kind
    let serverID: String
    let title: String
    let body: String

    var identifier: String { Self.identifier(kind, serverID: serverID) }
    var playsSound: Bool { kind == .serverDown }

    /// Tapping the notification opens this server.
    var route: DeepLinkRoute { DeepLinkRoute(target: .server(serverID), pageID: nil) }
    var userInfo: [String: String] { ["serverID": serverID] }

    /// Down and up for one server share a thread, because each replaces the other; it is the thread a pushed
    /// notification of the same kind would use.
    var threadIdentifier: String { PushKind.serverDown.threadIdentifier(serverID: serverID) }

    private static let prefix = "bloem.admin.alert"

    static func identifier(_ kind: Kind, serverID: String) -> String {
        "\(prefix).\(kind == .serverDown ? "down" : "back").\(serverID)"
    }

    /// Both notices a server can have on the lock screen.
    static func identifiers(forServer serverID: String) -> [String] {
        [identifier(.serverDown, serverID: serverID), identifier(.serverBack, serverID: serverID)]
    }

    static func shortTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    static func serverDown(
        serverID: String, name: String, since: Date?, reason: HealthFailure?, showsDetails: Bool,
        formatTime: (Date) -> String = AlertNotificationContent.shortTime
    ) -> AlertNotificationContent {
        let body: String
        if showsDetails, let since, let reason {
            body = String(localized: "No answer since \(formatTime(since)) (\(reason.summary))")
        } else {
            body = String(localized: "Open Bloem Admin to check the server")
        }
        return AlertNotificationContent(
            kind: .serverDown, serverID: serverID, title: String(localized: "Can't reach \(name)"), body: body
        )
    }

    static func serverBack(
        serverID: String, name: String, at: Date, showsDetails: Bool,
        formatTime: (Date) -> String = AlertNotificationContent.shortTime
    ) -> AlertNotificationContent {
        let body = showsDetails
            ? String(localized: "Answering again since \(formatTime(at))")
            : String(localized: "Open Bloem Admin to see it")
        return AlertNotificationContent(
            kind: .serverBack, serverID: serverID, title: String(localized: "\(name) is answering again"), body: body
        )
    }
}
