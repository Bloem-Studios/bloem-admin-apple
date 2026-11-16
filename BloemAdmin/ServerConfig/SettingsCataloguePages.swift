import Foundation

// The pages of the key catalogue. Page ids, titles, summaries and search words are the web's
// (`web/src/lib/adminSettingsSearch.ts`); labels and help are the words of the web page's controls
// (`web/src/pages/admin-settings`), with the product name in place of "Silo" and no full stop at
// the end of a help line. Every key and value was read against the server's settings registry
// (`internal/config/admin_settings.go`).

extension SettingsCatalogue {
    // MARK: General

    static let general = SettingsPage(
        id: "general", title: "General",
        summary: "The server's name and public address, the proxies in front of it, and Redis",
        icon: .slidersHorizontal,
        keywords: [
            "server name", "login subtitle", "branding name", "public url", "lan discovery", "local network",
            "local address", "lan address", "multicast", "reverse proxy", "trusted proxies", "x-forwarded-for",
            "client ip", "redis", "postgres", "database", "pool",
        ],
        sections: [
            SettingsSection("Identity", [
                SettingSpec("branding.server_name", "Server name", control: .text(), help: nil),
                SettingSpec(
                    "branding.login_subtitle", "Login subtitle", control: .text(),
                    help: "Shown under the server name on the sign-in page"
                ),
            ]),
            SettingsSection("Network", [
                SettingSpec(
                    "server.public_url", "Public URL", control: .text(placeholder: "https://silo.example.com", kind: .url),
                    help: "The HTTPS address people open. Used for websocket origins and links in email notifications"
                ),
                SettingSpec(
                    "server.lan_discovery", "Show on the local network", control: .toggle,
                    help: "Silo apps on the same network list this server when adding one, so nobody has to type its address. Needs a network that passes multicast (Docker host networking, not the default bridge)",
                    keywords: ["multicast", "lan"]
                ),
                SettingSpec(
                    "server.local_url", "Local network address",
                    control: .text(placeholder: "http://192.168.1.20:8080", kind: .url),
                    help: "Where devices on your home network reach the server directly: the host's IP and the port it listens on, or the published port under Docker. Leave empty when apps already find the server on the local network"
                ),
                SettingSpec(
                    "clientip.trusted_proxies", "Trusted proxies",
                    control: .text(placeholder: "172.16.0.0/12, 203.0.113.7/32"),
                    help: "Comma-separated proxy ranges; empty keeps the private defaults",
                    keywords: ["reverse proxy", "x-forwarded-for", "client ip"]
                ),
            ]),
            SettingsSection("Database", [
                SettingSpec(
                    "database.max_connections", "Maximum Postgres connections",
                    control: .number(min: 1),
                    help: "Raise only if the logs show connection-pool waits", keywords: ["pool", "postgres"]
                ),
            ]),
            SettingsSection("Redis", footer: "Needed when running more than one server", [
                SettingSpec(
                    "redis.url", "Connection URL", control: .secret,
                    help: "Replace the saved address, or clear it to turn Redis off", keywords: ["redis"]
                ),
                SettingSpec(
                    "redis.db", "Database number", control: .number(min: 0),
                    help: "Replaces the number in the URL. Installs sharing one Redis each need their own"
                ),
            ]),
        ],
        extras: [.connectionCheck(kind: "redis", keys: ["redis.url", "redis.db"])]
    )

    // MARK: Network access

    static let networkAccess = SettingsPage(
        id: "network-access", title: "Network access",
        summary: "Overlay-network providers such as Tailscale that reach this server without port forwarding",
        icon: .network,
        keywords: [
            "tailscale", "netbird", "overlay", "tailnet", "vpn", "remote access", "port forwarding",
            "network access provider", "plugin", "connect", "authorization",
        ],
        kind: .networkAccess
    )

    // MARK: Sign-in

