import Foundation

extension PushLinkPage {
    /// The app's page id for the page a notification names.
    var pageID: String {
        switch self {
        case .requests: DeepLinkPage.requests
        case .libraries: DeepLinkPage.libraries
        case .backups: DeepLinkPage.backups
        case .nodes: DeepLinkPage.nodes
        case .plugins: DeepLinkPage.plugins
        }
    }
}

/// What a notification says about where it leads, read from its `userInfo`. A pushed notification carries the
/// identifiers the extension put there (`PushNotificationComposer`); a local server alert carries only
/// `serverID`. Either way a tap goes to the saved server, and on a pushed one to the page and item.
struct PushTapInfo: Equatable, Sendable {
    var serverID: String?
    var kind: PushKind?
    var page: PushLinkPage?
    var itemID: String?

    init(userInfo: [AnyHashable: Any]) {
        serverID = (userInfo[PushUserInfo.serverID] as? String).flatMap { $0.isEmpty ? nil : $0 }
        kind = (userInfo[PushUserInfo.kind] as? String).flatMap(PushKind.init(rawValue:))
        page = (userInfo[PushUserInfo.page] as? String).flatMap(PushLinkPage.init(rawValue:))
        itemID = (userInfo[PushUserInfo.itemID] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Where a tap leads: that server, and on a page that has one, that page and item. Nil when the
    /// notification names no server.
    var route: DeepLinkRoute? {
        guard let serverID else { return nil }
        guard let page else { return DeepLinkRoute(target: .server(serverID), pageID: nil) }
        return DeepLinkRoute(target: .server(serverID), pageID: page.pageID, itemID: itemID)
    }
}
