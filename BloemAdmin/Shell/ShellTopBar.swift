import SwiftUI

// Accessibility identifiers. Plain strings so UI tests can build them without the app's types.
enum ShellID {
    static let menuButton = "shell-menu-button"
    static let searchButton = "shell-search-button"
    static let title = "shell-title"
    static let context = "shell-context"
    static let contextItemPrefix = "shell-context-item:"
    static let destinationPrefix = "shell-destination:"
    static let groupPrefix = "shell-group:"
    static let manageServers = "shell-manage-servers"
    static let settings = "shell-settings"
    static let signOut = "shell-sign-out"
    static let contextSheet = "shell-context-sheet"
    static let contextAddServer = "shell-context-add-server"
    static let menu = "shell-menu"
    static let menuScrim = "shell-menu-scrim"
    static let menuBadge = "shell-menu-badge"
    static let page = "shell-page"
    static let searchSheet = "shell-search-sheet"
    static let searchField = "shell-search-field"
    static let searchClose = "shell-search-close"
    static let searchResultPrefix = "shell-search-result:"
    static let searchGroupPrefix = "shell-search-group:"
    static let searchEmpty = "shell-search-empty"
    static let searchCount = "shell-search-count"
}

/// The server switcher's button in the top bar: the current name followed by a chevron (`Name ⌄`), the same control in
/// every staff app. It opens the switcher sheet (`ContextSwitcherSheet`). Dimmed while the shell is locked.
struct ContextDropdown: View {
    let control: ScopeControl
    var isEnabled: Bool = true
    /// Room for the context's name; scales with the text so the page title still leads.
    @ScaledMetric(relativeTo: .subheadline) private var maxWidth: CGFloat = 160

    var body: some View {
        let title = control.model.title
        Button(action: control.onOpenSwitcher) {
            HStack(spacing: Theme.Space.xs) {
                Text(title)
                    .bloemText(.bodyMedium)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                IconImage(.chevronDown, size: .inline)
                    .foregroundStyle(Theme.muted)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: maxWidth, minHeight: Theme.minimumTarget, alignment: .trailing)
            .contentShape(Rectangle())
            // The same cap as the title's: a bar does not grow with the accessibility sizes.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(String(localized: "Change server context from \(title)"))
        .accessibilityIdentifier(ShellID.context)
    }
}

/// The sheet the switcher opens: All servers and each saved server (and, under a server, its organizations), the
/// current one marked, then "Add server" as the last row. Picking a row closes the sheet.
struct ContextSwitcherSheet: View {
    let control: ScopeControl
    let onClose: () -> Void
    /// Run after the sheet is gone: another sheet cannot open over one that is still closing.
    let onAddServer: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text("Servers")
                .bloemText(.titleLarge)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.xl)
                .padding(.bottom, Theme.Space.s)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(control.model.items) { item in
                        Button {
                            control.select(item)
                            onClose()
                        } label: {
                            SwitcherRowLabel(
                                title: item.title,
                                icon: item.kind == .allServers ? .layers : (item.isIndented ? .building2 : .server),
                                isCurrent: item.isSelected,
                                indented: item.isIndented
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!item.isEnabled)
                        .accessibilityAddTraits(item.isSelected ? .isSelected : [])
                        .accessibilityIdentifier(ShellID.contextItemPrefix + item.id)
                    }
                    Divider().overlay(Theme.hairline).padding(.vertical, Theme.Space.xs)
                    Button {
                        onAddServer()
                        onClose()
                    } label: {
                        SwitcherRowLabel(title: String(localized: "Add server"), icon: .plus, isCurrent: false, indented: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(ShellID.contextAddServer)
                }
                .padding(.horizontal, Theme.Space.s)
                .padding(.vertical, Theme.Space.s)
            }
        }
        .background(Theme.sidebar.ignoresSafeArea())
        .accessibilityIdentifier(ShellID.contextSheet)
    }
}

