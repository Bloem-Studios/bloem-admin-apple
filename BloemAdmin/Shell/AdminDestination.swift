import Foundation

/// The web admin's sidebar groups, in the order the menu lists them (web adminNavigation.ts
/// ADMIN_NAV_SECTIONS, bloemAdminNavigation.ts withBloemAdminNav): Platform, Monitor, Manage, Configure.
/// A group with no pages for the server at hand is left out of the menu. `organization` is the one group
/// of an organization's menu (bloemAdminNavigation.ts ORGANIZATION_ADMIN_NAV_SECTIONS).
enum AdminGroup: Int, CaseIterable, Comparable, Sendable {
    case platform, monitor, manage, configure, organization

    var label: LocalizedStringResource {
        switch self {
        case .platform: "Platform"
        case .monitor: "Monitor"
        case .manage: "Manage"
        case .configure: "Configure"
        case .organization: "Organization"
        }
    }

    static func < (lhs: AdminGroup, rhs: AdminGroup) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One page of the menu. `id` values are shared with the Android app, so a page has one name everywhere.
struct AdminDestination: Identifiable, Equatable, Sendable {
    let id: String
    let group: AdminGroup
    let label: LocalizedStringResource
    /// The page's Lucide icon, named by the shared concept table in docs/design.md.
    let icon: BloemIcon
    /// The web's description of the page, shown in page search.
    let pageDescription: LocalizedStringResource
    /// The web's English search synonyms for the page; never shown.
    let keywords: [String]

    static func == (lhs: AdminDestination, rhs: AdminDestination) -> Bool { lhs.id == rhs.id }
}

extension AdminDestination {
    // The web's lucide icons, the same ones: Radio, LayoutDashboard, History, ScrollText, Inbox, CalendarClock,
    // Users, Building2, SlidersHorizontal (the server's settings), ShieldCheck, Cpu.
    static let nowPlaying = AdminDestination(
        id: "live.streams", group: .monitor, label: "Now playing",
        icon: .radio,
        pageDescription: "Live streams and current playback sessions",
        keywords: ["streams", "sessions", "now playing", "transcode", "activity"]
    )
    static let dashboard = AdminDestination(
        id: "overview.dashboard", group: .monitor, label: "Dashboard",
        icon: .layoutDashboard,
        pageDescription: "Live sessions, content health, and server activity",
        keywords: ["overview", "stats", "health", "scan all"]
    )
    static let logs = AdminDestination(
        id: "system.logs", group: .monitor, label: "Logs",
        icon: .scrollText,
        pageDescription: "Server log stream and operational output",
        keywords: ["server logs", "debug", "tail", "events"]
    )
    /// The web's Libraries page (Manage > Libraries).
    static let libraries = AdminDestination(
        id: "content.libraries", group: .manage, label: "Libraries",
        icon: .library,
        pageDescription: "Media libraries, paths, scanning, and catalog import",
        keywords: ["library", "paths", "scan", "catalog", "seed", "libraries", "mount", "refresh metadata"]
    )
    static let requests = AdminDestination(
        id: "work.requests", group: .manage, label: "Requests",
        icon: .inbox,
        pageDescription: "Review, approve, and decline media requests",
        keywords: ["requested media", "approvals", "request queue", "decline"]
    )
    /// The web's Nodes page (Manage > Playback > Nodes); Android's id.
    static let nodes = AdminDestination(
        id: "playback.nodes", group: .manage, label: "Nodes",
        icon: .cpu,
        pageDescription: "Stream nodes, remote worker status, and where playback work runs",
        keywords: ["stream nodes", "workers", "transcode nodes", "proxy nodes", "routing", "egress",
                   "gpu offload", "central egress"]
    )
    /// The web's Backups page (Configure > Server > Backups).
    static let backups = AdminDestination(
        id: "system.backups", group: .configure, label: "Backups",
        icon: .archive,
        pageDescription: "Nightly backups of the database and uploaded files, and how to restore them",
        keywords: ["backup", "back up now", "restore", "recovery", "database dump", "pg_dump",
                   "disaster recovery", "copies to keep", "retention"]
    )
    /// The web's Plugins page (Configure > Integrations > Plugins).
    static let plugins = AdminDestination(
        id: "system.plugins", group: .configure, label: "Plugins",
        icon: .puzzle,
        pageDescription: "Plugin catalog, repositories, installs, and plugin configuration",
        keywords: ["extensions", "plugin catalog", "repositories"]
    )
    static let users = AdminDestination(
        id: "people.users", group: .manage, label: "Users",
        icon: .users,
        pageDescription: "Accounts, roles, profile settings, and access",
        keywords: ["accounts", "profiles", "roles", "permissions"]
    )
    /// What the web calls Playback history; the apps used to call it Activity.
    static let playbackHistory = AdminDestination(
        id: "live.activity", group: .manage, label: "Playback history",
        icon: .history,
        pageDescription: "Historical playback events across users and profiles",
        keywords: ["history", "watched", "progress", "plays", "activity"]
    )
    /// The server's own configuration. "Settings" (with the gear) is the app's page at the drawer's foot, so this
    /// one is "Server settings" with the sliders (maintainer, 2026-11-16: the foot reads Settings in every staff app).
    static let settings = AdminDestination(
        id: "system.server", group: .configure, label: "Server settings",
        icon: .slidersHorizontal,
        pageDescription: "Server name and address, sign-in, playback, logging, email, notifications and downloads, with tests and restart status",
        // The web's search words for the settings pages, so page search finds the page by what is on it. Words
        // other pages already answer to (transcode, scheduled, approve, audit, streams) stay out of this list.
        // Settings search inside the page covers every word, down to single settings.
        keywords: [
            "settings", "configuration", "server name", "login subtitle", "public url", "reverse proxy",
            "trusted proxies", "redis", "database", "log level", "smtp", "mail server", "password reset",
            "single sign-on", "sso", "tailscale", "netbird", "hardware acceleration", "hevc", "tone mapping",
            "bandwidth", "storage budget", "push relay", "apns", "fcm", "discord", "web push", "restart",
        ]
    )
    static let scheduledTasks = AdminDestination(
        id: "work.jobs", group: .configure, label: "Scheduled tasks",
        icon: .calendarClock,
        pageDescription: "Background task schedules, runs, and run history",
        keywords: ["tasks", "jobs", "scheduler", "sync"]
    )
    static let audit = AdminDestination(
        id: "system.audit", group: .monitor, label: "Audit",
        icon: .shieldCheck,
        pageDescription: "Who changed what on this server, and when",
        keywords: ["audit", "changes", "events", "who changed"]
    )
    static let organizations = AdminDestination(
        id: "platform.organizations", group: .platform, label: "Organizations",
        icon: .building2,
        pageDescription: "Every organization on this server, and its members",
        keywords: ["organizations", "tenants", "memberships"]
    )
    /// Break-glass support access: the server Owner opens a customer's organization, stating why. Shown only to
    /// the Owner on a server that offers it (`SupportAccessEligibility`).
    static let supportAccess = AdminDestination(
        id: "platform.support-access", group: .platform, label: "Support access",
        icon: .lifeBuoy,
        pageDescription: "Open a customer's organization to help its administrator, with a reason they can see",
        keywords: ["support", "break glass", "organizations", "help", "customer"]
    )
    /// The web's API Keys page (Configure > Sign-in and security), with Android's id. One server at a time, so it is
    /// not in All servers: a revoke must name the server it acts on.
    static let apiKeys = AdminDestination(
        id: "system.api-keys", group: .configure, label: "API keys",
        icon: .keyRound,
        pageDescription: "Admin API keys and tier assignment",
        keywords: ["tokens", "keys", "access", "scopes", "rate limit tier"]
    )

