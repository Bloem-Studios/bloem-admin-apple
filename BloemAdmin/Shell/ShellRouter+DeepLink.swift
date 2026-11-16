import Foundation

extension ShellRouter {
    /// Opens the page a link names. A server that is not saved changes nothing and answers false. A page
    /// that is not a platform menu page opens the start page, as does a link with no page. Whatever
    /// covers the page (menu, search, Manage servers, App settings, Add Server) closes, and so does an
    /// open organization. A link that names an item on a page (a pushed notification does) asks that page to
    /// show it. The admin gate still decides whether the account may see the page.
    @discardableResult
    func open(_ route: DeepLinkRoute, savedServerIDs: Set<String>) -> Bool {
        let scope: ShellScope
        switch route.target {
        case .allServers:
            scope = .allServers
        case .server(let id):
            guard savedServerIDs.contains(id) else { return false }
            scope = .server(id)
        }
        isManagingServers = false
        isShowingAppSettings = false
        isAddingServer = false
        isSwitchingContext = false
        isConfirmingSignOut = false
        select(scope: scope)
        let page = route.pageID.flatMap { id in Self.linkablePageIDs.contains(id) ? id : nil }
        select(destinationID: page ?? AdminDestination.startID)
        if let page, let item = route.itemID { focus(itemID: item, on: page) }
        return true
    }

    /// Every platform page, whether or not the server shows it in its menu.
    private static let linkablePageIDs = Set(
        AdminDestination.singleServer(tenantsVisible: true, supportAccessVisible: true).map(\.id)
    )
}
