import SwiftUI

private let overviewDays = 30

/// Who this is, what they can reach, their profiles and a month of watching, as the web's Overview.
struct UserOverviewTab: View {
    let user: AdminUser
    let capabilities: UserCapabilities?
    @State private var profiles: SectionLoader<[UserProfile]>
    @State private var stats: SectionLoader<WatchSummary>
    @State private var watching: SectionLoader<[AdminSession]>
    private let client: APIClient

    init(user: AdminUser, admin: UserAdmin, capabilities: UserCapabilities?) {
        self.user = user
        self.capabilities = capabilities
        let client = admin.client
        self.client = client
        let id = user.id
        _watching = State(initialValue: SectionLoader(serverName: admin.serverName, sessionState: admin.sessionState) {
            try await client.watchingNow(userID: id)
        })
        _profiles = State(initialValue: SectionLoader(serverName: admin.serverName, sessionState: admin.sessionState) {
            try await client.userProfiles(userID: id)
        })
        _stats = State(initialValue: SectionLoader(serverName: admin.serverName, sessionState: admin.sessionState) {
            try await client.userWatchSummary(userID: id, days: overviewDays)
        })
    }

    private var showStats: Bool { capabilities?.watchSummary == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailCard(WatchingNowText.heading(count: watching.state.value?.count ?? 0)) {
                LoadStateBody(state: watching.state, retry: { Task { await watching.load() } }) { rows in
                    if rows.isEmpty { Text(WatchingNowText.empty).foregroundStyle(.bloemMuted) }
                    ForEach(rows) { session in
                        let line = WatchingNowText.line(session)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(line.title).bloemText(.titleSmall)
                            Text("\(line.status) · \(line.detail)").bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("watching-now-\(session.sessionID)")
                    }
                }
            }
            DetailCard(String(localized: "Details")) {
                FieldLine(String(localized: "Email"), user.email)
                FieldLine(String(localized: "Role"), Vocabulary.role(user.roleLabel))
            }
            DetailCard(String(localized: "Access")) {
                AccessSummaryLines(user: user)
            }
            DetailCard(String(localized: "Profiles")) {
                LoadStateBody(state: profiles.state, retry: { Task { await profiles.load() } }) { list in
                    if list.isEmpty { Text("No profiles").foregroundStyle(.bloemMuted) }
                    ForEach(list) { profile in
                        if let seen = UserFormat.date(profile.lastSeenAt) {
                            Text("\(profile.name) · Last seen \(seen)")
                        } else {
                            Text(profile.name)
                        }
                    }
                }
            }
            if showStats {
                DetailCard(String(localized: "Last \(overviewDays) days")) {
                    LoadStateBody(state: stats.state, retry: { Task { await stats.load() } }) { summary in
                        if summary.plays == 0 {
                            Text("Nothing played yet").foregroundStyle(.bloemMuted)
                        } else {
                            Text("Plays: \(summary.plays) (\(summary.completedPlays) finished)")
                            Text("Watch time: \(UserFormat.watchTime(summary.watchedSeconds))")
                            if let last = UserFormat.date(summary.lastPlayedAt) {
                                Text("Last played \(last)")
                            }
                        }
                    }
                }
            }
        }
        .task { await profiles.load() }
        // Watching now follows the `sessions` channel while the tab is on screen and the app is in the foreground.
        .liveRefresh(client: client, channels: [.sessions]) { await watching.load() }
        // The server's capabilities can arrive after the tab is shown, so the stats follow them.
        .task(id: showStats) { if showStats { await stats.load() } }
    }
}

/// The account's effective limits, as the server resolved them.
struct AccessSummaryLines: View {
    let user: AdminUser

    var body: some View {
        if let policy = user.effectivePolicy {
            if let libraries = policy.libraryIDs {
                Text("Libraries: \(libraries.count)")
            } else {
                Text("Libraries: all")
            }
            Text("Max streams: \(policy.maxStreams)")
            Text("Max transcodes: \(policy.maxTranscodes)")
            Text("Max profiles: \(policy.maxProfiles)")
            Text(policy.downloadAllowed ? "Downloads: allowed" : "Downloads: not allowed")
            Text(policy.requestsAllowed ? "Requests: allowed" : "Requests: not allowed")
        } else {
            Text("Unknown").foregroundStyle(.bloemMuted)
        }
    }
}

/// Sign-in: how the account signs in, then its sessions and devices with Revoke and Revoke all sessions.
struct UserSignInTab: View {
    let user: AdminUser
    let admin: UserAdmin
    let capabilities: UserCapabilities?
    let canRevoke: Bool

    @State private var model = UserSessionsViewModel()
    @State private var sessionPendingRevoke: AuthSession?
    @State private var confirmRevokeAll = false
    @State private var isWorking = false
    @State private var revokeSucceeded = false
    @Environment(\.showsClientIPs) private var showsClientIPs