    static let signIn = SettingsPage(
        id: "sign-in", title: "Sign-in",
        summary: "Silo passwords and signups, single sign-on, and network sign-in",
        icon: .keyRound,
        keywords: [
            "sso", "single sign-on", "oidc", "openid connect", "ldap", "active directory", "authentik",
            "authelia", "keycloak", "pocket id", "redirect uri", "callback url", "break-glass", "local password",
            "auto-create accounts", "email match", "provider logout", "rp-initiated logout", "bind dn",
            "base dn", "issuer", "client id", "signup", "invite", "forgot password", "password reset", "tailscale",
        ],
        sections: [
            SettingsSection("Passwords", [
                SettingSpec(
                    "auth.local_password_login", "Allow password sign-in", control: .toggle,
                    help: "Off: everyone signs in with the provider, except break-glass admins. Needs at least one break-glass admin; the server owner is one by default",
                    keywords: ["local password", "break-glass"]
                ),
                SettingSpec(
                    "signup.enabled", "Public signups", control: .toggle,
                    help: "Anyone with a valid invite code can create an account", keywords: ["signup", "invite"]
                ),
                SettingSpec(
                    "password_reset.self_service_enabled", "Self-service password reset", control: .toggle,
                    help: "Adds Forgot password to the sign-in page, so people can get a reset link by email. Needs email and the public URL",
                    keywords: ["forgot password", "password reset"]
                ),
            ]),
            SettingsSection("Single sign-on", footer: "Let people sign in with your identity provider. A server uses one provider at a time", [
                SettingSpec(
                    "auth.email_auto_match", "Match existing accounts by email", control: .toggle,
                    help: "A first sign-in connects to the regular account with the same email, when the provider says the email is verified. Whoever controls that email at the provider takes over the account, so turn this on only if the provider verifies every email",
                    keywords: ["email match"]
                ),
            ]),
        ],
        extras: [.signInProviders]
    )

    // MARK: Playback

    static let playback = SettingsPage(
        id: "playback", title: "Playback",
        summary: "Watch thresholds, transcoding, chapter thumbnails and seek previews, and skip markers",
        icon: .circlePlay,
        keywords: [
            "ffmpeg", "transcode", "hardware acceleration", "gpu", "hevc", "tone mapping", "chapter thumbnails",
            "trickplay", "seek preview", "watched threshold", "resume", "4k", "intro", "credits", "recap",
            "markers", "marker detection", "credits detection", "skip credits", "TheIntroDB",
            "online marker storage", "on-demand only", "store markers locally", "populate markers",
            "contribute markers", "scheduled online sync",
        ],
        sections: [
            SettingsSection("Watch behavior", [
                SettingSpec(
                    "playback.watched_threshold", "Mark watched at", control: .number(unit: "%", min: 1, max: 100),
                    keywords: ["watched threshold"]
                ),
                SettingSpec(
                    "playback.min_resume_threshold", "Show in Continue Watching after",
                    control: .number(unit: "%", min: 0, max: 100),
                    help: "Progress below this is ignored", keywords: ["resume"]
                ),
            ]),
            SettingsSection("Transcoding", [
                SettingSpec(
                    "playback.transcode_enabled", "Video transcoding", control: .toggle,
                    help: "Off never re-encodes video. Silo still repackages files and converts audio for devices that need it",
                    keywords: ["transcode", "ffmpeg"]
                ),
                SettingSpec(
                    "playback.hw_accel", "Hardware acceleration",
                    control: .choice([
                        SettingChoice("auto", "Auto"), SettingChoice("none", "Software"),
                        SettingChoice("nvenc", "NVENC"), SettingChoice("qsv", "Quick Sync"),
                        SettingChoice("vaapi", "VA-API"), SettingChoice("videotoolbox", "VideoToolbox"),
                    ]),
                    help: "Auto picks the best device. If startup fails, it keeps GPU encoding with CPU decoding before falling back to software",
                    keywords: ["gpu", "nvidia", "intel"]
                ),
                SettingSpec(
                    "allow_4k_transcode", "Allow 4K transcoding", control: .toggle,
                    help: "Heavy load on most hardware", keywords: ["4k", "uhd"]
                ),
                SettingSpec(
                    "playback.prefer_lower_version_transcode", "Prefer 1080p versions", control: .toggle,
                    help: "Transcode from the 1080p version instead of the 4K file when both exist"
                ),
                SettingSpec(
                    "playback.allow_hevc_encoding", "Allow HEVC encoding", control: .toggle,
                    help: "Use HEVC for clients that support HEVC over HLS. Other clients keep H.264", keywords: ["hevc"]
                ),
                SettingSpec(
                    "playback.transcode_hardware_tone_map_enabled", "Hardware HDR tone mapping", control: .toggle,
                    help: "Allows validated local or remote GPU executors to convert HDR video to SDR when transcoding",
                    keywords: ["tone mapping", "hdr"]
                ),
                SettingSpec(
                    "playback.transcode_software_tone_map_enabled", "Software HDR tone mapping", control: .toggle,
                    help: "Allows the CPU to convert HDR video to SDR when transcoding. This can be very CPU-intensive",
                    keywords: ["tone mapping", "hdr"]
                ),
                SettingSpec(
                    "enable_transcode_throttle", "Throttle transcoding", control: .toggle,
                    help: "Pause encoding once the client is far enough ahead"
                ),
                SettingSpec(
                    "transcode_throttle_seconds", "Buffer ahead", control: .number(unit: "seconds", min: 1),
                    help: "How far ahead of the client encoding runs before it pauses"
                ),
                SettingSpec(
                    "playback.segment_retention_seconds", "Transcode back buffer",
                    control: .number(unit: "seconds", min: 0),
                    help: "Keeps this much already-downloaded media for instant backward seeking, then reclaims older transcode segments. Use 0 to disable cleanup; enabled values must be at least 120 seconds"
                ),
            ]),
            SettingsSection("Connection speed tests", [
                SettingSpec(
                    "playback.bandwidth_probe_automatic", "Automatic speed tests", control: .toggle,
                    help: "Apps test a device's connection only when the server has no current reading for it. Off, viewers can still run Test speed in their own settings"
                ),
            ]),
            SettingsSection("Skip markers", footer: "Markers identify intros, credits, recaps, and previews so players can offer skip controls", [
                SettingSpec(
                    "markers.mode", "Marker source",
                    control: .choice([
                        SettingChoice("off", "Off"), SettingChoice("local", "Detect on this server"),
                        SettingChoice("both", "Online preferred + server detection"),
                        SettingChoice("online", "Online providers only"),
                    ]),
                    help: "Online markers take priority. Local detection uses CPU",
                    keywords: ["intro", "credits", "skip"]
                ),
                SettingSpec(
                    "markers.detect_intros", "Detect intros", control: .toggle,
                    help: "Finds each episode's opening from embedded chapters, or by comparing the start of episodes in a season"
                ),
                SettingSpec(
                    "markers.detect_credits", "Detect credits", control: .toggle,
                    help: "Finds end credits from embedded chapters, or by reading the end of each episode and movie. Uses more CPU than intro detection"
                ),
            ]),
        ]
    )

