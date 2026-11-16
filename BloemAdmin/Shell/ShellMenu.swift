import SwiftUI

/// What the menu lists: the groups the server's web admin uses, then the app's own three rows, Manage servers, Settings
/// and Sign out, pinned at the bottom. Shared by the iPhone drawer and the iPad sidebar.
struct ShellMenuContent: View {
    /// Shown above the pages (the drawer names what it lists); nil where the container titles itself.
    var heading: String?
    let destinations: [AdminDestination]
    let selectedID: String?
    let onSelect: (AdminDestination) -> Void
    /// A count to show beside a page's name, by destination id (Requests: what needs approval). Absent or 0: none.
    var badges: [String: Int] = [:]
    /// True while the Settings page is the one showing.
    var settingsSelected = false
    let onManageServers: () -> Void
    let onSettings: () -> Void
    let onSignOut: () -> Void
    @Environment(\.shellInteractionLock) private var lock
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// The foot (Manage servers, Settings, Sign out) stays pinned under the list while there is room. With very large text, or a
    /// phone held sideways, it would take most of the height and leave the pages a sliver to scroll in, so it scrolls with
    /// them.
    private var footScrolls: Bool { typeSize.isAccessibilitySize || verticalSizeClass == .compact }

    var body: some View {
        VStack(spacing: 0) {
            if let heading {
                Text(heading)
                    .bloemText(.titleLarge)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Theme.Space.xl)
                    .padding(.top, Theme.Space.l)
                    .accessibilityAddTraits(.isHeader)
            }
            if footScrolls {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        pages
                        Divider().overlay(Theme.hairline).padding(.vertical, Theme.Space.s)
                        foot
                    }
                }
            } else {
                ScrollView { pages }
                Divider().overlay(Theme.hairline)
                foot
            }
        }
    }

    private var pages: some View {
        let locked = lock?.isLocked ?? false
        return LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
            ForEach(AdminDestination.grouped(destinations)) { section in
                MenuGroupHeader(title: String(localized: section.group.label))
                    .accessibilityIdentifier(ShellID.groupPrefix + String(describing: section.group))
                ForEach(section.pages) { page in
                    MenuRow(
                        title: page.labelText,
                        icon: page.icon,
                        selected: page.id == selectedID,
                        badge: badges[page.id] ?? 0,
                        action: { onSelect(page) }
                    )
                    .disabled(locked)
                    .accessibilityIdentifier(ShellID.destinationPrefix + page.id)
                }
            }
        }
        .padding(Theme.Space.s)
    }

    private var foot: some View {
        let locked = lock?.isLocked ?? false
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            MenuRow(
                title: String(localized: "Manage servers"),
                icon: .server,
                selected: false,
                action: onManageServers
            )
            .disabled(locked)
            .accessibilityIdentifier(ShellID.manageServers)
            MenuRow(
                title: String(localized: "Settings"),
                // The shared Settings icon. The server's own page is "Server settings", with the sliders.
                icon: .settings,
                selected: settingsSelected,
                action: onSettings
            )
            .disabled(locked)
            .accessibilityIdentifier(ShellID.settings)
            MenuRow(
                title: String(localized: "Sign out"),
                icon: .logOut,
                selected: false,
                action: onSignOut
            )
            .disabled(locked)
            .accessibilityIdentifier(ShellID.signOut)
        }
        .padding(Theme.Space.s)
    }
}

/// A group's heading in the menu: sentence case, quiet, closer to its own pages than to the group above.
struct MenuGroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .bloemText(.labelMedium)
            .foregroundStyle(.bloemMuted)
            .padding(.horizontal, Theme.Space.m)
            .padding(.top, Theme.Space.xl)
            .padding(.bottom, Theme.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// What a menu row looks like: a 24pt icon column, the page name, and, when it is the open page, a soft
/// selection fill with a short accent bar on the leading edge. The page name stays in the text color; the
/// bar and the icon carry the accent. A button around it (the drawer) or a link (the organization menu)
/// supplies the action.
struct MenuRowLabel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let icon: BloemIcon
    let selected: Bool
    /// Requests waiting for approval, shown on the Requests row; 0 shows nothing.
    var badge = 0

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            // One 24 column for every icon, so the labels start on one line.
            IconImage(icon, size: .row)
                .frame(width: 24)
                .foregroundStyle(selected ? Theme.accent : Theme.muted)
            Text(title)
                .bloemText(.titleMedium)
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.leading)
                // One line, as the spec says; only the largest text sizes may wrap.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Spacer(minLength: 0)
            if let count = RequestBadgeText.visible(badge) {
                // Something that needs you: the tally dot, then the count as quiet text, not a pill.
                HStack(spacing: Theme.Space.s) {
                    TallyDot()
                    Text(count)
                        .bloemText(.labelMedium)
                        .foregroundStyle(Theme.muted)
                        .accessibilityIdentifier(ShellID.menuBadge)
                }
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(maxWidth: .infinity, minHeight: Theme.minimumTarget, alignment: .leading)
        .background(selected ? Theme.selectionFill : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
        .contentShape(Rectangle())
    }
}

private struct MenuRow: View {
    let title: String
    let icon: BloemIcon
    let selected: Bool
    var badge = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            MenuRowLabel(title: title, icon: icon, selected: selected, badge: badge)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(RequestBadgeText.spoken(badge).map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
