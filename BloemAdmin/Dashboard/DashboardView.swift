import SwiftUI

/// The single-server dashboard: the web's default sections in the web's order. Each section loads
/// on its own when the dashboard opens, when the app returns to the foreground and on pull to refresh
/// (the slow ones at most every five minutes), and keeps its last good value beside an error. Only the
/// live part, Now playing, follows the server's `sessions` channel; if the socket is down for good the
/// whole dashboard is read at most once a minute.
struct DashboardView: View {
    let client: APIClient
    /// Opens Now playing; nil hides "Manage streams".
    var onShowStreams: (() -> Void)?
    /// Opens Users; nil hides "Manage users".
    var onShowUsers: (() -> Void)?
    /// Opens Nodes from the health strip; nil leaves the Nodes cell plain.
    var onShowNodes: (() -> Void)?
    @Environment(\.adminSessionState) private var sessionState
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = DashboardViewModel()
    /// The session list behind Now playing, kept current by the events socket.
    @State private var live: LiveSessions

    init(client: APIClient, onShowStreams: (() -> Void)? = nil, onShowUsers: (() -> Void)? = nil, onShowNodes: (() -> Void)? = nil) {
        self.client = client
        self.onShowStreams = onShowStreams
        self.onShowUsers = onShowUsers
        self.onShowNodes = onShowNodes
        _live = State(initialValue: LiveSessions(client: client))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message = model.errorMessage, model.hasAnyValue {
                    PartialFailureBanner(message: message) {
                        Task { await model.load(client: client, sessionState: sessionState, forceRefresh: true) }
                    }
                }
                DashboardSectionsView(model: model, onShowStreams: onShowStreams, onShowUsers: onShowUsers, onShowNodes: onShowNodes)
            }
            .padding()
        }
        .overlay {
            if !model.hasLoadedAnything {
                ProgressView()
            } else if let message = model.errorMessage, !model.hasAnyValue {
                LoadFailureView(failure: (model.serverFailure ?? .serverFailure(statusCode: nil, message: message)).replacingMessage(message)) {
                    Task { await model.load(client: client, sessionState: sessionState, forceRefresh: true) }
                }
            }
        }
        .navigationTitle("Dashboard")
        // Read on open and on each return to the foreground, with no timer. Only a fallback tick (the
        // socket has been down for three attempts) reads it again, and that never force-refreshes the
        // server's cache; only pull to refresh does.
        .liveRefresh(
            client: client, channels: [],
            initial: {
                model.beginLiveSessions()
                await model.load(client: client, sessionState: sessionState)
            },
            onSignals: { signals in
                if signals.contains(.fallback) { await model.load(client: client, sessionState: sessionState) }
            }
        )
        // Now playing follows the `sessions` channel of the shared socket; it stops when the app leaves
        // the foreground.
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            live.sessionState = sessionState
            model.beginLiveSessions()
            await live.run()
            model.endLiveSessions()
        }
        .onChange(of: live.sessions) { syncLive() }
        .onChange(of: live.readFailure) { syncLive() }
        .onChange(of: live.state) { syncLive() }
        .onChange(of: live.failure) { syncLive() }
        // A chart's new window is read as soon as it is chosen, without waiting for the next poll.
        .task(id: model.ranges) {
            guard scenePhase == .active else { return }
            await model.loadCharts(client: client, sessionState: sessionState)
        }
        .refreshable {
            await model.load(client: client, sessionState: sessionState, forceRefresh: true)
            await live.refresh(force: true)
        }
    }

    private func syncLive() {
        model.applyLive(sessions: live.sessions, readFailure: live.readFailure, state: live.state, failure: live.failure)
    }
}

/// A failed stats refresh while earlier numbers are still on screen.
struct PartialFailureBanner: View {
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, icon: .triangleAlert)
                .bloemText(.bodyMedium)
                .foregroundStyle(.bloemWarn)
            Button("Try again", action: onRetry)
                .buttonStyle(.bloemSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.l)
        .bloemCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboard-partial-failure")
    }
}