    // MARK: Logging

    static let logging = SettingsPage(
        id: "logging", title: "Logging",
        summary: "What the server logs, and how much log history the database keeps",
        icon: .scrollText,
        keywords: [
            "log level", "debug", "quiet", "silenced log messages", "ops log", "retention", "decision log",
            "permission checks", "opa", "audit",
        ],
        sections: [
            SettingsSection("Server log", [
                SettingSpec(
                    "server.log_level", "Log level",
                    control: .choice([
                        SettingChoice("debug", "Debug"), SettingChoice("info", "Info"),
                        SettingChoice("warn", "Warn"), SettingChoice("error", "Error"),
                    ]),
                    help: "Sets the container log's level; Debug is loud, so keep it for chasing a problem. The Logs page records Info and above either way"
                ),
                SettingSpec(
                    "server.log_quiet", "Quiet log prefixes", control: .text(),
                    help: "Drops log lines starting with any of these words", keywords: ["silenced log messages"]
                ),
            ]),
            SettingsSection("Log retention", footer: "How much log history the database keeps", [
                SettingSpec(
                    "opslog.retention_days", "Delete log entries older than", control: .number(unit: "days", min: 1)
                ),
                SettingSpec("opslog.max_size_mb", "Maximum log size", control: .number(unit: "MB", min: 1)),
                SettingSpec("opslog.max_rows", "Maximum log entries", control: .number(min: 1)),
            ]),
            SettingsSection("Permission checks", [
                SettingSpec(
                    "policy.decision_log_retention_days", "Delete permission records older than",
                    control: .number(unit: "days", min: 1)
                ),
                SettingSpec(
                    "policy.decision_log_verbosity", "How much to record",
                    control: .choice([SettingChoice("digest", "Summary"), SettingChoice("verbose", "Full")]),
                    help: "Full also stores a sample of each request"
                ),
            ]),
        ]
    )

    // MARK: Email

