import Observation
import SwiftUI

/// Where the signed-in app is and which shell surfaces are open. One instance per window, owned by
/// `AppRootView`; everything under it reads it from the environment.
@Observable
@MainActor
final class ShellRouter {
    private(set) var scope: ShellScope
    private(set) var selectedDestinationID: String = AdminDestination.startID

    var isMenuOpen = false
    var isSearching = false
    var isManagingServers = false
    /// The Settings page is showing in place of a menu page (the drawer's foot opens it; picking any page closes it).
    var isShowingAppSettings = false
    var isAddingServer = false
    /// The server switcher sheet (the top bar's "Name ⌄") is open.
    var isSwitchingContext = false
    /// The Sign out confirmation is open.
    var isConfirmingSignOut = false

    /// Set by "Logs" and "FFmpeg logs" on a stream or a Playback history row: the playback session the
    /// Logs page opens on. The page takes it once (`takeLogsFocus`).
    private(set) var logsFocus: LogsFocus?

    /// An item a link named (a request, library or plugin from a pushed notification), waiting for its page.
    /// The page takes it once (`takeItemFocus`). Navigating anywhere by hand drops it.
    private(set) var itemFocus: ItemFocus?

    /// HOOK FOR ORGANIZATION MODE (empty by default). The organizations the account administers, listed
    /// under their server in the context dropdown.
    var organizations: [ScopeOrganization] = []
    /// HOOK FOR ORGANIZATION MODE. Set while an organization is open.
    var selectedOrganizationID: String?
    /// HOOK FOR ORGANIZATION MODE. Called when an organization in the dropdown is chosen. Does nothing
    /// until the integrator wires organization mode in.
    var onSelectOrganization: (ScopeOrganization) -> Void = { _ in }

    @ObservationIgnored private let preferences: ShellScopePreferences

    init(scope: ShellScope = .allServers, preferences: ShellScopePreferences = ShellScopePreferences()) {
        self.scope = scope
        self.preferences = preferences
    }

    /// Switches to All servers or one server. Either opens on Now playing, and anything open on top of
    /// the old scope closes.
    func select(scope newScope: ShellScope) {
        guard newScope != scope || selectedOrganizationID != nil else {
            isMenuOpen = false
            isSearching = false
            isShowingAppSettings = false
            return
        }
        scope = newScope
        selectedDestinationID = AdminDestination.startID
        selectedOrganizationID = nil
        isMenuOpen = false
        isSearching = false
        isShowingAppSettings = false
        preferences.remember(newScope)
    }

    func select(destinationID: String) {
        logsFocus = nil
        itemFocus = nil
        selectedDestinationID = destinationID
        isMenuOpen = false
        isSearching = false
        isShowingAppSettings = false
    }

    /// Opens the Logs page filtered to one playback session.
    func openLogs(_ focus: LogsFocus) {
        select(destinationID: AdminDestination.logs.id)
        logsFocus = focus
    }

    /// The Logs page reads the request it was opened with, once.
    func takeLogsFocus() -> LogsFocus? {
        defer { logsFocus = nil }
        return logsFocus
    }

    /// Asks the page `pageID` to show one item. Called by `open(_:savedServerIDs:)`, after it has moved there.
    func focus(itemID: String, on pageID: String) {
        itemFocus = ItemFocus(pageID: pageID, itemID: itemID)
    }

    /// The item waiting for `pageID`, which is then no longer waiting. nil when none is, or it is for another page.
    func takeItemFocus(for pageID: String) -> String? {
        guard let focus = itemFocus, focus.pageID == pageID else { return nil }
        itemFocus = nil
        return focus.itemID
    }

    /// Moves `step` pages along the menu (swipe), staying put at either end.
    func swipe(step: Int, in destinations: [AdminDestination]) {
        guard !coversPage, step != 0 else { return }
        guard let target = AdminDestination.adjacent(to: selectedDestinationID, step: step, in: destinations) else {
            return
        }
        selectedDestinationID = target.id
    }

    func openManageServers() {
        isMenuOpen = false
        isSearching = false
        isManagingServers = true
    }

    /// Opens the Settings page in the shell, where the page was.
    func openSettings() {
        isMenuOpen = false
        isSearching = false
        isShowingAppSettings = true
    }

    /// Opens the server switcher over the page.
    func openContextSwitcher() {
        isMenuOpen = false
        isSearching = false
        isSwitchingContext = true
    }

    /// Asks whether to sign out: of the open server, or of every saved server on All servers.
    func openSignOut() {
        isMenuOpen = false
        isSearching = false
        isConfirmingSignOut = true
    }

    /// A server that was removed cannot stay the scope: fall back to All servers.
    func reconcile(savedServerIDs: Set<String>) {
        if case .server(let id) = scope, !savedServerIDs.contains(id) {
            select(scope: .allServers)
        }
    }

    /// True while something covers the page, so a sideways drag must not change it.
    var coversPage: Bool {
        isMenuOpen || isSearching || isManagingServers || isShowingAppSettings || isAddingServer || isSwitchingContext
            || isConfirmingSignOut
    }
}

/// One item on one page that a link asked to show.
struct ItemFocus: Equatable, Sendable {
    let pageID: String
    let itemID: String
}