    /// An organization's page as page search reads it: a destination of the Organization group, named as the
    /// organization menu names it, with the web's words (Android's `organizationDestinations`). Its id never
    /// overlaps a platform page's.
    static func organization(_ page: OrganizationPage) -> AdminDestination {
        let id = organizationIDPrefix + page.rawValue
        switch page {
        case .overview:
            return AdminDestination(
                id: id, group: .organization, label: "Overview", icon: page.icon,
                pageDescription: "Members, libraries and recent changes at a glance",
                keywords: ["organization", "tenant", "health"]
            )
        case .people:
            return AdminDestination(
                id: id, group: .organization, label: "People", icon: page.icon,
                pageDescription: "Everyone in this organization, their profiles and their plan",
                keywords: ["people", "memberships", "profiles"]
            )
        case .streams:
            return AdminDestination(
                id: id, group: .organization, label: "Now playing", icon: page.icon,
                pageDescription: "Who is watching right now, on what, and whether it plays directly or is converted",
                keywords: ["streams", "sessions", "now playing", "watching"]
            )
        case .cohorts:
            return AdminDestination(
                id: id, group: .organization, label: "Cohorts", icon: page.icon,
                pageDescription: "Groups of accounts that share the same settings",
                keywords: ["entitlements", "cohorts", "policy", "revisions"]
            )
        case .groups:
            return AdminDestination(
                id: id, group: .organization, label: "Access groups", icon: page.icon,
                pageDescription: "Groups that set what their profiles can do",
                keywords: ["groups", "roles", "permissions"]
            )
        case .libraries:
            return AdminDestination(
                id: id, group: .organization, label: "Libraries", icon: page.icon,
                pageDescription: "Libraries this organization owns or has been given",
                keywords: ["libraries", "entitlements", "media ceiling", "grants"]
            )
        case .invitations:
            return AdminDestination(
                id: id, group: .organization, label: "Invitations", icon: page.icon,
                pageDescription: "Invite administrators and members to this organization",
                keywords: ["invitations", "invite", "members"]
            )
        case .decisions:
            return AdminDestination(
                id: id, group: .organization, label: "Access checks", icon: page.icon,
                pageDescription: "Why someone was allowed or refused something",
                keywords: ["policy", "decisions", "authorization", "access", "denied"]
            )
        case .activity:
            return AdminDestination(
                id: id, group: .organization, label: "Activity", icon: page.icon,
                pageDescription: "Who changed what in this organization, and when",
                keywords: ["activity", "audit", "events"]
            )
        }
    }

