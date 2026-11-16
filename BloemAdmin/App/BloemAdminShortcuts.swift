import AppIntents

/// The App Shortcuts Siri, Spotlight and the Shortcuts app offer without any setup. Each opens a page
/// across all servers; the intents also take a server, which can be chosen in the Shortcuts app.
///
/// App Shortcuts can only name an SF Symbol for their glyph, and the Bloem look has none, so they show the
/// app icon. The Home Screen quick actions (Info.plist) do use the Lucide icons.
struct BloemAdminShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenNowPlayingIntent(),
            phrases: [
                "Open Now playing in \(.applicationName)",
                "Show Now playing in \(.applicationName)",
            ],
            shortTitle: "Now playing"
        )
        AppShortcut(
            intent: OpenRequestsIntent(),
            phrases: [
                "Open Requests in \(.applicationName)",
                "Show Requests in \(.applicationName)",
            ],
            shortTitle: "Requests"
        )
        AppShortcut(
            intent: OpenDashboardIntent(),
            phrases: [
                "Open Dashboard in \(.applicationName)",
                "Show Dashboard in \(.applicationName)",
            ],
            shortTitle: "Dashboard"
        )
    }
}
