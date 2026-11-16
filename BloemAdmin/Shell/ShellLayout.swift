import SwiftUI

/// A horizontal swipe over a page goes to the next page (swipe left) or the previous one (swipe right) in
/// menu order, with no wrap-around (`PageSwipe`, `AdminDestination.adjacent`). It is a plain `.gesture`, so
/// anything inside the page that scrolls sideways (tab rows, charts) is a deeper gesture and takes the drag
/// first; vertical scrolling is never a swipe (`PageSwipe.dominance`).
private struct PageSwipeModifier: ViewModifier {
    let enabled: Bool
    let onStep: (Int) -> Void

    func body(content: Content) -> some View {
        content
            // Empty parts of a page (a centred message, the space below a short list) answer the drag too.
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 24, coordinateSpace: .local)
                    .onEnded { value in
                        guard enabled else { return }
                        let step = PageSwipe.step(forTranslation: value.translation.width, height: value.translation.height)
                        if step != 0 { onStep(step) }
                    },
                including: enabled ? .all : .subviews
            )
    }
}

extension View {
    func pageSwipe(enabled: Bool, onStep: @escaping (Int) -> Void) -> some View {
        modifier(PageSwipeModifier(enabled: enabled, onStep: onStep))
    }
}

/// The signed-in shell: a one-row top bar over the current page, with the menu beside it. On iPhone (and a
/// narrow iPad window) the menu is a drawer that opens from the menu button; on iPad it is a permanent
/// sidebar. There is no tab bar. `page` builds the content of one destination.
struct ShellLayout<Page: View>: View {
    let destinations: [AdminDestination]
    /// Names the sidebar on iPad: what is being looked at.
    let heading: String
    /// Counts shown beside menu items, by destination id (Requests: what needs approval).
    var badges: [String: Int] = [:]
    @ViewBuilder let page: (AdminDestination) -> Page

    @Environment(ShellRouter.self) private var router
    @Environment(\.settingsPage) private var settingsPage
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var drawerWidth: CGFloat = 300
    @State private var lock = ShellInteractionLock()

    var body: some View {
        @Bindable var router = router
        let effective = AdminDestination.effective(selectedID: router.selectedDestinationID, in: destinations)
        Group {
            if sizeClass == .regular {
                splitLayout(effective)
            } else {
                compactLayout(effective)
            }
        }
        .environment(\.shellInteractionLock, lock)
        .fullScreenCover(isPresented: $router.isSearching) {
            PageSearchSheet(
                destinations: destinations,
                selectedID: effective?.id,
                onPick: { router.select(destinationID: $0.id) },
                onDismiss: { router.isSearching = false }
            )
            .environment(\.shellInteractionLock, lock)
        }
    }

    // MARK: Pages

    @ViewBuilder
    private func pageView(_ destination: AdminDestination?, showsMenuButton: Bool) -> some View {
        if router.isShowingAppSettings, let settingsPage {
            // The app's Settings page, in the place of a menu page: the same bar, the menu beside it.
            NavigationStack {
                settingsPage()
                    .bloemPageBackground()
                    .toolbar(removing: showsMenuButton ? nil : .sidebarToggle)
                    .shellPageBar(
                        title: String(localized: "Settings"),
                        onMenu: showsMenuButton ? { router.isMenuOpen = true } : nil,
                        onSearch: { router.isSearching = true }
                    )
            }
            .id("app-settings")
            .transition(.opacity)
        } else if let destination {
            NavigationStack {
                page(destination)
                    .bloemPageBackground()
                    .toolbar(removing: showsMenuButton ? nil : .sidebarToggle)
                    .shellPageBar(
                        title: destination.labelText,
                        onMenu: showsMenuButton ? { router.isMenuOpen = true } : nil,
                        onSearch: { router.isSearching = true }
                    )
                    .pageSwipe(enabled: !router.coversPage && !lock.isLocked) { step in
                        router.swipe(step: step, in: destinations)
                    }
            }
            // Each destination gets its own stack, so a page opened inside one is left when the menu moves on.
            .id(destination.id)
            .transition(.opacity)
        }
    }