    static let email = SettingsPage(
        id: "email", title: "Email",
        summary: "The mail server Silo sends invitations, password resets, and notification emails through",
        icon: .mail,
        keywords: ["email", "smtp", "mail", "mail server", "invitations", "password reset", "test email"],
        sections: [
            SettingsSection("Mail server", footer: "Silo sends invitations, password resets, and notification emails through it", [
                SettingSpec("email.enabled", "Send email from this server", control: .toggle),
                SettingSpec("email.from_address", "From address", control: .text(kind: .email)),
                SettingSpec("email.from_name", "From name", control: .text()),
                SettingSpec(
                    "email.smtp_host", "Mail server address", control: .text(placeholder: "smtp.example.com"),
                    keywords: ["smtp"]
                ),
                SettingSpec(
                    "email.smtp_port", "Port", control: .number(min: 1, max: 65535),
                    help: "587 for STARTTLS (typical), 465 for implicit TLS"
                ),
                SettingSpec(
                    "email.smtp_security", "Encryption",
                    control: .choice([
                        SettingChoice("starttls", "STARTTLS"), SettingChoice("tls", "TLS (implicit)"),
                        SettingChoice("none", "None (insecure)"),
                    ]),
                    help: "Use whatever your mail provider documents"
                ),
                SettingSpec(
                    "email.smtp_username", "Username", control: .text(),
                    help: "Leave empty if the mail server needs no sign-in"
                ),
                SettingSpec("email.smtp_password", "Password", control: .secret),
            ]),
        ],
        extras: [.emailTest]
    )

    // MARK: Notifications

    static let notifications = SettingsPage(
        id: "notifications", title: "Notifications",
        summary: "Delivery channels, server channels, and how new content becomes notifications",
        icon: .bell,
        keywords: [
            "release events", "new episode", "silo push relay", "mobile push", "apns", "fcm", "discord",
            "web push", "webhooks", "server channels", "digest", "retention", "email",
        ],
        sections: [
            SettingsSection("Delivery channels", footer: "Where notifications go", [
                SettingSpec(
                    "notifications.ui_enabled", "In-app", control: .toggle,
                    help: "Notification inbox in the web, mobile, and TV apps"
                ),
                SettingSpec(
                    "notifications.web_push_enabled", "Web push", control: .toggle,
                    help: "Browser push to subscribed devices"
                ),
                SettingSpec(
                    "notifications.apple_push_delivery_enabled", "Apple push (APNs)", control: .toggle,
                    help: "Mobile push through the push relay", keywords: ["apns", "mobile push"]
                ),
                SettingSpec(
                    "notifications.android_push_delivery_enabled", "Android push (FCM)", control: .toggle,
                    help: "Mobile push through the push relay", keywords: ["fcm", "mobile push"]
                ),
            ]),
            SettingsSection("Email", footer: "Daily summary or a message per episode, for people who opt in", [
                SettingSpec("notifications.email_enabled", "Send notification emails", control: .toggle),
                SettingSpec(
                    "notifications.email.allow_per_episode", "Let people pick an email per episode", control: .toggle,
                    help: "Off sends them the daily summary instead"
                ),
                SettingSpec(
                    "notifications.email.digest_hour", "Daily summary hour", control: .number(min: 0, max: 23),
                    help: "Hour of the day, 0 to 23, in the server's own time zone", keywords: ["digest"]
                ),
            ]),
            SettingsSection("Discord", footer: "Direct messages from your Discord bot to linked accounts", [
                SettingSpec("notifications.discord_enabled", "Send Discord messages", control: .toggle, keywords: ["discord"]),
                SettingSpec(
                    "notifications.discord.allow_per_episode", "Let people pick a DM per episode", control: .toggle,
                    help: "Off sends them the daily summary instead"
                ),
                SettingSpec(
                    "notifications.discord.digest_hour", "Daily summary hour", control: .number(min: 0, max: 23),
                    help: "Hour of the day, 0 to 23, in the server's own time zone", keywords: ["digest"]
                ),
            ]),
            SettingsSection("Server channels", footer: "Server-wide announcements posted to a shared destination", [
                SettingSpec(
                    "notifications.server_channels_enabled", "Post to server channels", control: .toggle,
                    keywords: ["webhooks"]
                ),
                SettingSpec(
                    "notifications.server_channels.batch_seconds", "Batch window",
                    control: .number(unit: "seconds", min: 0),
                    help: "New content waits this long so a season posts as one message"
                ),
                SettingSpec(
                    "notifications.server_channels.mention_requesters", "Mention the requester on Discord", control: .toggle,
                    help: "Unlinked accounts show their username instead"
                ),
            ]),
            SettingsSection("Processing", footer: "How new content is noticed, grouped into messages, and how long it is kept", [
                SettingSpec(
                    "notifications.release_events_enabled", "Notice new content", control: .toggle,
                    help: "Record new items during library scans", keywords: ["release events", "new episode"]
                ),
                SettingSpec(
                    "notifications.fanout_enabled", "Work out who wants it", control: .toggle,
                    help: "Match each item against everyone's preferences"
                ),
                SettingSpec(
                    "notifications.fanout.settle_seconds", "Settle window", control: .number(unit: "seconds", min: 0),
                    help: "Items that finish scanning together arrive as one notification"
                ),
                SettingSpec(
                    "notifications.fanout.max_series_burst", "Max messages per show", control: .number(min: 1),
                    help: "Anything past this is skipped for that batch"
                ),
                SettingSpec(
                    "notifications.fanout.max_event_age_hours", "Max content age", control: .number(unit: "hours", min: 1),
                    help: "Older items are dropped instead of arriving as stale news"
                ),
            ]),
            SettingsSection("Retention", [
                SettingSpec("notifications.retention.read_days", "Read notifications", control: .number(unit: "days", min: 1)),
                SettingSpec("notifications.retention.unread_days", "Unread notifications", control: .number(unit: "days", min: 1)),
                SettingSpec("notifications.retention.event_days", "Notification events", control: .number(unit: "days", min: 1)),
            ]),
        ],
        extras: [.serverChannels]
    )

