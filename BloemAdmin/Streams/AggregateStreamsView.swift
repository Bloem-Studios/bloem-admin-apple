import SwiftUI

/// "All servers" version of `StreamsListView`: one section per server,
/// fanned out concurrently (item 2's `fanOut`, via `AggregateStreamsViewModel`)
/// rather than a single server's `client`. A server whose section failed to
/// load (no stored token, expired token, non-admin, network error) renders a
/// compact "tap to sign in" row instead of a session list; tapping it offers
/// a lightweight re-login sheet scoped to just that server (see
/// `SectionReLoginView` below — a v1 fallback, not the full single-server
/// `ReLoginView`, since that type is private to AdminGateView.swift; it
/// reuses the SAME `AdminGateViewModel.reLoginAndResetSession` networking +
/// hardened post-re-login cleanup, shared with `ReLoginView`).
struct AggregateStreamsView: View {
    let servers: [AdminServer]
    let store: ServerStore
    let sessionState: AdminSessionState
    /// The ONE shared `APIClient` per server —
    /// `AllServersView` owns this (see its doc comment) so every tab
    /// observes the same identity for a given server rather than each tab
    /// caching its own admin-token-only client (Stage 2 review C1/C2).
    let resolveClient: ServerClientResolver
    /// The platform administrator's page passes true; an organization context never does.
    var showClientIP = false
    @State private var viewModel = AggregateStreamsViewModel()
    @State private var reAuthServer: AdminServer?

    var body: some View {
        List {
            ForEach(servers) { server in
                Section(server.displayName) {
                    // Pure lookups only (review finding I4) — `loadAll`
                    // pre-populates both per-server caches before any
                    // network I/O, so `body` never inserts into this
                    // @Observable class's storage mid-render. Until the
                    // first `loadAll` has run (the very first frame), this
                    // is nil and the section shows a loading placeholder.
                    if let sectionViewModel = viewModel.existingViewModel(for: server) {
                        if let failure = viewModel.failure(for: server) {
                            ServerSectionFailureView(
                                failure: failure,
                                server: server,
                                onSignIn: { reAuthServer = server },
                                onRetry: {
                                    Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) }
                                }
                            )
                        } else if sectionViewModel.sessions.isEmpty {
                            Text("No active streams").foregroundStyle(.bloemMuted)
                        } else {
                            if let message = sectionViewModel.actionErrorMessage {
                                StreamActionErrorRow(message: message) { sectionViewModel.dismissActionError() }
                            }
                            ForEach(sectionViewModel.sessions) { session in
                                // Scoping the environment HERE (not once for the whole aggregate
                                // shell) lets the row's controls be reused unchanged: they read
                                // `adminSessionState` from the environment exactly as in
                                // single-server mode, just bound to THIS row's server id.
                                StreamControlledRow(
                                    session: session,
                                    client: resolveClient(server),
                                    viewModel: sectionViewModel,
                                    showClientIP: showClientIP,
                                    refreshAfterMutation: {
                                        await viewModel.refreshAfterDetailMutation(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
                                    }
                                )
                                .environment(\.adminSessionState, sessionState.scoped(to: server.id))
                            }
                        }
                    } else {
                        ProgressView()
                    }
                }
            }
        }
        .navigationTitle("Now playing · All servers")
        // Read on open, then whenever a server's `sessions` channel changes; a server whose socket has been
        // down for three attempts is read at most once a minute.
        .liveRefreshAll(
            servers: servers, resolveClient: resolveClient, channels: [.sessions],
            initial: {
                await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient)
                // The app's first page has shown data from a server: the one moment iOS may ask about notifications.
                if servers.contains(where: { viewModel.existingViewModel(for: $0) != nil && viewModel.failure(for: $0) == nil }) {
                    PushRuntime.shared.firstPageLoaded()
                }
            },
            onSignals: { server, _ in
                await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient)
            }
        )
        .refreshable { await viewModel.loadAll(servers: servers, store: store, sessionState: sessionState, resolveClient: resolveClient) }
        .sheet(item: $reAuthServer) { server in
            SectionReLoginView(server: server, store: store, sessionState: sessionState) {
                Task { await viewModel.reload(server: server, store: store, sessionState: sessionState, resolveClient: resolveClient) }
            }
        }
    }
}

/// Shared typed recovery row used by every All Servers section. Only an
/// actual signed-out/expired credential offers Sign In; transient and
/// incompatible failures offer Retry, while forbidden access is explanatory.
struct ServerSectionFailureView: View {
    let failure: ServerSectionFailure
    let server: AdminServer
    let onSignIn: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.summary, icon: icon)
                .foregroundStyle(failure.kind == .forbidden ? Theme.warn : Theme.danger)
            if let detail = failure.detail {
                DisclosureGroup {
                    Text(detail).bloemText(.bodySmall).foregroundStyle(.bloemMuted).textSelection(.enabled)
                } label: {
                    Text("Details").bloemText(.labelMedium).foregroundStyle(.bloemMuted)
                }
            }
            switch failure.recoveryAction {
            case .signIn:
                Button("Sign in", action: onSignIn)
                    .buttonStyle(.bloemSecondary)
                    .accessibilityHint("Sign in to \(server.displayName)")
            case .retry:
                Button("Try again", action: onRetry)
                    .buttonStyle(.bloemSecondary)
                    .accessibilityHint("Retry loading \(server.displayName)")
            case .none:
                EmptyView()
            }
        }
    }

    private var icon: BloemIcon { failure.kind.icon }
}

/// Minimal per-section re-login form. Deliberately a NEW, small view rather
/// than reusing AdminGateView.swift's `ReLoginView` type directly, since
/// that type is `private` to that file (scoped to the single-server gate
/// flow). What IS reused is the actual re-login logic:
/// `AdminGateViewModel.reLoginAndResetSession(username:password:server:store:sessionState:)`
/// — the same Keychain-token rewrite + re-check + hardened post-re-login
/// session cleanup used by single-server mode's `ReLoginView` — so this
/// sheet is a thin wrapper around already-tested behavior, not a
/// re-implementation of it.
///
/// Deliberately internal (not `private` to this file) — every one of the six
/// other "All servers" aggregate tabs (Activity/Jobs/Requests/Users/Server
/// Config/Audit) reuses this exact same sheet for their own per-section
/// "tap to sign in" affordance, rather than each defining its own copy.
struct SectionReLoginView: View {
    let server: AdminServer
    let store: ServerStore
    let sessionState: AdminSessionState
    let onSuccess: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var gateViewModel = AdminGateViewModel()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sign in again to \(server.displayName) to include it in All Servers.")
                        .foregroundStyle(.bloemMuted)
                }
                // reLoginAndResetSession (shared with AdminGateView.swift's ReLoginView, see its
                // doc comment, review finding I3) clears this server's mid-session-401 flag on
                // success, so this cleanup can never again be silently omitted by one of the two
                // call sites the way this view initially did.
                ReLoginSections(server: server, store: store, viewModel: gateViewModel, sessionState: sessionState) {
                    onSuccess()
                    dismiss()
                }
            }
            .navigationTitle(server.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