    private func select(_ destination: AdminDestination) {
        router.select(destinationID: destination.id)
    }

    // MARK: iPhone: drawer

    private func compactLayout(_ effective: AdminDestination?) -> some View {
        ZStack(alignment: .leading) {
            pageView(effective, showsMenuButton: true)
                .accessibilityHidden(router.isMenuOpen)
            if router.isMenuOpen {
                drawer(effective)
            }
        }
        .animation(reduceMotion ? nil : Theme.Motion.enter, value: router.isMenuOpen)
        .animation(reduceMotion ? nil : Theme.Motion.feedback, value: effective?.id)
    }

    private func drawer(_ effective: AdminDestination?) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                // The menu opens only from its button; a tap outside it, or a swipe back, closes it.
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { router.isMenuOpen = false }
                    .accessibilityElement()
                    .accessibilityLabel(String(localized: "Close menu"))
                    .accessibilityAddTraits(.isButton)
                    .accessibilityIdentifier(ShellID.menuScrim)
                ShellMenuContent(
                    heading: heading,
                    destinations: destinations,
                    selectedID: router.isShowingAppSettings ? nil : effective?.id,
                    onSelect: select,
                    badges: badges,
                    settingsSelected: router.isShowingAppSettings,
                    onManageServers: { router.openManageServers() },
                    onSettings: { router.openSettings() },
                    onSignOut: { router.openSignOut() }
                )
                .frame(width: min(drawerWidth, proxy.size.width * 0.9))
                .frame(maxHeight: .infinity)
                .background(Theme.sidebar.ignoresSafeArea())
                // Depth is a hairline edge, not a shadow.
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.hairline).frame(width: 1).ignoresSafeArea() }
                .transition(.move(edge: .leading))
                .gesture(
                    DragGesture(minimumDistance: 24).onEnded { value in
                        if value.translation.width < -48, abs(value.translation.height) < abs(value.translation.width) {
                            router.isMenuOpen = false
                        }
                    }
                )
                .accessibilityElement(children: .contain)
                .accessibilityAddTraits(.isModal)
                .accessibilityLabel(String(localized: "Navigation"))
                .accessibilityAction(.escape) { router.isMenuOpen = false }
                .accessibilityIdentifier(ShellID.menu)
            }
        }
        .transition(.opacity)
        .zIndex(1)
    }

    // MARK: iPad: sidebar

    private func splitLayout(_ effective: AdminDestination?) -> some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            ShellMenuContent(
                destinations: destinations,
                selectedID: router.isShowingAppSettings ? nil : effective?.id,
                onSelect: select,
                badges: badges,
                settingsSelected: router.isShowingAppSettings,
                onManageServers: { router.openManageServers() },
                onSettings: { router.openSettings() },
                onSignOut: { router.openSignOut() }
            )
            .navigationTitle(heading)
            .navigationBarTitleDisplayMode(.inline)
            // The menu is always visible: there is nothing to open or close.
            .toolbar(removing: .sidebarToggle)
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 340)
        } detail: {
            pageView(effective, showsMenuButton: false)
        }
        .navigationSplitViewStyle(.balanced)
        .animation(reduceMotion ? nil : Theme.Motion.feedback, value: effective?.id)
    }
}

// MARK: Settings page

private struct SettingsPageKey: EnvironmentKey {
    static var defaultValue: (() -> AnyView)? { nil }
}

extension EnvironmentValues {
    /// Builds the app's Settings page, which the shell shows in the place of a menu page when the drawer's Settings
    /// row is chosen. Nil in previews and tests of one screen: the row then opens nothing.
    var settingsPage: (() -> AnyView)? {
        get { self[SettingsPageKey.self] }
        set { self[SettingsPageKey.self] = newValue }
    }
}