    // MARK: Downloads

    static let downloads = SettingsPage(
        id: "downloads", title: "Downloads",
        summary: "Offline downloads, per-user and server-wide limits, and prepared copies",
        icon: .download,
        keywords: [
            "downloads", "offline", "bandwidth", "mbps", "throttle", "quota", "concurrency", "prepared copies",
            "artifacts", "storage budget", "cache", "disk ceiling",
        ],
        sections: [
            SettingsSection("Downloads", [
                SettingSpec(
                    "download.enabled", "Allow downloads", control: .toggle,
                    help: "The switch for the whole server. On, access groups and accounts decide who may download. Off, nobody can"
                ),
                SettingSpec(
                    "download.transcode_enabled", "Prepare device-friendly copies", control: .toggle,
                    help: "Converts video the device can't play and offers lower qualities. Off, every download keeps the original video, even where the device can't play it"
                ),
                SettingSpec(
                    "download.max_concurrent_prepares", "Files prepared at once", control: .number(min: 0),
                    help: "0 uses the built-in default of 2"
                ),
                SettingSpec(
                    "download.local_transcode_fallback", "Prepare locally when workers are unavailable", control: .toggle,
                    help: "This is separate from live playback routing"
                ),
            ]),
            SettingsSection("Per user", [
                SettingSpec(
                    "download.user_bandwidth_mbps", "Per-user bandwidth", control: .number(unit: "Mbps", min: 0),
                    help: "0 means no limit", keywords: ["throttle"]
                ),
                SettingSpec(
                    "download.max_concurrent_per_user", "Downloads at once per user", control: .number(min: 0),
                    help: "Counted per user, alongside the per-user bandwidth cap"
                ),
                SettingSpec(
                    "download.max_per_period", "Downloads per period", control: .number(min: 0),
                    help: "How many each user may start in the period below. 0 means no limit", keywords: ["quota"]
                ),
                SettingSpec(
                    "download.period_duration", "Period length", control: .text(placeholder: "24h"),
                    help: "Rolling window each user's count is measured over, for example 24h or 168h"
                ),
            ]),
            SettingsSection("Whole server", [
                SettingSpec(
                    "download.server_bandwidth_mbps", "Server bandwidth", control: .number(unit: "Mbps", min: 0),
                    help: "All downloads on this server combined. 0 means no limit", keywords: ["throttle"]
                ),
                SettingSpec(
                    "download.artifact_max_bytes", "Default storage budget per location",
                    control: .number(unit: "GB", min: 0, scale: 1_000_000_000),
                    help: "Applies to this server and to every node without its own budget. 0 means unlimited",
                    keywords: ["storage budget", "cache"]
                ),
                SettingSpec(
                    "download.artifact_disk_ceiling_percent", "Disk ceiling", control: .number(unit: "%", min: 50, max: 95),
                    help: "Above this disk fill, cached files at that location are deleted early, whatever the budget"
                ),
                SettingSpec(
                    "download.artifact_cache_hours", "Keep cached files for", control: .number(unit: "hours", min: 0, max: 720),
                    help: "Hours a prepared file nothing is waiting on stays after its last use. 0 deletes it once nothing needs it and it has gone unused for ten minutes"
                ),
            ]),
        ]
    )

    // MARK: Requests

    static let requests = SettingsPage(
        id: "requests", title: "Requests",
        summary: "Request limits and approval, the Sonarr and Radarr servers, and where requests go",
        icon: .inbox,
        keywords: [
            "requests", "media requests", "sonarr", "radarr", "arr", "request servers", "routing", "routes",
            "rules", "anime", "quota", "request limit", "approval", "auto approve", "4k", "root folder",
            "quality profile", "overseerr", "jellyseerr", "watchlist",
        ],
        kind: .requests
    )
}