/// One row of the switcher: an icon column, the name, and a check on the current one, which also takes the
/// `selected` surface.
private struct SwitcherRowLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let icon: BloemIcon
    let isCurrent: Bool
    let indented: Bool

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            IconImage(icon, size: .row)
                .frame(width: 24)
                .foregroundStyle(isCurrent ? Theme.accent : Theme.muted)
                .accessibilityHidden(true)
            Text(title)
                .bloemText(.titleMedium)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.leading)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Spacer(minLength: 0)
            if isCurrent {
                IconImage(.check, size: .row)
                    .foregroundStyle(Theme.text)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, indented ? Theme.Space.xl + Theme.Space.m : Theme.Space.m)
        .padding(.trailing, Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: Theme.minimumTarget, alignment: .leading)
        .background(isCurrent ? Theme.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
    }
}

/// The page title, as the top bar shows it.
struct ShellTitle: View {
    let title: String

    var body: some View {
        // The page title is titleLarge (20/28) in all three staff apps, where it was 16 here. A bar is wayfinding, not
        // reading: it grows with the text size up to the largest ordinary one and no further, as the system's own bars do.
        Text(title)
            .bloemText(.titleLarge)
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier(ShellID.title)
    }
}

/// The one-row top bar of a page of the signed-in app: menu button, page title, search button and context
/// dropdown. The row is the navigation bar itself, so pages keep their back button and own toolbar items.
/// `onMenu` is nil where the menu is always visible (iPad sidebar).
struct ShellPageBar: ViewModifier {
    let title: String
    let onMenu: (() -> Void)?
    let onSearch: () -> Void
    @Environment(\.scopeControl) private var control
    @Environment(\.shellInteractionLock) private var lock

    func body(content: Content) -> some View {
        let locked = lock?.isLocked ?? false
        content
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onMenu {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: onMenu) {
                            IconImage(.menu, size: .bar)
                                .foregroundStyle(.bloemText)
                                .frame(minWidth: 44, minHeight: 44)
                        }
                        .disabled(locked)
                        .accessibilityLabel(String(localized: "Open menu"))
                        .accessibilityIdentifier(ShellID.menuButton)
                    }
                    // Quiet chrome: no glass capsule behind the bar's buttons.
                    .bloemFlat()
                }
                ToolbarItem(placement: .principal) {
                    ShellTitle(title: title)
                }
                // Quiet chrome: no glass capsule behind the bar's buttons.
                .bloemFlat()
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onSearch) {
                        IconImage(.search, size: .bar)
                            .foregroundStyle(.bloemText)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .disabled(locked)
                    .accessibilityLabel(String(localized: "Search admin sections"))
                    .accessibilityIdentifier(ShellID.searchButton)
                }
                // Quiet chrome: no glass capsule behind the bar's buttons.
                .bloemFlat()
                if let control {
                    ToolbarItem(placement: .topBarTrailing) {
                        ContextDropdown(control: control, isEnabled: !locked)
                    }
                    // Quiet chrome: no glass capsule behind the bar's buttons.
                    .bloemFlat()
                }
            }
    }
}

extension View {
    func shellPageBar(title: String, onMenu: (() -> Void)?, onSearch: @escaping () -> Void) -> some View {
        modifier(ShellPageBar(title: title, onMenu: onMenu, onSearch: onSearch))
    }
}

/// A screen that comes before a server's pages (checking access, signing in again, no access, can't reach
/// the server): the same top bar with its own title and the context dropdown, and no menu or search because
/// there is nothing to navigate yet.
struct PreNavigationScreen<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    @Environment(\.scopeControl) private var control
    @Environment(\.shellInteractionLock) private var lock

    var body: some View {
        NavigationStack {
            content()
                .bloemPageBackground()
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        ShellTitle(title: title)
                    }
                    // Quiet chrome: no glass capsule behind the bar's buttons.
                    .bloemFlat()
                    if let control {
                        ToolbarItem(placement: .topBarTrailing) {
                            ContextDropdown(control: control, isEnabled: !(lock?.isLocked ?? false))
                        }
                        // Quiet chrome: no glass capsule behind the bar's buttons.
                        .bloemFlat()
                    }
                }
        }
    }
}


extension ToolbarContent {
    /// A bar item with no system background behind it (iOS 26 draws a glass capsule there by default).
    @ToolbarContentBuilder
    func bloemFlat() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