    // An unknown capability (the read failed) keeps the section.
    private var sessionsAvailable: Bool { capabilities?.loginSessions != false }
    private var devicesAvailable: Bool { capabilities?.accountDevices != false }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailCard(String(localized: "Password")) {
                Text(user.passwordLogin ? "Password sign-in" : "External sign-in")
                Text(user.passwordLogin
                     ? "This account signs in with a password."
                     : "This account signs in through an external provider and has no password. Setting one turns password sign-in on.")
                    .foregroundStyle(.bloemMuted)
                if user.passwordChangeRequired {
                    Text("The password is temporary. They must choose a new one at their next sign-in.")
                        .foregroundStyle(.bloemWarn)
                }
            }
            DetailCard(String(localized: "Sessions & devices")) {
                if !sessionsAvailable {
                    Text("Sessions are not available on this server").foregroundStyle(.bloemMuted)
                }
                if !devicesAvailable {
                    Text("Devices are not available on this server").foregroundStyle(.bloemMuted)
                }
                if sessionsAvailable || devicesAvailable {
                    panel
                }
            }
        }
        .task(id: "\(user.id)|\(sessionsAvailable)|\(devicesAvailable)") { await reload() }
        .sensoryFeedback(.success, trigger: revokeSucceeded)
        .confirmationDialog(
            "Revoke this session?",
            isPresented: Binding(get: { sessionPendingRevoke != nil }, set: { if !$0 { sessionPendingRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let session = sessionPendingRevoke { Task { await revoke(session) } }
                sessionPendingRevoke = nil
            }
            Button("Cancel", role: .cancel) { sessionPendingRevoke = nil }
        } message: {
            Text("The device using this session will be signed out immediately")
        }
        .confirmationDialog("Sign out of every device?", isPresented: $confirmRevokeAll, titleVisibility: .visible) {
            Button("Revoke all sessions", role: .destructive) { Task { await revokeAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            // If the user being viewed is the admin themself, this ends their own session too. The
            // warning says so unconditionally rather than guessing who "me" is.
            Text("Every device this user is signed in on will be signed out immediately. If this user is your own admin account, this will also sign YOU out.")
        }
    }

    @ViewBuilder
    private var panel: some View {
        if let message = model.actionErrorMessage {
            Text(message).foregroundStyle(.bloemDanger)
        } else if let revoked = model.revokedCount {
            Text("Revoked \(revoked) sessions")
        }
        if sessionsAvailable { sessionsList }
        if devicesAvailable { devicesList }
    }

    @ViewBuilder
    private var sessionsList: some View {
        HStack {
            Text("Sessions").bloemText(.titleMedium)
            Spacer()
            if canRevoke && !model.sessions.isEmpty {
                Button("Revoke all sessions") { confirmRevokeAll = true }
                    .frame(minHeight: 44)
                    .disabled(isWorking)
            }
        }
        switch model.sessionsPresentation {
        case .loading:
            Text("Loading…").foregroundStyle(.bloemMuted)
        case .failure:
            if let message = model.sessionsErrorMessage { Text(message).foregroundStyle(.bloemDanger) }
            Button("Try again") { Task { await reload() } }.frame(minHeight: 44)
        case .empty:
            Text("No active sessions")
        case .content:
            ForEach(model.sessions) { session in
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.deviceName.isEmpty ? String(localized: "Unknown device") : session.deviceName)
                        ForEach(UserSessionText.sessionLines(session, showsIPs: showsClientIPs), id: \.self) { line in
                            Text(line).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                        }
                    }
                    Spacer(minLength: 8)
                    if canRevoke {
                        Button("Revoke", role: .destructive) { sessionPendingRevoke = session }
                            .frame(minHeight: 44)
                            .disabled(isWorking)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var devicesList: some View {
        Text("Devices").bloemText(.titleMedium).padding(.top, 8)
        switch model.devicesPresentation {
        case .loading:
            Text("Loading…").foregroundStyle(.bloemMuted)
        case .failure:
            if let message = model.devicesErrorMessage { Text(message).foregroundStyle(.bloemDanger) }
            Button("Try again") { Task { await reload() } }.frame(minHeight: 44)
        case .empty:
            Text("No known devices")
        case .content:
            ForEach(model.devices) { device in
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.deviceName)
                    Text(device.devicePlatform.capitalized).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    Text(UserSessionText.deviceLastSeen(device)).bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func reload() async {
        model.serverName = admin.serverName
        await model.load(
            userID: user.id, client: admin.client, sessionState: admin.sessionState,
            includeSessions: sessionsAvailable, includeDevices: devicesAvailable
        )
    }

    private func revoke(_ session: AuthSession) async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await model.revokeSession(session, userID: user.id, client: admin.client, sessionState: admin.sessionState)
        if model.actionErrorMessage == nil {
            revokeSucceeded.toggle()
            await reload()
        }
    }

    private func revokeAll() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await model.revokeAllSessions(userID: user.id, client: admin.client, sessionState: admin.sessionState)
        if model.actionErrorMessage == nil {
            revokeSucceeded.toggle()
            await reload()
        }
    }
}

/// Activity: this user's playback history (the Activity screen's endpoint, filtered by user id) and
/// where they signed in from.
struct UserActivityTab: View {
    let user: AdminUser
    @State private var history: PagedFeed<PlaybackHistoryEntry>
    @State private var ips: SectionLoader<[UserIP]>
    @Environment(\.showsClientIPs) private var showsClientIPs

    init(user: AdminUser, admin: UserAdmin) {
        self.user = user
        let client = admin.client
        let id = user.id
        _history = State(initialValue: PagedFeed(serverName: admin.serverName, sessionState: admin.sessionState) { cursor in
            try await client.playbackHistory(filter: HistoryFilter(userID: id), cursor: cursor)
        })
        _ips = State(initialValue: SectionLoader(serverName: admin.serverName, sessionState: admin.sessionState) {
            try await client.userIPs(userID: id, days: 30)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailCard(String(localized: "Watch history")) {
                if !history.hasLoaded && history.errorMessage == nil {
                    Text("Loading…").foregroundStyle(.bloemMuted)
                }
                if let message = history.errorMessage {
                    Text(message).foregroundStyle(.bloemDanger)
                    Button("Try again") { Task { if history.hasLoaded { await history.loadMore() } else { await history.reload() } } }
                        .frame(minHeight: 44)
                }
                if history.hasLoaded && history.items.isEmpty && history.errorMessage == nil {
                    Text("No playback yet").foregroundStyle(.bloemMuted)
                }
                ForEach(history.items) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.mediaTitle)
                        let when = UserFormat.dateTime(entry.startedAt) ?? ""
                        Text("\(when) · \(entry.completed ? String(localized: "Completed") : String(localized: "Partial"))")
                            .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                    }
                    .accessibilityElement(children: .combine)
                }
                if history.hasMore {
                    Button("Load more") { Task { await history.loadMore() } }
                        .frame(minHeight: 44)
                        .disabled(history.isLoading)
                }
            }
            if showsClientIPs {
                DetailCard(String(localized: "IP addresses")) {
                    LoadStateBody(state: ips.state, retry: { Task { await ips.load() } }) { list in
                        if list.isEmpty { Text("No sign-ins in the last 30 days").foregroundStyle(.bloemMuted) }
                        ForEach(list) { ip in
                            VStack(alignment: .leading, spacing: 4) {
                                Text([ip.clientIP, ip.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                Text("\(ip.requestCount) requests · last \(UserFormat.dateTime(ip.lastSeen) ?? "")")
                                    .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                }
            }
        }
        .task {
            await history.reload()
            if showsClientIPs { await ips.load() }
        }
    }
}

/// Downloads: what this user has on their devices, read-only. Shown only when the server offers
/// account downloads.
struct UserDownloadsTab: View {
    let user: AdminUser
    @State private var summary: SectionLoader<UserDownloadSummary>
    @State private var feed: PagedFeed<UserDownload>

    init(user: AdminUser, admin: UserAdmin) {
        self.user = user
        let client = admin.client
        let id = user.id
        _summary = State(initialValue: SectionLoader(serverName: admin.serverName, sessionState: admin.sessionState) {
            try await client.userDownloadSummary(userID: id)
        })
        _feed = State(initialValue: PagedFeed(serverName: admin.serverName, sessionState: admin.sessionState) { cursor in
            try await client.userDownloads(userID: id, cursor: cursor)
        })
    }

    var body: some View {
        DetailCard(String(localized: "Downloads")) {
            LoadStateBody(state: summary.state, retry: { Task { await summary.load() } }) { s in
                Text("\(s.total) downloads on \(s.devices) devices: \(s.completed) done, \(s.inProgress) in progress, \(s.failed) failed")
                if s.totalBytes > 0 {
                    Text(UserFormat.bytes(s.totalBytes)).foregroundStyle(.bloemMuted)
                }
            }
            if !feed.hasLoaded && feed.errorMessage == nil {
                Text("Loading…").foregroundStyle(.bloemMuted)
            }
            if let message = feed.errorMessage {
                Text(message).foregroundStyle(.bloemDanger)
                Button("Try again") { Task { if feed.hasLoaded { await feed.loadMore() } else { await feed.reload() } } }
                    .frame(minHeight: 44)
            }
            if feed.hasLoaded && feed.items.isEmpty && feed.errorMessage == nil {
                Text("No downloads").foregroundStyle(.bloemMuted)
            }
            ForEach(feed.items) { download in
                VStack(alignment: .leading, spacing: 4) {
                    Text(download.title)
                    Text("\(download.status) · \(UserFormat.bytes(download.fileSize))")
                        .bloemText(.bodySmall).foregroundStyle(.bloemMuted)
                }
                .accessibilityElement(children: .combine)
            }
            if feed.hasMore {
                Button("Load more") { Task { await feed.loadMore() } }
                    .frame(minHeight: 44)
                    .disabled(feed.isLoading)
            }
        }
        .task {
            async let summaryRead: Void = summary.load()
            async let feedRead: Void = feed.reload()
            _ = await (summaryRead, feedRead)
        }
    }
}