    private static let organizationIDPrefix = "organization."

    /// The organization page this destination stands for; nil for a platform page.
    var organizationPage: OrganizationPage? {
        guard id.hasPrefix(Self.organizationIDPrefix) else { return nil }
        return OrganizationPage(rawValue: String(id.dropFirst(Self.organizationIDPrefix.count)))
    }

    /// The page a server or All servers opens on: what is playing right now, then the rest.
    static let startID = nowPlaying.id

    /// The menu of one server. Logs belong to a single server. The Platform group holds Organizations, for a
    /// Bloem server (`tenantsVisible`), and Support access, for the server Owner; with neither the group is left out.
    static func singleServer(tenantsVisible: Bool, supportAccessVisible: Bool = false) -> [AdminDestination] {
        var pages: [AdminDestination] = []
        if tenantsVisible { pages.append(organizations) }
        if supportAccessVisible { pages.append(supportAccess) }
        // Audit sits with Logs in Monitor, as on Android (the web keeps it as a tab of Logs).
        pages.append(contentsOf: [dashboard, nowPlaying, logs, audit, libraries, requests, users, playbackHistory, nodes,
                                  settings, scheduledTasks, backups, apiKeys, plugins])
        return pages
    }

    /// The menu of All servers: the same pages without Logs (one server's) and Support access (one organization at a
    /// time). Organizations is a Bloem page: it leads the menu, as a section per server, only when at least one saved
    /// server is a Bloem server (`organizationsVisible`). With plain Silo servers only, the menu has no Platform group.
    static func allServers(organizationsVisible: Bool) -> [AdminDestination] {
        var pages: [AdminDestination] = []
        if organizationsVisible { pages.append(organizations) }
        pages.append(contentsOf: [dashboard, nowPlaying, audit, libraries, requests, users, playbackHistory, nodes,
                                  settings, scheduledTasks, backups, plugins])
        return pages
    }

    /// The All servers menu when a Bloem server is saved. The app builds its menu with
    /// `allServers(organizationsVisible:)`; this is the full list, for what is true of every page the menu can hold.
    static let allServers: [AdminDestination] = allServers(organizationsVisible: true)

    /// The menu's sections: every group that has pages, in group order, each with its pages in the
    /// order given. A group added to `AdminGroup` shows up with no further wiring.
    static func grouped(_ destinations: [AdminDestination]) -> [AdminMenuSection] {
        AdminGroup.allCases.compactMap { group -> AdminMenuSection? in
            let pages = destinations.filter { $0.group == group }
            guard !pages.isEmpty else { return nil }
            return AdminMenuSection(group: group, pages: pages)
        }
    }

    /// Pages in the order the menu shows them, which is also the order a sideways swipe walks.
    static func menuOrder(_ destinations: [AdminDestination]) -> [AdminDestination] {
        grouped(destinations).flatMap(\.pages)
    }

    /// The page `step` places after `currentID` in menu order (negative: before). There is no wrap-around:
    /// past either end, or when `currentID` is not in the menu, the answer is nil.
    static func adjacent(to currentID: String?, step: Int, in destinations: [AdminDestination]) -> AdminDestination? {
        let order = menuOrder(destinations)
        guard let currentID, let index = order.firstIndex(where: { $0.id == currentID }) else { return nil }
        let target = index + step
        return order.indices.contains(target) ? order[target] : nil
    }

    /// The page to show for `selectedID`: itself when the menu has it, otherwise the start page, otherwise
    /// the first page (a menu that lacks the start page).
    static func effective(selectedID: String?, in destinations: [AdminDestination]) -> AdminDestination? {
        if let selectedID, let match = destinations.first(where: { $0.id == selectedID }) { return match }
        return destinations.first { $0.id == startID } ?? menuOrder(destinations).first
    }

    /// The label as shown, in the interface language.
    var labelText: String { String(localized: label) }
    var descriptionText: String { String(localized: pageDescription) }
}

/// One group of the menu with its pages.
struct AdminMenuSection: Identifiable, Equatable {
    let group: AdminGroup
    let pages: [AdminDestination]

    var id: AdminGroup { group }
}

/// Sideways swipe on a page: left goes to the next page, right to the previous one.
enum PageSwipe {
    /// How far a finger must travel sideways before a swipe counts, in points.
    static let distance: CGFloat = 56
    /// A swipe must be this much more sideways than vertical, so scrolling a list is never a swipe.
    static let dominance: CGFloat = 1.5

    /// +1 after a swipe to the left (next page), -1 after a swipe to the right (previous page), 0 otherwise.
    static func step(forTranslation width: CGFloat, height: CGFloat) -> Int {
        guard abs(width) >= distance, abs(width) > abs(height) * dominance else { return 0 }
        return width < 0 ? 1 : -1
    }
}
